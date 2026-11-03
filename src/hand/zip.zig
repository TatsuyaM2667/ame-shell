// zip の中の「圧縮していない」ファイルを取り出す(手のモデルの .task は無圧縮の zip)。外部のライブラリは使わない。
const std = @import("std");

/// zip の中の「圧縮していない」ファイルを探す(.task は無圧縮の zip)。中央ディレクトリから読む
pub fn unzipStored(z: []const u8, name: []const u8, out: *[]const u8) bool {
    if (z.len < 22) return false;
    var e: usize = z.len - 22;
    while (true) : (e -= 1) {
        if (std.mem.readInt(u32, z[e..][0..4], .little) == 0x06054b50) break;
        if (e == 0 or z.len - e > 70000) return false;
    }
    const count = std.mem.readInt(u16, z[e + 10 ..][0..2], .little);
    const cd_size: usize = std.mem.readInt(u32, z[e + 12 ..][0..4], .little);
    const cd_off: usize = std.mem.readInt(u32, z[e + 16 ..][0..4], .little);
    // zip の前に別のバイトが付いていることがある(MediaPipe の .task は先頭に 0 が 2 つ)。
    // 書かれている位置は zip の先頭から数えたものなので、実際の中央ディレクトリの位置との差を足す
    if (cd_off + cd_size > e) return false;
    const base = e - cd_size - cd_off;
    var off: usize = base + cd_off;
    for (0..count) |_| {
        if (off + 46 > z.len or std.mem.readInt(u32, z[off..][0..4], .little) != 0x02014b50) return false;
        const method = std.mem.readInt(u16, z[off + 10 ..][0..2], .little);
        const csize = std.mem.readInt(u32, z[off + 20 ..][0..4], .little);
        const nlen = std.mem.readInt(u16, z[off + 28 ..][0..2], .little);
        const xlen = std.mem.readInt(u16, z[off + 30 ..][0..2], .little);
        const clen = std.mem.readInt(u16, z[off + 32 ..][0..2], .little);
        const loc = base + std.mem.readInt(u32, z[off + 42 ..][0..4], .little);
        if (off + 46 + nlen > z.len) return false;
        const nm = z[off + 46 ..][0..nlen];
        if (std.mem.eql(u8, nm, name) and method == 0) {
            if (loc + 30 > z.len) return false;
            const lnlen = std.mem.readInt(u16, z[loc + 26 ..][0..2], .little);
            const lxlen = std.mem.readInt(u16, z[loc + 28 ..][0..2], .little);
            const start = loc + 30 + lnlen + lxlen;
            if (start + csize > z.len) return false;
            out.* = z[start .. start + csize];
            return true;
        }
        off += 46 + nlen + xlen + clen;
    }
    return false;
}

test "unzipStored: 中央ディレクトリから無圧縮のファイルを探す" {
    // 最小の zip(ファイル "a" = "xyz"、無圧縮)
    const z = "PK\x03\x04\x0a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x03\x00\x00\x00\x01\x00\x00\x00axyz" ++
        "PK\x01\x02\x14\x00\x0a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x03\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00a" ++
        "PK\x05\x06\x00\x00\x00\x00\x01\x00\x01\x00\x2f\x00\x00\x00\x22\x00\x00\x00\x00\x00";
    var out: []const u8 = undefined;
    try std.testing.expect(unzipStored(z, "a", &out));
    try std.testing.expectEqualStrings("xyz", out);
    try std.testing.expect(!unzipStored(z, "b", &out));
}

test "unzipStored: zip の前に余計なバイトがあっても読める" {
    const z = "\x00\x00" ++ "PK\x03\x04\x0a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x03\x00\x00\x00\x01\x00\x00\x00axyz" ++
        "PK\x01\x02\x14\x00\x0a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x03\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00a" ++
        "PK\x05\x06\x00\x00\x00\x00\x01\x00\x01\x00\x2f\x00\x00\x00\x22\x00\x00\x00\x00\x00";
    var out: []const u8 = undefined;
    try std.testing.expect(unzipStored(z, "a", &out));
    try std.testing.expectEqualStrings("xyz", out);
}

/// 手のモデル(.task)として使えるか: 中の 2 つのモデルを取り出せる
pub fn isHandModel(z: []const u8) bool {
    var d: []const u8 = undefined;
    var l: []const u8 = undefined;
    return unzipStored(z, "hand_detector.tflite", &d) and unzipStored(z, "hand_landmarks_detector.tflite", &l) and
        d.len > 8 and std.mem.eql(u8, d[4..8], "TFL3") and l.len > 8 and std.mem.eql(u8, l[4..8], "TFL3");
}
