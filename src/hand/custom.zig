// 自分のポーズ: 手の形そのもの(関節 21 点)と手の向きを登録して見分ける。片手でも両手でも登録できる。
// 「伸びている指」だけでは分けられない形(OK サイン・指を交差させる・横にしたピース(旗)・
// 両手でカメラを構える形など)も使える。
//
// 形の表し方(手 1 本): 手首を原点に、手首 → 中指の付け根が真上を向くように回し、その長さを 1 にそろえた
// 21 点の x, y(42 個)と、手の向き(手首 → 中指の付け根の向きの cos・sin、2 個)。左手は左右を反転するので、
// 右手で登録した片手の形を左手でも見分ける。向きを持つので、縦のピースと横のピースは別のポーズになる。
// 両手のポーズ: 画面の左にある手と右にある手の形を、組で覚える。両方が近いときだけ、そのポーズ。
// 登録: 設定画面(posegui.zig)で名前を付け、カメラの前で形を作って 1.5 秒撮る(20〜30 コマ)。
//       撮っている間に両手が映っていれば両手のポーズ、片手なら片手のポーズになる。
// 見分け方: 登録したどのコマとも、21 点の平均のずれ(手の大きさの何倍か)+ 向きのずれを比べ、一番近いポーズが
// そのポーズの境目より近ければ、そのポーズ。境目は、撮ったコマのばらつきから決める。
// 保存: $XDG_CONFIG_HOME/ame-shell/hand-custom-poses("AMEPOSE2")
const std = @import("std");

/// 手 1 本の形の数(21 点の x, y と、向きの cos・sin)
pub const DIM = 44;
pub const MAX = 16;
pub const SAMPLES = 32;
/// ポーズの番号(poses.zig の手のポーズの値)は 0x40 + 登録の順番
pub const BASE: u8 = 0x40;
/// 向きのずれの重み(横にしたピースと縦のピースを分けられるくらい。少し傾いたくらいでは外れない)
const ORI_W: f32 = 0.25;

pub const Shape = [DIM]f32;

pub const Pose = struct {
    name: [48]u8 = undefined,
    name_len: usize = 0,
    /// 1 = 片手 / 2 = 両手(samples[k][0] が画面の左の手、[1] が右の手)
    hands: u8 = 1,
    n: usize = 0,
    samples: [SAMPLES][2]Shape = undefined,
    /// これより近ければこのポーズ
    thr: f32 = 0.25,

    pub fn nameStr(self: *const Pose) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub var list: [MAX]Pose = undefined;
pub var n: usize = 0;
var loaded = false;

pub fn poses() []Pose {
    ensureLoaded();
    return list[0..n];
}

/// 手のポーズの値が自分のポーズか
pub fn isId(id: u8) bool {
    return id != 0xff and id >= BASE and id < BASE + MAX;
}

/// 両手のポーズか
pub fn isTwoHanded(id: u8) bool {
    if (!isId(id)) return false;
    const ps = poses();
    const i = id - BASE;
    return i < ps.len and ps[i].hands == 2;
}

/// 関節 21 点(画像の画素)→ 形。right = 右手らしさ(0〜1)
pub fn normalize(pts: [21][3]f32, right: f32) Shape {
    const ox = pts[0][0];
    const oy = pts[0][1];
    const vx = pts[9][0] - ox;
    const vy = pts[9][1] - oy;
    const len = @max(@sqrt(vx * vx + vy * vy), 1e-3);
    // 手首 → 中指の付け根を (0, -1) に向ける回転
    const ang = std.math.atan2(vy, vx) + std.math.pi / 2.0;
    const cs = @cos(-ang);
    const sn = @sin(-ang);
    const mirror: f32 = if (right < 0.5) -1 else 1;
    var out: Shape = undefined;
    for (0..21) |i| {
        const x = (pts[i][0] - ox) / len;
        const y = (pts[i][1] - oy) / len;
        out[i * 2] = (x * cs - y * sn) * mirror;
        out[i * 2 + 1] = x * sn + y * cs;
    }
    // 手の向き(手首 → 中指の付け根)。左手は左右を反転
    out[42] = vx / len * mirror;
    out[43] = vy / len;
    return out;
}

/// 21 点の平均のずれ + 向きのずれ
pub fn distance(a: *const Shape, b: *const Shape) f32 {
    var s: f32 = 0;
    for (0..21) |i| {
        const dx = a[i * 2] - b[i * 2];
        const dy = a[i * 2 + 1] - b[i * 2 + 1];
        s += @sqrt(dx * dx + dy * dy);
    }
    const ox = a[42] - b[42];
    const oy = a[43] - b[43];
    return s / 21 + ORI_W * @sqrt(ox * ox + oy * oy);
}

/// 片手の自分のポーズで、いちばん近いもの(境目より近いときだけ)。登録の順番を返す
pub fn match(f: *const Shape) ?usize {
    ensureLoaded();
    var best: ?usize = null;
    var best_r: f32 = 1;
    for (list[0..n], 0..) |*p, i| {
        if (p.hands != 1) continue;
        var d: f32 = 1e9;
        for (p.samples[0..p.n]) |*s| d = @min(d, distance(f, &s[0]));
        // 境目に対する近さで比べる(ばらつきの大きいポーズに引っぱられないように)
        const r = d / p.thr;
        if (r < best_r) {
            best_r = r;
            best = i;
        }
    }
    return best;
}

/// 両手の自分のポーズで、いちばん近いもの。left / right = 画面の左・右にある手の形
pub fn match2(left: *const Shape, right: *const Shape) ?usize {
    ensureLoaded();
    var best: ?usize = null;
    var best_r: f32 = 1;
    for (list[0..n], 0..) |*p, i| {
        if (p.hands != 2) continue;
        var d: f32 = 1e9;
        // 両方の手が近いこと(遠い方で決める)
        for (p.samples[0..p.n]) |*s| d = @min(d, @max(distance(left, &s[0]), distance(right, &s[1])));
        const r = d / p.thr;
        if (r < best_r) {
            best_r = r;
            best = i;
        }
    }
    return best;
}

pub fn find(name: []const u8) ?usize {
    ensureLoaded();
    for (list[0..n], 0..) |*p, i| if (std.mem.eql(u8, p.nameStr(), name)) return i;
    return null;
}

/// 登録する(同じ名前は置き換える)。hands = 1 なら samples[k][0] だけを使う。
/// 撮ったコマのばらつきから境目を決める
pub fn add(name: []const u8, hands: u8, samples: []const [2]Shape) ?usize {
    ensureLoaded();
    if (samples.len < 3 or name.len == 0 or (hands != 1 and hands != 2)) return null;
    const idx = find(name) orelse blk: {
        if (n >= MAX) return null;
        n += 1;
        break :blk n - 1;
    };
    var p = Pose{ .hands = hands };
    p.name_len = @min(name.len, p.name.len);
    @memcpy(p.name[0..p.name_len], name[0..p.name_len]);
    // 設定ファイルの区切り(空白)と混ざらないように
    for (p.name[0..p.name_len]) |*ch| if (ch.* == ' ' or ch.* == '\t') {
        ch.* = '_';
    };
    // 多ければ間引いて SAMPLES 個に
    const take = @min(samples.len, SAMPLES);
    for (0..take) |k| p.samples[k] = samples[k * samples.len / take];
    p.n = take;
    // ばらつき: 平均の形からのずれの平均(両手なら大きい方の手)
    var spread: f32 = 0;
    for (0..hands) |h| {
        var mean = [_]f32{0} ** DIM;
        for (p.samples[0..p.n]) |*s| for (&mean, s[h]) |*m, v| {
            m.* += v / @as(f32, @floatFromInt(p.n));
        };
        var sp: f32 = 0;
        for (p.samples[0..p.n]) |*s| sp += distance(&s[h], &mean) / @as(f32, @floatFromInt(p.n));
        spread = @max(spread, sp);
    }
    p.thr = std.math.clamp(spread * 3 + 0.1, 0.16, 0.34);
    list[idx] = p;
    save();
    return idx;
}

pub fn remove(i: usize) void {
    if (i >= n) return;
    std.mem.copyForwards(Pose, list[i .. n - 1], list[i + 1 .. n]);
    n -= 1;
    save();
}

// ---- ファイル ----

const MAGIC = "AMEPOSE2";

fn path(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |d| if (d.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell/hand-custom-poses", .{d}) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/ame-shell/hand-custom-poses", .{home}) catch null;
}

fn ensureLoaded() void {
    if (loaded) return;
    loaded = true;
    reload();
}

pub fn reload() void {
    loaded = true;
    n = 0;
    var pb: [512]u8 = undefined;
    const p = path(&pb) orelse return;
    const a = std.heap.page_allocator;
    const data = std.fs.cwd().readFileAlloc(a, p, 4 << 20) catch return;
    defer a.free(data);
    _ = parse(data);
}

/// 中身を読む(読めたポーズの数)。前の形式(AMEPOSE1、向きと両手が無い)は読まない
fn parse(data: []const u8) usize {
    if (data.len < 9 or !std.mem.eql(u8, data[0..8], MAGIC)) return 0;
    const count: usize = data[8];
    var off: usize = 9;
    n = 0;
    var k: usize = 0;
    while (k < count and n < MAX) : (k += 1) {
        if (off + 3 > data.len) break;
        const nl: usize = data[off];
        const ns: usize = data[off + 1];
        const hands: usize = data[off + 2];
        off += 3;
        if (ns > SAMPLES or hands < 1 or hands > 2 or off + nl + 4 + ns * hands * DIM * 4 > data.len) break;
        var pose = Pose{ .hands = @intCast(hands) };
        pose.name_len = @min(nl, pose.name.len);
        @memcpy(pose.name[0..pose.name_len], data[off .. off + pose.name_len]);
        off += nl;
        pose.thr = @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
        off += 4;
        pose.n = ns;
        for (0..ns) |s| for (0..hands) |h| for (0..DIM) |d| {
            pose.samples[s][h][d] = @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
            off += 4;
        };
        if (!std.math.isFinite(pose.thr) or pose.thr <= 0) continue;
        list[n] = pose;
        n += 1;
    }
    return n;
}

fn encode(w: anytype) !void {
    try w.writeAll(MAGIC);
    try w.writeByte(@intCast(n));
    for (list[0..n]) |*p| {
        try w.writeByte(@intCast(p.name_len));
        try w.writeByte(@intCast(p.n));
        try w.writeByte(p.hands);
        try w.writeAll(p.nameStr());
        try w.writeInt(u32, @bitCast(p.thr), .little);
        for (p.samples[0..p.n]) |*s| for (0..p.hands) |h| for (s[h]) |v| try w.writeInt(u32, @bitCast(v), .little);
    }
}

fn save() void {
    var pb: [512]u8 = undefined;
    const p = path(&pb) orelse return;
    if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
    const f = std.fs.cwd().createFile(p, .{}) catch return;
    defer f.close();
    var bw = std.io.bufferedWriter(f.writer());
    encode(bw.writer()) catch return;
    bw.flush() catch {};
}

// ---- 試験 ----

fn handPts(rot: f32, scale: f32, ox: f32, oy: f32) [21][3]f32 {
    var pts: [21][3]f32 = undefined;
    for (0..21) |i| {
        const f: f32 = @floatFromInt(i);
        // 手首から上(-y)へ伸びる手のような点
        const x0 = @sin(f) * 0.3 + (f - 10) * 0.05;
        const y0 = -f * 0.08 - 0.2 * @as(f32, @floatFromInt(@intFromBool(i >= 9)));
        const x = x0 * @cos(rot) - y0 * @sin(rot);
        const y = x0 * @sin(rot) + y0 * @cos(rot);
        pts[i] = .{ ox + x * scale, oy + y * scale, 0 };
    }
    return pts;
}

test "形: 大きさ・位置が違っても同じ、向きが違えば離れる、左右の手は同じ" {
    const a = normalize(handPts(0, 100, 300, 300), 1);
    const b = normalize(handPts(0, 230, 50, 400), 1);
    try std.testing.expect(distance(&a, &b) < 1e-3);
    // 少し傾けた(15 度)くらいでは近い
    const t = normalize(handPts(0.26, 100, 300, 300), 1);
    try std.testing.expect(distance(&a, &t) < 0.1);
    // 横にした(90 度): 指の形は同じでも、向きで離れる
    const side = normalize(handPts(std.math.pi / 2.0, 100, 300, 300), 1);
    try std.testing.expect(distance(&a, &side) > 0.3);
    // 鏡に映した左手
    var m = handPts(0, 100, 300, 300);
    for (&m) |*p| p[0] = 1000 - p[0];
    const cm = normalize(m, 0);
    try std.testing.expect(distance(&a, &cm) < 1e-3);
}

test "片手・両手のポーズを見分け、違う形は見分けない。ファイルに書いて読み直す" {
    n = 0;
    loaded = true;
    const up = normalize(handPts(0, 100, 300, 300), 1);
    const side = normalize(handPts(std.math.pi / 2.0, 100, 300, 300), 1);
    var p1 = Pose{ .n = 4, .thr = 0.2, .hands = 1 };
    var p2 = Pose{ .n = 4, .thr = 0.2, .hands = 2 };
    for (0..4) |k| {
        p1.samples[k][0] = up;
        p2.samples[k] = .{ up, side };
    }
    list[0] = p1;
    list[1] = p2;
    n = 2;
    try std.testing.expectEqual(@as(?usize, 0), match(&up));
    // 横の手だけでは片手のポーズ(縦)にならない
    try std.testing.expect(match(&side) == null);
    // 両手: 左が縦・右が横なら両手のポーズ、逆なら違う
    try std.testing.expectEqual(@as(?usize, 1), match2(&up, &side));
    try std.testing.expect(match2(&side, &up) == null);

    var buf: [1 << 15]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer());
    n = 0;
    try std.testing.expectEqual(@as(usize, 2), parse(fbs.getWritten()));
    try std.testing.expectEqual(@as(u8, 2), list[1].hands);
    try std.testing.expectEqual(@as(?usize, 1), match2(&up, &side));
    n = 0;
}
