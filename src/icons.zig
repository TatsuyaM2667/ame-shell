// アイコンの検索と読み込み(PNG / SVG)。
//
// 検索: 入っている全アイコンテーマ(ユーザー設定のテーマ → hicolor → breeze-dark → breeze →
// Adwaita → oxygen …)を一度だけ走査して「名前 → 一番良いファイル」の索引を作る。
// テーマの中ではカテゴリ(apps / devices / preferences …)を問わず、SVG(拡大しても綺麗)を
// 最優先、PNG は 64〜256px に近いものを選ぶ。索引作りは数十〜数百 ms かかるので、
// 必ずワーカースレッドから呼ぶこと(launcher.zig の IconWorker)。
//
// 読み込み: PNG/JPEG は stb_image、SVG は nanosvg でラスタライズし、指定の大きさに縮小する。
// "-symbolic" アイコン(単色の線画、暗い色で描かれている)は暗い UI で見えないので明るい色に塗り直す。
const std = @import("std");
const c = @import("c.zig");

const Best = struct { path: []const u8, score: i32, theme_rank: u8 };

var index_mutex: std.Thread.Mutex = .{};
var index: ?std.StringHashMap(Best) = null;
var index_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.c_allocator);

/// ユーザーが設定しているアイコンテーマ名(GTK → KDE の順に見る)
fn userTheme(a: std.mem.Allocator) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const files = [_]struct { rel: []const u8, key: []const u8 }{
        .{ .rel = ".config/gtk-3.0/settings.ini", .key = "gtk-icon-theme-name" },
        .{ .rel = ".config/gtk-4.0/settings.ini", .key = "gtk-icon-theme-name" },
        .{ .rel = ".config/kdeglobals", .key = "Theme" },
    };
    for (files) |f| {
        const p = std.fmt.allocPrint(a, "{s}/{s}", .{ home, f.rel }) catch continue;
        const data = std.fs.cwd().readFileAlloc(a, p, 1 << 20) catch continue;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| {
            const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, l[0..eq], " "), f.key)) continue;
            const v = std.mem.trim(u8, l[eq + 1 ..], " \"\r");
            if (v.len > 0) return v;
        }
    }
    return null;
}

/// ディレクトリ名から PNG の大きさを推測("48x48" / "48" / "48x48@2")。SVG は 1000 点。
fn score(path: []const u8) i32 {
    if (std.mem.endsWith(u8, path, ".svg")) return 1000;
    var it = std.mem.splitScalar(u8, path, '/');
    var size: i32 = 0;
    while (it.next()) |seg| {
        const x = std.mem.indexOfScalar(u8, seg, 'x') orelse seg.len;
        const n = std.fmt.parseInt(i32, seg[0..x], 10) catch continue;
        if (n >= 8 and n <= 1024) size = n;
    }
    if (size == 0) return 500; // pixmaps など大きさ不明
    // 96px 前後が理想(64 で表示、拡大率 1.25〜1.5 でも綺麗)。大きすぎるものはデコードが重い。
    return 900 - @as(i32, @intCast(@abs(size - 96))) * 2;
}

fn addTheme(map: *std.StringHashMap(Best), a: std.mem.Allocator, dir_path: []const u8, rank: u8) void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = dir.walk(a) catch return;
    defer walker.deinit();
    while (walker.next() catch null) |ent| {
        if (ent.kind != .file and ent.kind != .sym_link) continue;
        const is_svg = std.mem.endsWith(u8, ent.basename, ".svg");
        if (!is_svg and !std.mem.endsWith(u8, ent.basename, ".png")) continue;
        // カーソルや大きな壁紙のようなものは除外
        if (std.mem.indexOf(u8, ent.path, "cursors") != null) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, ent.path }) catch continue;
        const name = a.dupe(u8, ent.basename[0 .. ent.basename.len - 4]) catch continue;
        const sc = score(full);
        const gop = map.getOrPut(name) catch continue;
        if (!gop.found_existing or rank < gop.value_ptr.theme_rank or (rank == gop.value_ptr.theme_rank and sc > gop.value_ptr.score)) {
            gop.value_ptr.* = .{ .path = full, .score = sc, .theme_rank = rank };
        }
    }
}

fn buildIndex() void {
    const a = index_arena.allocator();
    var map = std.StringHashMap(Best).init(a);
    const home = std.posix.getenv("HOME") orelse "";
    var themes = std.ArrayList([]const u8).init(a);
    if (userTheme(a)) |t| themes.append(t) catch {};
    for ([_][]const u8{ "hicolor", "breeze-dark", "breeze", "Adwaita", "AdwaitaLegacy", "oxygen" }) |t| themes.append(t) catch {};
    const bases = [_][]const u8{
        std.fmt.allocPrint(a, "{s}/.local/share/icons", .{home}) catch "",
        std.fmt.allocPrint(a, "{s}/.icons", .{home}) catch "",
        "/usr/local/share/icons",
        "/usr/share/icons",
        std.fmt.allocPrint(a, "{s}/.local/share/flatpak/exports/share/icons", .{home}) catch "",
        "/var/lib/flatpak/exports/share/icons",
    };
    for (themes.items, 0..) |t, rank| {
        for (bases) |b| {
            const p = std.fmt.allocPrint(a, "{s}/{s}", .{ b, t }) catch continue;
            addTheme(&map, a, p, @intCast(rank));
        }
    }
    addTheme(&map, a, "/usr/share/pixmaps", 250);
    index = map;
}

/// アイコン名(または絶対パス)から読み込むべきファイルを返す。ワーカースレッド専用。
pub fn lookup(name: []const u8, buf: []u8) ?[:0]const u8 {
    if (name.len == 0) return null;
    if (name[0] == '/') {
        const p = std.fmt.bufPrintZ(buf, "{s}", .{name}) catch return null;
        return if (c.access(p.ptr, c.R_OK) == 0) p else null;
    }
    index_mutex.lock();
    defer index_mutex.unlock();
    if (index == null) buildIndex();
    // "foo.png" のように拡張子付きで書かれた Icon= にも対応
    var key = name;
    if (std.mem.endsWith(u8, key, ".png") or std.mem.endsWith(u8, key, ".svg")) key = key[0 .. key.len - 4];
    const best = index.?.get(key) orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}", .{best.path}) catch null;
}

/// 索引を作らずに hicolor だけを見る(起動直後にロゴを出すための軽い検索)
pub fn quickFind(name: []const u8, buf: []u8) ?[:0]const u8 {
    const cands = [_][]const u8{ "scalable/apps", "128x128/apps", "64x64/apps", "256x256/apps", "48x48/apps" };
    const exts = [_][]const u8{ "svg", "png", "png", "png", "png" };
    for (cands, exts) |d, e| {
        const p = std.fmt.bufPrintZ(buf, "/usr/share/icons/hicolor/{s}/{s}.{s}", .{ d, name, e }) catch continue;
        if (c.access(p.ptr, c.R_OK) == 0) return p;
    }
    const p = std.fmt.bufPrintZ(buf, "/usr/share/pixmaps/{s}.png", .{name}) catch return null;
    return if (c.access(p.ptr, c.R_OK) == 0) p else null;
}

/// 画像(PNG/JPEG/SVG)を読み、ow x oh の RGBA(c_allocator で確保)にする。
/// cover=true: 縦横比を保って隙間なく埋める(はみ出しは中央で切る)/ false: 全体を収める(余白は透明)。
pub fn decode(path: [:0]const u8, ow: usize, oh: usize, cover: bool) ?[*]u8 {
    if (std.mem.endsWith(u8, path, ".svg")) return decodeSvg(path, ow, oh);
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const src = c.stbi_load(path.ptr, &w, &h, &n, 4) orelse return null;
    defer c.stbi_image_free(src);
    return scaleRgba(src, @intCast(w), @intCast(h), ow, oh, cover);
}

fn decodeSvg(path: [:0]const u8, ow: usize, oh: usize) ?[*]u8 {
    const img = c.nsvgParseFromFile(path.ptr, "px", 96) orelse return null;
    defer c.nsvgDelete(img);
    if (img.*.width <= 0 or img.*.height <= 0) return null;
    const rast = c.nsvgCreateRasterizer() orelse return null;
    defer c.nsvgDeleteRasterizer(rast);
    const out: [*]u8 = @ptrCast(std.c.malloc(ow * oh * 4) orelse return null);
    @memset(out[0 .. ow * oh * 4], 0);
    const s = @min(@as(f32, @floatFromInt(ow)) / img.*.width, @as(f32, @floatFromInt(oh)) / img.*.height);
    const tx = (@as(f32, @floatFromInt(ow)) - img.*.width * s) / 2;
    const ty = (@as(f32, @floatFromInt(oh)) - img.*.height * s) / 2;
    c.nsvgRasterize(rast, img, tx, ty, s, out, @intCast(ow), @intCast(oh), @intCast(ow * 4));
    // "-symbolic" は単色の暗い線画: 明るい色(テキスト色に近い)へ塗り直す
    if (std.mem.indexOf(u8, path, "-symbolic") != null or std.mem.indexOf(u8, path, "/symbolic/") != null) {
        var i: usize = 0;
        while (i < ow * oh) : (i += 1) {
            out[i * 4 + 0] = 0xea;
            out[i * 4 + 1] = 0xf2;
            out[i * 4 + 2] = 0xff;
        }
    }
    return out;
}

/// 箱フィルタで縮小(乗算済みアルファで平均して縁のにじみを防ぐ。大きな画像は最大 8x8 点に間引く)
pub fn scaleRgba(src: [*]const u8, sw: usize, sh: usize, ow: usize, oh: usize, cover: bool) ?[*]u8 {
    const out: [*]u8 = @ptrCast(std.c.malloc(ow * oh * 4) orelse return null);
    @memset(out[0 .. ow * oh * 4], 0);
    const fx = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(ow));
    const fy = @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(oh));
    const scale = if (cover) @min(fx, fy) else @max(fx, fy);
    const dw: usize = @min(ow, @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(sw)) / scale))));
    const dh: usize = @min(oh, @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(sh)) / scale))));
    const ox = (ow - dw) / 2;
    const oy = (oh - dh) / 2;
    const sx0: f32 = if (cover) (@as(f32, @floatFromInt(sw)) - @as(f32, @floatFromInt(ow)) * scale) / 2 else 0;
    const sy0: f32 = if (cover) (@as(f32, @floatFromInt(sh)) - @as(f32, @floatFromInt(oh)) * scale) / 2 else 0;
    for (0..dh) |y| for (0..dw) |x| {
        const x0: usize = @intFromFloat(@max(0, sx0 + @as(f32, @floatFromInt(x)) * scale));
        const y0: usize = @intFromFloat(@max(0, sy0 + @as(f32, @floatFromInt(y)) * scale));
        const x1 = @min(sw, @max(x0 + 1, @as(usize, @intFromFloat(sx0 + @as(f32, @floatFromInt(x + 1)) * scale))));
        const y1 = @min(sh, @max(y0 + 1, @as(usize, @intFromFloat(sy0 + @as(f32, @floatFromInt(y + 1)) * scale))));
        const stepx = @max(1, (x1 -| x0) / 8);
        const stepy = @max(1, (y1 -| y0) / 8);
        var acc = [4]u32{ 0, 0, 0, 0 };
        var cnt: u32 = 0;
        var yy = y0;
        while (yy < y1) : (yy += stepy) {
            var xx = x0;
            while (xx < x1) : (xx += stepx) {
                const i = (yy * sw + xx) * 4;
                const al: u32 = src[i + 3];
                acc[0] += @as(u32, src[i]) * al;
                acc[1] += @as(u32, src[i + 1]) * al;
                acc[2] += @as(u32, src[i + 2]) * al;
                acc[3] += al;
                cnt += 1;
            }
        }
        const o = ((y + oy) * ow + (x + ox)) * 4;
        if (acc[3] > 0) {
            out[o] = @intCast(acc[0] / acc[3]);
            out[o + 1] = @intCast(acc[1] / acc[3]);
            out[o + 2] = @intCast(acc[2] / acc[3]);
        }
        out[o + 3] = @intCast(acc[3] / @max(cnt, 1));
    };
    return out;
}
