// ame-auth: ロック画面のパスワード照合の補助(FreeBSD 用。root の setuid で入れる)。
//
// FreeBSD の pam_unix は root でないとパスワードを照合できず、Linux の unix_chkpwd に当たる補助も無い。
// そこで、ame-shell のロック画面と ame-iwato はこの小さな補助にパスワードを渡して照合してもらう(swaylock が setuid で入るのと同じ考え)。
//
// 安全のために:
//   * 照合するのは「呼び出した人(実 UID)」のパスワードだけ。引数でユーザーを選べない
//   * 引数・環境変数は一切読まない(setuid の実行ファイルでは信用できない)。PAM は dlopen(setuid では LD_* は無視される)
//   * パスワードは標準入力から(コマンドラインに出さない)。使ったら消す
//   * 失敗したら 2 秒待ってから終わる(総当たりを遅くする)
//   * 続けて 5 回まちがえたら、しばらく(30 秒から倍々に、最大 15 分)照合そのものをしない。
//     数えるのは root だけが書ける /var/db/ame-auth/<UID>(本人には消せない)。1 回合えば 0 に戻す
// 照合は ame-shell の中のロック画面と同じもの(src/cmd/pam.zig)。
// 終了コード: 0 = 正しい / 1 = 違う(または、まちがいが続いたので待っている間) / 2 = 照合できない(設定・環境の問題)
const std = @import("std");
const pam = @import("cmd/pam.zig");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("time.h");
});

const STATE_DIR = "/var/db/ame-auth";
const FREE_FAILS = 5; // ここまでは待たずに試せる
const MAX_WAIT_S: i64 = 15 * 60;

var pw_buf: [256]u8 = undefined;

fn fail(code: u8) u8 {
    std.crypto.utils.secureZero(u8, &pw_buf);
    if (code == 1) _ = c.sleep(2);
    return code;
}

/// まちがいの数と、最後にまちがえた時刻
const Fails = struct { n: u32 = 0, last: i64 = 0 };

/// n 回まちがえた後に待つ秒数(FREE_FAILS 回までは 0)
fn waitSeconds(n: u32) i64 {
    if (n < FREE_FAILS) return 0;
    const k: u6 = @intCast(@min(n - FREE_FAILS, 10));
    return @min(@as(i64, 30) << k, MAX_WAIT_S);
}

/// 数える場所(root の 0700 のフォルダの中の、UID の名前のファイル)。用意できなければ null(数えずに照合する)
fn stateDir() ?std.fs.Dir {
    std.posix.mkdirZ(STATE_DIR, 0o700) catch |e| if (e != error.PathAlreadyExists) return null;
    // 他人に作られたもの・リンクは使わない
    const st = std.posix.fstatatZ(std.posix.AT.FDCWD, STATE_DIR, std.posix.AT.SYMLINK_NOFOLLOW) catch return null;
    if (st.uid != 0 or st.mode & 0o077 != 0 or !std.posix.S.ISDIR(st.mode)) return null;
    return std.fs.cwd().openDirZ(STATE_DIR, .{ .no_follow = true }) catch null;
}

fn readFails(dir: std.fs.Dir, name: []const u8) Fails {
    var b: [64]u8 = undefined;
    const s = dir.readFile(name, &b) catch return .{};
    var it = std.mem.tokenizeAny(u8, s, " \n");
    const n = std.fmt.parseInt(u32, it.next() orelse return .{}, 10) catch return .{};
    const last = std.fmt.parseInt(i64, it.next() orelse return .{}, 10) catch return .{};
    return .{ .n = n, .last = last };
}

fn writeFails(dir: std.fs.Dir, name: []const u8, f: Fails) void {
    var b: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{d} {d}\n", .{ f.n, f.last }) catch return;
    dir.writeFile(.{ .sub_path = name, .data = s, .flags = .{ .mode = 0o600 } }) catch {};
}

pub fn main() u8 {
    // パスワード(標準入力。最後の改行は除く)
    var total: usize = 0;
    while (total < pw_buf.len - 1) {
        const r = std.posix.read(0, pw_buf[total .. pw_buf.len - 1]) catch break;
        if (r == 0) break;
        total += r;
    }
    while (total > 0 and (pw_buf[total - 1] == '\n' or pw_buf[total - 1] == '\r')) total -= 1;
    if (total == 0) return fail(1);

    var nb: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&nb, "{d}", .{c.getuid()}) catch return fail(2);
    var dir = stateDir();
    defer if (dir) |*d| d.close();
    const now: i64 = c.time(null);
    var fails: Fails = if (dir) |d| readFails(d, name) else .{};
    // まちがいが続いた後の待ち時間の間は、照合しない(正しいパスワードでも)
    if (now - fails.last < waitSeconds(fails.n)) return fail(1);

    const p = pam.load("ame-shell") orelse return fail(2);
    if (pam.verify(p, pw_buf[0..total])) {
        if (dir) |d| d.deleteFile(name) catch {};
        return fail(0);
    }
    fails = .{ .n = fails.n +| 1, .last = now };
    if (dir) |d| writeFails(d, name, fails);
    return fail(1);
}

test "まちがいの後の待ち時間" {
    try std.testing.expectEqual(@as(i64, 0), waitSeconds(4));
    try std.testing.expectEqual(@as(i64, 30), waitSeconds(5));
    try std.testing.expectEqual(@as(i64, 60), waitSeconds(6));
    try std.testing.expectEqual(MAX_WAIT_S, waitSeconds(40));
}

test "まちがいの数を書いて読む" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(u32, 0), readFails(tmp.dir, "1000").n);
    writeFails(tmp.dir, "1000", .{ .n = 6, .last = 1234 });
    const f = readFails(tmp.dir, "1000");
    try std.testing.expectEqual(@as(u32, 6), f.n);
    try std.testing.expectEqual(@as(i64, 1234), f.last);
    // 壊れた中身は 0 回とみなす
    try tmp.dir.writeFile(.{ .sub_path = "1001", .data = "x y" });
    try std.testing.expectEqual(@as(u32, 0), readFails(tmp.dir, "1001").n);
}
