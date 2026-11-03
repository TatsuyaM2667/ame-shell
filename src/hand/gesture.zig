// 手の関節 21 点から、手の形・カーソルの位置・手の大きさを出す。OS・GPU に依存しない計算だけ(試験できる)。
//
// 精度のために:
//   * 関節を 3D のまま、点ごとに One Euro filter でならす(手ぶれ・1 コマの外れ値で形が変わらないように)
//   * 指が伸びているかは「関節の曲がり角」で見る(3D。手が傾いていても長さの比より安定する)。
//     伸びた/曲げたの切り替えに余裕(ヒステリシス)を持たせ、境目でぱたぱた変わらないようにする
//   * 親指は「第 1 関節の曲がり」と「人差し指の付け根からの離れ具合」の両方で見る
//
// 関節の番号(MediaPipe): 0 手首 / 親指 1〜4 / 人差し指 5〜8 / 中指 9〜12 / 薬指 13〜16 / 小指 17〜20
// (各指: 付け根(MCP)・第 2 関節(PIP)・第 1 関節(DIP)・先)
const std = @import("std");

pub const Gesture = enum(u8) { none, point, pinch, open, fist, other, number };

pub const Features = struct {
    gesture: Gesture,
    /// .number のときの本数(1〜4)
    fingers: u8 = 0,
    /// カーソル(画面の 0〜1)
    cx: f32,
    cy: f32,
    /// 手のひらの中心(カメラの画像の 0〜1。払う動きを見るのに使う。ならしていない生の値)
    px: f32,
    py: f32,
    /// 親指と人差し指の先の距離 ÷ 手の大きさ
    pinch: f32,
    /// 手の大きさ(手首〜中指の付け根)÷ 画像の幅。カメラに近づけると大きくなる(ズームに使う)
    size: f32,
};

const N = 21;

pub const Analyzer = struct {
    filt: [N][3]Euro = [_][3]Euro{[_]Euro{.{}} ** 3} ** N,
    /// 指ごとの「伸びている」(人差し指・中指・薬指・小指・親指)
    ext: [5]bool = .{ false, false, false, false, false },
    has_prev: bool = false,

    pub fn reset(self: *Analyzer) void {
        self.has_prev = false;
        for (&self.filt) |*f| for (f) |*e| e.reset();
    }

    pub fn step(self: *Analyzer, raw: [N][3]f32, w: f32, h: f32, t: f32) Features {
        // 関節をならす(速く動くときは遅れを小さく、止まっているときは強く)
        var p: [N][3]f32 = undefined;
        for (0..N) |i| for (0..3) |k| {
            p[i][k] = self.filt[i][k].step(raw[i][k], t);
        };
        self.has_prev = true;
        const s = @max(dist(p, 0, 9), 1);

        // 指の曲がり: 付け根→第 2 関節 と 第 1 関節→先 の向きの cos(1 = まっすぐ、-1 = 折り返し)
        const fingers = [_][4]usize{ .{ 5, 6, 7, 8 }, .{ 9, 10, 11, 12 }, .{ 13, 14, 15, 16 }, .{ 17, 18, 19, 20 } };
        for (fingers, 0..) |f, i| {
            const straight = cosBetween(p, f[0], f[1], f[2], f[3]);
            // 長さの比(指先が第 2 関節より手首から遠い)も見る: カメラに指先を向けたときの角度の誤差を補う
            const ratio = dist(p, f[3], 0) / @max(dist(p, f[1], 0), 1);
            const score = straight * 0.6 + (ratio - 1.0) * 1.5;
            // ヒステリシス: 伸ばすには 0.45 より上、曲げるには 0.15 より下
            if (self.ext[i]) {
                if (score < 0.15) self.ext[i] = false;
            } else if (score > 0.45) self.ext[i] = true;
        }
        // 親指: 先が中指の付け根から離れていて(曲げると手のひらに寄る)、第 1 関節がまっすぐ
        {
            const away = dist(p, 4, 9) / s;
            const straight = cosBetween(p, 2, 3, 3, 4);
            const score = (away - 0.6) * 2 + straight * 0.3;
            if (self.ext[4]) {
                if (score < 0.05) self.ext[4] = false;
            } else if (score > 0.35) self.ext[4] = true;
        }
        const e = self.ext;
        const pinch = dist(p, 4, 8) / s;
        const small = s < w * 0.05;
        var number: u8 = 0;
        const g: Gesture = blk: {
            if (small) break :blk .point;
            // つまむ: 親指と人差し指の先が近く、人差し指は握りこぶしほど曲がっていない
            if (pinch < 0.32 and dist(p, 8, 0) / s > 1.05) break :blk .pinch;
            const n4 = @as(u8, @intFromBool(e[0])) + @intFromBool(e[1]) + @intFromBool(e[2]) + @intFromBool(e[3]);
            if (n4 == 0) {
                if (e[4]) {
                    number = 1; // いいね
                    break :blk .number;
                }
                break :blk .fist;
            }
            if (n4 == 4) {
                if (e[4]) break :blk .open;
                number = 4;
                break :blk .number;
            }
            if (e[0] and !e[1] and !e[2] and !e[3]) break :blk .point;
            if (e[0] and e[1] and !e[2] and !e[3]) {
                number = 2;
                break :blk .number;
            }
            if (e[0] and e[1] and e[2] and !e[3]) {
                number = 3;
                break :blk .number;
            }
            break :blk .other;
        };
        // カーソル: 人差し指の先。つまむ動きに近づくほど親指との中点へ(つまんだ瞬間に跳ねないように)
        const tt = std.math.clamp((pinch - 0.3) / 0.35, 0, 1);
        const mx = (p[4][0] + p[8][0]) / 2;
        const my = (p[4][1] + p[8][1]) / 2;
        const ix = mx + (p[8][0] - mx) * tt;
        const iy = my + (p[8][1] - my) * tt;
        // カメラの真ん中の範囲を画面全体に(画面の端まで手を伸ばさなくてよいように)
        const mxr = 0.2;
        const myr = 0.17;
        return .{
            .gesture = g,
            .fingers = number,
            .cx = std.math.clamp((ix / w - mxr) / (1 - 2 * mxr), 0, 1),
            .cy = std.math.clamp((iy / h - myr) / (1 - 2 * myr), 0, 1),
            .px = raw[9][0] / w,
            .py = raw[9][1] / h,
            .pinch = pinch,
            .size = s / w,
        };
    }
};

fn dist(p: [N][3]f32, a: usize, b: usize) f32 {
    const dx = p[a][0] - p[b][0];
    const dy = p[a][1] - p[b][1];
    const dz = p[a][2] - p[b][2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

/// a→b の向きと c→d の向きの cos
fn cosBetween(p: [N][3]f32, a: usize, b: usize, cc: usize, d: usize) f32 {
    var u: [3]f32 = undefined;
    var v: [3]f32 = undefined;
    for (0..3) |k| {
        u[k] = p[b][k] - p[a][k];
        v[k] = p[d][k] - p[cc][k];
    }
    const lu = @sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2]);
    const lv = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (lu < 1e-3 or lv < 1e-3) return 0;
    return (u[0] * v[0] + u[1] * v[1] + u[2] * v[2]) / (lu * lv);
}

/// One Euro filter(ゆっくり動くときは強くならし、速く動くときは遅れを小さく)
pub const Euro = struct {
    x: f32 = 0,
    dx: f32 = 0,
    t: f32 = 0,
    init: bool = false,
    min_cutoff: f32 = 1.6,
    beta: f32 = 0.02,

    pub fn reset(self: *Euro) void {
        self.init = false;
    }

    pub fn step(self: *Euro, v: f32, t: f32) f32 {
        if (!self.init) {
            self.x = v;
            self.dx = 0;
            self.t = t;
            self.init = true;
            return v;
        }
        const dt = @max(t - self.t, 1.0 / 120.0);
        self.t = t;
        const d = (v - self.x) / dt;
        self.dx += alpha(1.0, dt) * (d - self.dx);
        const cutoff = self.min_cutoff + self.beta * @abs(self.dx);
        self.x += alpha(cutoff, dt) * (v - self.x);
        return self.x;
    }

    fn alpha(cutoff: f32, dt: f32) f32 {
        const tau = 1 / (2 * std.math.pi * cutoff);
        return 1 / (1 + tau / dt);
    }
};

/// 暗い映像を明るくする対応表(0〜255 → 0〜255)。平均の明るさが 120 前後になるように、
/// 暗いときだけ持ち上げる(ガンマ。明るいところは飛ばさない)。手の認識は暗い映像で精度が大きく落ちるため
pub fn brightLut(mean: f32, lut: *[256]u8) bool {
    if (mean >= 95) return false;
    const m = @max(mean, 4) / 255;
    // m^g = 0.47 となる g(0.47 ≒ 120/255)
    const g = std.math.clamp(@log(@as(f32, 0.47)) / @log(m), 0.25, 1);
    for (0..256) |i| {
        const v = @as(f32, @floatFromInt(i)) / 255;
        lut[i] = @intFromFloat(std.math.clamp(std.math.pow(f32, v, g) * 255, 0, 255));
    }
    return true;
}

test "brightLut: 暗いときだけ持ち上げる" {
    var lut: [256]u8 = undefined;
    try std.testing.expect(!brightLut(120, &lut));
    try std.testing.expect(brightLut(20, &lut));
    try std.testing.expect(lut[20] > 80 and lut[20] < 160);
    try std.testing.expect(lut[255] == 255 and lut[0] == 0);
}

test "Analyzer: 指を伸ばした・曲げた手を見分ける" {
    // まっすぐ上に伸びた手(親指は横へ): 開いた手
    var p: [N][3]f32 = undefined;
    p[0] = .{ 100, 200, 0 };
    const xs = [_]f32{ 60, 85, 100, 115, 130 };
    // 親指
    p[1] = .{ 80, 185, 0 };
    p[2] = .{ 65, 170, 0 };
    p[3] = .{ 50, 160, 0 };
    p[4] = .{ 35, 150, 0 };
    for (0..4) |f| {
        const x = xs[f + 1];
        const base = 5 + f * 4;
        p[base] = .{ x, 140, 0 };
        p[base + 1] = .{ x, 115, 0 };
        p[base + 2] = .{ x, 100, 0 };
        p[base + 3] = .{ x, 85, 0 };
    }
    var a = Analyzer{};
    var f = a.step(p, 640, 480, 0);
    try std.testing.expectEqual(Gesture.open, f.gesture);
    // 中指・薬指・小指を曲げる(先を手のひらへ): 指さす
    for (1..4) |k| {
        const base = 5 + k * 4;
        const x = xs[k + 1];
        p[base + 1] = .{ x, 125, 0 };
        p[base + 2] = .{ x, 140, 10 };
        p[base + 3] = .{ x, 150, 5 };
    }
    // 親指も畳む
    p[4] = .{ 100, 150, 0 };
    p[3] = .{ 92, 165, 0 };
    a.reset();
    f = a.step(p, 640, 480, 1);
    try std.testing.expectEqual(Gesture.point, f.gesture);
}
