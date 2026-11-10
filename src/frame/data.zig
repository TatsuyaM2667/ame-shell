// 枠 UI(caelestia 風)が使う追加のデータ源。全て「必要な間だけ」動かす:
//  * GPU/CPU 温度・GPU 使用率・ストレージ … ダッシュボードが開いている間の 1 秒ティックで読む
//  * 天気 … wttr.in を curl で非同期取得(30 分キャッシュ)。完了は pipe の EOF で知る
//  * 音声スペクトラム … メディアタブ・ロック画面で曲が流れている間だけ、録音して FFT(cava は使わない)
//  * 電源プロファイル … powerprofilesctl(ユーティリティを開いたとき)
const std = @import("std");
const c = @import("../c.zig");
const sys = @import("../platform/sys.zig");
const loop = @import("../platform/loop.zig");
const App = @import("../core/app.zig").App;
const is_bsd = @import("builtin").os.tag == .freebsd;
const bsd = @import("../platform/bsd.zig");

fn readHwmon(name: []const u8, file: []const u8) ?f32 {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        var p: [96]u8 = undefined;
        var b: [64]u8 = undefined;
        const np = std.fmt.bufPrintZ(&p, "/sys/class/hwmon/hwmon{d}/name", .{i}) catch return null;
        const n = sys.readFile(np, &b) orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        const fp = std.fmt.bufPrintZ(&p, "/sys/class/hwmon/hwmon{d}/{s}", .{ i, file }) catch return null;
        const v = sys.readFile(fp, &b) orelse return null;
        return @as(f32, @floatFromInt(std.fmt.parseInt(i64, v, 10) catch return null)) / 1000.0;
    }
    return null;
}

extern fn statvfs(path: [*:0]const u8, buf: *anyopaque) c_int;
fn statvfs_raw(path: [*:0]const u8, buf: *[32]u64) c_int {
    return statvfs(path, buf);
}

pub const Perf = struct {
    gpu_busy: ?f32 = null, // 0..1
    gpu_temp: ?f32 = null,
    cpu_temp: ?f32 = null,
    disk_used: f32 = 0, // GiB
    disk_total: f32 = 0,
    mem_used: f32 = 0, // GiB
    mem_total: f32 = 0,

    pub fn sample(self: *Perf) void {
        var b: [32]u8 = undefined;
        self.gpu_busy = null;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var p: [96]u8 = undefined;
            const gp = std.fmt.bufPrintZ(&p, "/sys/class/drm/card{d}/device/gpu_busy_percent", .{i}) catch break;
            if (sys.readFile(gp, &b)) |v| {
                self.gpu_busy = (std.fmt.parseFloat(f32, v) catch 0) / 100;
                break;
            }
        }
        self.gpu_temp = readHwmon("amdgpu", "temp1_input");
        // CPU: AMD は k10temp、Intel は coretemp。無ければ thermal_zone の最大値
        self.cpu_temp = readHwmon("k10temp", "temp1_input") orelse readHwmon("coretemp", "temp1_input") orelse sys.cpuTemp();
        // musl の struct statvfs は translate-c で不透明型になるので、u64 の並びとして読む。
        // 64bit の並び: Linux(glibc・musl)は bsize, frsize, blocks, bfree, bavail …、
        // FreeBSD は bavail, bfree, blocks, favail, ffree, files, bsize, flag, frsize …
        const I = if (is_bsd) .{ .frsize = 8, .blocks = 2, .bavail = 0 } else .{ .frsize = 1, .blocks = 2, .bavail = 4 };
        var vfs: [32]u64 = undefined;
        if (statvfs_raw("/", &vfs) == 0) {
            const bs: f64 = @floatFromInt(vfs[I.frsize]);
            const total = @as(f64, @floatFromInt(vfs[I.blocks])) * bs;
            const avail = @as(f64, @floatFromInt(vfs[I.bavail])) * bs;
            self.disk_total = @floatCast(total / (1 << 30));
            self.disk_used = @floatCast((total - avail) / (1 << 30));
        }
        if (is_bsd) {
            if (bsd.memory()) |m| {
                self.mem_total = @floatCast(m.total / (1 << 30));
                self.mem_used = @floatCast(m.used / (1 << 30));
            }
            return;
        }
        var mb: [2048]u8 = undefined;
        if (sys.readFile("/proc/meminfo", &mb)) |s| {
            var total: f32 = 0;
            var avail: f32 = 0;
            var lines = std.mem.splitScalar(u8, s, '\n');
            while (lines.next()) |l| {
                var it = std.mem.tokenizeAny(u8, l, ": ");
                const k = it.next() orelse continue;
                const v = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
                if (std.mem.eql(u8, k, "MemTotal")) total = v;
                if (std.mem.eql(u8, k, "MemAvailable")) avail = v;
            }
            self.mem_total = total / (1024 * 1024);
            self.mem_used = (total - avail) / (1024 * 1024);
        }
    }
};

pub fn uptime(buf: []u8) []const u8 {
    const secs: u64 = if (is_bsd) bsd.uptimeSecs() orelse return "" else blk: {
        var b: [64]u8 = undefined;
        const s = sys.readFile("/proc/uptime", &b) orelse return "";
        var it = std.mem.tokenizeScalar(u8, s, ' ');
        break :blk @intFromFloat(std.fmt.parseFloat(f64, it.next() orelse "0") catch 0);
    };
    const h = secs / 3600;
    const m = (secs % 3600) / 60;
    if (h > 0) return std.fmt.bufPrint(buf, "起動から {d}時間{d}分", .{ h, m }) catch "";
    return std.fmt.bufPrint(buf, "起動から {d}分", .{m}) catch "";
}

pub fn osName(buf: []u8) []const u8 {
    var b: [1024]u8 = undefined;
    const fallback = if (is_bsd) "FreeBSD" else "Linux";
    const s = sys.readFile("/etc/os-release", &b) orelse return fallback;
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "PRETTY_NAME=")) {
            const v = std.mem.trim(u8, l[12..], "\"");
            const n = @min(v.len, buf.len);
            @memcpy(buf[0..n], v[0..n]);
            return buf[0..n];
        }
    }
    return fallback;
}

// ---------------------------------------------------------------------------
// 天気(wttr.in)
// ---------------------------------------------------------------------------

pub const Weather = struct {
    app: *App,
    fd: c_int = -1,
    pid: c_int = 0,
    buf: [512]u8 = undefined,
    len: usize = 0,
    fetched_ms: u64 = 0,
    ok: bool = false,
    temp: [16]u8 = undefined,
    temp_len: usize = 0,
    cond: [64]u8 = undefined,
    cond_len: usize = 0,
    place: [64]u8 = undefined,
    place_len: usize = 0,
    symbol: [8]u8 = undefined,
    symbol_len: usize = 0,
    on_update: ?*const fn (ctx: *anyopaque) void = null,
    ctx: *anyopaque = undefined,

    /// 30 分以上経っていれば取り直す(ダッシュボードを開いたときに呼ぶ)。取るのは ame-weather(src/cmd/ame-weather.zig)
    pub fn refresh(self: *Weather) void {
        if (self.fd >= 0) return;
        if (self.fetched_ms != 0 and loop.nowMs() - self.fetched_ms < 30 * 60 * 1000) return;
        self.len = 0;
        // 場所は shell { weather-location "Sapporo" }。無ければ IP アドレスから推定
        var lb: [128]u8 = undefined;
        const loc = std.fmt.bufPrintZ(&lb, "{s}", .{self.app.cfg.weather_location.get()}) catch return;
        const fd = sys.spawnReader(&.{ "ame-weather", "--json", loc.ptr }, &self.pid) orelse return;
        self.fd = fd;
        self.app.loop.add(fd, c.EPOLLIN | c.EPOLLHUP, self, onRead) catch {
            _ = c.close(fd);
            self.fd = -1;
        };
    }

    /// 取得中なら止める(Frame を壊す前に。epoll に解放済みの self を残さない)
    pub fn cancel(self: *Weather) void {
        if (self.fd < 0) return;
        self.app.loop.remove(self.fd);
        _ = c.close(self.fd);
        self.fd = -1;
        if (self.pid > 0) _ = c.kill(self.pid, c.SIGTERM);
        self.pid = 0;
    }

    fn onRead(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Weather = @ptrCast(@alignCast(ctx));
        const n = c.read(fd, self.buf[self.len..].ptr, self.buf.len - self.len);
        if (n > 0) {
            self.len += @intCast(n);
            if (self.len < self.buf.len) return;
        }
        self.app.loop.remove(fd);
        _ = c.close(fd);
        self.fd = -1;
        self.fetched_ms = loop.nowMs();
        const R = struct { temp: []const u8, condition: []const u8, symbol: []const u8, place: []const u8 };
        const p = std.json.parseFromSlice(R, std.heap.c_allocator, std.mem.trim(u8, self.buf[0..self.len], " \n"), .{ .ignore_unknown_fields = true }) catch return;
        defer p.deinit();
        copy(&self.temp, &self.temp_len, p.value.temp);
        copy(&self.cond, &self.cond_len, p.value.condition);
        copy(&self.symbol, &self.symbol_len, p.value.symbol);
        copy(&self.place, &self.place_len, p.value.place);
        self.ok = true;
        if (self.on_update) |f| f(self.ctx);
    }

    fn copy(dst: []u8, len: *usize, src: []const u8) void {
        len.* = @min(src.len, dst.len);
        @memcpy(dst[0..len.*], src[0..len.*]);
        while (len.* > 0 and len.* < src.len and (dst[len.* - 1] & 0xC0) == 0x80) len.* -= 1;
    }

    /// 天気記号 → Nerd Font アイコン(夜は月。lib/weather.zig)
    pub fn icon(self: *const Weather) []const u8 {
        const hour = @import("../desktop/bar.zig").localTime().tm_hour;
        return @import("ame_lib").weather.icon(self.symbol[0..self.symbol_len], hour < 6 or hour >= 18);
    }
};

// ---------------------------------------------------------------------------
// 音声スペクトラム(メディアの波形)。cava を使わず ame-shell の中で計算する:
//  * 音: PulseAudio 互換の録音 API(libpulse-simple を実行時に読み込む。PipeWire の pipewire-pulse でも
//    動く)で「今鳴っている音」(@DEFAULT_MONITOR@)を別スレッドで受け取る
//  * 計算: 窓をかけて FFT(anim/fft.odin)、50Hz〜12kHz を対数で 48 の帯域に分け、dB にして自動で音量をそろえる
//  * 受け取るたびにスレッドが pipe に 1 バイト書き、描画のループ(epoll)で計算する(ポーリングしない)
// ---------------------------------------------------------------------------

pub const BARS = 48;
const FFT_N = 1024;
const RATE = 44100;
const CHUNK = RATE / 60; // 1 回に受け取るサンプル数(約 60 回/秒)

const PaSampleSpec = extern struct { format: c_int, rate: u32, channels: u8 };
const PaBufferAttr = extern struct { maxlength: u32, tlength: u32, prebuf: u32, minreq: u32, fragsize: u32 };
const PaNew = *const fn (?[*:0]const u8, [*:0]const u8, c_int, ?[*:0]const u8, [*:0]const u8, *const PaSampleSpec, ?*anyopaque, ?*const PaBufferAttr, *c_int) callconv(.C) ?*anyopaque;
const PaRead = *const fn (*anyopaque, *anyopaque, usize, *c_int) callconv(.C) c_int;
const PaFree = *const fn (*anyopaque) callconv(.C) void;
const Pa = struct { new: PaNew, read: PaRead, free: PaFree };
var pa_api: ?Pa = null;
var pa_tried = false;

fn loadPa() ?Pa {
    if (pa_tried) return pa_api;
    pa_tried = true;
    const h = c.dlopen("libpulse-simple.so.0", c.RTLD_NOW) orelse c.dlopen("libpulse-simple.so", c.RTLD_NOW) orelse return null;
    const n = c.dlsym(h, "pa_simple_new") orelse return null;
    const r = c.dlsym(h, "pa_simple_read") orelse return null;
    const fr = c.dlsym(h, "pa_simple_free") orelse return null;
    pa_api = .{ .new = @ptrCast(n), .read = @ptrCast(r), .free = @ptrCast(fr) };
    return pa_api;
}

/// FFT の表(窓・回転子・帯域の区切り)。一度だけ作る
const Tables = struct {
    window: [FFT_N]f32,
    tw: [FFT_N]f32, // cos, sin を N/2 組
    edges: [BARS + 1]i32,
};
var tables: ?Tables = null;

fn getTables() *const Tables {
    if (tables == null) {
        var t: Tables = undefined;
        const nf: f32 = @floatFromInt(FFT_N);
        for (0..FFT_N) |i| {
            const fi: f32 = @floatFromInt(i);
            t.window[i] = 0.5 - 0.5 * @cos(std.math.tau * fi / (nf - 1));
        }
        for (0..FFT_N / 2) |k| {
            const a = -std.math.tau * @as(f32, @floatFromInt(k)) / nf;
            t.tw[2 * k] = @cos(a);
            t.tw[2 * k + 1] = @sin(a);
        }
        // 50Hz〜12kHz を対数で等分(低い方は 1 ビン以上の幅を保つ)
        const lo_f: f32 = 50;
        const hi_f: f32 = 12000;
        var prev: i32 = 0;
        for (0..BARS + 1) |b| {
            const r = @as(f32, @floatFromInt(b)) / BARS;
            const f = lo_f * std.math.pow(f32, hi_f / lo_f, r);
            var bin: i32 = @intFromFloat(f * nf / RATE);
            if (b > 0 and bin <= prev) bin = prev + 1;
            t.edges[b] = @min(bin, FFT_N / 2 - 1);
            prev = t.edges[b];
        }
        tables = t;
    }
    return &tables.?;
}

pub const Spectrum = struct {
    app: *App,
    /// 受け取りスレッドからの知らせ(読む側の fd。動いていなければ -1)
    fd: c_int = -1,
    wfd: c_int = -1,
    values: [BARS]f32 = [_]f32{0} ** BARS,
    /// 試験用(ame-ctl debug-spectrum): 録音せずに、与えた値を出している扱いにする
    fake: bool = false,
    on_frame: ?*const fn (ctx: *anyopaque) void = null,
    ctx: *anyopaque = undefined,
    /// 波形が出せない理由(メディアタブに表示する)
    state: State = .idle,
    started_ms: u64 = 0,
    /// 最後に 0 でない値が来た時刻
    sound_ms: u64 = 0,
    /// 失敗したときは、しばらく起動し直さない(毎フレーム起動を試みないように)
    retry_ms: u64 = 0,
    last_calc_ms: u64 = 0,
    // 受け取りスレッドと共有するもの
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    ring: [FFT_N]f32 = [_]f32{0} ** FFT_N,
    // 自動で音量をそろえるための、最近の大きい音の目安(dB)
    peak_db: f32 = -30,

    pub const State = enum { idle, ok, missing, failed };

    /// 再生中なのにこれだけの間ずっと無音なら「音を拾えていない」とみなす
    const SILENT_MS = 3000;
    const RETRY_MS = 10_000;

    pub fn running(self: *const Spectrum) bool {
        return self.fd >= 0 or self.fake;
    }

    /// 波形の代わりに出す説明(出せているときは null)
    pub fn problem(self: *const Spectrum) ?[]const u8 {
        return switch (self.state) {
            .missing => "音を取り込めないため波形を表示できません(libpulse が必要です)",
            .failed => "音を取り込めませんでした(PipeWire / PulseAudio を確認)",
            .ok, .idle => if (self.running() and loop.nowMs() -| @max(self.started_ms, self.sound_ms) > SILENT_MS)
                "音を拾えていません(PipeWire / PulseAudio を確認)"
            else
                null,
        };
    }

    pub fn start(self: *Spectrum) void {
        if (self.fd >= 0) return;
        const now = loop.nowMs();
        if ((self.state == .missing or self.state == .failed) and now < self.retry_ms) return;
        self.retry_ms = now + RETRY_MS;
        if (loadPa() == null) {
            if (self.state != .missing) std.log.warn("spectrum: libpulse-simple が見つかりません。メディアの波形は表示されません", .{});
            self.state = .missing;
            return;
        }
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return;
        self.fd = fds[0];
        self.wfd = fds[1];
        self.stop_flag.store(false, .release);
        self.failed_flag.store(false, .release);
        @memset(&self.ring, 0);
        self.thread = std.Thread.spawn(.{}, capture, .{self}) catch {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            self.fd = -1;
            self.wfd = -1;
            self.state = .failed;
            return;
        };
        self.started_ms = now;
        self.sound_ms = 0;
        if (self.state != .ok) self.state = .idle;
        self.app.loop.add(self.fd, c.EPOLLIN, self, onRead) catch {};
    }

    pub fn stop(self: *Spectrum) void {
        if (self.fd < 0) return;
        self.stop_flag.store(true, .release);
        // 受け取りは 1/60 秒ごとに戻ってくるので、すぐ終わる
        if (self.thread) |t| t.join();
        self.thread = null;
        self.app.loop.remove(self.fd);
        _ = c.close(self.fd);
        _ = c.close(self.wfd);
        self.fd = -1;
        self.wfd = -1;
        @memset(&self.values, 0);
    }

    /// 受け取りスレッド: 録音の口を開き、1/60 秒ぶんずつ読んでリングに足す
    fn capture(self: *Spectrum) void {
        const pa = loadPa() orelse return;
        const ss = PaSampleSpec{ .format = 5, .rate = RATE, .channels = 1 }; // PA_SAMPLE_FLOAT32LE・モノラル
        const attr = PaBufferAttr{ .maxlength = std.math.maxInt(u32), .tlength = std.math.maxInt(u32), .prebuf = std.math.maxInt(u32), .minreq = std.math.maxInt(u32), .fragsize = CHUNK * 4 };
        var err: c_int = 0;
        const s = pa.new(null, "ame-shell", 2, "@DEFAULT_MONITOR@", "spectrum", &ss, null, &attr, &err) orelse {
            self.failed_flag.store(true, .release);
            _ = c.write(self.wfd, "F", 1);
            return;
        };
        defer pa.free(s);
        var buf: [CHUNK]f32 = undefined;
        while (!self.stop_flag.load(.acquire)) {
            if (pa.read(s, &buf, @sizeOf(@TypeOf(buf)), &err) < 0) {
                self.failed_flag.store(true, .release);
                _ = c.write(self.wfd, "F", 1);
                return;
            }
            self.mutex.lock();
            // 古いサンプルを前へ詰めて、新しいものを後ろへ
            std.mem.copyForwards(f32, self.ring[0 .. FFT_N - CHUNK], self.ring[CHUNK..]);
            @memcpy(self.ring[FFT_N - CHUNK ..], &buf);
            self.mutex.unlock();
            _ = c.write(self.wfd, "d", 1);
        }
    }

    fn onRead(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Spectrum = @ptrCast(@alignCast(ctx));
        var drain: [64]u8 = undefined;
        var failed = false;
        while (true) {
            const n = c.read(fd, &drain, drain.len);
            if (n <= 0) break;
            for (drain[0..@intCast(n)]) |b| failed = failed or b == 'F';
        }
        if (failed or self.failed_flag.load(.acquire)) {
            std.log.warn("spectrum: 音を取り込めませんでした(@DEFAULT_MONITOR@)", .{});
            self.state = .failed;
            self.stop();
            if (self.on_frame) |f| f(self.ctx);
            return;
        }
        // 描くのは 1 秒に 60 回まで
        const now = loop.nowMs();
        if (now -| self.last_calc_ms < 14) return;
        self.last_calc_ms = now;
        self.compute();
        if (self.on_frame) |f| f(self.ctx);
    }

    fn compute(self: *Spectrum) void {
        const t = getTables();
        var samples: [FFT_N]f32 = undefined;
        self.mutex.lock();
        samples = self.ring;
        self.mutex.unlock();
        var work: [2 * FFT_N]f32 = undefined;
        var bands: [BARS]f32 = undefined;
        @import("../gfx/anim.zig").ame_spectrum(&samples, FFT_N, &t.window, &t.tw, &work, &t.edges, BARS, &bands);
        // dB にして、最近の大きい音を基準に 0..1 へ(静かな曲でも見えるように自動でそろえる)
        var loudest: f32 = -120;
        var db: [BARS]f32 = undefined;
        for (bands, 0..) |p, i| {
            // 高い音ほど小さく出るので少し持ち上げる(ピンクノイズの傾き)
            const tilt = 3.0 * @as(f32, @floatFromInt(i)) / BARS;
            db[i] = 10 * @log10(p + 1e-12) + tilt * 6;
            loudest = @max(loudest, db[i]);
        }
        // 基準は上がるときは速く、下がるときはゆっくり
        self.peak_db = if (loudest > self.peak_db) loudest else self.peak_db - 0.15;
        self.peak_db = @max(self.peak_db, -40);
        const range: f32 = 45;
        var any = false;
        for (0..BARS) |i| {
            const v = std.math.clamp((db[i] - (self.peak_db - range)) / range, 0, 1);
            const target = v * v; // 小さい音を沈めて、山を目立たせる
            // 上がるときはすぐ、下がるときはなめらかに
            self.values[i] = if (target > self.values[i]) target else self.values[i] * 0.82 + target * 0.18;
            if (self.values[i] > 0.04) any = true;
        }
        if (any and loudest > -90) {
            self.sound_ms = loop.nowMs();
            self.state = .ok;
        }
    }
};

// ---------------------------------------------------------------------------
// 電源プロファイル(power-profiles-daemon)
// ---------------------------------------------------------------------------

pub const Profile = enum { unknown, saver, balanced, performance };

pub fn powerProfile() Profile {
    var out: [64]u8 = undefined;
    const s = sys.run(&.{ "powerprofilesctl", "get" }, &out) orelse return .unknown;
    if (std.mem.eql(u8, s, "power-saver")) return .saver;
    if (std.mem.eql(u8, s, "balanced")) return .balanced;
    if (std.mem.eql(u8, s, "performance")) return .performance;
    return .unknown;
}

pub fn setPowerProfile(p: Profile) void {
    const name: [*:0]const u8 = switch (p) {
        .saver => "power-saver",
        .performance => "performance",
        else => "balanced",
    };
    var out: [64]u8 = undefined;
    _ = sys.run(&.{ "powerprofilesctl", "set", name }, &out);
}

// ---------------------------------------------------------------------------
// ハードウェア名(起動時に 1 回だけ読む)
// ---------------------------------------------------------------------------

pub const HwInfo = struct {
    cpu: [96]u8 = undefined,
    cpu_len: usize = 0,
    gpu: [96]u8 = undefined,
    gpu_len: usize = 0,
    model: [96]u8 = undefined,
    model_len: usize = 0,
    disk: [96]u8 = undefined,
    disk_len: usize = 0,
    cores: u32 = 0,

    fn put(dst: []u8, len: *usize, s: []const u8) void {
        const t = std.mem.trim(u8, s, " \t\n");
        len.* = @min(t.len, dst.len);
        @memcpy(dst[0..len.*], t[0..len.*]);
    }

    pub fn cpuName(self: *const HwInfo) []const u8 {
        return self.cpu[0..self.cpu_len];
    }
    pub fn gpuName(self: *const HwInfo) []const u8 {
        return self.gpu[0..self.gpu_len];
    }
    pub fn modelName(self: *const HwInfo) []const u8 {
        return self.model[0..self.model_len];
    }
    pub fn diskName(self: *const HwInfo) []const u8 {
        return self.disk[0..self.disk_len];
    }

    /// gl_renderer: glGetString(GL_RENDERER)("AMD Radeon 680M (radeonsi, …)" の括弧の前を GPU 名にする)
    pub fn load(self: *HwInfo, gl_renderer: []const u8) void {
        // CPU: /proc/cpuinfo の model name("… with Radeon Graphics" の飾りは除く)
        var b: [8192]u8 = undefined;
        if (is_bsd) {
            // FreeBSD: CPU は hw.model、機種はローダが DMI から入れる smbios.* (kenv)
            if (bsd.str("hw.model", &b)) |v0| {
                var v = v0;
                if (std.mem.indexOf(u8, v, " with ")) |i| v = v[0..i];
                put(&self.cpu, &self.cpu_len, v);
            }
            var vb: [96]u8 = undefined;
            var pb: [96]u8 = undefined;
            const vendor = bsd.kenvGet("smbios.system.maker", &vb) orelse "";
            var product = bsd.kenvGet("smbios.system.version", &pb) orelse "";
            if (product.len == 0 or std.mem.indexOf(u8, product, "Default") != null or std.mem.eql(u8, product, "None")) {
                product = bsd.kenvGet("smbios.system.product", &pb) orelse "";
            }
            var mb: [192]u8 = undefined;
            put(&self.model, &self.model_len, std.fmt.bufPrint(&mb, "{s} {s}", .{ vendor, product }) catch product);
        }
        if (!is_bsd) if (sys.readFile("/proc/cpuinfo", &b)) |s| {
            var lines = std.mem.splitScalar(u8, s, '\n');
            while (lines.next()) |l| {
                if (self.cpu_len == 0 and std.mem.startsWith(u8, l, "model name")) {
                    const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
                    var v = std.mem.trim(u8, l[colon + 1 ..], " ");
                    if (std.mem.indexOf(u8, v, " with ")) |i| v = v[0..i];
                    if (std.mem.indexOf(u8, v, " w/ ")) |i| v = v[0..i];
                    put(&self.cpu, &self.cpu_len, v);
                }
            }
        };
        // /proc/cpuinfo は全スレッド分あって大きいので、論理 CPU 数は OS に聞く
        self.cores = @intCast(std.Thread.getCpuCount() catch 0);
        var g = gl_renderer;
        if (std.mem.indexOf(u8, g, " (")) |i| g = g[0..i];
        put(&self.gpu, &self.gpu_len, g);
        // 機種: DMI のメーカー + 型番(product_version に愛称、product_name に型式が入る機種が多い)
        var vb: [96]u8 = undefined;
        var pb: [96]u8 = undefined;
        const vendor = sys.readFile("/sys/class/dmi/id/sys_vendor", &vb) orelse "";
        var product = sys.readFile("/sys/class/dmi/id/product_version", &pb) orelse "";
        if (product.len == 0 or std.mem.indexOf(u8, product, "Default") != null or std.mem.eql(u8, product, "None")) {
            product = sys.readFile("/sys/class/dmi/id/product_name", &pb) orelse "";
        }
        var mb: [192]u8 = undefined;
        if (!is_bsd) put(&self.model, &self.model_len, std.fmt.bufPrint(&mb, "{s} {s}", .{ vendor, product }) catch product);
        // ディスク: 最初の nvme / sd の型番
        for ([_][:0]const u8{ "/sys/block/nvme0n1/device/model", "/sys/block/sda/device/model", "/sys/block/vda/device/model" }) |p| {
            var db: [96]u8 = undefined;
            if (sys.readFile(p, &db)) |s| {
                put(&self.disk, &self.disk_len, s);
                break;
            }
        }
    }
};
