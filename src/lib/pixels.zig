// RGBA の画素の小さな処理(画面にも OS にも依存しない)
const std = @import("std");

/// 画像を縦横半分に(2x2 の平均)。同じ箱の中で詰める(書く位置は常に読む位置より前なので安全)。
/// 画面より 2 倍以上大きい壁紙を、見た目を変えずにテクスチャのメモリを 1/4 にするため
pub fn halveInPlace(px: [*]u8, w: *c_int, h: *c_int) void {
    const ow: usize = @intCast(w.*);
    const nw = ow / 2;
    const nh: usize = @intCast(@divTrunc(h.*, 2));
    for (0..nh) |y| for (0..nw) |x| for (0..4) |k| {
        const a = (2 * y * ow + 2 * x) * 4 + k;
        const b = a + ow * 4;
        const s: u32 = @as(u32, px[a]) + px[a + 4] + px[b] + px[b + 4];
        px[(y * nw + x) * 4 + k] = @intCast((s + 2) / 4);
    };
    w.* = @intCast(nw);
    h.* = @intCast(nh);
}

/// 画面(ow x oh)を覆うのに足りる大きさを保ったまま、半分にできる回数
pub fn halvings(w: c_int, h: c_int, ow: c_int, oh: c_int) u32 {
    var n: u32 = 0;
    var cw = w;
    var ch = h;
    while (ow > 0 and oh > 0 and cw >= 2 * ow and ch >= 2 * oh) : (n += 1) {
        cw = @divTrunc(cw, 2);
        ch = @divTrunc(ch, 2);
    }
    return n;
}

test "半分にする" {
    // 3x2 → 1x1(端の列は捨てる)
    var px = [_]u8{ 0, 0, 0, 255, 4, 4, 4, 255, 9, 9, 9, 9, 8, 8, 8, 255, 4, 4, 4, 255, 9, 9, 9, 9 };
    var w: c_int = 3;
    var h: c_int = 2;
    halveInPlace(&px, &w, &h);
    try std.testing.expectEqual(@as(c_int, 1), w);
    try std.testing.expectEqual(@as(c_int, 1), h);
    try std.testing.expectEqualSlices(u8, &.{ 4, 4, 4, 255 }, px[0..4]);
    try std.testing.expectEqual(@as(u32, 1), halvings(4096, 2160, 1920, 1080));
    try std.testing.expectEqual(@as(u32, 0), halvings(3000, 2000, 1920, 1080));
    try std.testing.expectEqual(@as(u32, 0), halvings(4096, 2160, 0, 0));
}
