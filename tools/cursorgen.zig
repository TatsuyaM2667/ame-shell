// cursorgen: ame-shell のオリジナルのマウスカーソル(Xcursor のテーマ "ame")を作る。zig build が実行する。
//
//   cursorgen <出力先のテーマのディレクトリ>   → <出力先>/index.theme と <出力先>/cursors/*
//
// 形は 32×32 の座標の SVG で書き、同梱の nanosvg でラスタライズして、Xcursor の形式を直接書く
// (xcursorgen や ImageMagick は使わない)。見た目は ame-shell のガラスに合わせて、
//   本体 = 紺のグラデーション / 縁 = 白い細い線 / 影 = ぼかした柔らかい影 / 動く部分・目印 = アクセントの青。
// 縁は「全部の形を太い白い線で描いてから、その上に本体を塗る」ので、形を重ねても継ぎ目が出ない。
const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("math.h");
    @cInclude("nanosvg.h");
    @cInclude("nanosvgrast.h");
});

/// 書き出す大きさ(XCURSOR_SIZE。画面の拡大率に合わせて大きいものも)
const sizes = [_]u32{ 24, 32, 48, 64, 96 };
/// 回る輪の 1 周のコマ数と、1 コマの時間(ms)
const FRAMES = 24;
const DELAY = 40;

const BODY_TOP = "#2a3550";
const BODY_BOT = "#121826";
const RIM = "#f4f8ff";
const ACCENT = "#7ab8ff";
const DANGER = "#ff7d8e";

// ---- 形(本体に塗るもの。fill / stroke は外側の <g> から受け継ぐ)----

const arrow =
    \\<path d="M6 3.5 L6 24.6 L11.1 19.8 L14.5 27.4 Q15.0 28.5 16.1 28.0 L18.2 27.1 Q19.3 26.6 18.8 25.5 L15.5 18.2 L22.6 18.2 Z"/>
;
/// 指をさす手(人差し指 + 握った 3 本 + 親指 + 手のひら)
const hand =
    \\<rect x="11" y="3.2" width="5.2" height="16" rx="2.6"/>
    \\<rect x="15.6" y="11.2" width="4.6" height="8" rx="2.3"/>
    \\<rect x="19.6" y="12.4" width="4.4" height="8" rx="2.2"/>
    \\<rect x="8.6" y="14" width="15.4" height="14" rx="5"/>
    \\<rect x="5.6" y="14.6" width="5" height="9.5" rx="2.5" transform="rotate(-38 8.1 19.3)"/>
;
/// 開いた手(つかめる)
const hand_open =
    \\<rect x="8.4" y="7.4" width="4.2" height="13" rx="2.1"/>
    \\<rect x="12.4" y="4.6" width="4.4" height="15" rx="2.2"/>
    \\<rect x="16.6" y="5.6" width="4.4" height="14" rx="2.2"/>
    \\<rect x="20.8" y="8.6" width="4.0" height="12" rx="2.0"/>
    \\<rect x="8.4" y="14.5" width="16.4" height="13.5" rx="5.2"/>
    \\<rect x="4.4" y="15.2" width="4.8" height="9.5" rx="2.4" transform="rotate(-40 6.8 20)"/>
;
/// 握った手(つかんでいる)
const hand_closed =
    \\<rect x="8.8" y="11" width="4.2" height="8" rx="2.1"/>
    \\<rect x="12.8" y="10" width="4.4" height="8" rx="2.2"/>
    \\<rect x="17" y="10.4" width="4.4" height="8" rx="2.2"/>
    \\<rect x="21.2" y="11.6" width="4.0" height="7.5" rx="2.0"/>
    \\<rect x="8.6" y="14" width="16.6" height="13.5" rx="5.2"/>
    \\<rect x="5.4" y="16.6" width="4.8" height="7.6" rx="2.4" transform="rotate(-50 7.8 20.4)"/>
;
const ibeam =
    \\<rect x="11.2" y="4.6" width="9.6" height="2.6" rx="1.3"/>
    \\<rect x="14.7" y="5.5" width="2.6" height="21" rx="1.0"/>
    \\<rect x="11.2" y="24.8" width="9.6" height="2.6" rx="1.3"/>
;
const cross =
    \\<rect x="14.9" y="3.5" width="2.2" height="10" rx="1.1"/>
    \\<rect x="14.9" y="18.5" width="2.2" height="10" rx="1.1"/>
    \\<rect x="3.5" y="14.9" width="10" height="2.2" rx="1.1"/>
    \\<rect x="18.5" y="14.9" width="10" height="2.2" rx="1.1"/>
;
const plus_fat =
    \\<rect x="13.2" y="4.5" width="5.6" height="23" rx="1.6"/>
    \\<rect x="4.5" y="13.2" width="23" height="5.6" rx="1.6"/>
;
const disk = "<circle cx=\"16\" cy=\"16\" r=\"11\"/>";
const dbl_arrow = "<path d=\"M16 3 L22.4 10.2 H18.3 V21.8 H22.4 L16 29 L9.6 21.8 H13.7 V10.2 H9.6 Z\"/>";
const split_arrow =
    \\<rect x="14.8" y="5" width="2.4" height="22" rx="1.2"/>
    \\<path d="M3.6 16 L9.6 10.4 V14.6 H12.6 V17.4 H9.6 V21.6 Z"/>
    \\<path d="M28.4 16 L22.4 10.4 V14.6 H19.4 V17.4 H22.4 V21.6 Z"/>
;
/// 上下左右の矢印(1 本の輪郭。2 本の両矢印を重ねると頭どうしが重なって塊になる)
const four_way = "<path d=\"M16 3 L20.8 8.4 H17.4 V14.6 H23.6 V11.2 L29 16 L23.6 20.8 V17.4 H17.4 V23.6 H20.8 L16 29 L11.2 23.6 H14.6 V17.4 H8.4 V20.8 L3 16 L8.4 11.2 V14.6 H14.6 V8.4 H11.2 Z\"/>";
const lens =
    \\<circle cx="13" cy="13" r="8.6"/>
    \\<rect x="18.4" y="17.2" width="4.4" height="11" rx="2.2" transform="rotate(-45 20.6 22.7)"/>
;

// ---- 目印(アクセント。形とは別に描く)----

fn spinnerArc(comptime cx: []const u8, comptime cy: []const u8, comptime r: []const u8, comptime w: []const u8) []const u8 {
    // 円の 3/8 の弧。{R} は回転角(コマごとに差し替える)
    return "<circle cx=\"" ++ cx ++ "\" cy=\"" ++ cy ++ "\" r=\"" ++ r ++ "\" fill=\"none\" stroke=\"#ffffff\" stroke-opacity=\"0.16\" stroke-width=\"" ++ w ++ "\"/>" ++
        "<g transform=\"rotate({R} " ++ cx ++ " " ++ cy ++ ")\"><path d=\"M" ++ cx ++ " " ++ "{TOP}" ++ " A" ++ r ++ " " ++ r ++ " 0 0 1 {AX} {AY}\" fill=\"none\" stroke=\"" ++ ACCENT ++ "\" stroke-width=\"" ++ w ++ "\" stroke-linecap=\"round\"/></g>";
}

const Cursor = struct {
    name: []const u8,
    shapes: []const u8,
    /// アクセントの部分(形の上に描く)。{R}{TOP}{AX}{AY} を含むと回る
    marks: []const u8 = "",
    /// ラスタライズのときに形の中心が動くもの(回転)はこちら: <g transform> で全体を包む
    transform: []const u8 = "",
    hot: [2]f32,
    /// 回る輪の中心と半径(marks に弧があるとき)
    spin: ?[3]f32 = null,
    aliases: []const []const u8 = &.{},
};

const badge = struct {
    fn at(comptime inner: []const u8) []const u8 {
        return "<circle cx=\"23.6\" cy=\"23.6\" r=\"6.4\" fill=\"" ++ ACCENT ++ "\" stroke=\"" ++ RIM ++ "\" stroke-width=\"1.4\"/>" ++ inner;
    }
};

const cursors = [_]Cursor{
    .{ .name = "default", .shapes = arrow, .hot = .{ 6, 3.5 }, .aliases = &.{ "left_ptr", "arrow", "top_left_arrow", "left-arrow", "right_ptr", "center_ptr", "draft", "pencil", "color-picker" } },
    .{ .name = "pointer", .shapes = hand, .hot = .{ 13.6, 3.6 }, .aliases = &.{ "hand1", "hand2", "pointing_hand", "e29285e634086352946a0e7090d73106", "9d800788f1b08800ae810202380a0822" } },
    .{ .name = "grab", .shapes = hand_open, .hot = .{ 16, 16 }, .aliases = &.{ "openhand", "5aca4d189052212118709018842178c0", "208530c400c041818281048008011002" } },
    .{ .name = "grabbing", .shapes = hand_closed, .hot = .{ 16, 16 }, .aliases = &.{ "closedhand", "dnd-none", "fcf21c00b30f7e3f83fe0dfd12e71cff" } },
    .{ .name = "text", .shapes = ibeam, .hot = .{ 16, 16 }, .aliases = &.{ "xterm", "ibeam" } },
    .{ .name = "vertical-text", .shapes = ibeam, .transform = "rotate(90 16 16)", .hot = .{ 16, 16 } },
    .{ .name = "crosshair", .shapes = cross, .marks = "<circle cx=\"16\" cy=\"16\" r=\"1.8\" fill=\"" ++ ACCENT ++ "\"/>", .hot = .{ 16, 16 }, .aliases = &.{ "cross", "tcross", "cross_reverse", "diamond_cross" } },
    .{ .name = "cell", .shapes = plus_fat, .hot = .{ 16, 16 }, .aliases = &.{"plus"} },
    .{ .name = "wait", .shapes = disk, .marks = spinnerArc("16", "16", "6.6", "2.8"), .spin = .{ 16, 16, 6.6 }, .hot = .{ 16, 16 }, .aliases = &.{"watch"} },
    .{ .name = "progress", .shapes = arrow ++ "<circle cx=\"23.4\" cy=\"23.4\" r=\"6.6\"/>", .marks = spinnerArc("23.4", "23.4", "3.9", "2.0"), .spin = .{ 23.4, 23.4, 3.9 }, .hot = .{ 6, 3.5 }, .aliases = &.{ "left_ptr_watch", "half-busy", "00000000000000020006000e7e9ffc3f", "08e8e1c95fe2fc01f976f1e063a24ccd", "3ecb610c1bf2410f44200f48c40d3599" } },
    .{ .name = "not-allowed", .shapes = disk, .marks = "<circle cx=\"16\" cy=\"16\" r=\"6.6\" fill=\"none\" stroke=\"" ++ DANGER ++ "\" stroke-width=\"2.6\"/><path d=\"M11.3 20.7 L20.7 11.3\" stroke=\"" ++ DANGER ++ "\" stroke-width=\"2.6\" stroke-linecap=\"round\"/>", .hot = .{ 16, 16 }, .aliases = &.{ "crossed_circle", "forbidden", "no-drop", "dnd-no-drop", "circle", "X_cursor", "x-cursor", "pirate", "03b6e0fcb3499374a867c041f52298f0" } },
    .{ .name = "move", .shapes = four_way, .hot = .{ 16, 16 }, .aliases = &.{ "fleur", "size_all", "all-scroll", "all-resize", "dnd-move", "4498f0e0c1937ffe01fd06f973665830", "9081237383d90e509aa00f00170e968f" } },
    .{ .name = "ns-resize", .shapes = dbl_arrow, .hot = .{ 16, 16 }, .aliases = &.{ "sb_v_double_arrow", "v_double_arrow", "size_ver", "size-ver", "n-resize", "s-resize", "top_side", "bottom_side", "up-arrow", "down-arrow", "up_arrow", "00008160000006810000408080010102" } },
    .{ .name = "ew-resize", .shapes = dbl_arrow, .transform = "rotate(90 16 16)", .hot = .{ 16, 16 }, .aliases = &.{ "sb_h_double_arrow", "h_double_arrow", "size_hor", "size-hor", "e-resize", "w-resize", "left_side", "right_side", "right-arrow", "028006030e0e7ebffc7f7070c0600140" } },
    .{ .name = "nwse-resize", .shapes = dbl_arrow, .transform = "rotate(-45 16 16)", .hot = .{ 16, 16 }, .aliases = &.{ "size_fdiag", "size-fdiag", "nw-resize", "se-resize", "top_left_corner", "bottom_right_corner", "bd_double_arrow", "c7088f0f3e6c8088236ef8e1e3e70000" } },
    .{ .name = "nesw-resize", .shapes = dbl_arrow, .transform = "rotate(45 16 16)", .hot = .{ 16, 16 }, .aliases = &.{ "size_bdiag", "size-bdiag", "ne-resize", "sw-resize", "top_right_corner", "bottom_left_corner", "fd_double_arrow", "fcf1c3c7cd4491d801f1e1c78f100000" } },
    .{ .name = "col-resize", .shapes = split_arrow, .hot = .{ 16, 16 }, .aliases = &.{ "split_h", "14fef782d02440884392942c11205230" } },
    .{ .name = "row-resize", .shapes = split_arrow, .transform = "rotate(90 16 16)", .hot = .{ 16, 16 }, .aliases = &.{ "split_v", "2870a09082c103050810ffdffffe0204" } },
    .{ .name = "help", .shapes = arrow, .marks = badge.at("<path d=\"M21.5 21.9 Q21.5 19.6 23.7 19.6 Q25.9 19.6 25.9 21.5 Q25.9 22.8 24.5 23.3 Q23.7 23.6 23.7 24.6\" fill=\"none\" stroke=\"#0b1220\" stroke-width=\"1.7\" stroke-linecap=\"round\"/><circle cx=\"23.7\" cy=\"27.1\" r=\"1.0\" fill=\"#0b1220\"/>"), .hot = .{ 6, 3.5 }, .aliases = &.{ "question_arrow", "whats_this", "left_ptr_help", "d9ce0ab605698f320427677b458ad60b", "5c6cd98b3f3ebcb1f9c7f1c204630408" } },
    .{ .name = "copy", .shapes = arrow, .marks = badge.at("<path d=\"M23.6 20.4 V26.8 M20.4 23.6 H26.8\" stroke=\"#0b1220\" stroke-width=\"1.9\" stroke-linecap=\"round\"/>"), .hot = .{ 6, 3.5 }, .aliases = &.{ "dnd-copy", "1081e37283d90000800003c07f3ef6bf", "6407b0e94181790501fd1e167b474872", "b66166c04f8c3109214a4fbd64a50fc8" } },
    .{ .name = "alias", .shapes = arrow, .marks = badge.at("<path d=\"M21 26.2 Q21 21.4 25.8 21.4 M23.4 19.6 L26 21.4 L23.4 23.2\" fill=\"none\" stroke=\"#0b1220\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"), .hot = .{ 6, 3.5 }, .aliases = &.{ "link", "dnd-link", "dnd-ask", "3085a0e285430894940527032f8b26df", "640fb0e74195791501fd1ed57b41487f", "a2a266d0498c3104214a47bd64ab0fc8" } },
    .{ .name = "context-menu", .shapes = arrow, .marks = "<rect x=\"18.4\" y=\"17.6\" width=\"11\" height=\"11.4\" rx=\"2.4\" fill=\"" ++ ACCENT ++ "\" stroke=\"" ++ RIM ++ "\" stroke-width=\"1.4\"/><path d=\"M21 21.2 H26.8 M21 24 H26.8 M21 26.6 H24.6\" stroke=\"#0b1220\" stroke-width=\"1.4\" stroke-linecap=\"round\"/>", .hot = .{ 6, 3.5 } },
    .{ .name = "zoom-in", .shapes = lens, .marks = "<path d=\"M13 9.4 V16.6 M9.4 13 H16.6\" stroke=\"" ++ ACCENT ++ "\" stroke-width=\"2.2\" stroke-linecap=\"round\"/>", .hot = .{ 13, 13 } },
    .{ .name = "zoom-out", .shapes = lens, .marks = "<path d=\"M9.4 13 H16.6\" stroke=\"" ++ ACCENT ++ "\" stroke-width=\"2.2\" stroke-linecap=\"round\"/>", .hot = .{ 13, 13 } },
};

fn svgFor(a: std.mem.Allocator, cur: Cursor, frame: u32) ![:0]u8 {
    var marks: []const u8 = cur.marks;
    if (cur.spin) |sp| {
        // 弧の始まり(真上)と終わり(135° 先)。回転は {R}
        const deg: f32 = @as(f32, @floatFromInt(frame)) * 360.0 / FRAMES;
        const end = 135.0 * std.math.pi / 180.0;
        var m = try std.mem.replaceOwned(u8, a, marks, "{R}", try std.fmt.allocPrint(a, "{d:.2}", .{deg}));
        m = try std.mem.replaceOwned(u8, a, m, "{TOP}", try std.fmt.allocPrint(a, "{d:.3}", .{sp[1] - sp[2]}));
        m = try std.mem.replaceOwned(u8, a, m, "{AX}", try std.fmt.allocPrint(a, "{d:.3}", .{sp[0] + sp[2] * @sin(end)}));
        m = try std.mem.replaceOwned(u8, a, m, "{AY}", try std.fmt.allocPrint(a, "{d:.3}", .{sp[1] - sp[2] * @cos(end)}));
        marks = m;
    }
    const tf = if (cur.transform.len > 0) try std.fmt.allocPrint(a, " transform=\"{s}\"", .{cur.transform}) else "";
    return std.fmt.allocPrintZ(a,
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32">
        \\<defs><linearGradient id="b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{s}"/><stop offset="1" stop-color="{s}"/></linearGradient></defs>
        \\<g{s}>
        \\<g fill="{s}" stroke="{s}" stroke-width="2.4" stroke-linejoin="round">{s}</g>
        \\<g fill="url(#b)" stroke="none">{s}</g>
        \\{s}
        \\</g></svg>
    , .{ BODY_TOP, BODY_BOT, tf, RIM, RIM, cur.shapes, cur.shapes, marks });
}

/// SVG を size×size に描き、影を付けて、乗算済みの ARGB(Xcursor の画素)にする
fn render(a: std.mem.Allocator, rast: *c.NSVGrasterizer, svg: [:0]u8, size: u32) ![]u32 {
    const img = c.nsvgParse(svg.ptr, "px", 96) orelse return error.Parse;
    defer c.nsvgDelete(img);
    const n = size * size;
    const rgba = try a.alloc(u8, n * 4);
    @memset(rgba, 0);
    // 影の分だけ少し小さく描く(右下に落ちる影が切れないように)
    const s: f32 = @as(f32, @floatFromInt(size)) / 32.0;
    c.nsvgRasterize(rast, img, 0, 0, s * 0.94, rgba.ptr, @intCast(size), @intCast(size), @intCast(size * 4));
    // 影: 形のアルファをずらして、箱形のぼかしを 3 回(ほぼガウス)
    const sh = try a.alloc(f32, n);
    const tmp = try a.alloc(f32, n);
    @memset(sh, 0);
    const off: i32 = @intFromFloat(@max(1, @round(s * 1.1)));
    for (0..size) |y| for (0..size) |x| {
        const sx = @as(i32, @intCast(x)) - off;
        const sy = @as(i32, @intCast(y)) - off;
        if (sx < 0 or sy < 0) continue;
        sh[y * size + x] = @as(f32, @floatFromInt(rgba[(@as(usize, @intCast(sy)) * size + @as(usize, @intCast(sx))) * 4 + 3])) / 255.0;
    };
    const r: i32 = @intFromFloat(@max(1, @round(s * 1.2)));
    for (0..3) |_| {
        boxBlur(sh, tmp, size, r, true);
        boxBlur(tmp, sh, size, r, false);
    }
    const out = try a.alloc(u32, n);
    for (0..n) |i| {
        const fa = @as(f32, @floatFromInt(rgba[i * 4 + 3])) / 255.0;
        const sa = sh[i] * 0.42 * (1 - fa);
        const oa = fa + sa;
        // 乗算済み: 色 × アルファ(影は黒)
        const pr = @as(f32, @floatFromInt(rgba[i * 4 + 0])) / 255.0 * fa;
        const pg = @as(f32, @floatFromInt(rgba[i * 4 + 1])) / 255.0 * fa;
        const pb = @as(f32, @floatFromInt(rgba[i * 4 + 2])) / 255.0 * fa;
        const to = struct {
            fn b(v: f32) u32 {
                return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
            }
        }.b;
        out[i] = (to(oa) << 24) | (to(pr) << 16) | (to(pg) << 8) | to(pb);
    }
    return out;
}

fn boxBlur(src: []const f32, dst: []f32, size: u32, r: i32, horizontal: bool) void {
    const n: i32 = @intCast(size);
    const w: f32 = @floatFromInt(2 * r + 1);
    for (0..size) |j| {
        for (0..size) |i| {
            var sum: f32 = 0;
            var k: i32 = -r;
            while (k <= r) : (k += 1) {
                const p = @as(i32, @intCast(i)) + k;
                if (p < 0 or p >= n) continue;
                const idx = if (horizontal) j * size + @as(usize, @intCast(p)) else @as(usize, @intCast(p)) * size + j;
                sum += src[idx];
            }
            const o = if (horizontal) j * size + i else i * size + j;
            dst[o] = sum / w;
        }
    }
}

/// Xcursor のファイル: ヘッダ → 目次 → 画像(大きさごと × コマ)
const Img = struct { size: u32, hot: [2]u32, delay: u32, px: []const u32 };

fn writeXcursor(path: []const u8, imgs: []const Img) !void {
    var f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    var bw = std.io.bufferedWriter(f.writer());
    const w = bw.writer();
    const ntoc: u32 = @intCast(imgs.len);
    try w.writeAll("Xcur");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u32, 0x10000, .little);
    try w.writeInt(u32, ntoc, .little);
    var pos: u32 = 16 + ntoc * 12;
    for (imgs) |im| {
        try w.writeInt(u32, 0xfffd0002, .little);
        try w.writeInt(u32, im.size, .little);
        try w.writeInt(u32, pos, .little);
        pos += 36 + im.size * im.size * 4;
    }
    for (imgs) |im| {
        try w.writeInt(u32, 36, .little);
        try w.writeInt(u32, 0xfffd0002, .little);
        try w.writeInt(u32, im.size, .little);
        try w.writeInt(u32, 1, .little);
        try w.writeInt(u32, im.size, .little);
        try w.writeInt(u32, im.size, .little);
        try w.writeInt(u32, im.hot[0], .little);
        try w.writeInt(u32, im.hot[1], .little);
        try w.writeInt(u32, im.delay, .little);
        for (im.px) |p| try w.writeInt(u32, p, .little);
    }
    try bw.flush();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2) return error.Usage;
    const out_dir = args[1];
    const cdir = try std.fs.path.join(a, &.{ out_dir, "cursors" });
    try std.fs.cwd().makePath(cdir);
    const rast = c.nsvgCreateRasterizer() orelse return error.Rasterizer;
    // --preview <ファイル.ppm>: 全部のカーソルを暗い背景と明るい背景に並べた確認用の画像(48px)
    var preview: ?*Preview = null;
    if (args.len >= 4 and std.mem.eql(u8, args[2], "--preview")) {
        const pv = try a.create(Preview);
        pv.* = .{ .path = args[3], .a = a };
        preview = pv;
    }
    defer if (preview) |pv| pv.write() catch {};
    defer c.nsvgDeleteRasterizer(rast);

    for (cursors) |cur| {
        var imgs = std.ArrayList(Img).init(a);
        const nframes: u32 = if (cur.spin != null) FRAMES else 1;
        for (sizes) |size| {
            const s: f32 = @as(f32, @floatFromInt(size)) / 32.0 * 0.94;
            const hot = [2]u32{ @intFromFloat(@round(cur.hot[0] * s)), @intFromFloat(@round(cur.hot[1] * s)) };
            for (0..nframes) |fi| {
                const svg = try svgFor(a, cur, @intCast(fi));
                const px = try render(a, rast, svg, size);
                try imgs.append(.{ .size = size, .hot = hot, .delay = if (nframes > 1) DELAY else 0, .px = px });
            }
        }
        const path = try std.fs.path.join(a, &.{ cdir, cur.name });
        try writeXcursor(path, imgs.items);
        if (preview) |pv| try pv.add(imgs.items);
        // 古い名前・ハッシュの名前は同じファイルへのリンク
        for (cur.aliases) |al| {
            const ap = try std.fs.path.join(a, &.{ cdir, al });
            std.fs.cwd().deleteFile(ap) catch {};
            try std.fs.cwd().symLink(cur.name, ap, .{});
        }
    }
    const idx = try std.fs.path.join(a, &.{ out_dir, "index.theme" });
    try std.fs.cwd().writeFile(.{ .sub_path = idx, .data =
        \\[Icon Theme]
        \\Name=ame
        \\Comment=ame-shell のマウスカーソル(紺のガラスと白い縁)
        \\
    });
}

/// 確認用の画像(PPM)。1 行目は暗い背景、2 行目は明るい背景に、48px の 1 コマ目を並べる
const Preview = struct {
    path: []const u8,
    a: std.mem.Allocator,
    cells: std.ArrayListUnmanaged([]const u32) = .{},

    fn add(self: *Preview, imgs: []const Img) !void {
        for (imgs) |im| if (im.size == 48) {
            try self.cells.append(self.a, im.px);
            return;
        };
    }

    fn write(self: *Preview) !void {
        const cell: usize = 56;
        const n = self.cells.items.len;
        const w = cell * n;
        const h = cell * 2;
        const buf = try self.a.alloc(u8, w * h * 3);
        for (0..h) |y| for (0..w) |x| {
            const bg: [3]u8 = if (y < cell) .{ 0x24, 0x3a, 0x5e } else .{ 0xe8, 0xec, 0xf2 };
            var col = [3]f32{ @floatFromInt(bg[0]), @floatFromInt(bg[1]), @floatFromInt(bg[2]) };
            const ci = x / cell;
            const lx = x % cell;
            const ly = y % cell;
            if (lx >= 4 and ly >= 4 and lx < 52 and ly < 52) {
                const p = self.cells.items[ci][(ly - 4) * 48 + (lx - 4)];
                const al = @as(f32, @floatFromInt(p >> 24)) / 255.0;
                col[0] = @as(f32, @floatFromInt((p >> 16) & 255)) + col[0] * (1 - al);
                col[1] = @as(f32, @floatFromInt((p >> 8) & 255)) + col[1] * (1 - al);
                col[2] = @as(f32, @floatFromInt(p & 255)) + col[2] * (1 - al);
            }
            for (0..3) |k| buf[(y * w + x) * 3 + k] = @intFromFloat(std.math.clamp(col[k], 0, 255));
        };
        var f = try std.fs.cwd().createFile(self.path, .{});
        defer f.close();
        try f.writer().print("P6\n{d} {d}\n255\n", .{ w, h });
        try f.writeAll(buf);
    }
};
