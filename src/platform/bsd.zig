// FreeBSD 用のシステム情報(Linux の /proc・/sys の代わり)。
//
// sysctl(8) の値を sysctlbyname(3) で直接読み、無いものは FreeBSD 標準のコマンド
// (ifconfig・mixer・backlight)に聞く。sys.zig / data.zig から、ビルド対象が FreeBSD のときだけ使われる。
const std = @import("std");

extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*const anyopaque, newlen: usize) c_int;
extern "c" fn kenv(action: c_int, name: [*:0]const u8, value: ?[*]u8, len: c_int) c_int;
const KENV_GET = 0;

/// 整数の sysctl(int / long のどちらでも)
pub fn int(name: [*:0]const u8) ?i64 {
    var buf: [8]u8 = [_]u8{0} ** 8;
    var len: usize = buf.len;
    if (sysctlbyname(name, &buf, &len, null, 0) != 0) return null;
    return switch (len) {
        4 => std.mem.readInt(i32, buf[0..4], .little),
        8 => std.mem.readInt(i64, buf[0..8], .little),
        else => null,
    };
}

/// 文字列の sysctl(hw.model など)
pub fn str(name: [*:0]const u8, buf: []u8) ?[]const u8 {
    var len: usize = buf.len;
    if (sysctlbyname(name, buf.ptr, &len, null, 0) != 0 or len == 0) return null;
    return std.mem.trim(u8, std.mem.sliceTo(buf[0..len], 0), " \n\t");
}

/// カーネル環境変数(smbios.system.product など。ローダが DMI から入れる)
pub fn kenvGet(name: [*:0]const u8, buf: []u8) ?[]const u8 {
    const n = kenv(KENV_GET, name, buf.ptr, @intCast(buf.len));
    if (n <= 0) return null;
    return std.mem.trim(u8, std.mem.sliceTo(buf[0..@intCast(n)], 0), " \n\t");
}

// ---- 電源(acpi_battery(4)) ----

pub const Battery = struct { present: bool, percent: u8, charging: bool, on_ac: bool };

pub fn battery() Battery {
    const life = int("hw.acpi.battery.life");
    const acline = int("hw.acpi.acline");
    // hw.acpi.battery.state: ビット 0 = 放電中、ビット 1 = 充電中
    const state = int("hw.acpi.battery.state") orelse 0;
    const present = life != null and life.? >= 0 and (int("hw.acpi.battery.units") orelse 1) > 0;
    return .{
        .present = present,
        .percent = if (present) @intCast(std.math.clamp(life.?, 0, 100)) else 0,
        .charging = (state & 2) != 0 or (present and life.? >= 100 and (acline orelse 0) == 1),
        .on_ac = if (acline) |a| a == 1 else !present,
    };
}

// ---- CPU・メモリ・温度 ----

/// kern.cp_time: user, nice, sys, intr, idle(全 CPU の合計)
pub fn cpuTimes() ?struct { idle: u64, total: u64 } {
    var t: [5]c_long = undefined;
    var len: usize = @sizeOf(@TypeOf(t));
    if (sysctlbyname("kern.cp_time", &t, &len, null, 0) != 0) return null;
    var total: u64 = 0;
    for (t) |v| total += @intCast(@max(v, 0));
    return .{ .idle = @intCast(@max(t[4], 0)), .total = total };
}

/// (使用中, 全体) バイト。使える = 空き + inactive + laundry(Linux の MemAvailable に近い)
pub fn memory() ?struct { used: f64, total: f64 } {
    const page: f64 = @floatFromInt(int("hw.pagesize") orelse return null);
    const total: f64 = @floatFromInt(int("vm.stats.vm.v_page_count") orelse return null);
    const free: f64 = @floatFromInt(int("vm.stats.vm.v_free_count") orelse 0);
    const inactive: f64 = @floatFromInt(int("vm.stats.vm.v_inactive_count") orelse 0);
    const laundry: f64 = @floatFromInt(int("vm.stats.vm.v_laundry_count") orelse 0);
    const avail = free + inactive + laundry;
    return .{ .used = (total - avail) * page, .total = total * page };
}

/// dev.cpu.0.temperature(単位は 0.1 K。coretemp(4) / amdtemp(4) が読み込まれているとき)
pub fn cpuTemp() ?f32 {
    const dk = int("dev.cpu.0.temperature") orelse return null;
    const cel = @as(f32, @floatFromInt(dk)) / 10.0 - 273.15;
    return if (cel > 0 and cel < 150) cel else null;
}

/// 起動からの秒数(kern.boottime は struct timeval)
pub fn uptimeSecs() ?u64 {
    var tv: [2]i64 = undefined;
    var len: usize = @sizeOf(@TypeOf(tv));
    if (sysctlbyname("kern.boottime", &tv, &len, null, 0) != 0) return null;
    const now = std.time.timestamp();
    return if (now > tv[0]) @intCast(now - tv[0]) else 0;
}

// ---- ネットワーク(ifconfig) ----

pub const NetInfo = struct { wifi: bool, connected: bool, name_buf: [64]u8 = undefined, name_len: usize = 0 };

/// 接続中の Wi-Fi(SSID)か有線 IF を探す
pub fn network(run: anytype) NetInfo {
    var n = NetInfo{ .wifi = false, .connected = false };
    var lb: [512]u8 = undefined;
    const list = run(&.{ "ifconfig", "-l" }, &lb) orelse return n;
    var it = std.mem.tokenizeAny(u8, list, " \n");
    var names: [16][32]u8 = undefined;
    var lens: [16]usize = undefined;
    var cnt: usize = 0;
    while (it.next()) |ifn| {
        if (cnt >= names.len) break;
        if (std.mem.startsWith(u8, ifn, "lo") or std.mem.startsWith(u8, ifn, "pflog") or std.mem.startsWith(u8, ifn, "bridge") or std.mem.startsWith(u8, ifn, "tap") or std.mem.startsWith(u8, ifn, "epair")) continue;
        lens[cnt] = @min(ifn.len, 31);
        @memcpy(names[cnt][0..lens[cnt]], ifn[0..lens[cnt]]);
        names[cnt][lens[cnt]] = 0;
        cnt += 1;
    }
    for (0..cnt) |i| {
        var ob: [2048]u8 = undefined;
        const out = run(&.{ "ifconfig", @as([*:0]const u8, @ptrCast(&names[i])) }, &ob) orelse continue;
        const wifi = std.mem.indexOf(u8, out, "ssid ") != null;
        const up = std.mem.indexOf(u8, out, "status: associated") != null or std.mem.indexOf(u8, out, "status: active") != null;
        if (!up) continue;
        n.connected = true;
        n.wifi = wifi;
        var label: []const u8 = names[i][0..lens[i]];
        if (wifi) if (std.mem.indexOf(u8, out, "ssid ")) |p| {
            const rest = out[p + 5 ..];
            const end = std.mem.indexOf(u8, rest, " channel") orelse std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            label = std.mem.trim(u8, rest[0..end], " \"");
        };
        n.name_len = @min(label.len, n.name_buf.len);
        @memcpy(n.name_buf[0..n.name_len], label[0..n.name_len]);
        if (wifi) break;
    }
    return n;
}

// ---- 音量(mixer(8)。PipeWire が無いとき) ----

pub fn mixerVolume(run: anytype) ?struct { level: f32, muted: bool } {
    var b: [128]u8 = undefined;
    // 出力例: "vol.volume=0.75:0.75"
    const s = run(&.{ "mixer", "vol.volume" }, &b) orelse return null;
    const eq = std.mem.indexOfScalar(u8, s, '=') orelse return null;
    const rest = s[eq + 1 ..];
    const end = std.mem.indexOfAny(u8, rest, ":\n") orelse rest.len;
    const v = std.fmt.parseFloat(f32, rest[0..end]) catch return null;
    var mb: [64]u8 = undefined;
    const m = run(&.{ "mixer", "vol.mute" }, &mb) orelse "";
    return .{ .level = v, .muted = std.mem.endsWith(u8, std.mem.trim(u8, m, " \n"), "=1") };
}

// ---- 明るさ(backlight(8)) ----

pub fn backlight(run: anytype) ?f32 {
    var b: [64]u8 = undefined;
    // "backlight -q" は数値(%)だけを出す
    const s = run(&.{ "backlight", "-q" }, &b) orelse return null;
    const v = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \n")) catch return null;
    return v / 100;
}
