// ame-power: 電源プロファイルを読む / 変える(powerprofilesctl の代わり)。
//
//   ame-power                 今のプロファイル(power-saver / balanced / performance)を 1 行
//   ame-power set <名前>      変える(power-saver・balanced・performance)
//
// power-profiles-daemon に D-Bus で直接たずねる(新しい名前 org.freedesktop.UPower.PowerProfiles、無ければ古い net.hadess.PowerProfiles)。
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
    std.io.getStdErr().writeAll("使い方: ame-power [set power-saver|balanced|performance]\n") catch {};
    std.process.exit(2);
}

pub fn main() u8 {
    var args = std.process.args();
    _ = args.next();
    const cmd = args.next();
    var want: ?[*:0]const u8 = null;
    if (cmd) |s| {
        if (!std.mem.eql(u8, s, "set")) usage();
        const v = args.next() orelse usage();
        for (names) |n| if (std.mem.eql(u8, v, n)) {
            want = n;
        };
        if (want == null or args.next() != null) usage();
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
            if (bus.setStr(s.dest, s.path, s.dest, "ActiveProfile", w)) return 0;
            std.log.err("変えられません: {s}", .{bus.err()});
            return 1;
        }
        std.io.getStdOut().writer().print("{s}\n", .{cur}) catch {};
        return 0;
    }
    std.log.err("power-profiles-daemon が動いていません: {s}", .{bus.err()});
    return 1;
}
