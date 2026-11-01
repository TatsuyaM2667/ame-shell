// ログイン画面(SDDM の ame テーマ)と見た目をそろえるための書き出し。
//
// SDDM のテーマは別のユーザー(sddm)で動き、ホーム(0700)は読めない。そこでインストーラが
// ユーザーごとに書き込める置き場を用意する(scripts/sddm-theme.sh):
//   Linux: /var/lib/ame-shell/greeter/<ユーザー名>/   FreeBSD: /var/db/ame-shell/greeter/<ユーザー名>/
// 置き場が無い・書けないときは何もしない(SDDM のテーマは自前の背景で表示する)。
//
// 書き出すもの:
//   backdrop.bmp … ロック画面の背景(ぼかした壁紙。ロックしたときはロック画面そのものの背景、
//                  壁紙を変えたときはぼかしただけのもの)。ぼかしてあるので横 1280px 以下に縮める
//   avatar.bmp   … ユーザーの写真(256px の正方形)
//   state        … "accent=#rrggbb" と "tinted=0|1"(1 = ロック画面の暗さ・色味まで入った背景)
// 書き出しは別スレッドで行い、描画を止めない。GPU からの読み出しだけは描画スレッドで行う(数 ms)。
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const Color = @import("anim.zig").Color;

const MAX_W = 1280;

/// 置き場(書き込めるときだけ)。buf に入れて返す
pub fn dir(buf: []u8) ?[:0]const u8 {
    // 試験用: 置き場を差し替える
    if (std.posix.getenv("AME_SDDM_DIR")) |d| {
        const p = std.fmt.bufPrintZ(buf, "{s}", .{d}) catch return null;
        return if (c.access(p.ptr, c.W_OK) == 0) p else null;
    }
    const user = std.posix.getenv("USER") orelse std.posix.getenv("LOGNAME") orelse return null;
    const root = if (builtin.os.tag == .freebsd) "/var/db/ame-shell/greeter" else "/var/lib/ame-shell/greeter";
    const p = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ root, user }) catch return null;
    if (c.access(p.ptr, c.W_OK) != 0) return null;
    return p;
}

/// 今バインドしたいフレームバッファ fbo(0 = 画面)の (w, h) を読み出し、背景として書き出す。描画スレッドで呼ぶこと
pub fn saveFramebuffer(fbo: c.GLuint, w: c_int, h: c_int, accent: Color, tinted: bool) void {
    var db: [256]u8 = undefined;
    const d = dir(&db) orelse return;
    if (w <= 0 or h <= 0) return;
    const n: usize = @intCast(w * h * 4);
    const px: [*]u8 = @ptrCast(std.c.malloc(n) orelse return);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
    c.glReadPixels(0, 0, w, h, c.GL_RGBA, c.GL_UNSIGNED_BYTE, px);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    const job = Job{ .px = px, .w = @intCast(w), .h = @intCast(h), .accent = accent, .tinted = tinted, .name = "backdrop", .max_w = MAX_W };
    var j = job;
    @memcpy(j.dir[0..d.len], d);
    j.dir_len = d.len;
    const t = std.Thread.spawn(.{}, writeBackdrop, .{j}) catch {
        std.c.free(px);
        return;
    };
    t.detach();
}

/// 壁紙そのもの(ぼかす前)を書き出す: ログイン画面(ame-shell の greeter)がその人の壁紙で表示するため。
/// mode はオーロラ・雨なら絵は要らない(greeter が自分で描く)ので wallmode だけ書く
pub fn saveWallpaper(fbo: c.GLuint, w: c_int, h: c_int, mode: []const u8) void {
    var db: [256]u8 = undefined;
    const d = dir(&db) orelse return;
    var pb: [320]u8 = undefined;
    if (std.fmt.bufPrint(&pb, "{s}/wallmode", .{d})) |p| {
        if (std.fs.cwd().createFile(p, .{})) |f| {
            defer f.close();
            f.writer().print("{s}\n", .{mode}) catch {};
        } else |_| {}
    } else |_| {}
    const is_image = std.mem.eql(u8, mode, "image") or std.mem.eql(u8, mode, "video");
    if (!is_image or w <= 0 or h <= 0) return;
    const n: usize = @intCast(w * h * 4);
    const px: [*]u8 = @ptrCast(std.c.malloc(n) orelse return);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
    c.glReadPixels(0, 0, w, h, c.GL_RGBA, c.GL_UNSIGNED_BYTE, px);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    var j = Job{ .px = px, .w = @intCast(w), .h = @intCast(h), .accent = .{}, .tinted = false, .name = "wallpaper", .max_w = 1920, .state = false };
    @memcpy(j.dir[0..d.len], d);
    j.dir_len = d.len;
    const t = std.Thread.spawn(.{}, writeBackdrop, .{j}) catch {
        std.c.free(px);
        return;
    };
    t.detach();
}

const Job = struct {
    px: [*]u8,
    w: usize,
    h: usize,
    accent: Color,
    tinted: bool,
    /// 書き出すファイルの名前(.bmp を除く)と、横幅の上限
    name: []const u8,
    max_w: usize,
    /// state(アクセント色)も書くか
    state: bool = true,
    dir: [256]u8 = undefined,
    dir_len: usize = 0,
};

fn writeBackdrop(j: Job) void {
    defer std.c.free(j.px);
    const d = j.dir[0..j.dir_len];
    // ぼかした絵なので縮めても見た目は変わらない(大きな画面で 15MB にならないように)
    var step: usize = 1;
    while (j.w / step > j.max_w) step += 1;
    const ow = j.w / step;
    const oh = j.h / step;
    var pb: [320]u8 = undefined;
    const tmp = std.fmt.bufPrint(&pb, "{s}/{s}.bmp.tmp", .{ d, j.name }) catch return;
    // GL の読み出しは下の行から、BMP も下の行から(高さを正で書く)なので、そのまま並べればよい
    writeBmp(tmp, ow, oh, struct {
        fn get(ctx: *const Job, s: usize, x: usize, y: usize) [3]u8 {
            const i = ((y * s) * ctx.w + x * s) * 4;
            return .{ ctx.px[i], ctx.px[i + 1], ctx.px[i + 2] };
        }
    }.get, &j, step) catch return;
    var fb: [320]u8 = undefined;
    const final = std.fmt.bufPrint(&fb, "{s}/{s}.bmp", .{ d, j.name }) catch return;
    std.fs.cwd().rename(tmp, final) catch return;
    if (j.state) writeState(d, j.accent, j.tinted);
}

fn writeState(d: []const u8, accent: Color, tinted: bool) void {
    var pb: [320]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/state", .{d}) catch return;
    const f = std.fs.cwd().createFile(p, .{}) catch return;
    defer f.close();
    const to8 = struct {
        fn conv(v: f32) u8 {
            return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
        }
    }.conv;
    f.writer().print("accent=#{x:0>2}{x:0>2}{x:0>2}\ntinted={d}\n", .{ to8(accent.r), to8(accent.g), to8(accent.b), @intFromBool(tinted) }) catch {};
}

/// ユーザーの写真(size x size の RGBA、上の行から)を書き出す。どのスレッドから呼んでもよい
pub fn saveAvatar(px: [*]const u8, size: usize) void {
    var db: [256]u8 = undefined;
    const d = dir(&db) orelse return;
    var pb: [320]u8 = undefined;
    const tmp = std.fmt.bufPrint(&pb, "{s}/avatar.bmp.tmp", .{d}) catch return;
    const Ctx = struct { px: [*]const u8, size: usize };
    const ctx = Ctx{ .px = px, .size = size };
    writeBmp(tmp, size, size, struct {
        fn get(cx: *const Ctx, _: usize, x: usize, y: usize) [3]u8 {
            // BMP は下の行から: 画像の上下を反転して読む
            const i = ((cx.size - 1 - y) * cx.size + x) * 4;
            return .{ cx.px[i], cx.px[i + 1], cx.px[i + 2] };
        }
    }.get, &ctx, 1) catch return;
    var fb: [320]u8 = undefined;
    const final = std.fmt.bufPrint(&fb, "{s}/avatar.bmp", .{d}) catch return;
    std.fs.cwd().rename(tmp, final) catch {};
}

/// 24bit の BMP(下の行から)を書く。get(ctx, step, x, y) が RGB を返す
fn writeBmp(path: []const u8, w: usize, h: usize, comptime get: anytype, ctx: anytype, step: usize) !void {
    const f = try std.fs.cwd().createFile(path, .{ .mode = 0o644 });
    defer f.close();
    var bw = std.io.bufferedWriter(f.writer());
    const wr = bw.writer();
    const row = (w * 3 + 3) & ~@as(usize, 3);
    const size = 54 + row * h;
    try wr.writeAll("BM");
    try wr.writeInt(u32, @intCast(size), .little);
    try wr.writeInt(u32, 0, .little);
    try wr.writeInt(u32, 54, .little);
    try wr.writeInt(u32, 40, .little);
    try wr.writeInt(i32, @intCast(w), .little);
    try wr.writeInt(i32, @intCast(h), .little);
    try wr.writeInt(u16, 1, .little);
    try wr.writeInt(u16, 24, .little);
    try wr.writeInt(u32, 0, .little);
    try wr.writeInt(u32, @intCast(row * h), .little);
    try wr.writeInt(i32, 2835, .little);
    try wr.writeInt(i32, 2835, .little);
    try wr.writeInt(u32, 0, .little);
    try wr.writeInt(u32, 0, .little);
    for (0..h) |y| {
        for (0..w) |x| {
            const rgb = get(ctx, step, x, y);
            try wr.writeAll(&.{ rgb[2], rgb[1], rgb[0] });
        }
        for (0..row - w * 3) |_| try wr.writeByte(0);
    }
    try bw.flush();
}
