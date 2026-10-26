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
        // 自分自身を exec し直す(設定やウィジェットを完全に読み直したいとき用)。
        // /proc/self/exe は、ビルドで実行ファイルが置き換わると "… (deleted)" になって exec できないので、
        // 起動時の argv[0](シンボリックリンク経由なら新しいビルドを指す)を PATH 検索付きで使う。
        const arg0 = std.os.argv[0];
        const argv = [_:null]?[*:0]const u8{ arg0, null };
        _ = c.execvp(arg0, @ptrCast(&argv));
        std.log.err("再起動(exec)に失敗しました", .{});
        // 監督ループ(river.sh / ame-river-init)が再起動するよう、異常終了として返す
        return 1;
    }
    return 0;
}
