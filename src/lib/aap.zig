// AirPods の AAP(Apple のアクセサリの通信)の読み書き: 送るパケット・頭の向きと電池のパケットの読み方・
// 頭を振って戻す動きの見つけ方。OS にも画面にも依存しない(つなぐのは ame-airpods コマンド)。
// 通信の形は LibrePods(kavishdevar/librepods)の解析による:
//   頭の向きのパケットは 04 00 04 00 17 00 00 00 10 00 で始まり、43・45・47 バイト目に向きの値
//   (符号つき 16 ビット、リトルエンディアン)。最初の 10 個の平均を「正面」にして、
//   上下(pitch) = ((o2 - 正面) + (o3 - 正面)) / 2 / 32000 × 180 度
//   左右(yaw)   = ((o2 - 正面) - (o3 - 正面)) / 2 / 32000 × 180 度
const std = @import("std");

// ---- AAP のパケット(LibrePods より)----
pub const HANDSHAKE = [_]u8{ 0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
pub const REQUEST_NOTIFICATIONS = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x0F, 0x00, 0xFF, 0xFF, 0xFF, 0xFF };
pub const HEAD_TRACKING_START = [_]u8{
    0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x08, 0xA1, 0x02, 0x42,
    0x0B, 0x08, 0x0E, 0x10, 0x02, 0x1A, 0x05, 0x01, 0x40, 0x9C, 0x00, 0x00,
};
pub const HEAD_TRACKING_STOP = [_]u8{
    0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x11, 0x00, 0x08, 0x7E, 0x10, 0x02,
    0x42, 0x0B, 0x08, 0x4E, 0x10, 0x02, 0x1A, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00,
};
pub const AAP_PSM: u16 = 0x1001;

pub const Gesture = enum(u8) { right, left, up, down };

/// 頭の向きを頼んだ返事(04 00 04 00 17 00 00 00 10 00 …、短いもの)で、断られた(状態 3)か
pub fn isRejected(p: []const u8) bool {
    if (p.len < 16 or p.len > 40) return false;
    const prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00 };
    if (!std.mem.eql(u8, p[0..10], &prefix)) return false;
    // 中身は protobuf: 08 <番号> 10 <状態> …。状態 3 = 使えない
    return p[12] == 0x08 and p[14] == 0x10 and p[15] == 0x03;
}

/// 頭の向きのパケットなら o1・o2・o3
pub fn parseHead(p: []const u8) ?[3]i16 {
    if (p.len <= 60) return null;
    const prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00 };
    if (!std.mem.eql(u8, p[0..10], &prefix)) return null;
    if (p[10] != 0x44 and p[10] != 0x45) return null;
    if (p[11] != 0x00) return null;
    return .{
        std.mem.readInt(i16, p[43..45], .little),
        std.mem.readInt(i16, p[45..47], .little),
        std.mem.readInt(i16, p[47..49], .little),
    };
}

/// 最初の 10 個の平均を正面にして、上下・左右の角度(度)にする
pub const Calib = struct {
    n: u32 = 0,
    sum: [3]f64 = .{ 0, 0, 0 },
    zero: [3]f32 = .{ 0, 0, 0 },

    pub fn angles(self: *Calib, o: [3]i16) ?[2]f32 {
        if (self.n < 10) {
            for (0..3) |i| self.sum[i] += @floatFromInt(o[i]);
            self.n += 1;
            if (self.n == 10) for (0..3) |i| {
                self.zero[i] = @floatCast(self.sum[i] / 10);
            };
            return null;
        }
        const a2 = @as(f32, @floatFromInt(o[1])) - self.zero[1];
        const a3 = @as(f32, @floatFromInt(o[2])) - self.zero[2];
        return .{ (a2 + a3) / 2 / 32000 * 180, (a2 - a3) / 2 / 32000 * 180 };
    }
};

/// 頭を振って戻す・向いて戻すを見つける
pub const Detector = struct {
    yaw_t: f32 = 25,
    pitch_t: f32 = 18,
    base_p: f32 = 0,
    base_y: f32 = 0,
    has_base: bool = false,
    state: enum { idle, out, held, cool } = .idle,
    yaw_axis: bool = false,
    sign: f32 = 1,
    t0: i64 = 0,
    last: i64 = 0,

    /// 戻ったとみなす近さ(度)
    const BACK: f32 = 8;
    /// 振ってからこの時間のうちに戻れば動き。過ぎたら「よそ見」として何もしない
    const WINDOW_MS: i64 = 1200;
    const COOL_MS: i64 = 700;

    pub fn step(self: *Detector, p: f32, y: f32, now: i64) ?Gesture {
        if (!self.has_base) {
            self.base_p = p;
            self.base_y = y;
            self.has_base = true;
            self.last = now;
            return null;
        }
        const dt: f32 = @as(f32, @floatFromInt(@max(now - self.last, 0))) / 1000;
        self.last = now;
        const dp = p - self.base_p;
        const dy = y - self.base_y;
        switch (self.state) {
            .idle => {
                // ふだんの姿勢へゆっくり合わせ直す(2.5 秒くらい)
                if (@abs(dp) < 6 and @abs(dy) < 6) {
                    const k = @min(1, dt / 2.5);
                    self.base_p += dp * k;
                    self.base_y += dy * k;
                }
                const ry = @abs(dy) / self.yaw_t;
                const rp = @abs(dp) / self.pitch_t;
                if (ry >= 1 or rp >= 1) {
                    self.state = .out;
                    self.yaw_axis = ry >= rp;
                    self.sign = if (self.yaw_axis) std.math.sign(dy) else std.math.sign(dp);
                    self.t0 = now;
                }
            },
            .out => {
                const d = if (self.yaw_axis) dy else dp;
                if (now - self.t0 > WINDOW_MS) {
                    self.state = .held;
                } else if (@abs(d) < BACK) {
                    self.state = .cool;
                    self.t0 = now;
                    return if (self.yaw_axis)
                        (if (self.sign > 0) .right else .left)
                    else
                        (if (self.sign > 0) .up else .down);
                }
            },
            .held => {
                // よそ見から戻ったら、その姿勢を基準にし直す
                if (@abs(dp) < BACK and @abs(dy) < BACK) self.state = .idle;
                if (now - self.t0 > 6000) {
                    // 長く向いたまま: そこを新しい基準に
                    self.base_p = p;
                    self.base_y = y;
                    self.state = .idle;
                }
            },
            .cool => if (now - self.t0 > COOL_MS) {
                self.state = .idle;
            },
        }
        return null;
    }
};

test "頭の向きのパケットを読む" {
    var p = [_]u8{0} ** 70;
    const prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x44, 0x00 };
    @memcpy(p[0..12], &prefix);
    std.mem.writeInt(i16, p[43..45], -100, .little);
    std.mem.writeInt(i16, p[45..47], 1234, .little);
    std.mem.writeInt(i16, p[47..49], -5678, .little);
    const o = parseHead(&p).?;
    try std.testing.expectEqual(@as(i16, -100), o[0]);
    try std.testing.expectEqual(@as(i16, 1234), o[1]);
    try std.testing.expectEqual(@as(i16, -5678), o[2]);
    p[10] = 0x33;
    try std.testing.expect(parseHead(&p) == null);
    try std.testing.expect(parseHead(p[0..40]) == null);
}

test "振って戻すと動き・向いたままは何もしない" {
    var d = Detector{};
    var t: i64 = 0;
    // 正面で落ち着く
    while (t < 1000) : (t += 50) try std.testing.expect(d.step(0, 0, t) == null);
    // 右へ 35 度振って 0.4 秒で戻す → right
    var got: ?Gesture = null;
    const t1 = t;
    while (t < t1 + 400) : (t += 50) {
        if (d.step(0, 35, t)) |g| got = g;
    }
    if (d.step(0, 2, t)) |g| got = g;
    try std.testing.expectEqual(Gesture.right, got.?);
    t += 1000;
    _ = d.step(0, 0, t);
    // 下を向いたまま 3 秒(キーボードを見る)→ 戻しても何もしない
    got = null;
    const t2 = t;
    while (t < t2 + 3000) : (t += 50) {
        if (d.step(-30, 0, t)) |g| got = g;
    }
    while (t < t2 + 3500) : (t += 50) {
        if (d.step(0, 0, t)) |g| got = g;
    }
    try std.testing.expect(got == null);
    // 上を向いてすぐ戻す → up
    t += 1000;
    const t3 = t;
    while (t < t3 + 300) : (t += 50) {
        if (d.step(25, 1, t)) |g| got = g;
    }
    while (t < t3 + 600) : (t += 50) {
        if (d.step(0, 0, t)) |g| got = g;
    }
    try std.testing.expectEqual(Gesture.up, got.?);
}

test "頭の向きを断られた返事" {
    // AirPods Pro 2 が返した実際のもの(DeviceID が Apple でないとき)
    const r = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x08, 0x00, 0x08, 0x21, 0x10, 0x03, 0x4a, 0x02, 0x08, 0x0e };
    try std.testing.expect(isRejected(&r));
    var ok = r;
    ok[15] = 0x02;
    try std.testing.expect(!isRejected(&ok));
}

test "最初の 10 個で正面を決める" {
    var cb = Calib{};
    for (0..10) |_| try std.testing.expect(cb.angles(.{ 0, 1000, 1000 }) == null);
    const a = cb.angles(.{ 0, 1000 + 3200, 1000 + 3200 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 18), a[0], 0.01); // 上下だけ
    try std.testing.expectApproxEqAbs(@as(f32, 0), a[1], 0.01);
}

// ---- 電池(AAP のパケット 04 00 04 00 04 00 [数] ([部品] 01 [残り%] [状態] 01) × 数)----

pub const Battery = struct {
    /// 残り %(null = 分からない・つながっていない)
    level: ?u8 = null,
    charging: bool = false,
};

/// 左・右・ケースの順
pub const Batteries = [3]Battery;

pub fn parseBattery(p: []const u8, out: *Batteries) bool {
    if (p.len < 7) return false;
    const prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x04, 0x00 };
    if (!std.mem.eql(u8, p[0..6], &prefix)) return false;
    const n: usize = p[6];
    if (n == 0 or n > 3 or p.len < 7 + n * 5) return false;
    out.* = .{ .{}, .{}, .{} };
    for (0..n) |i| {
        const e = p[7 + i * 5 ..][0..5];
        if (e[1] != 0x01) return false;
        const idx: usize = switch (e[0]) {
            0x04 => 0, // 左
            0x02 => 1, // 右
            0x08 => 2, // ケース
            else => continue,
        };
        // 状態: 01 充電中 / 02 使用中 / 04 つながっていない / 05 最適化充電
        if (e[3] == 0x04) continue;
        out[idx] = .{ .level = @min(e[2], 100), .charging = e[3] == 0x01 or e[3] == 0x05 };
    }
    return true;
}

test "電池のパケットを読む" {
    // AirPods Pro 2 が返した実際のもの: 左 60% 使用中・右 47% 使用中・ケースはつながっていない
    const p = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x03, 0x04, 0x01, 0x3c, 0x02, 0x01, 0x02, 0x01, 0x2f, 0x02, 0x01, 0x08, 0x01, 0x00, 0x04, 0x01 };
    var b: Batteries = undefined;
    try std.testing.expect(parseBattery(&p, &b));
    try std.testing.expectEqual(@as(u8, 60), b[0].level.?);
    try std.testing.expectEqual(@as(u8, 47), b[1].level.?);
    try std.testing.expect(b[2].level == null);
    try std.testing.expect(!b[0].charging);
}
