// ame-auth: ロック画面のパスワード照合の補助(FreeBSD 用。root の setuid で入れる)。
//
// FreeBSD の pam_unix は root でないとパスワードを照合できず、Linux の unix_chkpwd に当たる補助も無い。
// そこで、ame-shell のロック画面はこの小さな補助にパスワードを渡して照合してもらう(swaylock が setuid で入るのと同じ考え)。
//
// 安全のために:
//   * 照合するのは「呼び出した人(実 UID)」のパスワードだけ。引数でユーザーを選べない
//   * 引数・環境変数は一切読まない(setuid の実行ファイルでは信用できない)。PAM は dlopen(setuid では LD_* は無視される)
//   * パスワードは標準入力から(コマンドラインに出さない)。使ったら消す
//   * 失敗したら 2 秒待ってから終わる(総当たりを遅くする)
// 終了コード: 0 = 正しい / 1 = 違う / 2 = 照合できない(設定・環境の問題)
const std = @import("std");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("unistd.h");
    @cInclude("dlfcn.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

// PAM(OpenPAM / Linux-PAM で同じ ABI)
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

var pw_buf: [256]u8 = undefined;
var pw_len: usize = 0;

fn conv(num: c_int, msgs: [*c][*c]const PamMessage, resp: [*c][*c]PamResponse, _: ?*anyopaque) callconv(.C) c_int {
    if (num <= 0 or num > 32) return PAM_CONV_ERR;
    const n: usize = @intCast(num);
    const arr: [*]PamResponse = @ptrCast(@alignCast(c.calloc(n, @sizeOf(PamResponse)) orelse return PAM_CONV_ERR));
    for (0..n) |i| {
        const m = msgs[i];
        if (m.*.msg_style == PAM_PROMPT_ECHO_OFF or m.*.msg_style == PAM_PROMPT_ECHO_ON) {
            pw_buf[pw_len] = 0;
            arr[i].resp = @ptrCast(c.strdup(@ptrCast(&pw_buf)));
        }
    }
    resp.* = @ptrCast(arr);
    return PAM_SUCCESS;
}

fn wipe() void {
    @memset(&pw_buf, 0);
    pw_len = 0;
}

fn fail(code: u8) u8 {
    wipe();
    if (code == 1) _ = c.sleep(2);
    return code;
}

pub fn main() u8 {
    // 実 UID の利用者(環境変数の USER などは使わない)
    const pw = c.getpwuid(c.getuid()) orelse return fail(2);
    const name = pw.*.pw_name orelse return fail(2);

    // パスワード(標準入力。最後の改行は除く)
    var total: usize = 0;
    while (total < pw_buf.len - 1) {
        const r = c.read(0, &pw_buf[total], pw_buf.len - 1 - total);
        if (r <= 0) break;
        total += @intCast(r);
    }
    while (total > 0 and (pw_buf[total - 1] == '\n' or pw_buf[total - 1] == '\r')) total -= 1;
    pw_len = total;
    if (pw_len == 0) return fail(1);

    const h = c.dlopen("libpam.so", c.RTLD_NOW) orelse c.dlopen("libpam.so.6", c.RTLD_NOW) orelse c.dlopen("libpam.so.0", c.RTLD_NOW) orelse return fail(2);
    const start: PamStart = @ptrCast(c.dlsym(h, "pam_start") orelse return fail(2));
    const authenticate: PamFn = @ptrCast(c.dlsym(h, "pam_authenticate") orelse return fail(2));
    const acct: PamFn = @ptrCast(c.dlsym(h, "pam_acct_mgmt") orelse return fail(2));
    const end: PamFn = @ptrCast(c.dlsym(h, "pam_end") orelse return fail(2));

    const cv = PamConv{ .conv = conv, .appdata_ptr = null };
    var ph: ?*anyopaque = null;
    // サービス "ame-shell"(install-session.sh が /usr/local/etc/pam.d に置く)
    if (start("ame-shell", name, &cv, &ph) != PAM_SUCCESS) return fail(2);
    var r = authenticate(ph, 0);
    if (r == PAM_SUCCESS) r = acct(ph, 0);
    _ = end(ph, r);
    return if (r == PAM_SUCCESS) fail(0) else fail(1);
}
