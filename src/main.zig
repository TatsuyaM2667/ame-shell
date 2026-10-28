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
    installFatalSignalHandlers();
    std.log.info("ame-shell starting (pid {d}, {s})", .{ c.getpid(), @tagName(@import("builtin").os.tag) });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = if (@import("builtin").mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    const app = App.init(alloc) catch |e| {
        // TTY のコンソールは日本語を表示できないことがあるので ASCII でも出す
        std.log.err("startup failed: {s} / 起動に失敗しました", .{@errorName(e)});
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
    if (app.disconnected) return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// 致命的なシグナル: TTY でも読めるよう ASCII でシグナル名をログに出してから、既定の動作に戻して
// 同じシグナルを送り直す(コアダンプと終了コードはそのまま)。
// SIGSEGV 等は、Zig の標準のハンドラ(ReleaseSafe / Debug でスタックトレースを出す)が有効ならそちらに任せる。
// ---------------------------------------------------------------------------

fn installFatalSignalHandlers() void {
    const act = std.posix.Sigaction{ .handler = .{ .handler = onFatalSignal }, .mask = std.posix.empty_sigset, .flags = 0 };
    std.posix.sigaction(std.posix.SIG.SYS, &act, null) catch {};
    std.posix.sigaction(std.posix.SIG.ABRT, &act, null) catch {};
    if (!std.debug.default_enable_segfault_handler) {
        for ([_]u6{ std.posix.SIG.SEGV, std.posix.SIG.BUS, std.posix.SIG.ILL, std.posix.SIG.FPE }) |s| {
            std.posix.sigaction(s, &act, null) catch {};
        }
    }
}

fn onFatalSignal(sig: c_int) callconv(.C) void {
    const name: []const u8 = switch (sig) {
        std.posix.SIG.SYS => "SIGSYS (bad system call: a system call this OS does not have)",
        std.posix.SIG.SEGV => "SIGSEGV (invalid memory access)",
        std.posix.SIG.BUS => "SIGBUS (bus error)",
        std.posix.SIG.ILL => "SIGILL (illegal instruction)",
        std.posix.SIG.FPE => "SIGFPE (arithmetic error)",
        std.posix.SIG.ABRT => "SIGABRT (abort)",
        else => "fatal signal",
    };
    // シグナルハンドラの中なので write(2) だけを使う
    const pre = "ame-shell: crashed with ";
    _ = std.c.write(2, pre, pre.len);
    _ = std.c.write(2, name.ptr, name.len);
    const tip = " -- rebuild with: zig build -Doptimize=ReleaseSafe -Dstrip=false for a backtrace\n";
    _ = std.c.write(2, tip, tip.len);
    const dfl = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.empty_sigset, .flags = 0 };
    std.posix.sigaction(@intCast(sig), &dfl, null) catch {};
    _ = std.c.raise(sig);
}
