// PNG の書き出し(スクリーンショット用)。外部ライブラリを使わず、圧縮は std の zlib。
const std = @import("std");
const ca = std.heap.c_allocator;

/// RGBA → PNG(色は RGB 8bit。行ごとに None / Sub / Up / Paeth から差の小さいものを選ぶ)
pub fn encode(w: anytype, rgba: []const u8, width: u32, height: u32) !void {
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // RGB
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(w, "IHDR", &ihdr);

    // IDAT: zlib で圧縮した行(先頭 1 バイトがフィルタの種類)
    var idat = std.ArrayList(u8).init(ca);
    defer idat.deinit();
    {
        var z = try std.compress.zlib.compressor(idat.writer(), .{ .level = .fast });
        const rw: usize = @as(usize, width) * 3;
        const rows = try ca.alloc(u8, rw * 6); // 前の行・今の行・候補 4 つ(None は今の行そのもの)
        defer ca.free(rows);
        const prev = rows[0..rw];
        const cur = rows[rw .. 2 * rw];
        @memset(prev, 0);
        var cand: [3][]u8 = .{ rows[2 * rw .. 3 * rw], rows[3 * rw .. 4 * rw], rows[4 * rw .. 5 * rw] };
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const src = rgba[y * width * 4 ..][0 .. @as(usize, width) * 4];
            for (0..width) |x| {
                cur[x * 3 + 0] = src[x * 4 + 0];
                cur[x * 3 + 1] = src[x * 4 + 1];
                cur[x * 3 + 2] = src[x * 4 + 2];
            }
            var best: u8 = 0;
            var best_sum: u64 = score(cur);
            for (0..rw) |i| {
                const a: u8 = if (i >= 3) cur[i - 3] else 0;
                const b = prev[i];
                const cc: u8 = if (i >= 3) prev[i - 3] else 0;
                cand[0][i] = cur[i] -% a;
                cand[1][i] = cur[i] -% b;
                cand[2][i] = cur[i] -% paeth(a, b, cc);
            }
            for (cand, 1..) |cd, k| {
                const sc = score(cd);
                if (sc < best_sum) {
                    best_sum = sc;
                    best = @intCast(if (k == 3) 4 else k); // Sub=1 Up=2 Paeth=4
                }
            }
            try z.writer().writeByte(best);
            try z.writer().writeAll(switch (best) {
                0 => cur,
                1 => cand[0],
                2 => cand[1],
                else => cand[2],
            });
            @memcpy(prev, cur);
        }
        try z.finish();
    }
    try chunk(w, "IDAT", idat.items);
    try chunk(w, "IEND", "");
}

fn score(row: []const u8) u64 {
    var s: u64 = 0;
    for (row) |v| s += if (v < 128) v else 256 - @as(u64, v);
    return s;
}

fn paeth(a: u8, b: u8, cc: u8) u8 {
    const p: i16 = @as(i16, a) + b - cc;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - cc);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return cc;
}

fn chunk(w: anytype, typ: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try w.writeAll(&len);
    try w.writeAll(typ);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(typ);
    crc.update(data);
    var cb: [4]u8 = undefined;
    std.mem.writeInt(u32, &cb, crc.final(), .big);
    try w.writeAll(&cb);
}

test "png: 小さな画像を書いて std の zlib で読み戻せる" {
    const w = 5;
    const h = 3;
    var px: [w * h * 4]u8 = undefined;
    for (0..w * h) |i| px[i * 4 ..][0..4].* = .{ @intCast(i * 13 % 256), @intCast(i * 7 % 256), @intCast(i * 29 % 256), 255 };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try encode(out.writer(), &px, w, h);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", out.items[0..8]);
    // IDAT を取り出して展開し、フィルタを戻すと元の画素になる
    const idat_len = std.mem.readInt(u32, out.items[33..37], .big);
    try std.testing.expectEqualSlices(u8, "IDAT", out.items[37..41]);
    var fbs = std.io.fixedBufferStream(out.items[41 .. 41 + idat_len]);
    var raw = std.ArrayList(u8).init(std.testing.allocator);
    defer raw.deinit();
    try std.compress.zlib.decompress(fbs.reader(), raw.writer());
    try std.testing.expectEqual(@as(usize, h * (1 + w * 3)), raw.items.len);
    var prev = [_]u8{0} ** (w * 3);
    var cur: [w * 3]u8 = undefined;
    for (0..h) |y| {
        const row = raw.items[y * (1 + w * 3) ..][0 .. 1 + w * 3];
        for (0..w * 3) |i| {
            const a: u8 = if (i >= 3) cur[i - 3] else 0;
            const b = prev[i];
            const cc: u8 = if (i >= 3) prev[i - 3] else 0;
            cur[i] = row[1 + i] +% switch (row[0]) {
                0 => 0,
                1 => a,
                2 => b,
                4 => paeth(a, b, cc),
                else => unreachable,
            };
        }
        for (0..w) |x| try std.testing.expectEqualSlices(u8, px[(y * w + x) * 4 ..][0..3], cur[x * 3 ..][0..3]);
        prev = cur;
    }
}
