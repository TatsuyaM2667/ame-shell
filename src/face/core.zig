// 顔認証の中核: モデル・登録データ・カメラ・照合の決まり。
// ロック画面(face/unlock.zig、ame-shell の中のスレッド)と、ログイン画面の PAM モジュール(pam_face.zig、
// greetd の中で root として動く)の両方から使う。どちらも同じ厳しさで照合する。
//
// 照合の決まり(安心して使える厳しさに):
//   * 赤外線カメラ(GREY を出すカメラ)で、赤外線で登録した顔だけを使う(require_ir。既定でオン)。
//     スマホやタブレットの画面は赤外線では真っ暗に写るので、画面に映した写真・動画では外れない
//   * 顔が赤外線の照明で十分明るいこと(照明の当たらない遠くの写真などを除く)
//   * 登録した顔のうち、近い 2 つとの平均の近さ(cos)が threshold 以上(既定 0.6)。1 つだけたまたま近いのでは通さない
//   * それが 3 コマ続くこと(0.15 秒おき)
// 登録データとモデルはどちらも中身を確かめてから使う(モデルは SHA-256、登録データは形と大きさ)。
const std = @import("std");
const v4l2 = @import("../platform/v4l2.zig");
const nn = @import("../hand/nn.zig");
const onnx = @import("onnx.zig");
const face = @import("face.zig");

pub const EMB = face.EMB;
pub const MAX_ENROLL = 12;
pub const MIN_ENROLL = 5;
/// 赤外線の映像で、顔の明るさがこれより暗ければ照明が当たっていない(写真・画面のおそれ)
pub const IR_MIN_BRIGHT = 18;
/// 続けて一致しなければならないコマの数
pub const NEED_HITS = 3;
/// 既定の近さの境目と、設定で下げられる下限(これより緩くはできない)
pub const DEFAULT_THRESHOLD: f32 = 0.6;
pub const MIN_THRESHOLD: f32 = 0.5;

pub const Model = struct { file: []const u8, url: [:0]const u8, sha256: []const u8, max: usize };
pub const DET_MODEL = Model{
    .file = "blaze_face_short_range.tflite",
    .url = "https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite",
    .sha256 = "b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f",
    .max = 4 << 20,
};
pub const EMB_MODEL = Model{
    .file = "face_recognition_sface_2021dec.onnx",
    .url = "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx",
    .sha256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
    .max = 64 << 20,
};

pub fn sha256Is(b: []const u8, hex: []const u8) bool {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(b, &d, .{});
    const got = std.fmt.bytesToHex(d, .lower);
    return std.mem.eql(u8, &got, hex);
}

/// ふつうのファイルだけを、大きさの上限つきで読む(FIFO などで止まらないように O_NONBLOCK・リンクはたどらない)
pub fn readRegular(a: std.mem.Allocator, path: []const u8, max: usize, owner: ?std.posix.uid_t) ?[]u8 {
    const fd = std.posix.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch return null;
    defer std.posix.close(fd);
    const f = std.fs.File{ .handle = fd };
    const st = f.stat() catch return null;
    if (st.kind != .file or st.size > max) return null;
    if (owner) |uid| {
        // 本人のもので、ほかの人が書き換えられないこと(root として読むログイン画面のため)
        const raw = std.posix.fstat(fd) catch return null;
        if (raw.uid != uid or raw.mode & 0o022 != 0) return null;
    }
    return f.readToEndAlloc(a, max) catch null;
}

/// モデルを読んで SHA-256 を確かめる(合わなければ null)。確かめた中身だけを解釈する
pub fn readModel(a: std.mem.Allocator, path: []const u8, m: Model) ?[]u8 {
    const b = readRegular(a, path, m.max, null) orelse return null;
    if (sha256Is(b, m.sha256)) return b;
    a.free(b);
    return null;
}

// ---- 登録データ: "AMEFACE1"・赤外線か(u8)・数(u8)・予備 2・特徴 × 数(f32 × 128) ----

pub const MAGIC = "AMEFACE1";
pub const FILE_MAX = 12 + MAX_ENROLL * EMB * 4;

pub const Enrolled = struct {
    ir: bool,
    n: usize,
    embs: [MAX_ENROLL][EMB]f32,
};

pub fn parseEnrolled(data: []const u8, out: *Enrolled) bool {
    if (data.len < 12 or !std.mem.eql(u8, data[0..8], MAGIC)) return false;
    out.ir = data[8] != 0;
    out.n = data[9];
    if (out.n == 0 or out.n > MAX_ENROLL or data.len != 12 + out.n * EMB * 4) return false;
    for (0..out.n) |i| for (0..EMB) |k| {
        const v: f32 = @bitCast(std.mem.readInt(u32, data[12 + (i * EMB + k) * 4 ..][0..4], .little));
        if (!std.math.isFinite(v)) return false;
        out.embs[i][k] = v;
    };
    return true;
}

pub fn encodeEnrolled(e: *const Enrolled, buf: *[FILE_MAX]u8) []const u8 {
    @memcpy(buf[0..8], MAGIC);
    buf[8] = @intFromBool(e.ir);
    buf[9] = @intCast(e.n);
    buf[10] = 0;
    buf[11] = 0;
    for (0..e.n) |i| for (0..EMB) |k| {
        std.mem.writeInt(u32, buf[12 + (i * EMB + k) * 4 ..][0..4], @bitCast(e.embs[i][k]), .little);
    };
    return buf[0 .. 12 + e.n * EMB * 4];
}

/// 登録した顔が全部同じ人か: 平均の顔(長さ 1 にそろえる)に、どれも十分近い
pub fn consistent(e: *const Enrolled) bool {
    var mean = [_]f32{0} ** EMB;
    for (e.embs[0..e.n]) |*v| for (&mean, v) |*mv, x| {
        mv.* += x;
    };
    var len: f32 = 0;
    for (mean) |x| len += x * x;
    for (&mean) |*mv| mv.* /= @max(@sqrt(len), 1e-6);
    for (e.embs[0..e.n]) |*v| if (face.cosine(v, &mean) < 0.5) return false;
    return true;
}

/// 登録した顔との近さ: 近い 2 つの平均(登録が 1 つならそれ)。1 つの向きだけ偶然近い、を通さない
pub fn score(known: *const Enrolled, e: *const [EMB]f32) f32 {
    var s1: f32 = -1;
    var s2: f32 = -1;
    for (known.embs[0..known.n]) |*k| {
        const s = face.cosine(k, e);
        if (s > s1) {
            s2 = s1;
            s1 = s;
        } else if (s > s2) s2 = s;
    }
    return if (known.n >= 2) (s1 + s2) / 2 else s1;
}

// ---- カメラ ----

/// dev が空なら、赤外線カメラ(GREY を出すもの)を先に探し、require_ir でなければ普通のカメラも
pub fn openCamera(dev: []const u8, require_ir: bool) ?v4l2.Camera {
    var buf: [72]u8 = undefined;
    if (dev.len > 0) {
        const p = std.fmt.bufPrintZ(&buf, "{s}", .{dev}) catch return null;
        if (v4l2.Camera.openFmt(p.ptr, 640, 360, 30, .grey)) |cam| return cam else |_| {}
        if (require_ir) return null;
        return v4l2.Camera.open(p.ptr, 640, 480, 30) catch null;
    }
    for (0..10) |i| {
        const p = std.fmt.bufPrintZ(&buf, "/dev/video{d}", .{i}) catch continue;
        if (v4l2.Camera.openFmt(p.ptr, 640, 360, 30, .grey)) |cam| return cam else |_| {}
    }
    if (require_ir) return null;
    for (0..10) |i| {
        const p = std.fmt.bufPrintZ(&buf, "/dev/video{d}", .{i}) catch continue;
        if (v4l2.Camera.open(p.ptr, 640, 480, 30)) |cam| return cam else |_| {}
    }
    return null;
}

// ---- 推論 ----

pub const Engine = struct {
    det: nn.Net,
    emb: nn.Net,
    rec: face.Recognizer,

    /// 確かめ済みのモデルの中身から作る。a はアリーナを想定(deinit の後で丸ごと返す)
    pub fn create(a: std.mem.Allocator, det_b: []const u8, emb_b: []const u8) !*Engine {
        const self = try a.create(Engine);
        self.det = try nn.Net.init(a, det_b, 1);
        errdefer self.det.deinit();
        const g = try onnx.parse(a, emb_b);
        const m = try onnx.toModel(a, &g);
        self.emb = try nn.Net.initModel(a, m, 2);
        self.rec = face.Recognizer.init(&self.det, &self.emb);
        return self;
    }

    pub fn deinit(self: *Engine) void {
        self.emb.deinit();
        self.det.deinit();
    }

    pub const Look = union(enum) { none, small, dark, face: [EMB]f32 };

    /// 1 コマを見る: 顔が無い・小さい(遠い)・暗い(赤外線の照明が当たっていない)・特徴
    pub fn look(self: *Engine, img: face.Image, ir: bool) Look {
        const f = (self.rec.detect(img) catch null) orelse return .none;
        if (f.w < @as(f32, @floatFromInt(img.w)) * 0.12) return .small;
        if (ir and brightness(img, f) < IR_MIN_BRIGHT) return .dark;
        var e: [EMB]f32 = undefined;
        self.rec.embed(img, f, &e) catch return .none;
        return .{ .face = e };
    }
};

/// 顔の箱の中の明るさの平均(0〜255)
fn brightness(img: face.Image, f: face.Face) f32 {
    const W: f32 = @floatFromInt(img.w - 1);
    const H: f32 = @floatFromInt(img.h - 1);
    const x0: usize = @intFromFloat(std.math.clamp(f.x + f.w * 0.2, 0, W));
    const x1: usize = @intFromFloat(std.math.clamp(f.x + f.w * 0.8, 0, W));
    const y0: usize = @intFromFloat(std.math.clamp(f.y + f.h * 0.2, 0, H));
    const y1: usize = @intFromFloat(std.math.clamp(f.y + f.h * 0.8, 0, H));
    var s: u64 = 0;
    var n: u64 = 0;
    var y = y0;
    while (y < y1) : (y += 2) {
        var x = x0;
        while (x < x1) : (x += 2) {
            s += img.rgb[(y * img.w + x) * 3];
            n += 1;
        }
    }
    return if (n == 0) 0 else @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
}

// ---- 照合 ----

pub const Policy = struct {
    threshold: f32 = DEFAULT_THRESHOLD,
    max_ms: i64 = 6000,
    require_ir: bool = true,
};

pub const Outcome = enum { matched, no_face, no_match, too_dark, ir_required, failed, cancelled };

pub const Result = struct { outcome: Outcome, best: f32 = -1 };

/// カメラで、登録した顔かどうかを確かめる(最長 pol.max_ms)。quit が立ったらやめる。
/// on_score はコマごとの近さ(記録用。null で呼ばない)
pub fn verify(a: std.mem.Allocator, eng: *Engine, cam: *v4l2.Camera, known: *const Enrolled, pol: Policy, quit: *const std.atomic.Value(bool), ctx: anytype, comptime on_score: ?fn (@TypeOf(ctx), f32) void) Result {
    const ir = cam.fmt == .grey;
    // 赤外線で登録した顔は赤外線でだけ。require_ir なら登録も照合も赤外線でなければならない
    if ((known.ir or pol.require_ir) and !ir) return .{ .outcome = .ir_required };
    if (pol.require_ir and !known.ir) return .{ .outcome = .ir_required };
    const thr = @max(pol.threshold, MIN_THRESHOLD);
    const rgb = a.alloc(u8, cam.w * cam.h * 3) catch return .{ .outcome = .failed };
    defer a.free(rgb);
    const img = face.Image{ .rgb = rgb, .w = cam.w, .h = cam.h };
    const t0 = std.time.milliTimestamp();
    var last: i64 = 0;
    var hits: u32 = 0;
    var seen = false;
    var dark = false;
    var best: f32 = -1;
    while (!quit.load(.acquire)) {
        const now = std.time.milliTimestamp();
        if (now - t0 > pol.max_ms) break;
        var pfd = [_]std.posix.pollfd{.{ .fd = cam.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 150) catch break;
        if (now - last < 150) {
            _ = cam.grab(null, false);
            continue;
        }
        if (!cam.grab(rgb, false)) continue;
        last = now;
        switch (eng.look(img, ir)) {
            .none, .small => hits = 0,
            .dark => {
                dark = true;
                hits = 0;
            },
            .face => |*e| {
                seen = true;
                const s = score(known, e);
                best = @max(best, s);
                if (on_score) |f| f(ctx, s);
                if (s >= thr) {
                    hits += 1;
                    if (hits >= NEED_HITS) return .{ .outcome = .matched, .best = s };
                } else hits = 0;
            },
        }
    }
    if (quit.load(.acquire)) return .{ .outcome = .cancelled, .best = best };
    return .{ .outcome = if (seen) .no_match else if (dark) .too_dark else .no_face, .best = best };
}

test "登録データの読み書きと形の確認" {
    var e = Enrolled{ .ir = true, .n = 2, .embs = undefined };
    for (0..2) |i| for (0..EMB) |k| {
        e.embs[i][k] = @as(f32, @floatFromInt(i + k)) / 100;
    };
    var buf: [FILE_MAX]u8 = undefined;
    const b = encodeEnrolled(&e, &buf);
    var r: Enrolled = undefined;
    try std.testing.expect(parseEnrolled(b, &r));
    try std.testing.expect(r.ir and r.n == 2 and r.embs[1][5] == e.embs[1][5]);
    // 大きさが合わない・数が多すぎる・NaN は読まない
    try std.testing.expect(!parseEnrolled(b[0 .. b.len - 1], &r));
    var bad = buf;
    bad[9] = MAX_ENROLL + 1;
    try std.testing.expect(!parseEnrolled(bad[0..b.len], &r));
    bad = buf;
    std.mem.writeInt(u32, bad[12..16], 0x7fc00000, .little);
    try std.testing.expect(!parseEnrolled(bad[0..b.len], &r));
}

test "近さは近い 2 つの平均" {
    var e = Enrolled{ .ir = true, .n = 3, .embs = undefined };
    for (&e.embs) |*v| @memset(v, 0);
    e.embs[0][0] = 1;
    e.embs[1][1] = 1;
    e.embs[2][0] = 0.6;
    e.embs[2][1] = 0.8;
    var p = [_]f32{0} ** EMB;
    p[0] = 1;
    // 1.0(0 番)と 0.6(2 番)の平均
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), score(&e, &p), 1e-5);
}
