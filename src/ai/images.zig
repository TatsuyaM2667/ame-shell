// AI チャットに付ける画像の置き場と下ごしらえ。
//
// 付けた画像は $XDG_STATE_HOME/ame-shell/ai-images/<中身の hash>.<拡張子> に写す(会話を保存しても画像が残るように。
// 元のファイルを消したり動かしたりしても、会話の画像は見える)。
// 各社の API は画像の大きさに上限がある(Anthropic は 1 枚 5MB・長い辺 8000px、推奨は 1568px まで)ので、
//   ・PNG / JPEG で 3.5MB 以下・長い辺 2048px 以下 → そのまま
//   ・それより大きい PNG / JPEG(BMP も)→ 長い辺 1568px に縮めて PNG で書き直す(まだ大きければ 1024px)
//   ・GIF / WebP は縮められないので、3.5MB 以下ならそのまま、超えたら付けない
const std = @import("std");
const c = @import("../c.zig");
const lib_ai = @import("ame_lib").ai;
const icons = @import("../gfx/icons.zig");
const png = @import("../gfx/png.zig");

const MAX_BYTES = 3_500_000; // base64 にして 5MB 弱
const MAX_SIDE = 2048;

pub const Error = error{ NotImage, TooLarge, NoDir, Write, Decode };

fn dir(buf: []u8) ?[]const u8 {
    var pb: [512]u8 = undefined;
    const p = @import("ai.zig").statePath(&pb, "ai-images") orelse return null;
    std.fs.cwd().makePath(p) catch return null;
    std.posix.fchmodat(std.posix.AT.FDCWD, p, 0o700, 0) catch {};
    const n = @min(p.len, buf.len);
    @memcpy(buf[0..n], p[0..n]);
    return buf[0..n];
}

/// 画像のバイト列をしまい、そのパスを out に書いて返す(同じ中身なら同じファイル)
pub fn store(bytes: []const u8, out: []u8) Error![]const u8 {
    const mime = lib_ai.mimeOf(bytes) orelse return error.NotImage;
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const decodable = c.stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp) != 0;
    const small = bytes.len <= MAX_BYTES and (!decodable or @max(w, h) <= MAX_SIDE);
    if (small) return write(bytes, extOf(mime), out);
    if (!decodable) return error.TooLarge; // GIF・WebP の大きいもの
    // 縮めて PNG に
    const px = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 4) orelse return error.Decode;
    defer c.stbi_image_free(px);
    for ([_]u32{ 1568, 1024, 768 }) |side| {
        const k = @min(1.0, @as(f32, @floatFromInt(side)) / @as(f32, @floatFromInt(@max(w, h))));
        const ow: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(w)) * k)));
        const oh: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(h)) * k)));
        const scaled = icons.scaleRgba(px, @intCast(w), @intCast(h), ow, oh, false) orelse return error.Decode;
        defer std.c.free(scaled);
        var enc = std.ArrayList(u8).init(std.heap.c_allocator);
        defer enc.deinit();
        png.encode(enc.writer(), scaled[0 .. ow * oh * 4], @intCast(ow), @intCast(oh)) catch return error.Decode;
        if (enc.items.len <= MAX_BYTES) return write(enc.items, "png", out);
    }
    return error.TooLarge;
}

/// ファイルの画像をしまう
pub fn storeFile(path: []const u8, out: []u8) Error![]const u8 {
    const bytes = std.fs.cwd().readFileAlloc(std.heap.c_allocator, path, 64 << 20) catch return error.NotImage;
    defer std.heap.c_allocator.free(bytes);
    return store(bytes, out);
}

fn extOf(mime: []const u8) []const u8 {
    return mime["image/".len..];
}

fn write(bytes: []const u8, ext: []const u8, out: []u8) Error![]const u8 {
    var db: [512]u8 = undefined;
    const d = dir(&db) orelse return error.NoDir;
    const p = std.fmt.bufPrint(out, "{s}/{x:0>16}.{s}", .{ d, std.hash.Wyhash.hash(0, bytes), ext }) catch return error.NoDir;
    std.fs.cwd().access(p, .{}) catch {
        const f = std.fs.cwd().createFile(p, .{ .mode = 0o600 }) catch return error.Write;
        defer f.close();
        f.writeAll(bytes) catch return error.Write;
    };
    return p;
}

/// 理由を人の言葉に
pub fn describe(e: Error) []const u8 {
    return switch (e) {
        error.NotImage => "画像ではありません(PNG・JPEG・GIF・WebP を付けられます)",
        error.TooLarge => "画像が大きすぎます(GIF・WebP は 3.5MB まで)",
        error.Decode => "画像を読めませんでした",
        error.NoDir, error.Write => "画像を保存できませんでした",
    };
}
