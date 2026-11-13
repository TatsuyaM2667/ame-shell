// 枠 UI(caelestia 風)が使う追加のデータ源。全て「必要な間だけ」動かす:
//  * GPU/CPU 温度・GPU 使用率・ストレージ … ダッシュボードが開いている間の 1 秒ティックで読む
//  * 天気 … wttr.in を ame-kuraokami(ame-yatagarasu)で非同期取得(30 分キャッシュ)。完了は pipe の EOF で知る
//  * 音声スペクトラム … メディアタブ・ロック画面で曲が流れている間だけ、録音して FFT(cava は使わない)
//  * 電源プロファイル … ame-tajikara(src/cmd)(ユーティリティを開いたとき)
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

    /// 30 分以上経っていれば取り直す(ダッシュボードを開いたときに呼ぶ)。取るのは ame-kuraokami(src/cmd/ame-kuraokami.zig)
    pub fn refresh(self: *Weather) void {
        if (self.fd >= 0) return;
        if (self.fetched_ms != 0 and loop.nowMs() - self.fetched_ms < 30 * 60 * 1000) return;
        self.len = 0;
        // 場所は shell { weather-location "Sapporo" }。無ければ IP アドレスから推定
        var lb: [128]u8 = undefined;
        const loc = std.fmt.bufPrintZ(&lb, "{s}", .{self.app.cfg.weather_location.get()}) catch return;
        const fd = sys.spawnReader(&.{ "ame-kuraokami", "--json", loc.ptr }, &self.pid) orelse return;
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
// 音声スペクトラム(メディアの波形)。cava の代わりの小さな道具 ame-hamon(odin/ame-hamon)を動かし、
// 1 行 = 棒の高さ(0〜1000)を ';' でつないだもの を読むだけ(録音・FFT・音量のそろえは向こうがする)。
//  * 見えている間だけ動かす(start / stop)。無音の間は向こうが何も書かないので、描画も起きない
// ---------------------------------------------------------------------------

pub const BARS = 48;

pub const Spectrum = struct {
    app: *App,
    /// ame-hamon の出力を読む fd(動いていなければ -1)
    fd: c_int = -1,
    pid: c_int = 0,
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
    /// 行の途中までを持っておく
    part: [BARS * 6]u8 = undefined,
    part_len: usize = 0,

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
            .missing => "音を取り込めないため波形を表示できません(ame-hamon が必要です)",
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
        if (!sys.hasCommand("ame-hamon")) {
            if (self.state != .missing) std.log.warn("spectrum: ame-hamon が見つかりません。メディアの波形は表示されません", .{});
            self.state = .missing;
            return;
        }
        self.fd = sys.spawnReader(&.{ "ame-hamon", "-b", std.fmt.comptimePrint("{d}", .{BARS}) }, &self.pid) orelse {
            self.state = .failed;
            return;
        };
        self.part_len = 0;
        self.started_ms = now;
        self.sound_ms = 0;
        if (self.state != .ok) self.state = .idle;
        self.app.loop.add(self.fd, c.EPOLLIN, self, onRead) catch {};
    }

    pub fn stop(self: *Spectrum) void {
        if (self.fd < 0) return;
        // SIGCHLD は無視しているので、子は自動で片付く
        if (self.pid > 0) _ = c.kill(self.pid, c.SIGTERM);
        self.app.loop.remove(self.fd);
        _ = c.close(self.fd);
        self.fd = -1;
        self.pid = 0;
        @memset(&self.values, 0);
    }

    fn onRead(ctx: *anyopaque, fd: c_int, events: u32) void {
        const self: *Spectrum = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var got = false;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) {
                if (n == 0 or events & c.EPOLLHUP != 0) {
                    std.log.warn("spectrum: ame-hamon が止まりました(音を取り込めない)", .{});
                    self.state = .failed;
                    self.stop();
                    if (self.on_frame) |f| f(self.ctx);
                    return;
                }
                break;
            }
            for (buf[0..@intCast(n)]) |ch| {
                if (ch != '\n') {
                    if (self.part_len < self.part.len) self.part[self.part_len] = ch;
                    self.part_len += 1;
                    continue;
                }
                if (self.part_len <= self.part.len and parseBars(self.part[0..self.part_len], &self.values)) got = true;
                self.part_len = 0;
            }
        }
        if (!got) return;
        for (self.values) |v| if (v > 0.04) {
            self.sound_ms = loop.nowMs();
            self.state = .ok;
            break;
        };
        if (self.on_frame) |f| f(self.ctx);
    }
};

/// 「12;0;1000;…;」を 0..1 にして out に入れる。本数が合わなければ false
fn parseBars(line: []const u8, out: *[BARS]f32) bool {
    var tmp: [BARS]f32 = undefined;
    var it = std.mem.tokenizeScalar(u8, line, ';');
    var i: usize = 0;
    while (it.next()) |s| : (i += 1) {
        if (i >= BARS) return false;
        const v = std.fmt.parseInt(u32, s, 10) catch return false;
        tmp[i] = @as(f32, @floatFromInt(@min(v, 1000))) / 1000;
    }
    if (i != BARS) return false;
    out.* = tmp;
    return true;
}

test "スペクトラムの行" {
    var v: [BARS]f32 = undefined;
    var line: [BARS * 5]u8 = undefined;
    var len: usize = 0;
    for (0..BARS) |i| {
        const s = std.fmt.bufPrint(line[len..], "{d};", .{if (i == 0) @as(u32, 1000) else 0}) catch unreachable;
        len += s.len;
    }
    try std.testing.expect(parseBars(line[0..len], &v));
    try std.testing.expectEqual(@as(f32, 1), v[0]);
    try std.testing.expectEqual(@as(f32, 0), v[1]);
    try std.testing.expect(!parseBars("1;2;3;", &v));
    try std.testing.expect(!parseBars("x;", &v));
}

// ---------------------------------------------------------------------------
// 電源プロファイル(power-profiles-daemon)
// ---------------------------------------------------------------------------

pub const Profile = enum { unknown, saver, balanced, performance };

pub fn powerProfile() Profile {
    var out: [64]u8 = undefined;
    const s = sys.run(&.{"ame-tajikara"}, &out) orelse return .unknown;
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
    _ = sys.run(&.{ "ame-tajikara", "set", name }, &out);
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
