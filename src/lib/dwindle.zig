// Hyprland の dwindle と同じ並べ方の木(画面にも OS にも依存しない。wm.zig がワークスペースごとに 1 本持つ)。
//
//   * 窓(葉)を開くと、狙った窓(フォーカス中・カーソルの下)の場所を 2 つに分け、片方に入る。
//     どちら側に入るかは呼ぶ側が決める(wm.zig はカーソルの反対側。カーソルの下の窓がフォーカスを持ち続けるように)。
//     → 左半分の窓の上で開けば、左半分がさらに分かれる(1 つ目の窓が常に左半分を占めるのではない)
//   * 分ける向きは、その場所の形で決まる(横長なら左右、縦長なら上下)。toggleSplit で逆に固定できる
//   * 窓を閉じると、兄弟がその場所を引き継ぐ
//   * 分け目ごとに比率を持つ(resize・splitRatio)
// 窓は usize の id(wm.zig は Window のポインタ)で表す。
const std = @import("std");

pub const Rect = [4]f32; // x, y, w, h
pub const Dir = enum { auto, side, stack };
pub const Item = struct { id: usize, rect: Rect };

pub const Node = struct {
    parent: ?*Node = null,
    /// 葉のときの窓
    id: usize = 0,
    a: ?*Node = null,
    b: ?*Node = null,
    ratio: f32 = 0.5,
    dir: Dir = .auto,
    /// 最後に並べたときの場所と、左右に分けたか(上下なら false)
    box: Rect = .{ 0, 0, 0, 0 },
    side: bool = true,

    fn leaf(n: *const Node) bool {
        return n.a == null;
    }
};

pub const Tree = struct {
    alloc: std.mem.Allocator,
    root: ?*Node = null,

    pub fn deinit(self: *Tree) void {
        if (self.root) |r| self.freeNode(r);
        self.root = null;
    }

    fn freeNode(self: *Tree, n: *Node) void {
        if (n.a) |x| self.freeNode(x);
        if (n.b) |x| self.freeNode(x);
        self.alloc.destroy(n);
    }

    pub fn find(self: *const Tree, id: usize) ?*Node {
        return if (self.root) |r| findIn(r, id) else null;
    }

    fn findIn(n: *Node, id: usize) ?*Node {
        if (n.leaf()) return if (n.id == id) n else null;
        return findIn(n.a.?, id) orelse findIn(n.b.?, id);
    }

    pub fn empty(self: *const Tree) bool {
        return self.root == null;
    }

    /// 葉の並び(左上から順に)
    pub fn order(self: *const Tree, out: []usize) usize {
        var n: usize = 0;
        if (self.root) |r| collect(r, out, &n);
        return n;
    }

    fn collect(nd: *Node, out: []usize, n: *usize) void {
        if (nd.leaf()) {
            if (n.* < out.len) out[n.*] = nd.id;
            n.* += 1;
            return;
        }
        collect(nd.a.?, out, n);
        collect(nd.b.?, out, n);
    }

    /// 窓 id を入れる。target の場所を分ける(無ければいちばん右下の葉)。first なら左・上の側に入る
    pub fn insert(self: *Tree, id: usize, target: ?usize, first: bool) !void {
        const leaf = try self.alloc.create(Node);
        leaf.* = .{ .id = id };
        const t = (if (target) |ti| self.find(ti) else null) orelse self.lastLeaf() orelse {
            self.root = leaf;
            return;
        };
        const old = self.alloc.create(Node) catch |e| {
            self.alloc.destroy(leaf);
            return e;
        };
        // t は分け目になり、元の窓は old へ移る
        old.* = .{ .id = t.id, .parent = t, .box = t.box };
        leaf.parent = t;
        t.id = 0;
        t.ratio = 0.5;
        t.dir = .auto;
        if (first) {
            t.a = leaf;
            t.b = old;
        } else {
            t.a = old;
            t.b = leaf;
        }
    }

    fn lastLeaf(self: *const Tree) ?*Node {
        var n = self.root orelse return null;
        while (!n.leaf()) n = n.b.?;
        return n;
    }

    /// 窓 id を外す。兄弟がその場所を引き継ぐ
    pub fn remove(self: *Tree, id: usize) void {
        const n = self.find(id) orelse return;
        const p = n.parent orelse {
            self.alloc.destroy(n);
            self.root = null;
            return;
        };
        const sib = if (p.a == n) p.b.? else p.a.?;
        const gp = p.parent;
        const box = p.box;
        p.* = sib.*;
        p.parent = gp;
        p.box = box;
        if (p.a) |x| x.parent = p;
        if (p.b) |x| x.parent = p;
        self.alloc.destroy(sib);
        self.alloc.destroy(n);
    }

    /// 2 つの窓の場所を入れ替える
    pub fn swap(self: *Tree, x: usize, y: usize) void {
        const a = self.find(x) orelse return;
        const b = self.find(y) orelse return;
        a.id = y;
        b.id = x;
    }

    /// area を分けて、窓ごとの場所を out に足す
    pub fn layout(self: *Tree, area: Rect, gap: f32, out: *std.ArrayList(Item)) void {
        if (self.root) |r| lay(r, area, gap, out);
    }

    fn lay(n: *Node, r: Rect, gap: f32, out: *std.ArrayList(Item)) void {
        n.box = r;
        if (n.leaf()) {
            out.append(.{ .id = n.id, .rect = r }) catch {};
            return;
        }
        n.side = switch (n.dir) {
            .auto => r[2] > r[3], // Hyprland と同じ: 横長のときだけ左右(正方形は上下)
            .side => true,
            .stack => false,
        };
        if (n.side) {
            const lw = (r[2] - gap) * n.ratio;
            lay(n.a.?, .{ r[0], r[1], lw, r[3] }, gap, out);
            lay(n.b.?, .{ r[0] + lw + gap, r[1], r[2] - lw - gap, r[3] }, gap, out);
        } else {
            const th = (r[3] - gap) * n.ratio;
            lay(n.a.?, .{ r[0], r[1], r[2], th }, gap, out);
            lay(n.b.?, .{ r[0], r[1] + th + gap, r[2], r[3] - th - gap }, gap, out);
        }
    }

    /// 窓 id のいる分け目の向きを逆にする(Hyprland の togglesplit)
    pub fn toggleSplit(self: *Tree, id: usize) void {
        const n = self.find(id) orelse return;
        const p = n.parent orelse return;
        p.dir = if (p.side) .stack else .side;
    }

    /// 窓 id のいる分け目の比率を d だけ変える(Hyprland の splitratio)
    pub fn splitRatio(self: *Tree, id: usize, d: f32) void {
        const n = self.find(id) orelse return;
        const p = n.parent orelse return;
        p.ratio = std.math.clamp(p.ratio + d, 0.1, 0.9);
    }

    /// 窓の辺を動かす(Super+右ドラッグ)。edges: 上 1・下 2・左 4・右 8。dx・dy は前回からの動き
    pub fn resize(self: *Tree, id: usize, dx: f32, dy: f32, edges: u32) void {
        const n = self.find(id) orelse return;
        if (dx != 0) if (edgeSplit(n, true, edges & 8 != 0)) |p| {
            p.ratio = std.math.clamp(p.ratio + dx / @max(p.box[2], 1), 0.1, 0.9);
        };
        if (dy != 0) if (edgeSplit(n, false, edges & 2 != 0)) |p| {
            p.ratio = std.math.clamp(p.ratio + dy / @max(p.box[3], 1), 0.1, 0.9);
        };
    }

    /// 窓の右(下)の辺を持つ分け目 = 窓が a 側にいる、いちばん近い左右(上下)の分け目。左(上)の辺なら b 側
    fn edgeSplit(n: *Node, side: bool, far_edge: bool) ?*Node {
        var cur = n;
        while (cur.parent) |p| : (cur = p) {
            if (p.side != side) continue;
            if ((p.a == cur) == far_edge) return p;
        }
        return null;
    }
};

test "dwindle: 左半分の窓の上で開くと左半分が分かれる" {
    const t = std.testing;
    var tr = Tree{ .alloc = t.allocator };
    defer tr.deinit();
    var items = std.ArrayList(Item).init(t.allocator);
    defer items.deinit();

    try tr.insert(1, null, false);
    try tr.insert(2, 1, false); // 1 | 2
    tr.layout(.{ 0, 0, 1000, 500 }, 0, &items);
    try t.expectEqual(@as(f32, 500), items.items[1].rect[0]);
    // 左の 1 の上で開く → 1 の場所(500x500 の正方形)が上下に分かれる。2 は右半分のまま
    try tr.insert(3, 1, false);
    items.clearRetainingCapacity();
    tr.layout(.{ 0, 0, 1000, 500 }, 0, &items);
    try t.expectEqual(@as(usize, 3), items.items.len);
    for (items.items) |it| switch (it.id) {
        1 => try t.expectEqualSlices(f32, &.{ 0, 0, 500, 250 }, &it.rect),
        3 => try t.expectEqualSlices(f32, &.{ 0, 250, 500, 250 }, &it.rect),
        2 => try t.expectEqualSlices(f32, &.{ 500, 0, 500, 500 }, &it.rect),
        else => unreachable,
    };
    // 1 を閉じると 3 が左半分を引き継ぐ
    tr.remove(1);
    items.clearRetainingCapacity();
    tr.layout(.{ 0, 0, 1000, 500 }, 0, &items);
    try t.expectEqual(@as(usize, 2), items.items.len);
    for (items.items) |it| if (it.id == 3) try t.expectEqualSlices(f32, &.{ 0, 0, 500, 500 }, &it.rect);
}

test "dwindle: 左側に入る・入れ替え・比率・向き" {
    const t = std.testing;
    var tr = Tree{ .alloc = t.allocator };
    defer tr.deinit();
    var items = std.ArrayList(Item).init(t.allocator);
    defer items.deinit();
    try tr.insert(1, null, false);
    try tr.insert(2, 1, true); // カーソルが 1 の左半分 → 2 | 1
    var ord: [4]usize = undefined;
    try t.expectEqual(@as(usize, 2), tr.order(&ord));
    try t.expectEqualSlices(usize, &.{ 2, 1 }, ord[0..2]);
    tr.swap(1, 2);
    _ = tr.order(&ord);
    try t.expectEqualSlices(usize, &.{ 1, 2 }, ord[0..2]);
    tr.layout(.{ 0, 0, 1000, 500 }, 0, &items);
    // 1 の右の辺を 100 動かす → 比率 0.6
    tr.resize(1, 100, 0, 8);
    items.clearRetainingCapacity();
    tr.layout(.{ 0, 0, 1000, 500 }, 0, &items);
    try t.expectApproxEqAbs(@as(f32, 600), items.items[0].rect[2], 0.01);
    // 2 の左の辺を動かしても同じ分け目
    tr.resize(2, -100, 0, 4);
    tr.toggleSplit(1);
    items.clearRetainingCapacity();
    tr.layout(.{ 0, 0, 1000, 500 }, 0, &items);
    try t.expectApproxEqAbs(@as(f32, 250), items.items[0].rect[3], 0.01);
    tr.remove(2);
    tr.remove(1);
    try t.expect(tr.empty());
}
