// pam_ame_face.so: ログイン画面(greetd + ame-greeter)の顔認証の PAM モジュール。
// greetd の中で root として動く。照合はロック画面と同じ face/core.zig(赤外線のみ・近い 2 つの平均・3 コマ続けて)。
//
// PAM の設定(install-session.sh が作る ame-greetd。greetd の config.toml の [general] service で使う):
//   auth requisite pam_nologin.so
//   -auth sufficient /usr/local/lib/ame-shell/pam_ame_face.so [threshold=0.6] [camera=/dev/video2] [allow_rgb]
//   auth include greetd
//   ...
// 動き:
//   1. まず "ame-face" と問う(見える問い)。ame-greeter が "face" と答えたときだけカメラを使う。
//      ほかの答え(パスワードでのログイン)なら PAM_IGNORE で、次のパスワードの照合へ
//   2. その人の ~/.local/share/ame-shell/face.bin(本人のもので、ほかの人が書けないこと)と、
//      モデル(SHA-256 を確かめる)を読む。root でもリンクはたどらない
//   3. 赤外線カメラで最長 6 秒確かめ、一致すれば PAM_SUCCESS。だめなら理由を "ame-face:<理由>" の案内で伝えて失敗
// root の顔認証はしない。
const std = @import("std");
const builtin = @import("builtin");
const core = @import("face/core.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

pub const std_options: std.Options = .{ .log_level = .warn };

// Linux-PAM と OpenPAM(FreeBSD)で番号が違うもの
const bsd = builtin.os.tag == .freebsd;
const PAM_SUCCESS: c_int = 0;
const PAM_AUTH_ERR: c_int = if (bsd) 9 else 7;
const PAM_AUTHINFO_UNAVAIL: c_int = if (bsd) 12 else 9;
const PAM_IGNORE: c_int = 25;
const PAM_CONV: c_int = 5;
const PAM_PROMPT_ECHO_ON: c_int = 2;
const PAM_TEXT_INFO: c_int = 4;

const PamMessage = extern struct { msg_style: c_int, msg: [*:0]const u8 };
const PamResponse = extern struct { resp: ?[*:0]u8, resp_retcode: c_int };
const ConvFn = *const fn (c_int, [*]const *const PamMessage, *?[*]PamResponse, ?*anyopaque) callconv(.C) c_int;
const PamConv = extern struct { conv: ?ConvFn, appdata_ptr: ?*anyopaque };

extern fn pam_get_user(pamh: *anyopaque, user: *?[*:0]const u8, prompt: ?[*:0]const u8) c_int;
extern fn pam_get_item(pamh: *anyopaque, item_type: c_int, item: *?*const anyopaque) c_int;

/// 1 つ問って答えを out に写す(答えの無い案内なら空)。会話できなければ null
fn converse(pamh: *anyopaque, style: c_int, text: [*:0]const u8, out: []u8) ?[]const u8 {
    var item: ?*const anyopaque = null;
    if (pam_get_item(pamh, PAM_CONV, &item) != PAM_SUCCESS) return null;
    const conv: *const PamConv = @ptrCast(@alignCast(item orelse return null));
    const f = conv.conv orelse return null;
    const m = PamMessage{ .msg_style = style, .msg = text };
    const mp = [_]*const PamMessage{&m};
    var resp: ?[*]PamResponse = null;
    if (f(1, &mp, &resp, conv.appdata_ptr) != PAM_SUCCESS) return null;
    const r = resp orelse return out[0..0];
    defer c.free(r);
    const s = r[0].resp orelse return out[0..0];
    defer c.free(s);
    const len = std.mem.len(s);
    const n = @min(len, out.len);
    @memcpy(out[0..n], s[0..n]);
    _ = c.explicit_bzero(s, len);
    return out[0..n];
}

fn tell(pamh: *anyopaque, reason: []const u8) void {
    var b: [64]u8 = undefined;
    const t = std.fmt.bufPrintZ(&b, "ame-face:{s}", .{reason}) catch return;
    var sink: [8]u8 = undefined;
    _ = converse(pamh, PAM_TEXT_INFO, t.ptr, &sink);
}

const Args = struct {
    threshold: f32 = core.DEFAULT_THRESHOLD,
    camera: []const u8 = "",
    allow_rgb: bool = false,
};

fn parseArgs(argc: c_int, argv: ?[*]const [*:0]const u8) Args {
    var a = Args{};
    const v = argv orelse return a;
    for (0..@intCast(@max(argc, 0))) |i| {
        const s = std.mem.span(v[i]);
        if (std.mem.startsWith(u8, s, "threshold=")) {
            const t = std.fmt.parseFloat(f32, s["threshold=".len..]) catch continue;
            a.threshold = std.math.clamp(t, core.MIN_THRESHOLD, 0.95);
        } else if (std.mem.startsWith(u8, s, "camera=")) {
            a.camera = s["camera=".len..];
        } else if (std.mem.eql(u8, s, "allow_rgb")) a.allow_rgb = true;
    }
    return a;
}

export fn pam_sm_authenticate(pamh: *anyopaque, flags: c_int, argc: c_int, argv: ?[*]const [*:0]const u8) c_int {
    _ = flags;
    const args = parseArgs(argc, argv);

    var user: ?[*:0]const u8 = null;
    if (pam_get_user(pamh, &user, null) != PAM_SUCCESS) return PAM_IGNORE;
    var pwbuf: [2048]u8 = undefined;
    var pw: c.struct_passwd = undefined;
    var found: ?*c.struct_passwd = null;
    if (c.getpwnam_r(user orelse return PAM_IGNORE, &pw, &pwbuf, pwbuf.len, &found) != 0 or found == null) return PAM_IGNORE;
    if (pw.pw_uid == 0) return PAM_IGNORE;
    const home = std.mem.span(pw.pw_dir orelse return PAM_IGNORE);

    // ame-greeter が顔でのログインを頼んだときだけ
    var ans: [16]u8 = undefined;
    const r = converse(pamh, PAM_PROMPT_ECHO_ON, "ame-face", &ans) orelse return PAM_IGNORE;
    if (!std.mem.eql(u8, r, "face")) return PAM_IGNORE;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pb: [1024]u8 = undefined;
    const fp = std.fmt.bufPrint(&pb, "{s}/.local/share/ame-shell/face.bin", .{home}) catch return PAM_AUTHINFO_UNAVAIL;
    const data = core.readRegular(a, fp, core.FILE_MAX, pw.pw_uid) orelse {
        tell(pamh, "not-enrolled");
        return PAM_AUTHINFO_UNAVAIL;
    };
    var known: core.Enrolled = undefined;
    if (!core.parseEnrolled(data, &known)) {
        tell(pamh, "not-enrolled");
        return PAM_AUTHINFO_UNAVAIL;
    }

    const det_b = readModel(a, home, core.DET_MODEL) orelse {
        tell(pamh, "no-model");
        return PAM_AUTHINFO_UNAVAIL;
    };
    const emb_b = readModel(a, home, core.EMB_MODEL) orelse {
        tell(pamh, "no-model");
        return PAM_AUTHINFO_UNAVAIL;
    };
    const eng = core.Engine.create(a, det_b, emb_b) catch {
        tell(pamh, "failed");
        return PAM_AUTHINFO_UNAVAIL;
    };
    defer eng.deinit();

    var cam = core.openCamera(args.camera, !args.allow_rgb) orelse {
        tell(pamh, "no-camera");
        return PAM_AUTHINFO_UNAVAIL;
    };
    defer cam.close();
    var quit = std.atomic.Value(bool).init(false);
    const res = core.verify(a, eng, &cam, &known, .{ .threshold = args.threshold, .require_ir = !args.allow_rgb }, &quit, {}, null);
    if (res.outcome == .matched) return PAM_SUCCESS;
    tell(pamh, switch (res.outcome) {
        .no_face => "no-face",
        .no_match => "no-match",
        .too_dark => "too-dark",
        .ir_required => "ir-required",
        else => "failed",
    });
    return PAM_AUTH_ERR;
}

/// モデルは本人の置き場(登録のときに取ってきたもの)から。中身は SHA-256 で確かめるので、置き場は信用しなくてよい
fn readModel(a: std.mem.Allocator, home: []const u8, m: core.Model) ?[]u8 {
    var pb: [1024]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/.local/share/ame-shell/models/{s}", .{ home, m.file }) catch return null;
    return core.readModel(a, p, m);
}

export fn pam_sm_setcred(pamh: *anyopaque, flags: c_int, argc: c_int, argv: ?[*]const [*:0]const u8) c_int {
    _ = pamh;
    _ = flags;
    _ = argc;
    _ = argv;
    return PAM_IGNORE;
}
