// ame-tajikara: 電源プロファイルを読む / 変える(powerprofilesctl の代わり)。
// 名前は力の神、天手力男神(あめのたぢからお)から。
//
//   ame-tajikara                 今のプロファイル(power-saver / balanced / performance)を 1 行
//   ame-tajikara set <名前>      変える(power-saver・balanced・performance)
//   ame-tajikara restore         最後に set したプロファイルに戻す(ログインのとき)
//
// power-profiles-daemon に D-Bus で直接たずねる(新しい名前 org.freedesktop.UPower.PowerProfiles、無ければ古い net.hadess.PowerProfiles)。
// set したものは $XDG_STATE_HOME/ame-shell/power に覚える(デーモンが起動のたびに別のものに戻すことがあるので)。
// 終了コード: 0 できた / 1 デーモンが無い・変えられない / 2 使い方の誤り
const std = @import("std");
const sysbus = @import("sysbus.zig");

const Svc = struct { dest: [*:0]const u8, path: [*:0]const u8 };
const services = [_]Svc{
    .{ .dest = "org.freedesktop.UPower.PowerProfiles", .path = "/org/freedesktop/UPower/PowerProfiles" },
    .{ .dest = "net.hadess.PowerProfiles", .path = "/net/hadess/PowerProfiles" },
};
const names = [_][:0]const u8{ "power-saver", "balanced", "performance" };

fn usage() noreturn {
    std.io.getStdErr().writeAll("使い方: ame-tajikara [set power-saver|balanced|performance | restore]\n") catch {};
    std.process.exit(2);
}

/// 名前が正しければ、その(0 終わりの)名前
fn known(v: []const u8) ?[*:0]const u8 {
    for (names) |n| if (std.mem.eql(u8, v, n)) return n;
    return null;
}

fn statePath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |x| if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell/power", .{x}) catch null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/ame-shell/power", .{std.posix.getenv("HOME") orelse return null}) catch null;
}

fn save(name: []const u8) void {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb) orelse return;
    if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
    std.fs.cwd().writeFile(.{ .sub_path = p, .data = name }) catch {};
}

fn saved() ?[*:0]const u8 {
    var pb: [512]u8 = undefined;
    var b: [32]u8 = undefined;
    const s = std.fs.cwd().readFile(statePath(&pb) orelse return null, &b) catch return null;
    return known(std.mem.trim(u8, s, " \n"));
}

pub fn main() u8 {
    var args = std.process.args();
    _ = args.next();
    var want: ?[*:0]const u8 = null;
    var remember = false;
    if (args.next()) |s| {
        if (std.mem.eql(u8, s, "restore")) {
            if (args.next() != null) usage();
            want = saved() orelse return 0; // 覚えていなければ何もしない
        } else if (std.mem.eql(u8, s, "set")) {
            want = known(args.next() orelse usage()) orelse usage();
            if (args.next() != null) usage();
            remember = true;
        } else usage();
    }
    var bus = sysbus.Bus.open() orelse {
        std.log.err("システムの D-Bus に接続できません", .{});
        return 1;
    };
    defer bus.close();
    var buf: [32]u8 = undefined;
    for (services) |s| {
        // 先に読んで、そのサービスがあるかを確かめる
        const cur = bus.getStr(s.dest, s.path, s.dest, "ActiveProfile", &buf) orelse continue;
        if (want) |w| {
            if (!std.mem.eql(u8, cur, std.mem.span(w)) and !bus.setStr(s.dest, s.path, s.dest, "ActiveProfile", w)) {
                std.log.err("変えられません: {s}", .{bus.err()});
                return 1;
            }
            if (remember) save(std.mem.span(w));
            return 0;
        }
        std.io.getStdOut().writer().print("{s}\n", .{cur}) catch {};
        return 0;
    }
    std.log.err("power-profiles-daemon が動いていません: {s}", .{bus.err()});
    return 1;
}

test "プロファイルの名前" {
    try std.testing.expect(known("balanced") != null);
    try std.testing.expect(known("turbo") == null);
}
