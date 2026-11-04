// 自分のポーズ: 手の形そのもの(関節 21 点)を登録して見分ける。「伸びている指」だけでは分けられない形
// (OK サイン・指を交差させる・親指の向き・指の曲げ方など)も使える。
//
// 形の表し方: 手首を原点に、手首 → 中指の付け根が真上を向くように回し、その長さを 1 にそろえた 21 点の x, y
// (42 個の数)。左手は左右を反転するので、右手で登録した形を左手でも見分ける。
// 登録: 設定画面(posegui.zig)で名前を付け、カメラの前で形を作って 1.5 秒撮る(20〜30 コマ)。
// 見分け方: 登録したどのコマとも、21 点の平均のずれ(手の大きさの何倍か)を比べ、一番近いポーズが
// そのポーズの境目より近ければ、そのポーズ。境目は、撮ったコマのばらつきから決める。
// 保存: $XDG_CONFIG_HOME/ame-shell/hand-custom-poses(名前と数。"AMEPOSE1")
const std = @import("std");

pub const DIM = 42;
pub const MAX = 16;
pub const SAMPLES = 32;
/// ポーズの番号(poses.zig の手のポーズの値)は 0x40 + 登録の順番
pub const BASE: u8 = 0x40;

pub const Shape = [DIM]f32;

pub const Pose = struct {
    name: [48]u8 = undefined,
    name_len: usize = 0,
    n: usize = 0,
    samples: [SAMPLES]Shape = undefined,
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
    return out;
}

/// 21 点の平均のずれ
pub fn distance(a: *const Shape, b: *const Shape) f32 {
    var s: f32 = 0;
    for (0..21) |i| {
        const dx = a[i * 2] - b[i * 2];
        const dy = a[i * 2 + 1] - b[i * 2 + 1];
        s += @sqrt(dx * dx + dy * dy);
    }
    return s / 21;
}

/// いちばん近い登録したポーズ(境目より近いときだけ)。登録の順番を返す
pub fn match(f: *const Shape) ?usize {
    ensureLoaded();
    var best: ?usize = null;
    var best_r: f32 = 1;
    for (list[0..n], 0..) |*p, i| {
        var d: f32 = 1e9;
        for (p.samples[0..p.n]) |*s| d = @min(d, distance(f, s));
        // 境目に対する近さで比べる(ばらつきの大きいポーズに引っぱられないように)
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

/// 登録する(同じ名前は置き換える)。撮ったコマのばらつきから境目を決める
pub fn add(name: []const u8, samples: []const Shape) ?usize {
    ensureLoaded();
    if (samples.len < 3 or name.len == 0) return null;
    const idx = find(name) orelse blk: {
        if (n >= MAX) return null;
        n += 1;
        break :blk n - 1;
    };
    var p = Pose{};
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
    // ばらつき: 平均の形からのずれの平均
    var mean = [_]f32{0} ** DIM;
    for (p.samples[0..p.n]) |*s| for (&mean, s) |*m, v| {
        m.* += v / @as(f32, @floatFromInt(p.n));
    };
    var spread: f32 = 0;
    for (p.samples[0..p.n]) |*s| spread += distance(s, &mean) / @as(f32, @floatFromInt(p.n));
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

const MAGIC = "AMEPOSE1";

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
    const data = std.fs.cwd().readFileAlloc(a, p, 1 << 20) catch return;
    defer a.free(data);
    _ = parse(data);
}

/// 中身を読む(読めたポーズの数)
fn parse(data: []const u8) usize {
    if (data.len < 9 or !std.mem.eql(u8, data[0..8], MAGIC)) return 0;
    const count = data[8];
    var off: usize = 9;
    n = 0;
    var k: usize = 0;
    while (k < count and n < MAX) : (k += 1) {
        if (off + 2 > data.len) break;
        const nl: usize = data[off];
        const ns: usize = data[off + 1];
        off += 2;
        if (ns > SAMPLES or off + nl + 4 + ns * DIM * 4 > data.len) break;
        var pose = Pose{};
        pose.name_len = @min(nl, pose.name.len);
        @memcpy(pose.name[0..pose.name_len], data[off .. off + pose.name_len]);
        off += nl;
        pose.thr = @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
        off += 4;
        pose.n = ns;
        for (0..ns) |s| for (0..DIM) |d| {
            pose.samples[s][d] = @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
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
        try w.writeAll(p.nameStr());
        try w.writeInt(u32, @bitCast(p.thr), .little);
        for (p.samples[0..p.n]) |*s| for (s) |v| try w.writeInt(u32, @bitCast(v), .little);
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

test "形の正規化: 回しても、大きさを変えても、左右の手でも同じ" {
    var pts: [21][3]f32 = undefined;
    for (0..21) |i| {
        const f: f32 = @floatFromInt(i);
        pts[i] = .{ 100 + f * 3, 200 - f * 7 + @sin(f) * 5, 0 };
    }
    const a = normalize(pts, 1);
    // 2 倍に大きくして 90 度回し、ずらす
    var q: [21][3]f32 = undefined;
    for (0..21) |i| {
        const x = (pts[i][0] - 100) * 2;
        const y = (pts[i][1] - 200) * 2;
        q[i] = .{ 500 - y, 300 + x, 0 };
    }
    const b = normalize(q, 1);
    try std.testing.expect(distance(&a, &b) < 1e-3);
    // 鏡に映した左手
    var m: [21][3]f32 = undefined;
    for (0..21) |i| m[i] = .{ 1000 - pts[i][0], pts[i][1], 0 };
    const cm = normalize(m, 0);
    try std.testing.expect(distance(&a, &cm) < 1e-3);
}

test "登録したポーズを見分け、違う形は見分けない" {
    n = 0;
    loaded = true;
    var s1: [8]Shape = undefined;
    var s2: [8]Shape = undefined;
    for (0..8) |k| {
        for (0..DIM) |d| {
            const jitter = @as(f32, @floatFromInt((k * 7 + d * 3) % 5)) * 0.004;
            s1[k][d] = @as(f32, @floatFromInt(d % 7)) * 0.1 + jitter;
            s2[k][d] = @as(f32, @floatFromInt((d * 5) % 11)) * 0.1 + jitter;
        }
    }
    // 保存はしない(試験なので list に直接)
    var p1 = Pose{ .n = 8, .thr = 0.2 };
    var p2 = Pose{ .n = 8, .thr = 0.2 };
    for (0..8) |k| {
        p1.samples[k] = s1[k];
        p2.samples[k] = s2[k];
    }
    list[0] = p1;
    list[1] = p2;
    n = 2;
    try std.testing.expectEqual(@as(?usize, 0), match(&s1[3]));
    try std.testing.expectEqual(@as(?usize, 1), match(&s2[5]));
    var far: Shape = undefined;
    for (&far) |*v| v.* = 3;
    try std.testing.expect(match(&far) == null);

    // ファイルの形で書いて読み直す
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer());
    n = 0;
    try std.testing.expectEqual(@as(usize, 2), parse(fbs.getWritten()));
    try std.testing.expectEqual(@as(?usize, 1), match(&s2[2]));
    n = 0;
}

/// 手のポーズの値が自分のポーズか
pub fn isId(id: u8) bool {
    return id != 0xff and id >= BASE and id < BASE + MAX;
}
