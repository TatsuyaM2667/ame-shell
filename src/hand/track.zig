// 手の追跡: カメラの 1 コマ(RGB)から、手の関節 21 点を求める。OS に依存しない計算だけ。
//
// MediaPipe の手のモデル 2 つを、同じ考え方でつなぐ:
//   1. 手のひらの検出(192×192、2016 個のアンカー)… 手が見つかっていないときだけ
//      → 手のひらの箱と 7 つの目印。手首(0)と中指の付け根(2)の向きで、手の回転が分かる
//   2. その手を「指先が上を向くように回して」切り抜き(224×224)、関節 21 点を求める
//   3. 次のコマは、関節の位置から切り抜きの枠を作る(検出を飛ばせるので軽い)。手が消えたら 1 に戻る
const std = @import("std");
pub const nn = @import("nn.zig");

pub const Image = struct {
    rgb: []const u8,
    w: usize,
    h: usize,
};

pub const Roi = struct {
    cx: f32,
    cy: f32,
    size: f32,
    rot: f32,
};

pub const Hand = struct {
    /// 画像の画素の座標(x, y)と奥行き(z、手首からの相対)
    pts: [21][3]f32,
    score: f32,
    /// 右手なら 1 に近い(カメラに映った向きのまま。鏡にしていない)
    right: f32,
};

const DET = 192;
const LMK = 224;
const N_ANCHOR = 2016;

pub const Tracker = struct {
    det: *nn.Net,
    lmk: *nn.Net,
    anchors: [N_ANCHOR][2]f32,
    roi: ?Roi = null,
    /// 検出の入力の値の範囲(モデルによって [0,1] か [-1,1])
    det_signed: bool = true,
    lmk_signed: bool = false,

    pub fn init(det: *nn.Net, lmk: *nn.Net) Tracker {
        var self = Tracker{ .det = det, .lmk = lmk, .anchors = undefined };
        makeAnchors(&self.anchors);
        return self;
    }

    /// 1 コマを処理する。手が無ければ null
    pub fn step(self: *Tracker, img: Image) !?Hand {
        if (self.roi == null) {
            self.roi = try self.detect(img) orelse return null;
        }
        const roi = self.roi.?;
        const h = try self.landmarks(img, roi);
        if (h.score < 0.7) {
            self.roi = null;
            return null;
        }
        self.roi = roiFromLandmarks(h.pts);
        return h;
    }

    // ---- 1. 手のひらの検出 ----
    pub fn detect(self: *Tracker, img: Image) !?Roi {
        // 縦横比を保って 192×192 に収め、余りは黒で埋める(letterbox)
        const side: f32 = @floatFromInt(@max(img.w, img.h));
        const pad_x = (side - @as(f32, @floatFromInt(img.w))) / 2;
        const pad_y = (side - @as(f32, @floatFromInt(img.h))) / 2;
        const inp = self.det.input();
        const sc = side / DET;
        for (0..DET) |y| for (0..DET) |x| {
            const sx = (@as(f32, @floatFromInt(x)) + 0.5) * sc - pad_x - 0.5;
            const sy = (@as(f32, @floatFromInt(y)) + 0.5) * sc - pad_y - 0.5;
            const px = sample(img, sx, sy);
            for (0..3) |k| inp[(y * DET + x) * 3 + k] = norm(px[k], self.det_signed);
        };
        try self.det.run();
        const boxes = self.det.output(0); // [2016][18]
        const scores = self.det.output(1); // [2016]
        var best: ?usize = null;
        var best_s: f32 = 0.5;
        for (0..N_ANCHOR) |i| {
            const s = sigmoid(std.math.clamp(scores[i], -100, 100));
            if (s > best_s) {
                best_s = s;
                best = i;
            }
        }
        const i = best orelse return null;
        // 重なる候補を、スコアで重み付けして平均する(1 つの手が複数のアンカーで見つかるため)
        const b0 = decodeBox(boxes[i * 18 ..][0..18], self.anchors[i]);
        var acc = [_]f32{0} ** 18;
        var wsum: f32 = 0;
        for (0..N_ANCHOR) |j| {
            const s = sigmoid(std.math.clamp(scores[j], -100, 100));
            if (s < 0.5) continue;
            const bj = decodeBox(boxes[j * 18 ..][0..18], self.anchors[j]);
            if (iou(b0, bj) < 0.3) continue;
            for (0..18) |k| acc[k] += bj[k] * s;
            wsum += s;
        }
        for (&acc) |*a| a.* /= wsum;
        // 正規化した座標(letterbox の中)→ 画像の画素
        const toX = struct {
            fn f(v: f32, s: f32, p: f32) f32 {
                return v * s - p;
            }
        }.f;
        const cx = toX(acc[0], side, pad_x);
        const cy = toX(acc[1], side, pad_y);
        const w = acc[2] * side;
        const h = acc[3] * side;
        const wx = toX(acc[4], side, pad_x);
        const wy = toX(acc[5], side, pad_y);
        const mx = toX(acc[8], side, pad_x);
        const my = toX(acc[9], side, pad_y);
        // 手首 → 中指の付け根が上を向くように回す角度
        const rot = normAngle(std.math.pi / 2.0 - std.math.atan2(-(my - wy), mx - wx));
        // 手のひらの箱から、指先まで入るように中心を指の方へずらし(-0.5)、2.6 倍に広げる
        const size = @max(w, h);
        return .{
            .cx = cx + 0.5 * h * @sin(rot),
            .cy = cy - 0.5 * h * @cos(rot),
            .size = size * 2.6,
            .rot = rot,
        };
    }

    // ---- 2. 関節 21 点 ----
    pub fn landmarks(self: *Tracker, img: Image, roi: Roi) !Hand {
        const inp = self.lmk.input();
        const cs = @cos(roi.rot);
        const sn = @sin(roi.rot);
        for (0..LMK) |y| for (0..LMK) |x| {
            const u = ((@as(f32, @floatFromInt(x)) + 0.5) / LMK - 0.5) * roi.size;
            const v = ((@as(f32, @floatFromInt(y)) + 0.5) / LMK - 0.5) * roi.size;
            const sx = roi.cx + u * cs - v * sn - 0.5;
            const sy = roi.cy + u * sn + v * cs - 0.5;
            const px = sample(img, sx, sy);
            for (0..3) |k| inp[(y * LMK + x) * 3 + k] = norm(px[k], self.lmk_signed);
        };
        try self.lmk.run();
        const lm = self.lmk.output(0);
        var hand = Hand{ .pts = undefined, .score = self.lmk.output(1)[0], .right = self.lmk.output(2)[0] };
        for (0..21) |k| {
            const u = (lm[k * 3] / LMK - 0.5) * roi.size;
            const v = (lm[k * 3 + 1] / LMK - 0.5) * roi.size;
            hand.pts[k] = .{ roi.cx + u * cs - v * sn, roi.cy + u * sn + v * cs, lm[k * 3 + 2] / LMK * roi.size };
        }
        return hand;
    }
};

/// 関節の位置から、次のコマの切り抜きの枠(MediaPipe の hand_landmarks_to_rect と同じ考え)
pub fn roiFromLandmarks(p: [21][3]f32) Roi {
    const rot = normAngle(std.math.pi / 2.0 - std.math.atan2(-(p[9][1] - p[0][1]), p[9][0] - p[0][0]));
    const cs = @cos(-rot);
    const sn = @sin(-rot);
    const idx = [_]usize{ 0, 1, 2, 3, 5, 6, 9, 10, 13, 14, 17, 18 };
    var lo = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
    var hi = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
    for (idx) |k| {
        const x = p[k][0] * cs - p[k][1] * sn;
        const y = p[k][0] * sn + p[k][1] * cs;
        lo = .{ @min(lo[0], x), @min(lo[1], y) };
        hi = .{ @max(hi[0], x), @max(hi[1], y) };
    }
    const rcx = (lo[0] + hi[0]) / 2;
    const rcy = (lo[1] + hi[1]) / 2;
    // 回した座標の中心を元に戻す
    const c2 = @cos(rot);
    const s2 = @sin(rot);
    const w = hi[0] - lo[0];
    const h = hi[1] - lo[1];
    const cx = rcx * c2 - rcy * s2;
    const cy = rcx * s2 + rcy * c2;
    return .{
        .cx = cx + 0.1 * h * @sin(rot),
        .cy = cy - 0.1 * h * @cos(rot),
        .size = @max(w, h) * 2.0,
        .rot = rot,
    };
}

fn makeAnchors(out: *[N_ANCHOR][2]f32) void {
    // SSD のアンカー(MediaPipe の手のひら検出の設定): 刻み 8 で 1 層、刻み 16 で 3 層、各層 2 個、大きさは固定
    var n: usize = 0;
    const groups = [_]struct { stride: usize, per: usize }{ .{ .stride = 8, .per = 2 }, .{ .stride = 16, .per = 6 } };
    for (groups) |g| {
        const fm = DET / g.stride;
        for (0..fm) |y| for (0..fm) |x| for (0..g.per) |_| {
            out[n] = .{ (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(fm)), (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(fm)) };
            n += 1;
        };
    }
}

/// 生の値 → [cx, cy, w, h, 目印 7 つの x, y](letterbox の中で 0〜1)
fn decodeBox(r: *const [18]f32, a: [2]f32) [18]f32 {
    var o: [18]f32 = undefined;
    o[0] = r[0] / DET + a[0];
    o[1] = r[1] / DET + a[1];
    o[2] = r[2] / DET;
    o[3] = r[3] / DET;
    var k: usize = 0;
    while (k < 7) : (k += 1) {
        o[4 + k * 2] = r[4 + k * 2] / DET + a[0];
        o[5 + k * 2] = r[5 + k * 2] / DET + a[1];
    }
    return o;
}

fn iou(a: [18]f32, b: [18]f32) f32 {
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

fn normAngle(a: f32) f32 {
    return a - 2 * std.math.pi * @floor((a + std.math.pi) / (2 * std.math.pi));
}

inline fn norm(v: f32, signed: bool) f32 {
    return if (signed) v / 127.5 - 1 else v / 255;
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
