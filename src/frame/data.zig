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
        // musl の struct statvfs は translate-c で不透明型になるので、先頭 5 項目(64bit では
        // glibc・musl とも bsize, frsize, blocks, bfree, bavail の u64)だけを読む。
        var vfs: [32]u64 = undefined;
        if (statvfs_raw("/", &vfs) == 0) {
            const bs: f64 = @floatFromInt(vfs[1]);
            const total = @as(f64, @floatFromInt(vfs[2])) * bs;
            const avail = @as(f64, @floatFromInt(vfs[4])) * bs;
            self.disk_total = @floatCast(total / (1 << 30));
            self.disk_used = @floatCast((total - avail) / (1 << 30));
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
    var b: [64]u8 = undefined;
    const s = sys.readFile("/proc/uptime", &b) orelse return "";
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    const secs: u64 = @intFromFloat(std.fmt.parseFloat(f64, it.next() orelse "0") catch 0);
    const h = secs / 3600;
    const m = (secs % 3600) / 60;
    if (h > 0) return std.fmt.bufPrint(buf, "起動から {d}時間{d}分", .{ h, m }) catch "";
    return std.fmt.bufPrint(buf, "起動から {d}分", .{m}) catch "";
}

pub fn osName(buf: []u8) []const u8 {
    var b: [1024]u8 = undefined;
    const s = sys.readFile("/etc/os-release", &b) orelse return "Linux";
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "PRETTY_NAME=")) {
            const v = std.mem.trim(u8, l[12..], "\"");
            const n = @min(v.len, buf.len);
            @memcpy(buf[0..n], v[0..n]);
            return buf[0..n];
        }
    }
    return "Linux";
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
        // %t 気温 / %C 天気(日本語)/ %x 天気記号(アイコン選択用)/ %l 場所(IP から推定)
        const fd = sys.spawnReader(&.{ "curl", "-sf", "--max-time", "8", "https://wttr.in/?format=%t|%C|%x|%l&lang=ja" }, &self.pid) orelse return;
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
