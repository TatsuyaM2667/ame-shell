// パスワードの照合。ame-shell の中のロック画面(lock/lock.zig)と単体のロック ame-iwato が同じものを使う。
//
//   Linux:   PAM(実行時に dlopen。ヘッダは要らない)。サービスは ame-shell、無ければ同じ目的の swaylock。
//            pam_unix が照合に使う setuid の unix_chkpwd があることも確かめる(無いと一般ユーザーは照合できない)
//   FreeBSD: pam_unix は root でないと照合できないので、root の setuid の ame-auth にパスワードを標準入力で渡す
//
// prepare は「ロックする前に」呼び、照合できない構成なら理由を返す(閉じ込め防止: 外せないロックをかけない)。
// check は待つ(PAM は失敗すると数秒待つ)ので、呼ぶ側が子プロセスの中で呼ぶ。
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("dlfcn.h");
    @cInclude("sys/wait.h");
});

// ---- PAM の ABI(OpenPAM と Linux-PAM で同じ)----
const PAM_SUCCESS = 0;
const PAM_PROMPT_ECHO_OFF = 1;
const PAM_PROMPT_ECHO_ON = 2;
const PAM_CONV_ERR = 19;
const PamMessage = extern struct { msg_style: c_int, msg: ?[*:0]const u8 };
const PamResponse = extern struct { resp: ?[*:0]u8, resp_retcode: c_int };
const ConvFn = *const fn (c_int, [*c][*c]const PamMessage, [*c][*c]PamResponse, ?*anyopaque) callconv(.C) c_int;
const PamConv = extern struct { conv: ConvFn, appdata_ptr: ?*anyopaque };
const PamStart = *const fn ([*:0]const u8, [*:0]const u8, *const PamConv, *?*anyopaque) callconv(.C) c_int;
const PamFn = *const fn (?*anyopaque, c_int) callconv(.C) c_int;

pub const Pam = struct { start: PamStart, auth: PamFn, end: PamFn, service: [*:0]const u8 };

/// 照合の方法
pub const Auth = union(enum) { pam: Pam, helper: [*:0]const u8 };

pub const Prepared = union(enum) { ok: Auth, err: []const u8 };

fn exists(p: [*:0]const u8) bool {
    return c.access(p, c.R_OK) == 0;
}

/// FreeBSD: root が持ち主で setuid の ame-auth(install-session.sh が libexec に入れる)
pub fn findHelper() ?[*:0]const u8 {
    for ([_][*:0]const u8{ "/usr/local/libexec/ame-shell/ame-auth", "/usr/libexec/ame-shell/ame-auth" }) |p| {
        const st = std.posix.fstatatZ(std.posix.AT.FDCWD, p, 0) catch continue;
        if (st.mode & std.posix.S.ISUID != 0 and st.uid == 0) return p;
    }
    return null;
}

/// 照合できる構成かを確かめ、方法を返す。できなければ理由
pub fn prepare() Prepared {
    if (builtin.os.tag == .freebsd) {
        const h = findHelper() orelse return .{ .err = "ame-auth(照合の補助)が入っていません(sh install.sh で入れ直してください)" };
        if (!exists("/usr/local/etc/pam.d/ame-shell") and !exists("/etc/pam.d/ame-shell"))
            return .{ .err = "PAM サービス ame-shell が未インストールです(sh install.sh で入れ直してください)" };
        return .{ .ok = .{ .helper = h } };
    }
    // サービス設定: /etc/pam.d が優先、無ければ /usr/lib/pam.d(Chimera はこちら)
    const service: [*:0]const u8 = if (exists("/etc/pam.d/ame-shell") or exists("/usr/lib/pam.d/ame-shell"))
        "ame-shell"
    else if (exists("/etc/pam.d/swaylock") or exists("/usr/lib/pam.d/swaylock"))
        "swaylock"
    else
        return .{ .err = "PAM サービス ame-shell が未インストールです(install-session.sh を実行してください)" };
    // pam_unix はパスワード照合に setuid の unix_chkpwd を使う(NixOS は /run/wrappers/bin の setuid の包み)
    var found = false;
    for ([_][*:0]const u8{ "/usr/bin/unix_chkpwd", "/usr/sbin/unix_chkpwd", "/sbin/unix_chkpwd", "/run/wrappers/bin/unix_chkpwd" }) |p| {
        const st = std.posix.fstatatZ(std.posix.AT.FDCWD, p, 0) catch continue;
        if (st.mode & std.posix.S.ISUID != 0) found = true;
    }
    if (!found) return .{ .err = "unix_chkpwd(setuid)が無いため、一般ユーザーでは認証できません" };
    return .{ .ok = .{ .pam = load(service) orelse return .{ .err = "libpam が見つからないか不完全なため、ロックできません" } } };
}

/// libpam を読む(Linux-PAM は .so.0、FreeBSD の OpenPAM は .so.6)。無い・不完全なら null
pub fn load(service: [*:0]const u8) ?Pam {
    const h = c.dlopen("libpam.so.0", c.RTLD_NOW) orelse c.dlopen("libpam.so.6", c.RTLD_NOW) orelse c.dlopen("libpam.so", c.RTLD_NOW) orelse return null;
    return .{
        .start = @ptrCast(c.dlsym(h, "pam_start") orelse return null),
        .auth = @ptrCast(c.dlsym(h, "pam_authenticate") orelse return null),
        .end = @ptrCast(c.dlsym(h, "pam_end") orelse return null),
        .service = service,
    };
}

/// 今のユーザーの名前。照合する相手なので、書き換えられる環境変数(USER・LOGNAME)ではなく実 UID から取る
pub fn currentUser(buf: []u8) ?[:0]const u8 {
    const pw = c.getpwuid(c.getuid()) orelse return null;
    const name = std.mem.sliceTo(pw.*.pw_name orelse return null, 0);
    if (name.len == 0) return null;
    return std.fmt.bufPrintZ(buf, "{s}", .{name}) catch null;
}

// 照合中のパスワード(子プロセスの中だけで使い、終わったら消す)
var conv_pw: [257]u8 = undefined;

fn pamConv(num: c_int, msgs: [*c][*c]const PamMessage, resp: [*c][*c]PamResponse, _: ?*anyopaque) callconv(.C) c_int {
    if (num <= 0 or num > 32) return PAM_CONV_ERR;
    const n: usize = @intCast(num);
    const arr: [*]PamResponse = @ptrCast(@alignCast(c.calloc(n, @sizeOf(PamResponse)) orelse return PAM_CONV_ERR));
    for (0..n) |i| {
        const m = msgs[i];
        if (m.*.msg_style == PAM_PROMPT_ECHO_OFF or m.*.msg_style == PAM_PROMPT_ECHO_ON)
            arr[i].resp = @ptrCast(c.strdup(@ptrCast(&conv_pw)));
    }
    resp.* = @ptrCast(arr);
    return PAM_SUCCESS;
}

/// 試験用: Debug ビルドの入れ子の試験セッション(AME_SESSION_NESTED=1)で AME_LOCK_FAKE=1 のときだけ "ame" で外せる。
/// 入れる版(ReleaseFast など)では環境変数を何にしても効かない(ロックを無力化できないように)
pub fn fakeMode() bool {
    return builtin.mode == .Debug and std.posix.getenv("AME_LOCK_FAKE") != null and
        std.mem.eql(u8, std.posix.getenv("AME_SESSION_NESTED") orelse "", "1");
}

/// PAM で、実 UID の本人のパスワードを確かめる。ame-auth もこれを使う
pub fn verify(p: Pam, pw: []const u8) bool {
    if (pw.len == 0 or pw.len >= conv_pw.len) return false;
    defer std.crypto.utils.secureZero(u8, &conv_pw);
    var ub: [64]u8 = undefined;
    const user = currentUser(&ub) orelse return false;
    @memcpy(conv_pw[0..pw.len], pw);
    conv_pw[pw.len] = 0;
    const cv = PamConv{ .conv = pamConv, .appdata_ptr = null };
    var h: ?*anyopaque = null;
    if (p.start(p.service, user.ptr, &cv, &h) != PAM_SUCCESS) return false;
    // パスワードを確かめるだけ(pam_authenticate)。pam_acct_mgmt は呼ばない: ログインの時の確認(Arch の login →
    // system-login の account の段など)は、ログイン中の一般ユーザーのプロセスからは通らないことがある(swaylock も呼ばない)
    const r = p.auth(h, 0);
    _ = p.end(h, r);
    return r == PAM_SUCCESS;
}

/// パスワードが正しいか(待つので子プロセスの中で呼ぶ)
pub fn check(auth: Auth, pw: []const u8) bool {
    if (fakeMode()) return std.mem.eql(u8, pw, "ame");
    if (pw.len == 0 or pw.len >= conv_pw.len) return false;
    switch (auth) {
        .helper => |hp| {
            // ame-shell は SIGCHLD を無視している(子は自動で片付く)。待てるように既定に戻す(この子プロセスの中だけ)
            const dfl = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.empty_sigset, .flags = 0 };
            std.posix.sigaction(std.posix.SIG.CHLD, &dfl, null) catch {};
            var p: [2]c_int = undefined;
            if (c.pipe(&p) != 0) return false;
            const pid = c.fork();
            if (pid < 0) return false;
            if (pid == 0) {
                _ = c.dup2(p[0], 0);
                _ = c.close(p[0]);
                _ = c.close(p[1]);
                // setuid の補助には何も引き継がせない(環境変数も空)
                const argv = [_:null]?[*:0]const u8{ hp, null };
                const envp = [_:null]?[*:0]const u8{null};
                _ = c.execve(hp, @ptrCast(&argv), @ptrCast(&envp));
                c._exit(2);
            }
            _ = c.close(p[0]);
            _ = c.write(p[1], pw.ptr, pw.len);
            _ = c.close(p[1]);
            var status: c_int = 0;
            if (c.waitpid(pid, &status, 0) != pid) return false;
            return c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0;
        },
        .pam => |p| return verify(p, pw),
    }
}

test "空のパスワードは照合しない" {
    try std.testing.expect(!check(.{ .helper = "/nonexistent" }, ""));
}
