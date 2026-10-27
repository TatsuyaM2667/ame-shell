// 枠 UI(caelestia 風)が使う追加のデータ源。全て「必要な間だけ」動かす:
//  * GPU/CPU 温度・GPU 使用率・ストレージ … ダッシュボードが開いている間の 1 秒ティックで読む
//  * 天気 … wttr.in を curl で非同期取得(30 分キャッシュ)。完了は pipe の EOF で知る
//  * cava(音声スペクトラム)… メディアタブ表示中だけ起動し、終わったら kill
//  * 電源プロファイル … powerprofilesctl(ユーティリティを開いたとき)
const std = @import("std");
const c = @import("../c.zig");
const sys = @import("../platform/sys.zig");
const loop = @import("../platform/loop.zig");
const App = @import("../app.zig").App;
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

    /// 30 分以上経っていれば取り直す(ダッシュボードを開いたときに呼ぶ)
    pub fn refresh(self: *Weather) void {
        if (self.fd >= 0) return;
        if (self.fetched_ms != 0 and loop.nowMs() - self.fetched_ms < 30 * 60 * 1000) return;
        self.len = 0;
        // %t 気温 / %C 天気(日本語)/ %x 天気記号(アイコン選択用)/ %l 場所。
        // 場所は shell { weather-location "Sapporo" } で指定でき、無ければ IP アドレスから推定
        var ub: [256]u8 = undefined;
        var lb: [96]u8 = undefined;
        var ln: usize = 0;
        for (self.app.cfg.weather_location.get()) |ch| {
            if (ln >= lb.len) break;
            // URL に入れられない文字は落とし、空白は + に(wttr.in の書式)
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == ',' or ch >= 0x80) {
                lb[ln] = ch;
                ln += 1;
            } else if (ch == ' ') {
                lb[ln] = '+';
                ln += 1;
            }
        }
        const url = std.fmt.bufPrintZ(&ub, "https://wttr.in/{s}?format=%t|%C|%x|%l&lang=ja", .{lb[0..ln]}) catch return;
        const fd = sys.spawnReader(&.{ "curl", "-sf", "--max-time", "8", url.ptr }, &self.pid) orelse return;
        self.fd = fd;
        self.app.loop.add(fd, c.EPOLLIN | c.EPOLLHUP, self, onRead) catch {};
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
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, self.buf[0..self.len], " \n"), '|');
        const t = it.next() orelse return;
        const cond = it.next() orelse return;
        const sym = it.next() orelse "";
        const place = it.next() orelse "";
        if (t.len == 0 or std.mem.indexOf(u8, t, "Unknown") != null) return;
        copy(&self.temp, &self.temp_len, std.mem.trimLeft(u8, t, "+"));
        copy(&self.cond, &self.cond_len, cond);
        copy(&self.symbol, &self.symbol_len, sym);
        copy(&self.place, &self.place_len, place);
        self.ok = true;
        if (self.on_update) |f| f(self.ctx);
    }

    fn copy(dst: []u8, len: *usize, src: []const u8) void {
        len.* = @min(src.len, dst.len);
        @memcpy(dst[0..len.*], src[0..len.*]);
        while (len.* > 0 and len.* < src.len and (dst[len.* - 1] & 0xC0) == 0x80) len.* -= 1;
    }

    /// wttr.in の天気記号 → Nerd Font アイコン
    pub fn icon(self: *const Weather) []const u8 {
        const s = self.symbol[0..self.symbol_len];
        const hour = @import("../bar.zig").localTime().tm_hour;
        const night = hour < 6 or hour >= 18;
        if (std.mem.eql(u8, s, "o")) return if (night) "\u{F0594}" else "\u{F0599}"; // 晴れ
        if (std.mem.eql(u8, s, "m")) return if (night) "\u{F0F31}" else "\u{F0595}"; // 晴れ時々曇り
        if (std.mem.eql(u8, s, "mm") or std.mem.eql(u8, s, "mmm")) return "\u{F0590}"; // 曇り
        if (std.mem.eql(u8, s, "=")) return "\u{F0591}"; // 霧
        if (std.mem.indexOf(u8, s, "/!/") != null or std.mem.indexOf(u8, s, "!") != null) return "\u{F0593}"; // 雷
        if (std.mem.indexOf(u8, s, "*") != null) return "\u{F0598}"; // 雪
        if (std.mem.indexOf(u8, s, "/") != null or std.mem.indexOf(u8, s, ".") != null) return "\u{F0597}"; // 雨
        return "\u{F0590}";
    }
};

// ---------------------------------------------------------------------------
// cava(音声スペクトラム)
// ---------------------------------------------------------------------------

pub const BARS = 48;

pub const Cava = struct {
    app: *App,
    fd: c_int = -1,
    pid: c_int = 0,
    buf: [1024]u8 = undefined,
    len: usize = 0,
    values: [BARS]f32 = [_]f32{0} ** BARS,
    on_frame: ?*const fn (ctx: *anyopaque) void = null,
    ctx: *anyopaque = undefined,

    pub fn running(self: *const Cava) bool {
        return self.fd >= 0;
    }

    pub fn start(self: *Cava) void {
        if (self.fd >= 0) return;
        // 設定ファイルを XDG_RUNTIME_DIR に書く(raw 出力、ASCII、; 区切り、改行でフレーム)
        const rt = std.posix.getenv("XDG_RUNTIME_DIR") orelse return;
        var pbuf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pbuf, "{s}/ame-cava.conf", .{rt}) catch return;
        const f = std.fs.cwd().createFile(path, .{}) catch return;
        f.writer().print(
            \\[general]
            \\bars = {d}
            \\framerate = 60
            \\[output]
            \\method = raw
            \\raw_target = /dev/stdout
            \\data_format = ascii
            \\ascii_max_range = 100
            \\bar_delimiter = 59
            \\frame_delimiter = 10
            \\
        , .{BARS}) catch {};
        f.close();
        self.fd = sys.spawnReader(&.{ "cava", "-p", path.ptr }, &self.pid) orelse return;
        self.app.loop.add(self.fd, c.EPOLLIN | c.EPOLLHUP, self, onRead) catch {};
    }

    pub fn stop(self: *Cava) void {
        if (self.fd < 0) return;
        _ = c.kill(self.pid, c.SIGTERM);
        self.app.loop.remove(self.fd);
        _ = c.close(self.fd);
        self.fd = -1;
        self.len = 0;
        @memset(&self.values, 0);
    }

    fn onRead(ctx: *anyopaque, fd: c_int, ev: u32) void {
        const self: *Cava = @ptrCast(@alignCast(ctx));
        const n = c.read(fd, self.buf[self.len..].ptr, self.buf.len - self.len);
        if (n <= 0) {
            if (n == 0 or ev & c.EPOLLHUP != 0) self.stop();
            return;
        }
        self.len += @intCast(n);
        var got = false;
        // 最後の完全な行だけを使う(遅れて溜まった古いフレームは捨てる)
        while (std.mem.indexOfScalar(u8, self.buf[0..self.len], '\n')) |nl| {
            var it = std.mem.splitScalar(u8, self.buf[0..nl], ';');
            var i: usize = 0;
            while (it.next()) |v| {
                if (i >= BARS) break;
                if (v.len == 0) continue;
                self.values[i] = (std.fmt.parseFloat(f32, v) catch 0) / 100;
                i += 1;
            }
            const rest = self.len - nl - 1;
            std.mem.copyForwards(u8, self.buf[0..rest], self.buf[nl + 1 .. self.len]);
            self.len = rest;
            got = true;
        }
        if (self.len == self.buf.len) self.len = 0;
        if (got) if (self.on_frame) |f| f(self.ctx);
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
