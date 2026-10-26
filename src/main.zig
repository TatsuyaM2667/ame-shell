// ame-shell エントリポイント。
const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig").App;

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main() !u8 {
    // 日本語ロケール(xkb の compose / strftime 等のため)
    _ = c.setlocale(c.LC_ALL, "");
    // 子プロセス(ランチャーから起動したアプリ)のゾンビを残さない
    // (musl の SIG_IGN マクロは translate-c できないので std.posix を使う)
    const ign = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.empty_sigset, .flags = 0 };
    std.posix.sigaction(std.posix.SIG.CHLD, &ign, null) catch {};
    std.posix.sigaction(std.posix.SIG.PIPE, &ign, null) catch {};

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = if (@import("builtin").mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    const app = App.init(alloc) catch |e| {
        std.log.err("起動に失敗しました: {s}", .{@errorName(e)});
        return 1;
    };
    app.run();
    app.ipc_server.deinit();
    if (app.restart_requested) {
        // 自分自身を exec し直す(設定やウィジェットを完全に読み直したいとき用)
        var buf: [512]u8 = undefined;
        const exe = std.fs.selfExePath(&buf) catch return 0;
        buf[exe.len] = 0;
        const argv = [_:null]?[*:0]const u8{ @ptrCast(exe.ptr), null };
        _ = c.execv(@ptrCast(exe.ptr), @ptrCast(&argv));
    }
    return 0;
}
