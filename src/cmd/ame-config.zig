// ame-config: ame-shell の設定ファイル(config.ame)を調べる。
//
//   ame-config check [ファイル]   文法と値を確かめる。問題があれば「ファイル:行: 内容」を標準エラーへ
//                                 終了コード 0 問題なし / 1 警告あり / 2 読めない
//   ame-config path               使う設定ファイルの場所($AME_CONFIG → $XDG_CONFIG_HOME → ~/.config)
//
// ファイルを省くと path の場所。ame-shell は警告があっても起動する(分からない行は無視する)ので、
// 保存したあとに `ame-config check` で確かめると、効いていない行が分かる。
const std = @import("std");
const config = @import("ame_lib").config;

fn usage() noreturn {
    std.io.getStdErr().writeAll(
        \\使い方: ame-config check [ファイル]
        \\        ame-config path
        \\
    ) catch {};
    std.process.exit(2);
}

/// 警告("line N: …")を「ファイル:N: …」の形にして書く(エディタやほかの道具がそのまま読める形)
pub fn report(w: anytype, path: []const u8, diag: []const u8) !usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, diag, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        n += 1;
        if (std.mem.startsWith(u8, l, "line ")) {
            const rest = l[5..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
            try w.print("{s}:{s}:{s}\n", .{ path, rest[0..colon], rest[colon + @intFromBool(colon < rest.len) ..] });
        } else try w.print("{s}: {s}\n", .{ path, l });
    }
    return n;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2) usage();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const eq = std.mem.eql;
    if (eq(u8, args[1], "path")) {
        if (args.len != 2) usage();
        try std.io.getStdOut().writer().print("{s}\n", .{config.userPath(&pb)});
        return;
    }
    if (!eq(u8, args[1], "check") or args.len > 3) usage();
    const path = if (args.len == 3) args[2] else config.userPath(&pb);
    const src = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch |e| {
        std.io.getStdErr().writer().print("ame-config: {s} を読めません({s})\n", .{ path, @errorName(e) }) catch {};
        std.process.exit(2);
    };
    var diag = config.Diag{};
    _ = config.parse(src, .{}, &diag);
    const n = try report(std.io.getStdErr().writer(), path, diag.get());
    if (n > 0) std.process.exit(1);
}

test "report format" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const n = try report(buf.writer(), "c.ame", "line 3: unknown or invalid 'bar.x 1'\nline 9: unmatched '}'\n");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("c.ame:3: unknown or invalid 'bar.x 1'\nc.ame:9: unmatched '}'\n", buf.items);
}
