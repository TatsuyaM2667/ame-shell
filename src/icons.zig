// アイコンの検索と読み込み(PNG / SVG)。
//
// 検索: 入っている全アイコンテーマ(ユーザー設定のテーマとその Inherits → hicolor → breeze-dark →
// breeze → Adwaita → oxygen …)を一度だけ走査して「名前 → 一番良い SVG と一番良い PNG」の索引を作る。
// テーマの中ではカテゴリ(apps / devices / preferences …)を問わない。SVG(拡大しても綺麗)を優先し、
// PNG は 64〜256px に近いものを選ぶ。SVG が nanosvg で描けない(CSS を使うものなど)・空になるときは
// 同じ名前の PNG に切り替える(Arch のアプリで頭文字だけの表示になっていた原因)。
// 索引作りは数十〜数百 ms かかるので、必ずワーカースレッドから呼ぶこと(launcher.zig の IconWorker)。
//
// 探す場所: $XDG_DATA_HOME/icons, ~/.icons, $XDG_DATA_DIRS の各 icons, /usr/local/share/icons,
// /usr/share/icons, Flatpak のエクスポート, /usr/share/pixmaps。シンボリックリンクのディレクトリも辿り、
// 読めないディレクトリは飛ばす(途中で走査をやめない)。
//
// 読み込み: PNG/JPEG は stb_image、SVG は nanosvg でラスタライズし、指定の大きさに縮小する。
// "-symbolic" アイコン(単色の線画、暗い色で描かれている)は暗い UI で見えないので明るい色に塗り直す。
const std = @import("std");
const c = @import("c.zig");

const Best = struct { path: []const u8, score: i32, theme_rank: u8 };
const Map = std.StringHashMap(Best);
const Index = struct { svg: Map, png: Map };

var index_mutex: std.Thread.Mutex = .{};
var index: ?Index = null;
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
        if (iniValue(data, f.key)) |v| return v;
    }
    return null;
}

/// "key=value" の行から値を取り出す(最初に見つかったもの)
fn iniValue(data: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, l[0..eq], " \t"), key)) continue;
        const v = std.mem.trim(u8, l[eq + 1 ..], " \t\"\r");
        if (v.len > 0) return v;
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

fn put(map: *Map, name: []const u8, full: []const u8, rank: u8) void {
    const sc = score(full);
    const gop = map.getOrPut(name) catch return;
    if (!gop.found_existing or rank < gop.value_ptr.theme_rank or (rank == gop.value_ptr.theme_rank and sc > gop.value_ptr.score)) {
        gop.value_ptr.* = .{ .path = full, .score = sc, .theme_rank = rank };
    }
}

/// dir_path 以下(depth 段まで)の .svg / .png を索引に入れる。シンボリックリンクは辿り、
/// 種類の分からないエントリ(d_type を返さないファイルシステム)は stat で調べる。読めないものは飛ばす
fn addTree(idx: *Index, a: std.mem.Allocator, dir_path: []const u8, rank: u8, depth: u8) void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (true) {
        const ent = (it.next() catch break) orelse break;
        if (std.mem.eql(u8, ent.name, "cursors")) continue; // カーソルは除外
        const is_img = std.mem.endsWith(u8, ent.name, ".svg") or std.mem.endsWith(u8, ent.name, ".png");
        var kind = ent.kind;
        if (is_img and (kind == .sym_link or kind == .unknown)) {
            kind = .file; // 画像へのリンク(Papirus などに大量にある)は stat しない。壊れたリンクは読むときに失敗する
        } else if (kind == .sym_link or kind == .unknown) {
            const st = dir.statFile(ent.name) catch continue;
            kind = st.kind;
        }
        if (kind == .directory) {
            if (depth == 0) continue;
            const sub = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, ent.name }) catch continue;
            addTree(idx, a, sub, rank, depth - 1);
            continue;
        }
        if (kind != .file) continue;
        const is_svg = std.mem.endsWith(u8, ent.name, ".svg");
        if (!is_svg and !std.mem.endsWith(u8, ent.name, ".png")) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, ent.name }) catch continue;
        const name = a.dupe(u8, ent.name[0 .. ent.name.len - 4]) catch continue;
        put(if (is_svg) &idx.svg else &idx.png, name, full, rank);
    }
}

fn appendUnique(list: *std.ArrayList([]const u8), s: []const u8) void {
    if (s.len == 0) return;
    for (list.items) |x| if (std.mem.eql(u8, x, s)) return;
    list.append(s) catch {};
}

/// アイコンのテーマを置く場所の一覧(重複なし)
fn baseDirs(a: std.mem.Allocator) std.ArrayList([]const u8) {
    var bases = std.ArrayList([]const u8).init(a);
    const home = std.posix.getenv("HOME") orelse "";
    if (std.posix.getenv("XDG_DATA_HOME")) |d| {
        appendUnique(&bases, std.fmt.allocPrint(a, "{s}/icons", .{d}) catch "");
    } else appendUnique(&bases, std.fmt.allocPrint(a, "{s}/.local/share/icons", .{home}) catch "");
    appendUnique(&bases, std.fmt.allocPrint(a, "{s}/.icons", .{home}) catch "");
    var it = std.mem.splitScalar(u8, std.posix.getenv("XDG_DATA_DIRS") orelse "", ':');
    while (it.next()) |d| if (d.len > 0) appendUnique(&bases, std.fmt.allocPrint(a, "{s}/icons", .{std.mem.trimRight(u8, d, "/")}) catch "");
    appendUnique(&bases, "/usr/local/share/icons");
    appendUnique(&bases, "/usr/share/icons");
    appendUnique(&bases, std.fmt.allocPrint(a, "{s}/.local/share/flatpak/exports/share/icons", .{home}) catch "");
    appendUnique(&bases, "/var/lib/flatpak/exports/share/icons");
    return bases;
}

/// テーマの index.theme の Inherits(カンマ区切り)を themes に足す
fn addInherits(a: std.mem.Allocator, bases: []const []const u8, theme: []const u8, themes: *std.ArrayList([]const u8)) void {
    for (bases) |b| {
        const p = std.fmt.allocPrint(a, "{s}/{s}/index.theme", .{ b, theme }) catch continue;
        const data = std.fs.cwd().readFileAlloc(a, p, 1 << 20) catch continue;
        const inh = iniValue(data, "Inherits") orelse return;
        var it = std.mem.splitScalar(u8, inh, ',');
        while (it.next()) |t| appendUnique(themes, std.mem.trim(u8, t, " "));
        return;
    }
}

fn buildIndex() void {
    const a = index_arena.allocator();
    var idx = Index{ .svg = Map.init(a), .png = Map.init(a) };
    const bases = baseDirs(a);
    var themes = std.ArrayList([]const u8).init(a);
    if (userTheme(a)) |t| {
        appendUnique(&themes, t);
        addInherits(a, bases.items, t, &themes);
        // Inherits の先の Inherits(Papirus-Dark → Papirus → breeze-dark … のように 2 段まで)
        var i: usize = 1;
        while (i < themes.items.len and i < 4) : (i += 1) addInherits(a, bases.items, themes.items[i], &themes);
    }
    for ([_][]const u8{ "hicolor", "breeze-dark", "breeze", "Adwaita", "AdwaitaLegacy", "oxygen" }) |t| appendUnique(&themes, t);
    var found = std.ArrayList(u8).init(a);
    for (themes.items, 0..) |t, rank| {
        var have = false;
        for (bases.items) |b| {
            const p = std.fmt.allocPrint(a, "{s}/{s}", .{ b, t }) catch continue;
            std.fs.cwd().access(p, .{}) catch continue;
            have = true;
            addTree(&idx, a, p, @intCast(@min(rank, 200)), 6);
        }
        if (have) found.writer().print(" {s}", .{t}) catch {};
    }
    addTree(&idx, a, "/usr/share/pixmaps", 250, 1);
    addTree(&idx, a, "/usr/local/share/pixmaps", 250, 1);
    std.log.info("icons: SVG {d} 件 / PNG {d} 件(テーマ:{s})", .{ idx.svg.count(), idx.png.count(), found.items });
    if (std.mem.indexOf(u8, found.items, " hicolor") == null)
        std.log.warn("icons: hicolor のアイコンテーマが見つかりません。アプリのアイコンが頭文字だけになります(hicolor-icon-theme を入れてください)", .{});
    if (std.mem.indexOf(u8, found.items, " Adwaita") == null and std.mem.indexOf(u8, found.items, " breeze") == null)
        std.log.warn("icons: Adwaita / breeze のアイコンテーマが見つかりません(adwaita-icon-theme を入れてください)", .{});
    index = idx;
}

/// 読み込む候補(良い順に最大 2 つ: SVG と PNG)。描けなければ次を試す
pub const Candidates = struct {
    paths: [2][:0]const u8 = undefined,
    n: usize = 0,
};

/// アイコン名(または絶対パス)から読み込むべきファイルの候補を返す。ワーカースレッド専用。
/// bufs はパスの置き場(候補ごとに 1 つ)。
pub fn lookupAll(name: []const u8, bufs: *[2][600]u8) Candidates {
    var out = Candidates{};
    if (name.len == 0) return out;
    if (name[0] == '/') {
        const p = std.fmt.bufPrintZ(&bufs[0], "{s}", .{name}) catch return out;
        if (c.access(p.ptr, c.R_OK) == 0) {
            out.paths[0] = p;
            out.n = 1;
        }
        return out;
    }
    index_mutex.lock();
    defer index_mutex.unlock();
    if (index == null) buildIndex();
    const idx = &index.?;
    // "foo.png" のように拡張子付きで書かれた Icon= にも対応
    var key = name;
    if (std.mem.endsWith(u8, key, ".png") or std.mem.endsWith(u8, key, ".svg") or std.mem.endsWith(u8, key, ".xpm")) key = key[0 .. key.len - 4];
    var s = idx.svg.get(key);
    var p = idx.png.get(key);
    if (s == null and p == null) {
        // 大文字小文字だけ違う名前(Icon=Foo と foo.png など)
        var lb: [256]u8 = undefined;
        if (key.len <= lb.len) {
            const lower = std.ascii.lowerString(&lb, key);
            s = idx.svg.get(lower);
            p = idx.png.get(lower);
        }
    }
    // テーマの優先度が高い方を先に。同じなら SVG を先に(拡大しても綺麗)
    const order: [2]?Best = if (s != null and p != null and p.?.theme_rank < s.?.theme_rank) .{ p, s } else .{ s, p };
    for (order) |b| if (b) |best| {
        out.paths[out.n] = std.fmt.bufPrintZ(&bufs[out.n], "{s}", .{best.path}) catch continue;
        out.n += 1;
    };
    return out;
}

/// アイコン名から一番良いファイルを返す(候補の 1 つ目)。ワーカースレッド専用。
pub fn lookup(name: []const u8, buf: []u8) ?[:0]const u8 {
    var bufs: [2][600]u8 = undefined;
    const cand = lookupAll(name, &bufs);
    if (cand.n == 0) return null;
    return std.fmt.bufPrintZ(buf, "{s}", .{cand.paths[0]}) catch null;
}

/// アイコンを探して size x size の RGBA にする。SVG が描けない・真っ透明なら PNG を試す。ワーカースレッド専用。
pub fn load(name: []const u8, size: usize) ?[*]u8 {
    var bufs: [2][600]u8 = undefined;
    const cand = lookupAll(name, &bufs);
    for (cand.paths[0..cand.n]) |path| {
        const px = decode(path, size, size, false) orelse continue;
        if (!isBlank(px, size * size)) return px;
        std.c.free(px);
    }
    if (cand.n > 0) std.log.info("icons: {s} を描けませんでした({s})", .{ name, cand.paths[0] });
    return null;
}

/// 全部が透明か(nanosvg が対応していない描き方の SVG は何も描かれない)
fn isBlank(px: [*]const u8, n: usize) bool {
    var i: usize = 0;
    while (i < n) : (i += 1) if (px[i * 4 + 3] > 8) return false;
    return true;
}

/// 索引を作らずに hicolor だけを見る(起動直後にロゴを出すための軽い検索)
pub fn quickFind(name: []const u8, buf: []u8) ?[:0]const u8 {
    const cands = [_][]const u8{ "scalable/apps", "128x128/apps", "64x64/apps", "256x256/apps", "48x48/apps" };
    const exts = [_][]const u8{ "svg", "png", "png", "png", "png" };
    for ([_][]const u8{ "/usr/share", "/usr/local/share" }) |root| {
        for (cands, exts) |d, e| {
            const p = std.fmt.bufPrintZ(buf, "{s}/icons/hicolor/{s}/{s}.{s}", .{ root, d, name, e }) catch continue;
            if (c.access(p.ptr, c.R_OK) == 0) return p;
        }
        const p = std.fmt.bufPrintZ(buf, "{s}/pixmaps/{s}.png", .{ root, name }) catch continue;
        if (c.access(p.ptr, c.R_OK) == 0) return p;
    }
    return null;
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
