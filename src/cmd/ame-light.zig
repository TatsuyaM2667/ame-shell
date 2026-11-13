// ame-light: 画面の明るさを読む / 変える(brightnessctl の代わり)。
//
//   ame-light                 今の明るさ(0〜100 の数)を 1 行
//   ame-light set 40          40% に(40% とも書ける)
//   ame-light set +5 / -5     5% 明るく / 暗く(brightnessctl の 5%+ / 5%- の書き方も読む)
//   ame-light restore         最後に set した明るさに戻す(起動時。カーネルは再起動のたびにファームウェアの値に戻すので)
//
// set した明るさ(%)は $XDG_STATE_HOME/ame-shell/light に覚える。
//
// /sys/class/backlight の最初の機器を使う。書き込めればそこへ直接、書き込めなければ(ふつうは root だけ)
// logind(elogind)の Session.SetBrightness に頼む(ログイン中の人なら root なしで変えられる)。
// 真っ暗で戻せなくならないよう 1% より下にはしない。
// 終了コード: 0 できた / 1 バックライトが無い・変えられない / 2 使い方の誤り
const std = @import("std");
const sysbus = @import("sysbus.zig");
const c = sysbus.c;

fn usage() noreturn {
    std.io.getStdErr().writeAll("使い方: ame-light [set <0-100 | +N | -N> | restore]\n") catch {};
    std.process.exit(2);
}

/// 「40」「40%」「+5」「-5」「5%+」「5%-」を、新しい生の値(1〜max)にする
fn target(arg: []const u8, cur: u32, max: u32) ?u32 {
    var s = arg;
    var sign: i8 = 0;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        sign = if (s[0] == '+') 1 else -1;
        s = s[1..];
    } else if (s.len > 0 and (s[s.len - 1] == '+' or s[s.len - 1] == '-')) {
        sign = if (s[s.len - 1] == '+') 1 else -1;
        s = s[0 .. s.len - 1];
    }
    if (s.len > 0 and s[s.len - 1] == '%') s = s[0 .. s.len - 1];
    const pct = std.fmt.parseFloat(f64, s) catch return null;
    if (pct < 0 or pct > 100 or max == 0) return null;
    const fmax: f64 = @floatFromInt(max);
    const step = pct / 100 * fmax;
    const want = switch (sign) {
        0 => step,
        1 => @as(f64, @floatFromInt(cur)) + step,
        else => @as(f64, @floatFromInt(cur)) - step,
    };
    const lo = @max(1, fmax / 100);
    return @intFromFloat(@round(std.math.clamp(want, lo, fmax)));
}

const Dev = struct { name: [64]u8 = undefined, name_len: usize = 0, cur: u32 = 0, max: u32 = 0 };

fn readNum(path: []const u8) ?u32 {
    var b: [32]u8 = undefined;
    const s = std.fs.cwd().readFile(path, &b) catch return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, s, " \n"), 10) catch null;
}

fn find() ?Dev {
    var dir = std.fs.cwd().openDir("/sys/class/backlight", .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (e.name.len > 63) continue;
        var p: [128]u8 = undefined;
        var d = Dev{};
        d.max = readNum(std.fmt.bufPrint(&p, "/sys/class/backlight/{s}/max_brightness", .{e.name}) catch continue) orelse continue;
        d.cur = readNum(std.fmt.bufPrint(&p, "/sys/class/backlight/{s}/brightness", .{e.name}) catch continue) orelse continue;
        if (d.max == 0) continue;
        @memcpy(d.name[0..e.name.len], e.name);
        d.name_len = e.name.len;
        return d;
    }
    return null;
}

fn writeSysfs(d: *const Dev, v: u32) bool {
    var p: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&p, "/sys/class/backlight/{s}/brightness", .{d.name[0..d.name_len]}) catch return false;
    const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch return false;
    defer f.close();
    var b: [16]u8 = undefined;
    f.writeAll(std.fmt.bufPrint(&b, "{d}", .{v}) catch return false) catch return false;
    return true;
}

/// logind の Session.SetBrightness("backlight", 名前, 値)。自分のセッションは "auto"、無ければ自分の pid から探す
fn writeLogind(d: *const Dev, v: u32) bool {
    var bus = sysbus.Bus.open() orelse {
        std.log.err("システムの D-Bus に接続できません", .{});
        return false;
    };
    defer bus.close();
    var name: [65:0]u8 = undefined;
    @memcpy(name[0..d.name_len], d.name[0..d.name_len]);
    name[d.name_len] = 0;
    var pb: [128]u8 = undefined;
    const paths = [_]?[*:0]const u8{ "/org/freedesktop/login1/session/auto", sessionByPid(&bus, &pb) };
    for (paths) |maybe| {
        const path = maybe orelse continue;
        const m = c.dbus_message_new_method_call("org.freedesktop.login1", path, "org.freedesktop.login1.Session", "SetBrightness") orelse return false;
        var sub: [*c]const u8 = "backlight";
        var n: [*c]const u8 = &name;
        var val: u32 = v;
        _ = c.dbus_message_append_args(m, c.DBUS_TYPE_STRING, &sub, c.DBUS_TYPE_STRING, &n, c.DBUS_TYPE_UINT32, &val, c.DBUS_TYPE_INVALID);
        if (bus.send(m)) |r| {
            c.dbus_message_unref(r);
            return true;
        }
    }
    std.log.err("明るさを変えられません: {s}", .{bus.err()});
    return false;
}

extern "c" fn getpid() c_int;

fn sessionByPid(bus: *sysbus.Bus, buf: *[128]u8) ?[*:0]const u8 {
    const m = c.dbus_message_new_method_call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetSessionByPID") orelse return null;
    var pid: u32 = @intCast(getpid());
    _ = c.dbus_message_append_args(m, c.DBUS_TYPE_UINT32, &pid, c.DBUS_TYPE_INVALID);
    const r = bus.send(m) orelse return null;
    defer c.dbus_message_unref(r);
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(r, &it) == 0) return null;
    const s = sysbus.copyStr(&it, buf[0..127]) orelse return null;
    buf[s.len] = 0;
    return @ptrCast(buf);
}

fn statePath(buf: []u8) ?[]const u8 {
    var d: [400]u8 = undefined;
    const dir = @import("ame_lib").ai.stateDir(&d) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/light", .{dir}) catch null;
}

fn loadSaved(buf: []u8) ?[]const u8 {
    var pb: [512]u8 = undefined;
    const s = std.fs.cwd().readFile(statePath(&pb) orelse return null, buf) catch return null;
    return std.mem.trim(u8, s, " \n");
}

fn save(pct: u32) void {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb) orelse return;
    if (std.fs.path.dirname(p)) |dir| std.fs.cwd().makePath(dir) catch {};
    var b: [8]u8 = undefined;
    std.fs.cwd().writeFile(.{ .sub_path = p, .data = std.fmt.bufPrint(&b, "{d}", .{pct}) catch return }) catch {};
}

pub fn main() u8 {
    var ab: [4][]const u8 = undefined;
    var n: usize = 0;
    var args = std.process.args();
    _ = args.next();
    while (args.next()) |a| : (n += 1) {
        if (n >= ab.len) usage();
        ab[n] = a;
    }
    const d = find() orelse {
        std.log.err("画面のバックライトが見つかりません(/sys/class/backlight)", .{});
        return 1;
    };
    const out = std.io.getStdOut().writer();
    if (n == 0 or (n == 1 and std.mem.eql(u8, ab[0], "get"))) {
        out.print("{d}\n", .{(d.cur * 100 + d.max / 2) / d.max}) catch {};
        return 0;
    }
    if (n == 1 and std.mem.eql(u8, ab[0], "restore")) {
        var sb: [16]u8 = undefined;
        const saved = loadSaved(&sb) orelse return 0; // 覚えていなければ何もしない
        const v = target(saved, d.cur, d.max) orelse return 0;
        if (v == d.cur) return 0;
        return if (writeSysfs(&d, v) or writeLogind(&d, v)) 0 else 1;
    }
    if (n != 2 or !std.mem.eql(u8, ab[0], "set")) usage();
    const v = target(ab[1], d.cur, d.max) orelse usage();
    if (v != d.cur and !writeSysfs(&d, v) and !writeLogind(&d, v)) return 1;
    save((v * 100 + d.max / 2) / d.max);
    return 0;
}

test "明るさの書き方" {
    try std.testing.expectEqual(@as(?u32, 40), target("40", 10, 100));
    try std.testing.expectEqual(@as(?u32, 40), target("40%", 10, 100));
    try std.testing.expectEqual(@as(?u32, 15), target("+5", 10, 100));
    try std.testing.expectEqual(@as(?u32, 15), target("5%+", 10, 100));
    try std.testing.expectEqual(@as(?u32, 5), target("-5", 10, 100));
    try std.testing.expectEqual(@as(?u32, 5), target("5%-", 10, 100));
    // 1% より下にはしない・上は max まで
    try std.testing.expectEqual(@as(?u32, 3), target("-50", 10, 255));
    try std.testing.expectEqual(@as(?u32, 255), target("+50", 200, 255));
    try std.testing.expectEqual(@as(?u32, null), target("abc", 10, 100));
    try std.testing.expectEqual(@as(?u32, null), target("150", 10, 100));
}
