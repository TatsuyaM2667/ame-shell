// 顔の見分け: カメラの 1 コマから「誰の顔か」を表す 128 個の数(特徴)を出す。OS に依存しない計算だけ(試験できる)。
//
//   1. 顔の検出(MediaPipe の BlazeFace short range、128×128、896 個のアンカー、Apache-2.0)
//      → 顔の箱と 6 つの目印(両目・鼻・口・両耳)
//   2. 両目・鼻・口が決まった位置に来るように、回転・拡大して 112×112 に切り抜く(似た形への変換を最小二乗で)
//   3. 顔の特徴(OpenCV Zoo の SFace、Apache-2.0。ONNX を face/onnx.zig でエンジンの形に直す)→ 長さ 1 にそろえる
//   2 つの特徴の内積(cos)が大きいほど同じ人。
// 推論は手の認識と同じ自作のエンジン(hand/nn.zig)。
const std = @import("std");
const nn = @import("../hand/nn.zig");
pub const Image = @import("../hand/track.zig").Image;

const DET = 128;
const N_ANCHOR = 896;
pub const EMB = 128;
const CROP = 112;

/// 切り抜いた 112×112 の中での、両目(画像の左・右)・鼻・口の中心の位置(SFace / ArcFace の型)
const TEMPLATE = [4][2]f32{
    .{ 38.2946, 51.6963 },
    .{ 73.5318, 51.5014 },
    .{ 56.0252, 71.7366 },
    .{ 56.1396, 92.2848 },
};

pub const Face = struct {
    /// 顔の箱(画素)
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    score: f32,
    /// 両目(画像の左・右)・鼻・口(画素)
    pts: [4][2]f32,
};

pub const Recognizer = struct {
    det: *nn.Net,
    emb: *nn.Net,
    anchors: [N_ANCHOR][2]f32,
    /// 検出の入力の値の範囲([-1,1] なら true)
    det_signed: bool = true,

    pub fn init(det: *nn.Net, emb: *nn.Net) Recognizer {
        var self = Recognizer{ .det = det, .emb = emb, .anchors = undefined };
        makeAnchors(&self.anchors);
        return self;
    }

    /// いちばん大きく写った顔。無ければ null。
    /// 映像全体を 128×128 に縮めると顔は 20 画素ほどになり、目・鼻・口の位置が 10 画素ほどずれる(切り抜きがずれて、
    /// 同じ人でも特徴がばらつく)。見つけた顔の周りだけをもう一度 128×128 にして探し直し、位置を細かく求める
    pub fn detect(self: *Recognizer, img: Image) !?Face {
        const W: f32 = @floatFromInt(img.w);
        const H: f32 = @floatFromInt(img.h);
        const side = @max(W, H);
        const first = try self.region(img, (W - side) / 2, (H - side) / 2, side) orelse return null;
        // 顔の箱の 2.2 倍の正方形(顔が入力の半分ほどになる大きさ)
        const s2 = @max(first.w, first.h) * 2.2;
        if (s2 >= side * 0.8) return first;
        const cx = first.x + first.w / 2;
        const cy = first.y + first.h / 2;
        return try self.region(img, cx - s2 / 2, cy - s2 / 2, s2) orelse first;
    }

    /// 画像の (x0, y0) から一辺 side の正方形を 128×128 にして顔を探す(外側は黒)
    fn region(self: *Recognizer, img: Image, x0: f32, y0: f32, side: f32) !?Face {
        const inp = self.det.input();
        const sc = side / DET;
        for (0..DET) |y| for (0..DET) |x| {
            const sx = (@as(f32, @floatFromInt(x)) + 0.5) * sc + x0 - 0.5;
            const sy = (@as(f32, @floatFromInt(y)) + 0.5) * sc + y0 - 0.5;
            const px = sample(img, sx, sy);
            for (0..3) |k| inp[(y * DET + x) * 3 + k] = if (self.det_signed) px[k] / 127.5 - 1 else px[k] / 255;
        };
        try self.det.run();
        // 出力: 箱と目印 [896][16] と、点数 [896]。並びはモデルによって逆のことがあるので大きさで見分ける
        var boxes = self.det.output(0);
        var scores = self.det.output(1);
        if (boxes.len < scores.len) std.mem.swap([]f32, &boxes, &scores);
        if (boxes.len != N_ANCHOR * 16 or scores.len != N_ANCHOR) return error.BadModel;
        var best: ?usize = null;
        var best_s: f32 = 0.6;
        for (0..N_ANCHOR) |i| {
            const s = sigmoid(std.math.clamp(scores[i], -100, 100));
            if (s > best_s) {
                best_s = s;
                best = i;
            }
        }
        const i = best orelse return null;
        // 重なる候補を点数で重み付けして平均する
        const b0 = decode(boxes[i * 16 ..][0..16], self.anchors[i]);
        var acc = [_]f32{0} ** 16;
        var wsum: f32 = 0;
        for (0..N_ANCHOR) |j| {
            const s = sigmoid(std.math.clamp(scores[j], -100, 100));
            if (s < 0.5) continue;
            const bj = decode(boxes[j * 16 ..][0..16], self.anchors[j]);
            if (iou(b0, bj) < 0.3) continue;
            for (0..16) |k| acc[k] += bj[k] * s;
            wsum += s;
        }
        for (&acc) |*v| v.* /= wsum;
        var f = Face{
            .x = (acc[0] - acc[2] / 2) * side + x0,
            .y = (acc[1] - acc[3] / 2) * side + y0,
            .w = acc[2] * side,
            .h = acc[3] * side,
            .score = best_s,
            .pts = undefined,
        };
        for (0..4) |k| f.pts[k] = .{ acc[4 + k * 2] * side + x0, acc[5 + k * 2] * side + y0 };
        // 両目は画像の左にある方を先に(鏡にした映像でも同じ型に合うように)
        if (f.pts[0][0] > f.pts[1][0]) std.mem.swap([2]f32, &f.pts[0], &f.pts[1]);
        return f;
    }

    /// 顔を 112×112 にそろえて切り抜き、特徴(長さ 1)を出す
    pub fn embed(self: *Recognizer, img: Image, f: Face, out: *[EMB]f32) !void {
        // 型の位置 → 画像の位置 への変換(回転・拡大・移動)を最小二乗で求める
        const t = similarity(TEMPLATE, f.pts);
        const inp = self.emb.input();
        for (0..CROP) |y| for (0..CROP) |x| {
            const u = @as(f32, @floatFromInt(x));
            const v = @as(f32, @floatFromInt(y));
            const px = sample(img, t[0] * u - t[1] * v + t[2], t[1] * u + t[0] * v + t[3]);
            // SFace は 0〜255 の RGB を受け取る(引き算・掛け算はモデルの中)
            for (0..3) |k| inp[(y * CROP + x) * 3 + k] = px[k];
        };
        try self.emb.run();
        const o = self.emb.output(0);
        if (o.len != EMB) return error.BadModel;
        normalize(o, out);
    }

    /// 112×112 に切り抜いた絵を見る(試験用): 切り抜いた RGB を out に
    pub fn cropDebug(img: Image, f: Face, out: *[CROP * CROP * 3]u8) void {
        const t = similarity(TEMPLATE, f.pts);
        for (0..CROP) |y| for (0..CROP) |x| {
            const u = @as(f32, @floatFromInt(x));
            const v = @as(f32, @floatFromInt(y));
            const px = sample(img, t[0] * u - t[1] * v + t[2], t[1] * u + t[0] * v + t[3]);
            for (0..3) |k| out[(y * CROP + x) * 3 + k] = @intFromFloat(std.math.clamp(px[k], 0, 255));
        };
    }
};

/// 2 つの特徴の近さ(cos、-1〜1)
pub fn cosine(a: *const [EMB]f32, b: *const [EMB]f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

fn normalize(v: []const f32, out: *[EMB]f32) void {
    var s: f32 = 0;
    for (v) |x| s += x * x;
    const inv = 1 / @max(@sqrt(s), 1e-6);
    for (out, v) |*o, x| o.* = x * inv;
}

/// 点の組 src → dst に合う変換 [a, b, tx, ty](x' = a x - b y + tx、y' = b x + a y + ty)を最小二乗で
fn similarity(src: [4][2]f32, dst: [4][2]f32) [4]f32 {
    var ms = [2]f32{ 0, 0 };
    var md = [2]f32{ 0, 0 };
    for (0..4) |k| for (0..2) |j| {
        ms[j] += src[k][j] / 4;
        md[j] += dst[k][j] / 4;
    };
    var num_a: f32 = 0;
    var num_b: f32 = 0;
    var den: f32 = 0;
    for (0..4) |k| {
        const sx = src[k][0] - ms[0];
        const sy = src[k][1] - ms[1];
        const dx = dst[k][0] - md[0];
        const dy = dst[k][1] - md[1];
        num_a += sx * dx + sy * dy;
        num_b += sx * dy - sy * dx;
        den += sx * sx + sy * sy;
    }
    const a = num_a / @max(den, 1e-6);
    const b = num_b / @max(den, 1e-6);
    return .{ a, b, md[0] - (a * ms[0] - b * ms[1]), md[1] - (b * ms[0] + a * ms[1]) };
}

fn makeAnchors(out: *[N_ANCHOR][2]f32) void {
    // BlazeFace short range: 16×16 に 2 個ずつ、8×8 に 6 個ずつ(stride 8, 16, 16, 16)
    var n: usize = 0;
    for ([_][2]usize{ .{ 16, 2 }, .{ 8, 6 } }) |l| {
        const fm = l[0];
        for (0..fm) |y| for (0..fm) |x| for (0..l[1]) |_| {
            out[n] = .{ (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(fm)), (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(fm)) };
            n += 1;
        };
    }
}

/// [cx, cy, w, h, 目印×6(x, y)](正規化した座標)
fn decode(raw: *const [16]f32, an: [2]f32) [16]f32 {
    var o: [16]f32 = undefined;
    o[0] = raw[0] / DET + an[0];
    o[1] = raw[1] / DET + an[1];
    o[2] = raw[2] / DET;
    o[3] = raw[3] / DET;
    for (0..6) |k| {
        o[4 + k * 2] = raw[4 + k * 2] / DET + an[0];
        o[5 + k * 2] = raw[5 + k * 2] / DET + an[1];
    }
    return o;
}

fn iou(a: [16]f32, b: [16]f32) f32 {
    const ax0 = a[0] - a[2] / 2;
    const ax1 = a[0] + a[2] / 2;
    const ay0 = a[1] - a[3] / 2;
    const ay1 = a[1] + a[3] / 2;
    const bx0 = b[0] - b[2] / 2;
    const bx1 = b[0] + b[2] / 2;
    const by0 = b[1] - b[3] / 2;
    const by1 = b[1] + b[3] / 2;
    const iw = @max(0, @min(ax1, bx1) - @max(ax0, bx0));
    const ih = @max(0, @min(ay1, by1) - @max(ay0, by0));
    const inter = iw * ih;
    const uni = a[2] * a[3] + b[2] * b[3] - inter;
    return if (uni > 0) inter / uni else 0;
}

fn sigmoid(x: f32) f32 {
    return 1 / (1 + @exp(-x));
}

/// 双線形の補間で 1 画素を読む(外側は黒)
fn sample(img: Image, x: f32, y: f32) [3]f32 {
    if (x < -1 or y < -1 or x >= @as(f32, @floatFromInt(img.w)) or y >= @as(f32, @floatFromInt(img.h))) return .{ 0, 0, 0 };
    const fx = @floor(x);
    const fy = @floor(y);
    const wx = x - fx;
    const wy = y - fy;
    const x0: i64 = @intFromFloat(fx);
    const y0: i64 = @intFromFloat(fy);
    var out = [3]f32{ 0, 0, 0 };
    const W: i64 = @intCast(img.w);
    const H: i64 = @intCast(img.h);
    inline for (.{ 0, 1 }) |dy| inline for (.{ 0, 1 }) |dx| {
        const xx = x0 + dx;
        const yy = y0 + dy;
        if (xx >= 0 and yy >= 0 and xx < W and yy < H) {
            const wgt = (if (dx == 0) 1 - wx else wx) * (if (dy == 0) 1 - wy else wy);
            const p = img.rgb[@as(usize, @intCast(yy * W + xx)) * 3 ..][0..3];
            for (0..3) |k| out[k] += wgt * @as(f32, @floatFromInt(p[k]));
        }
    };
    return out;
}

test "similarity: 回転・拡大・移動を求める" {
    // 30 度回して 2 倍し、(10, 5) ずらした点
    const c = @cos(@as(f32, 0.5236)) * 2;
    const s = @sin(@as(f32, 0.5236)) * 2;
    var dst: [4][2]f32 = undefined;
    for (TEMPLATE, 0..) |p, k| dst[k] = .{ c * p[0] - s * p[1] + 10, s * p[0] + c * p[1] + 5 };
    const t = similarity(TEMPLATE, dst);
    try std.testing.expectApproxEqAbs(c, t[0], 1e-3);
    try std.testing.expectApproxEqAbs(s, t[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 10), t[2], 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 5), t[3], 1e-2);
}

test "anchors: 896 個" {
    var an: [N_ANCHOR][2]f32 = undefined;
    makeAnchors(&an);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 32.0), an[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 15.5 / 16.0), an[511][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5 / 8.0), an[895][1], 1e-6);
}
