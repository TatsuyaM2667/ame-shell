// ランチャー: .desktop を検索してアプリを起動する。2 つの見せ方を持つ:
//   * classic  … 画面中央のガラスパネル(専用サーフェス)
//   * caelestia … 枠の下辺から生えるドロワー(描画は frame から drawPanel で呼ばれる)
//
// モード(検索欄の先頭文字で切り替え):
//   (なし)     アプリ検索。Odin 製ファジーマッチ + 起動回数で並べる
//   ">"        アクション(壁紙 / ロック / ログアウト / スリープ / 再起動 / 電源オフ / コマンド実行)
//   ">壁紙" / ">wallpaper"  壁紙ピッカー(~/Pictures/wallpapers 等のサムネイル + オーロラ/雨)
//
// アニメーション: 結果の行は連鎖スプリングで順に出現、選択ハイライトはスプリングで移動、
// パネルの大きさも結果数に合わせて伸縮する。
//
// アイコンと壁紙のサムネイルはワーカースレッドでデコード・縮小する(巨大な PNG/JPEG で
// 描画が止まらないように)。結果は pipe + epoll で受け取る。
const std = @import("std");
const c = @import("c.zig");
const anim = @import("anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("gfx.zig");
const theme = @import("theme.zig");
const appmod = @import("app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("surface.zig");
const Surface = surface.Surface;
const sys = @import("platform/sys.zig");
const loop = @import("platform/loop.zig");
const cfgmod = @import("config.zig");
const icons = @import("icons.zig");
const video = @import("video.zig");

const SW: u32 = 720;
const SH: u32 = 600;
const PW: f32 = 640;
const SEARCH_H: f32 = 62;
const ROW_H: f32 = 58;
const MAX_ROWS = 7;
// 壁紙ピッカーの大きなカードでも粗く見えない大きさ(GPU へ送ったら CPU 側は解放する)
const THUMB_W = 640;
const THUMB_H = 400;

pub const Entry = struct {
    id: []const u8, // ファイル名(重複排除キー)
    name: []const u8,
    name_ja: []const u8 = "",
    generic: []const u8 = "",
    comment: []const u8 = "",
    keywords: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    terminal: bool = false,
    uses: u32 = 0,
    /// 最後に起動した時刻(UNIX 秒)。よく使う順(frecency)の計算に使う
    last_used: i64 = 0,
    /// お気に入りの順番(上に固定される)。null = お気に入りではない
    fav: ?u32 = null,
    icon_tex: c.GLuint = 0,
    icon_state: u8 = 0, // 0=読み込み中 1=無し 2=画素あり(icon_px)
    icon_px: ?[*]u8 = null, // 64x64 RGBA(c_allocator)

    pub fn display(self: *const Entry) []const u8 {
        return if (self.name_ja.len > 0) self.name_ja else self.name;
    }
};

pub const Wall = struct {
    name: []const u8,
    path: []const u8, // 空ならシェーダ壁紙
    mode: cfgmod.WallMode,
    tex: c.GLuint = 0,
    state: u8 = 0,
    px: ?[*]u8 = null,
};

const Action = enum { wallpaper, update, lock, logout, sleep, reboot, poweroff };
const actions = [_]struct { a: Action, icon: []const u8, name: []const u8, desc: []const u8, keys: []const u8 }{
    .{ .a = .wallpaper, .icon = "\u{F0E09}", .name = "壁紙", .desc = "壁紙を選ぶ", .keys = "wallpaper kabegami" },
    .{ .a = .update, .icon = "\u{F06B0}", .name = "アップデート", .desc = "パッケージと ame-shell を更新する(ame-update)", .keys = "update upgrade appudeto koushin" },
    .{ .a = .lock, .icon = "\u{F033E}", .name = "ロック", .desc = "画面をロックする", .keys = "lock rokku" },
    .{ .a = .logout, .icon = "\u{F0343}", .name = "ログアウト", .desc = "River を終了する", .keys = "logout exit" },
    .{ .a = .sleep, .icon = "\u{F04B2}", .name = "スリープ", .desc = "ロックしてサスペンド", .keys = "sleep suspend" },
    .{ .a = .reboot, .icon = "\u{F0709}", .name = "再起動", .desc = "コンピュータを再起動する", .keys = "reboot restart" },
    .{ .a = .poweroff, .icon = "\u{F0425}", .name = "電源オフ", .desc = "コンピュータの電源を切る", .keys = "shutdown poweroff" },
};

const Kind = enum { app, action, command, wallpaper };
const Result = struct { kind: Kind, idx: u32, score: i32 };

pub const Launcher = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry),
    walls: std.ArrayList(Wall),
    /// ユーザーの写真を選ぶための画像(~/Pictures 以下)
    photos: std.ArrayList(Wall),
    results: std.ArrayList(Result),
    surf: ?*Surface = null,
    out: ?*Output = null,
    is_open: bool = false,
    query: [256]u8 = undefined,
    qlen: usize = 0,
    sel: usize = 0,
    scroll: usize = 0,
    scanned_ms: u64 = 0,
    wall_mode: bool = false,
    /// 2 回押しで実行する危険なアクション
    armed: ?Action = null,
    // アニメーション
    open_s: Spring = Spring.init(0, 0.38, 0.78),
    sel_y: Spring = Spring.init(0, 0.22, 0.82),
    sel_x: Spring = Spring.init(0, 0.22, 0.82),
    height_s: Spring = Spring.init(SEARCH_H, 0.34, 0.85),
    rows: [MAX_ROWS]Spring = [_]Spring{Spring.init(0, 0.30, 0.72)} ** MAX_ROWS,
    caret: Spring = Spring.init(0, 0.15, 1.0),
    hover_row: ?usize = null,
    icons: *IconWorker = undefined,
    gen: u32 = 0,
    /// 読み込み済みのアイコン・サムネイルのテクスチャ。再走査(30 秒ごと)をまたいで使い回し、
    /// 開くたびにアイコンが消えて読み直しになるのを防ぐ。キーは "i:アイコン名" / "t:パス"、tex = 0 は「見つからない」
    tex_cache: std.StringHashMapUnmanaged(Cached) = .{},

    pub fn create(app: *App) !*Launcher {
        const self = try app.alloc.create(Launcher);
        self.* = .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(app.alloc),
            .entries = std.ArrayList(Entry).init(app.alloc),
            .walls = std.ArrayList(Wall).init(app.alloc),
            .photos = std.ArrayList(Wall).init(app.alloc),
            .results = std.ArrayList(Result).init(app.alloc),
        };
        self.icons = try IconWorker.create();
        try app.loop.add(self.icons.pipe_r, c.EPOLLIN, self, onIconsReady);
        return self;
    }

    // ---------------------------------------------------------------------
    // .desktop と壁紙の読み込み
    // ---------------------------------------------------------------------

    fn scan(self: *Launcher) void {
        // テクスチャは tex_cache が持つので消さない(次の走査で使い回す)
        for (self.entries.items) |e| if (e.icon_px) |p| std.c.free(p);
        for (self.walls.items) |w| if (w.px) |p| std.c.free(p);
        for (self.photos.items) |w| if (w.px) |p| std.c.free(p);
        self.photos.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
        self.walls.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var seen = std.StringHashMap(void).init(a);

        var dirs = std.ArrayList([]const u8).init(a);
        const home = std.posix.getenv("HOME") orelse "/";
        if (std.posix.getenv("XDG_DATA_HOME")) |d| dirs.append(d) catch {} else dirs.append(std.fmt.allocPrint(a, "{s}/.local/share", .{home}) catch "") catch {};
        const data_dirs = std.posix.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
        var it = std.mem.splitScalar(u8, data_dirs, ':');
        while (it.next()) |d| if (d.len > 0) dirs.append(d) catch {};
        // Flatpak のエクスポート(XDG_DATA_DIRS に入っていない環境向け)
        dirs.append(std.fmt.allocPrint(a, "{s}/.local/share/flatpak/exports/share", .{home}) catch "") catch {};
        dirs.append("/var/lib/flatpak/exports/share") catch {};

        for (dirs.items) |d| {
            const path = std.fmt.allocPrint(a, "{s}/applications", .{d}) catch continue;
            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var walker = dir.walk(a) catch continue;
            defer walker.deinit();
            while (walker.next() catch null) |ent| {
                if (ent.kind != .file and ent.kind != .sym_link) continue;
                if (!std.mem.endsWith(u8, ent.path, ".desktop")) continue;
                // サブディレクトリの "/" は "-" に置き換えて ID にする(仕様通り)
                const id = a.dupe(u8, ent.path) catch continue;
                std.mem.replaceScalar(u8, id, '/', '-');
                if (seen.contains(id)) continue;
                seen.put(id, {}) catch {};
                const data = dir.readFileAlloc(a, ent.path, 256 * 1024) catch continue;
                if (parseDesktop(a, id, data)) |e| self.entries.append(e) catch {};
            }
        }
        self.scanWalls();
        self.scanPhotos();
        self.loadHistory();
        self.loadFavorites();
        self.scanned_ms = loop.nowMs();
        self.startIconWorker();
        std.log.info("launcher: {d} 件のアプリ / {d} 件の壁紙", .{ self.entries.items.len, self.walls.items.len });
    }

    fn scanWalls(self: *Launcher) void {
        const a = self.arena.allocator();
        self.walls.append(.{ .name = "オーロラ(ライブ)", .path = "", .mode = .aurora }) catch {};
        self.walls.append(.{ .name = "雨(ライブ)", .path = "", .mode = .rain }) catch {};
        const home = std.posix.getenv("HOME") orelse return;
        // 自分の壁紙のフォルダ → 既定の壁紙(ame-wallpapers を取得した場所・インストール先)の順。
        // 同じ名前のファイルは最初に見つけたものだけ(Pictures と既定の両方にある場合など)
        const dirs = [_][]const u8{
            std.fmt.allocPrint(a, "{s}/Pictures/wallpapers", .{home}) catch "",
            std.fmt.allocPrint(a, "{s}/Pictures/Wallpapers", .{home}) catch "",
            std.fmt.allocPrint(a, "{s}/.config/ame-shell/wallpapers", .{home}) catch "",
            std.fmt.allocPrint(a, "{s}/.local/share/ame-shell/wallpapers", .{home}) catch "",
            std.fmt.allocPrint(a, "{s}/wallpapers", .{self.app.shareDir()}) catch "",
        };
        var seen = std.StringHashMap(void).init(a);
        for (dirs) |p| {
            if (p.len == 0) continue;
            var dir = std.fs.cwd().openDir(p, .{ .iterate = true }) catch continue;
            defer dir.close();
            var di = dir.iterate();
            while (di.next() catch null) |ent| {
                if (ent.kind != .file and ent.kind != .sym_link) continue;
                const lower = std.ascii.allocLowerString(a, ent.name) catch continue;
                const is_img = std.mem.endsWith(u8, lower, ".jpg") or std.mem.endsWith(u8, lower, ".jpeg") or std.mem.endsWith(u8, lower, ".png");
                // GIF・動画はライブ壁紙(libmpv で再生)
                const is_vid = video.isVideoPath(lower);
                if (!is_img and !is_vid) continue;
                if (seen.contains(lower)) continue;
                seen.put(lower, {}) catch {};
                const full = std.fmt.allocPrint(a, "{s}/{s}", .{ p, ent.name }) catch continue;
                const stem = if (is_vid) std.fmt.allocPrint(a, "{s}(ライブ)", .{std.fs.path.stem(ent.name)}) catch continue else a.dupe(u8, std.fs.path.stem(ent.name)) catch continue;
                self.walls.append(.{ .name = stem, .path = full, .mode = if (is_vid) .video else .image }) catch {};
            }
        }
    }

    /// ~/Pictures 以下(3 階層まで)の写真。ユーザーの写真のピッカー用
    fn scanPhotos(self: *Launcher) void {
        const a = self.arena.allocator();
        const home = std.posix.getenv("HOME") orelse return;
        const root = std.fmt.allocPrint(a, "{s}/Pictures", .{home}) catch return;
        var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
        defer dir.close();
        var walker = dir.walk(a) catch return;
        defer walker.deinit();
        while (walker.next() catch null) |ent| {
            if (self.photos.items.len >= 128) break;
            if (ent.kind != .file and ent.kind != .sym_link) continue;
            if (std.mem.count(u8, ent.path, "/") > 2) continue;
            const lower = std.ascii.allocLowerString(a, ent.basename) catch continue;
            if (!(std.mem.endsWith(u8, lower, ".jpg") or std.mem.endsWith(u8, lower, ".jpeg") or std.mem.endsWith(u8, lower, ".png"))) continue;
            const full = std.fmt.allocPrint(a, "{s}/{s}", .{ root, ent.path }) catch continue;
            const stem = a.dupe(u8, std.fs.path.stem(ent.basename)) catch continue;
            self.photos.append(.{ .name = stem, .path = full, .mode = .image }) catch {};
        }
    }

    pub fn photoTex(self: *Launcher, i: usize) c.GLuint {
        const ph = &self.photos.items[i];
        if (ph.tex == 0 and ph.state == 2) if (ph.px) |px| {
            ph.tex = gfx.uploadImage(px, THUMB_W, THUMB_H);
            self.cachePut("t:", ph.path, ph.tex);
            std.c.free(px);
            ph.px = null;
        };
        return ph.tex;
    }

    fn historyPath(buf: []u8) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        if (std.posix.getenv("XDG_STATE_HOME")) |s| return std.fmt.bufPrint(buf, "{s}/ame-shell/launcher-history", .{s}) catch null;
        return std.fmt.bufPrint(buf, "{s}/.local/state/ame-shell/launcher-history", .{home}) catch null;
    }

    fn loadHistory(self: *Launcher) void {
        var pbuf: [512]u8 = undefined;
        const p = historyPath(&pbuf) orelse return;
        const data = std.fs.cwd().readFileAlloc(self.arena.allocator(), p, 1 << 20) catch return;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| {
            var t = std.mem.tokenizeScalar(u8, l, ' ');
            const n = std.fmt.parseInt(u32, t.next() orelse continue, 10) catch continue;
            const id = t.next() orelse continue;
            const last = std.fmt.parseInt(i64, t.next() orelse "0", 10) catch 0;
            for (self.entries.items) |*e| if (std.mem.eql(u8, e.id, id)) {
                e.uses = n;
                e.last_used = last;
            };
        }
    }

    /// お気に入り: ~/.config/ame-shell/favorites に 1 行 1 つ(.desktop の ID)。手で並べ替えてもよい
    fn loadFavorites(self: *Launcher) void {
        var pbuf: [512]u8 = undefined;
        const p = favoritesPath(&pbuf) orelse return;
        const data = std.fs.cwd().readFileAlloc(self.arena.allocator(), p, 1 << 20) catch return;
        var lines = std.mem.splitScalar(u8, data, '\n');
        var rank: u32 = 0;
        while (lines.next()) |l| {
            const id = std.mem.trim(u8, l, " \r\t");
            if (id.len == 0 or id[0] == '#') continue;
            for (self.entries.items) |*e| if (std.mem.eql(u8, e.id, id)) {
                e.fav = rank;
            };
            rank += 1;
        }
    }

    fn saveFavorites(self: *Launcher) void {
        var pbuf: [512]u8 = undefined;
        const p = favoritesPath(&pbuf) orelse return;
        if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
        const f = std.fs.cwd().createFile(p, .{}) catch return;
        defer f.close();
        const w = f.writer();
        w.writeAll("# ランチャーで上に固定するアプリ(.desktop の ID、上から順)\n") catch {};
        // 順番を保って書き出す
        var r: u32 = 0;
        while (r < 1000) : (r += 1) {
            var found = false;
            for (self.entries.items) |e| if (e.fav != null and e.fav.? == r) {
                w.print("{s}\n", .{e.id}) catch {};
                found = true;
            };
            if (!found and r > self.entries.items.len) break;
        }
    }

    /// 選択中のアプリをお気に入りに入れる/外す(Ctrl+F・右クリック)
    fn toggleFavorite(self: *Launcher, i: usize) void {
        if (i >= self.results.items.len) return;
        const r = self.results.items[i];
        if (r.kind != .app) return;
        const e = &self.entries.items[r.idx];
        if (e.fav != null) {
            e.fav = null;
        } else {
            var max: u32 = 0;
            var any = false;
            for (self.entries.items) |x| if (x.fav) |fr| {
                max = @max(max, fr);
                any = true;
            };
            e.fav = if (any) max + 1 else 0;
        }
        self.saveFavorites();
        const keep = e.id;
        self.search();
        // 並び替わった後も同じアプリを選んだままにする
        for (self.results.items, 0..) |res, j| if (res.kind == .app and std.mem.eql(u8, self.entries.items[res.idx].id, keep)) self.select(j);
        self.redraw();
    }

    fn saveHistory(self: *Launcher) void {
        var pbuf: [512]u8 = undefined;
        const p = historyPath(&pbuf) orelse return;
        if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
        const f = std.fs.cwd().createFile(p, .{}) catch return;
        defer f.close();
        const w = f.writer();
        for (self.entries.items) |e| if (e.uses > 0) w.print("{d} {s} {d}\n", .{ e.uses, e.id, e.last_used }) catch {};
    }

    // ---------------------------------------------------------------------
    // 検索
    // ---------------------------------------------------------------------

    fn isWallQuery(q: []const u8) bool {
        if (q.len == 0 or q[0] != '>') return false;
        const rest = std.mem.trimLeft(u8, q[1..], " ");
        return std.mem.startsWith(u8, rest, "壁紙") or std.mem.startsWith(u8, rest, "wallpaper") or std.mem.startsWith(u8, rest, "wall ");
    }

    fn search(self: *Launcher) void {
        self.results.clearRetainingCapacity();
        self.armed = null;
        const q = self.query[0..self.qlen];
        self.wall_mode = isWallQuery(q);
        if (self.wall_mode) {
            // 壁紙: ">壁紙 " の後ろの語で絞り込む
            const sp = std.mem.indexOfScalar(u8, q, ' ');
            const filt = if (sp) |i| std.mem.trim(u8, q[i..], " ") else "";
            for (self.walls.items, 0..) |w, i| {
                const sc = if (filt.len == 0) 0 else anim.fuzzy(filt, w.name);
                if (sc >= 0) self.results.append(.{ .kind = .wallpaper, .idx = @intCast(i), .score = sc }) catch {};
            }
        } else if (q.len > 0 and q[0] == '>') {
            const rest = std.mem.trim(u8, q[1..], " ");
            for (actions, 0..) |ac, i| {
                var sc: i32 = if (rest.len == 0) 0 else -1;
                if (rest.len > 0) sc = @max(anim.fuzzy(rest, ac.name), anim.fuzzy(rest, ac.keys));
                if (sc >= 0) self.results.append(.{ .kind = .action, .idx = @intCast(i), .score = sc }) catch {};
            }
            if (rest.len > 0) self.results.append(.{ .kind = .command, .idx = 0, .score = -100 }) catch {};
        } else {
            for (self.entries.items, 0..) |e, i| {
                var best: i32 = -1;
                if (q.len == 0) {
                    best = 0;
                } else {
                    // 名前一致を最優先、次いで日本語名、その他は控えめに
                    const fields = [_]struct { s: []const u8, bonus: i32 }{
                        .{ .s = e.name, .bonus = 30 },
                        .{ .s = e.name_ja, .bonus = 30 },
                        .{ .s = e.generic, .bonus = 0 },
                        .{ .s = e.keywords, .bonus = -5 },
                        .{ .s = std.fs.path.basename(firstWord(e.exec)), .bonus = 5 },
                    };
                    for (fields) |f| {
                        if (f.s.len == 0) continue;
                        const sc = anim.fuzzy(q, f.s);
                        if (sc >= 0) best = @max(best, sc + f.bonus);
                    }
                }
                if (best < 0) continue;
                // お気に入りは常に上、その次によく(最近)使うもの
                if (e.fav) |rank| best += 100000 - @as(i32, @intCast(@min(rank, 1000))) * 10;
                best += frecency(&e);
                self.results.append(.{ .kind = .app, .idx = @intCast(i), .score = best }) catch {};
            }
        }
        const Ctx = struct {
            l: *Launcher,
            fn lt(ctx: @This(), a: Result, b: Result) bool {
                if (a.score != b.score) return a.score > b.score;
                if (a.kind == .app and b.kind == .app)
                    return std.ascii.lessThanIgnoreCase(ctx.l.entries.items[a.idx].display(), ctx.l.entries.items[b.idx].display());
                return a.idx < b.idx;
            }
        };
        std.mem.sort(Result, self.results.items, Ctx{ .l = self }, Ctx.lt);
        self.sel = 0;
        self.scroll = 0;
        self.sel_y.set(0);
        self.sel_x.set(0);
        // 結果が変わったら行の出現アニメをやり直す(連鎖)
        for (&self.rows) |*r| {
            r.snap(@min(r.x, 0.4));
            r.set(0);
        }
        if (self.results.items.len > 0) self.rows[0].set(1);
    }

    // ---------------------------------------------------------------------
    // 開閉
    // ---------------------------------------------------------------------

    pub fn toggle(self: *Launcher) void {
        if (self.is_open) self.close() else self.open();
    }

    pub fn open(self: *Launcher) void {
        if (self.is_open) return;
        // 起動のたびに再走査するのは重いので 30 秒キャッシュ
        if (self.entries.items.len == 0 or loop.nowMs() - self.scanned_ms > 30_000) self.scan();
        const app = self.app;
        self.is_open = true;
        self.qlen = 0;
        self.search();
        if (app.activeFrame()) |f| {
            // caelestia: 枠の下辺から生える(サーフェスは作らない)
            f.launcherChanged();
            return;
        }
        if (self.surf == null) {
            const out = app.activeOutput() orelse return;
            self.out = out;
            self.surf = Surface.createLayer(app, .{ .ctx = self, .draw = draw, .pointer = pointer, .key = key, .configured = configured }, .{
                .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
                .anchor = 0, // 中央
                .width = SW,
                .height = SH,
                .keyboard = c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
                .namespace = "ame-launcher",
                .output = out.wl,
            }) catch return;
            self.surf.?.output = out;
            self.open_s.snap(0);
            self.height_s.snap(SEARCH_H);
        }
        self.open_s.set(1);
        self.surf.?.schedule();
    }

    pub fn close(self: *Launcher) void {
        if (!self.is_open) return;
        self.is_open = false;
        self.armed = null;
        if (self.app.cfg.layout == .caelestia) {
            for (self.app.outputs.items) |o| if (o.frame) |f| f.launcherChanged();
        }
        self.open_s.set(0);
        // キーボードを即座に返す(閉じるアニメの間も入力を奪わない)
        if (self.surf) |s| if (s.layer) |l| {
            c.zwlr_layer_surface_v1_set_keyboard_interactivity(l, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
            s.setInputRect(0, 0, 0, 0);
            s.schedule();
        };
    }

    pub fn reap(self: *Launcher) void {
        if (!self.is_open and self.open_s.x < 0.01 and self.surf != null) {
            self.surf.?.destroy();
            self.surf = null;
            self.out = null;
        }
    }

    pub fn backdropChanged(self: *Launcher) void {
        if (self.surf) |s| s.schedule();
    }

    pub fn outputRemoved(self: *Launcher, o: *Output) void {
        if (self.out == o) {
            if (self.surf) |s| s.destroy();
            self.surf = null;
            self.out = null;
            self.is_open = false;
        }
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        const self: *Launcher = @ptrCast(@alignCast(ctx));
        const o = self.out orelse return;
        const sz = o.logicalSize();
        s.origin = .{ (@as(f32, @floatFromInt(sz[0])) - @as(f32, @floatFromInt(s.width))) / 2, (@as(f32, @floatFromInt(sz[1])) - @as(f32, @floatFromInt(s.height))) / 2 };
    }

    fn redraw(self: *Launcher) void {
        if (self.surf) |s| s.schedule();
        if (self.app.activeFrame()) |f| f.schedule();
    }

    /// 起動直後のアイドル時に一覧を読み、表示名をグリフ先読みに回す
    pub fn prescan(self: *Launcher, warmer: *@import("text.zig").Warmer) void {
        self.scan();
        for (self.entries.items) |e| {
            warmer.add(e.display());
            if (e.comment.len > 0) warmer.add(e.comment);
        }
        for (actions) |a| {
            warmer.add(a.name);
            warmer.add(a.desc);
        }
    }

    /// 外部(ame-ctl)から検索語を入れる
    pub fn setQuery(self: *Launcher, q: []const u8) void {
        self.qlen = @min(q.len, self.query.len);
        @memcpy(self.query[0..self.qlen], q[0..self.qlen]);
        self.search();
        self.redraw();
    }

    fn activate(self: *Launcher, i: usize) void {
        if (i >= self.results.items.len) return;
        const r = self.results.items[i];
        var buf: [1024]u8 = undefined;
        switch (r.kind) {
            .command => {
                const cmd = std.mem.trim(u8, self.query[1..self.qlen], " ");
                if (cmd.len == 0) return;
                const z = std.fmt.bufPrintZ(&buf, "{s}", .{cmd}) catch return;
                self.app.spawn(z);
            },
            .app => {
                const e = &self.entries.items[r.idx];
                var exec_buf: [1024]u8 = undefined;
                const cmd = stripFieldCodes(e.exec, &exec_buf);
                const z = if (e.terminal)
                    std.fmt.bufPrintZ(&buf, "{s} -e {s}", .{ self.app.cfg.terminal.get(), cmd }) catch return
                else
                    std.fmt.bufPrintZ(&buf, "{s}", .{cmd}) catch return;
                self.app.spawn(z);
                // caelestia: 行のアイコンからウィンドウの場所へ広がる起動演出
                if (self.app.activeFrame()) |f| {
                    const row: f32 = @floatFromInt(i -| self.scroll);
                    const from = [4]f32{ f.launch.ox + 16, f.launch.oy + 12 + row * ROW_H + (ROW_H - 38) / 2, 38, 38 };
                    @import("frame/frame.zig").startLaunch(f, from, e.icon_tex, e.display());
                }
                e.uses += 1;
                e.last_used = std.time.timestamp();
                self.saveHistory();
            },
            .action => {
                const a = actions[r.idx].a;
                if (a == .wallpaper) {
                    // 全画面の壁紙ピッカーへ
                    self.close();
                    self.app.wallpick.open();
                    return;
                }
                if (a != .lock and self.armed != a) {
                    // 取り返しのつかない操作は 2 回目の Enter で実行
                    self.armed = a;
                    self.redraw();
                    return;
                }
                self.close();
                switch (a) {
                    .lock => _ = self.app.lock.lock(),
                    .logout => self.app.riverCommand(&.{"exit"}),
                    .sleep => {
                        _ = self.app.lock.lock();
                        sys.power(.suspend_);
                    },
                    .reboot => sys.power(.reboot),
                    .poweroff => sys.power(.poweroff),
                    // 端末で ame-update を実行(root のパスワードを聞かれることがあるので端末の中で)
                    .update => sys.spawnDetached("foot -T ame-update -e sh -c 'ame-update; echo; printf \"Enter で閉じます \"; read x'"),
                    .wallpaper => {},
                }
                return;
            },
            .wallpaper => {
                const w = self.walls.items[r.idx];
                for (self.app.outputs.items) |o| if (o.wall) |wp| wp.switchTo(w.mode, w.path);
            },
        }
        self.close();
    }

    // ---------------------------------------------------------------------
    // キー入力(classic のサーフェスと caelestia の枠の両方から呼ばれる)
    // ---------------------------------------------------------------------

    pub fn frameKey(self: *Launcher, s: *Surface, ev: surface.KeyEvent) void {
        key(self, s, ev);
    }

    fn key(ctx: *anyopaque, s: *Surface, ev: surface.KeyEvent) void {
        const self: *Launcher = @ptrCast(@alignCast(ctx));
        if (!self.is_open) return;
        const n = self.results.items.len;
        const horiz = self.wall_mode; // 壁紙は横に並ぶので左右で選ぶ
        switch (ev.sym) {
            c.XKB_KEY_Escape => self.close(),
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => self.activate(self.sel),
            c.XKB_KEY_Down, c.XKB_KEY_Tab => if (n > 0) self.select(@min(self.sel + 1, n - 1)),
            c.XKB_KEY_Up, c.XKB_KEY_ISO_Left_Tab => if (self.sel > 0) self.select(self.sel - 1),
            c.XKB_KEY_Right => if (horiz and n > 0) self.select(@min(self.sel + 1, n - 1)),
            c.XKB_KEY_Left => if (horiz and self.sel > 0) self.select(self.sel - 1),
            c.XKB_KEY_Page_Down => if (n > 0) self.select(@min(self.sel + MAX_ROWS, n - 1)),
            c.XKB_KEY_Page_Up => self.select(self.sel -| MAX_ROWS),
            c.XKB_KEY_BackSpace => {
                if (ev.ctrl) {
                    self.qlen = 0;
                } else if (self.qlen > 0) {
                    // UTF-8 の1文字分を消す
                    var i = self.qlen - 1;
                    while (i > 0 and (self.query[i] & 0xC0) == 0x80) i -= 1;
                    self.qlen = i;
                }
                self.caret.kick(-30);
                self.search();
            },
            else => {
                if (ev.ctrl) {
                    if (ev.sym == c.XKB_KEY_u) {
                        self.qlen = 0;
                        self.search();
                    } else if (ev.sym == c.XKB_KEY_f) {
                        self.toggleFavorite(self.sel);
                    } else if (ev.sym == c.XKB_KEY_n or ev.sym == c.XKB_KEY_j) {
                        if (n > 0) self.select(@min(self.sel + 1, n - 1));
                    } else if (ev.sym == c.XKB_KEY_p or ev.sym == c.XKB_KEY_k) {
                        if (self.sel > 0) self.select(self.sel - 1);
                    }
                } else if (ev.utf8.len > 0 and ev.utf8[0] >= 0x20 and ev.utf8[0] != 0x7f and self.qlen + ev.utf8.len < self.query.len) {
                    @memcpy(self.query[self.qlen .. self.qlen + ev.utf8.len], ev.utf8);
                    self.qlen += ev.utf8.len;
                    self.caret.kick(40);
                    self.search();
                }
            },
        }
        s.schedule();
        self.redraw();
    }

    fn select(self: *Launcher, i: usize) void {
        self.sel = i;
        self.armed = null;
        const vis: usize = if (self.wall_mode) 4 else MAX_ROWS;
        if (i < self.scroll) self.scroll = i;
        if (i >= self.scroll + vis) self.scroll = i + 1 - vis;
        self.sel_y.set(@floatFromInt(i - self.scroll));
        self.sel_x.set(@floatFromInt(i - self.scroll));
    }

    // ---------------------------------------------------------------------
    // 結果の行(classic と caelestia で共有)
    // ---------------------------------------------------------------------

    fn stepRows(self: *Launcher, dt: f32, n_vis: usize) bool {
        var animating = false;
        for (0..MAX_ROWS) |i| {
            if (i < n_vis) {
                if (i == 0 or self.rows[i - 1].x > 0.35) self.rows[i].set(1);
            } else self.rows[i].set(0);
            if (self.rows[i].step(dt)) animating = true;
        }
        return animating;
    }

    fn drawRow(self: *Launcher, cv: *gfx.Canvas, res: Result, x: f32, ry: f32, w: f32) void {
        const app = self.app;
        const txt = theme.text(app);
        const sub = theme.subtext(app);
        const acc = theme.accent(app);
        const ix = x + 16;
        const iy = ry + (ROW_H - 38) / 2;
        switch (res.kind) {
            .command => {
                cv.rect(ix, iy, 38, 38, 11, acc.alpha(0.25));
                _ = cv.text(ix + 19, iy + 27, 20, txt, "\u{F018D}", .{ .alignment = .center });
                _ = cv.text(ix + 54, ry + 26, 16, txt, "コマンドを実行", .{ .bold = true });
                _ = cv.text(ix + 54, ry + 46, 12.5, sub, std.mem.trim(u8, self.query[1..self.qlen], " "), .{ .max_w = w - 100 });
            },
            .action => {
                const a = actions[res.idx];
                const armed = self.armed == a.a;
                const col = if (armed) theme.danger(app) else acc;
                cv.rect(ix, iy, 38, 38, 11, col.alpha(0.25));
                _ = cv.text(ix + 19, iy + 27, 20, txt, a.icon, .{ .alignment = .center });
                _ = cv.text(ix + 54, ry + 26, 16, txt, a.name, .{ .bold = true });
                _ = cv.text(ix + 54, ry + 46, 12.5, if (armed) col else sub, if (armed) "もう一度 Enter で実行" else a.desc, .{ .max_w = w - 100 });
            },
            .app => {
                const e = &self.entries.items[res.idx];
                self.drawIcon(cv, e, ix, iy, 38);
                if (e.fav != null) {
                    // お気に入りの印(右端の星)
                    _ = cv.text(x + w - 28, ry + 35, 16, Color.hex(0xffd36b), "\u{F04CE}", .{ .alignment = .center, .glow = 3, .glow_color = Color.hex(0xffd36b).alpha(0.5) });
                }
                _ = cv.text(ix + 54, ry + 26, 16, txt, e.display(), .{ .bold = true, .max_w = w - 100 });
                const desc = if (e.comment.len > 0) e.comment else if (e.generic.len > 0) e.generic else firstWord(e.exec);
                _ = cv.text(ix + 54, ry + 46, 12.5, sub, desc, .{ .max_w = w - 100 });
            },
            .wallpaper => {},
        }
    }

    /// 壁紙ピッカー: サムネイルを横に並べる
    fn drawWalls(self: *Launcher, cv: *gfx.Canvas, x: f32, y: f32, w: f32) void {
        const app = self.app;
        const acc = theme.accent(app);
        const txt = theme.text(app);
        const tw: f32 = (w - 32 - 3 * 12) / 4;
        const th = tw * 0.625;
        const n = @min(self.results.items.len -| self.scroll, 4);
        // 選択枠(スプリングで横移動)
        const sx = x + 16 + self.sel_x.x * (tw + 12);
        cv.shadow(sx - 4, y - 4, tw + 8, th + 8, 16, 10, acc.alpha(0.5));
        cv.rectBorder(sx - 4, y - 4, tw + 8, th + 8, 16, .{ .a = 0 }, acc, 2.5);
        for (0..n) |i| {
            const res = self.results.items[self.scroll + i];
            const wl = &self.walls.items[res.idx];
            const rt = self.rows[@min(i, MAX_ROWS - 1)].x;
            const tx = x + 16 + @as(f32, @floatFromInt(i)) * (tw + 12);
            cv.save();
            cv.translate(0, (1 - rt) * 20);
            cv.opacity(rt);
            _ = self.wallTex(self.results.items[self.scroll + i].idx);
            if (wl.tex != 0) {
                cv.image(wl.tex, tx, y, tw, th, 12);
            } else {
                // ライブ壁紙(またはサムネイル待ち)はそれらしいグラデーション
                const a = Color.hex(app.cfg.aurora_a);
                const b = Color.hex(app.cfg.aurora_b);
                cv.rectGrad(tx, y, tw, th, 12, if (wl.mode == .rain) Color.hex(0x1b2a55) else b.alpha(0.8), if (wl.mode == .rain) Color.hex(0x070b18) else a.alpha(0.6));
                _ = cv.text(tx + tw / 2, y + th / 2 + 10, 26, Color.hex(0xffffff).alpha(0.85), if (wl.mode == .rain) "\u{F0597}" else if (wl.mode == .aurora) "\u{F0E09}" else "\u{F02E9}", .{ .alignment = .center });
            }
            _ = cv.text(tx + tw / 2, y + th + 20, 12, txt, wl.name, .{ .alignment = .center, .max_w = tw });
            cv.restore();
        }
    }

    /// 壁紙のサムネイル(未転送なら GPU へ送り、CPU 側の画素は解放する)
    pub fn wallTex(self: *Launcher, i: usize) c.GLuint {
        const wl = &self.walls.items[i];
        if (wl.tex == 0 and wl.state == 2) if (wl.px) |px| {
            wl.tex = gfx.uploadImage(px, THUMB_W, THUMB_H);
            self.cachePut("t:", wl.path, wl.tex);
            std.c.free(px);
            wl.px = null;
        };
        return wl.tex;
    }

    /// ウィンドウの app_id から .desktop の項目を探す(名前・アイコンの表示用)。
    /// 例: "firefox" → firefox.desktop、"org.gnome.Nautilus" → org.gnome.Nautilus.desktop、"foot" → foot.desktop
    pub fn findApp(self: *Launcher, app_id: []const u8) ?*Entry {
        if (app_id.len == 0) return null;
        const eqi = std.ascii.eqlIgnoreCase;
        var best: ?*Entry = null;
        for (self.entries.items) |*e| {
            const stem = if (std.mem.endsWith(u8, e.id, ".desktop")) e.id[0 .. e.id.len - 8] else e.id;
            if (eqi(stem, app_id)) return e;
            if (best != null) continue;
            // 逆ドメイン名の最後の部分 / 実行ファイル名 / 表示名
            const last = if (std.mem.lastIndexOfScalar(u8, stem, '.')) |i| stem[i + 1 ..] else stem;
            var it = std.mem.tokenizeAny(u8, e.exec, " \t");
            const exe = std.fs.path.basename(it.next() orelse "");
            if (eqi(last, app_id) or eqi(exe, app_id) or eqi(e.name, app_id)) best = e;
        }
        return best;
    }

    pub fn entryIcon(self: *Launcher, e: *Entry) c.GLuint {
        self.uploadIcon(e);
        return e.icon_tex;
    }

    fn uploadIcon(self: *Launcher, e: *Entry) void {
        if (e.icon_state != 2 or e.icon_tex != 0) return;
        const px = e.icon_px orelse return;
        e.icon_tex = gfx.uploadImage(px, ICON_PX, ICON_PX);
        std.c.free(px);
        e.icon_px = null;
        self.cachePut("i:", e.icon, e.icon_tex);
    }

    fn cachePut(self: *Launcher, comptime kind: []const u8, name: []const u8, tex: c.GLuint) void {
        var kb: [700]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, kind ++ "{s}", .{name}) catch return;
        const a = std.heap.c_allocator;
        const gop = self.tex_cache.getOrPut(a, k) catch return;
        if (gop.found_existing) {
            if (gop.value_ptr.tex != 0 and gop.value_ptr.tex != tex) c.glDeleteTextures(1, &gop.value_ptr.tex);
        } else {
            gop.key_ptr.* = a.dupe(u8, k) catch {
                self.tex_cache.removeByPtr(gop.key_ptr);
                return;
            };
        }
        gop.value_ptr.* = .{ .tex = tex, .gen = self.gen };
    }

    /// キャッシュにあればそのテクスチャ(0 = 見つからないと分かっている)。使ったしるしに今の世代を付ける
    fn cacheGet(self: *Launcher, comptime kind: []const u8, name: []const u8) ?c.GLuint {
        var kb: [700]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, kind ++ "{s}", .{name}) catch return null;
        const v = self.tex_cache.getPtr(k) orelse return null;
        v.gen = self.gen;
        return v.tex;
    }

    /// 一覧が無い/古ければ読み直す(壁紙ピッカーから)
    pub fn ensureScanned(self: *Launcher) void {
        if (self.entries.items.len == 0 or loop.nowMs() - self.scanned_ms > 30_000) self.scan();
    }

    fn visibleRows(self: *Launcher) usize {
        return @min(self.results.items.len -| self.scroll, MAX_ROWS);
    }

    // ---------------------------------------------------------------------
    // caelestia: 枠の下辺のドロワーとして描く(リストが上、検索欄が下)
    // ---------------------------------------------------------------------

    pub fn panelSize(self: *Launcher) [2]f32 {
        if (self.wall_mode) return .{ 820, 14 + (820 - 32 - 36) / 4 * 0.625 + 34 + 64 };
        const n = self.visibleRows();
        return .{ PW, 12 + @as(f32, @floatFromInt(n)) * ROW_H + (if (n > 0) @as(f32, 8) else 0) + 64 };
    }

    pub fn drawPanel(self: *Launcher, cv: *gfx.Canvas, w: f32, h: f32, dt: f32) bool {
        const app = self.app;
        const acc = theme.accent(app);
        const txt = theme.text(app);
        const sub = theme.subtext(app);
        const n_vis = if (self.wall_mode) @min(self.results.items.len -| self.scroll, 4) else self.visibleRows();
        var animating = false;
        var sp = [_]*Spring{ &self.sel_y, &self.sel_x, &self.caret };
        if (anim.stepAll(&sp, dt)) animating = true;
        if (self.stepRows(dt, n_vis)) animating = true;

        // ---- 結果(上から)----
        if (self.wall_mode) {
            self.drawWalls(cv, 0, 16, w);
        } else {
            if (n_vis > 0) {
                const hy = 12 + self.sel_y.x * ROW_H;
                cv.rectGrad(10, hy + 3, w - 20, ROW_H - 6, 14, acc.alpha(0.30), acc.alpha(0.18));
                cv.rectBorder(10, hy + 3, w - 20, ROW_H - 6, 14, .{ .a = 0 }, acc.lighten(0.4).alpha(0.45), 1);
            }
            for (0..n_vis) |i| {
                const rt = self.rows[i].x;
                if (rt < 0.01) continue;
                cv.save();
                cv.translate(0, (1 - rt) * 18);
                cv.opacity(rt);
                self.drawRow(cv, self.results.items[self.scroll + i], 0, 12 + @as(f32, @floatFromInt(i)) * ROW_H, w);
                cv.restore();
            }
            if (self.results.items.len == 0 and self.qlen > 0) {
                _ = cv.text(w / 2, h - 80, 14, sub, "見つかりません", .{ .alignment = .center });
            }
        }

        // ---- 検索欄(下)----
        const fy = h - 58;
        cv.rect(12, fy, w - 24, 46, 23, Color.hex(0xffffff).alpha(0.07));
        _ = cv.text(36, fy + 30, 17, acc, "\u{F0349}", .{ .alignment = .center });
        const q = self.query[0..self.qlen];
        var caret_x: f32 = 58;
        if (q.len == 0) {
            _ = cv.text(58, fy + 29, 14.5, sub.alpha(0.75), "検索…  ( > アクション ・ Ctrl+F/右クリックでお気に入り)", .{});
        } else {
            caret_x += cv.text(58, fy + 29, 15.5, txt, q, .{ .max_w = w - 100 });
        }
        cv.rect(caret_x + 2, fy + 12 - self.caret.x * 0.03, 2, 22 + self.caret.x * 0.05, 1, acc);
        if (q.len > 0) _ = cv.text(w - 30, fy + 29, 13, sub, "\u{F0156}", .{ .alignment = .center });
        return animating or theme.accentAnimating();
    }

    pub fn panelPointer(self: *Launcher, ev: surface.PointerEvent, lx: f32, ly: f32, w: f32, h: f32) bool {
        if (!self.is_open) return false;
        var idx: ?usize = null;
        if (self.wall_mode) {
            const tw: f32 = (w - 32 - 3 * 12) / 4;
            const th = tw * 0.625;
            if (ly >= 16 and ly < 16 + th + 24 and lx >= 16) {
                const i: usize = @intFromFloat((lx - 16) / (tw + 12));
                if (i < 4 and self.scroll + i < self.results.items.len) idx = i;
            }
        } else if (ly >= 12 and ly < h - 64) {
            const i: usize = @intFromFloat((ly - 12) / ROW_H);
            if (i < self.visibleRows()) idx = i;
        }
        switch (ev.kind) {
            .motion, .enter => if (idx != self.hover_row) {
                self.hover_row = idx;
                if (idx) |i| self.select(self.scroll + i);
                return true;
            },
            .press => {
                if (idx != null and ev.button == 0x111) {
                    // 右クリック: お気に入りの切り替え
                    self.toggleFavorite(self.scroll + idx.?);
                } else if (idx) |i| {
                    self.activate(self.scroll + i);
                } else if (ly >= h - 58 and lx > w - 50 and self.qlen > 0) {
                    self.qlen = 0; // ✕ で検索語を消す
                    self.search();
                }
                return true;
            },
            .scroll => {
                const n = self.results.items.len;
                if (n == 0) return false;
                if (ev.scroll > 0) self.select(@min(self.sel + 1, n - 1)) else if (self.sel > 0) self.select(self.sel - 1);
                return true;
            },
            else => {},
        }
        return false;
    }

    // ---------------------------------------------------------------------
    // classic: 中央のパネル
    // ---------------------------------------------------------------------

    fn panelX(s: *Surface) f32 {
        return (@as(f32, @floatFromInt(s.width)) - PW) / 2;
    }

    fn pointer(ctx: *anyopaque, s: *Surface, ev: surface.PointerEvent) void {
        const self: *Launcher = @ptrCast(@alignCast(ctx));
        if (!self.is_open) return;
        const px = panelX(s);
        const py: f32 = 30;
        if (ev.kind == .press) {
            if (ev.x < px or ev.x > px + PW or ev.y < py or ev.y > py + self.height_s.x) {
                self.close();
                return;
            }
        }
        // 中身の座標に直して共有の処理へ(classic は検索欄が上なので行の開始を合わせる)
        const ly = ev.y - (py + SEARCH_H + 6) + 12;
        if (self.panelPointer(ev, ev.x - px, ly, PW, 10000)) s.schedule();
    }

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *Launcher = @ptrCast(@alignCast(ctx));
        const app = self.app;
        const n_vis = if (self.wall_mode) @min(self.results.items.len -| self.scroll, 4) else self.visibleRows();
        const body: f32 = if (self.wall_mode) (PW - 32 - 36) / 4 * 0.625 + 50 else @as(f32, @floatFromInt(n_vis)) * ROW_H + 14;
        self.height_s.set(SEARCH_H + (if (n_vis > 0) body else 0));

        var animating = false;
        var springs = [_]*Spring{ &self.open_s, &self.sel_y, &self.sel_x, &self.height_s, &self.caret };
        if (anim.stepAll(&springs, dt)) animating = true;
        if (self.stepRows(dt, n_vis)) animating = true;
        if (theme.accentAnimating()) animating = true;
        if (!self.is_open and self.open_s.x < 0.01 and !self.open_s.moving()) {
            app.reap_pending = true;
            return false;
        }

        const acc = theme.accent(app);
        const txt = theme.text(app);
        const sub = theme.subtext(app);
        const t = self.open_s.x;
        const px = panelX(s);
        const py: f32 = 30;
        const ph = self.height_s.x;
        const r = app.cfg.radius + 4;

        cv.save();
        cv.translate(0, (1 - t) * 24);
        cv.scaleAbout(px + PW / 2, py + ph / 2, 0.92 + 0.08 * t);
        cv.opacity(std.math.clamp(t * 1.3, 0, 1));
        cv.shadow(px, py + 10, PW, ph, r, 30, theme.shadow().alpha(1.2));
        cv.glass(px, py, PW, ph, r, theme.glassStrong(app));

        const sx = px + 22;
        const base = py + SEARCH_H / 2 + 8;
        _ = cv.text(sx, base + 1, 22, acc, "\u{F0349}", .{ .glow = 4, .glow_color = acc.alpha(0.4) });
        const q = self.query[0..self.qlen];
        const qx = sx + 40;
        var caret_x = qx;
        if (q.len == 0) {
            _ = cv.text(qx, base, 18, sub.alpha(0.7), "アプリを検索…  ( > でアクション)", .{});
        } else {
            caret_x += cv.text(qx, base, 20, txt, q, .{ .max_w = PW - 90 });
        }
        cv.rect(caret_x + 2, base - 19 - self.caret.x * 0.03, 2, 24 + self.caret.x * 0.06, 1, acc);
        if (n_vis > 0) cv.rect(px + 18, py + SEARCH_H, PW - 36, 1, 0.5, Color.hex(0xffffff).alpha(0.10 * t));

        const ly = py + SEARCH_H + 6;
        cv.setClip(px, ly, PW, ph - SEARCH_H - 6);
        if (self.wall_mode) {
            self.drawWalls(cv, px, ly + 10, PW);
        } else {
            if (n_vis > 0) {
                const hy = ly + self.sel_y.x * ROW_H;
                cv.rectGrad(px + 10, hy + 3, PW - 20, ROW_H - 6, 14, acc.alpha(0.30), acc.alpha(0.18));
                cv.rectBorder(px + 10, hy + 3, PW - 20, ROW_H - 6, 14, .{ .a = 0 }, acc.lighten(0.4).alpha(0.45), 1);
            }
            for (0..n_vis) |i| {
                const rt = self.rows[i].x;
                if (rt < 0.01) continue;
                cv.save();
                cv.translate((1 - rt) * 28, 0);
                cv.opacity(rt);
                self.drawRow(cv, self.results.items[self.scroll + i], px, ly + @as(f32, @floatFromInt(i)) * ROW_H, PW);
                cv.restore();
            }
            if (self.results.items.len == 0 and q.len > 0)
                _ = cv.text(px + PW / 2, py + SEARCH_H + 40, 15, sub, "見つかりません", .{ .alignment = .center });
        }
        cv.setClip(0, 0, 0, 0);
        cv.restore();
        return animating;
    }

    /// アイコン: PNG が見つかればそれを、無ければ頭文字の丸アイコン(名前から色を決める)。
    fn drawIcon(self: *Launcher, cv: *gfx.Canvas, e: *Entry, x: f32, y: f32, size: f32) void {
        // 縮小済み 64x64 の転送は数十µs なので描画中に行ってよい
        self.uploadIcon(e);
        if (e.icon_tex != 0) {
            cv.image(e.icon_tex, x, y, size, size, 9);
            return;
        }
        const h = std.hash.Wyhash.hash(0, e.name);
        const hues = [_]u32{ 0x5b8cff, 0x3fc8d8, 0x9a6cff, 0x4fd39a, 0xff8a9b, 0xffb35c, 0x6aa8ff };
        const col = Color.hex(hues[h % hues.len]);
        cv.rectGrad(x, y, size, size, size * 0.3, col.lighten(0.25), col);
        const name = e.display();
        const n = std.unicode.utf8ByteSequenceLength(name[0]) catch 1;
        _ = cv.text(x + size / 2, y + size * 0.68, size * 0.5, Color.hex(0xffffff), name[0..@min(n, name.len)], .{ .bold = true, .alignment = .center });
    }

    fn startIconWorker(self: *Launcher) void {
        startIconWorkerImpl(self);
    }
};

fn firstWord(s: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    return it.next() orelse "";
}

/// Exec の %f %U 等のフィールドコードを除く(%% は % に)。
fn stripFieldCodes(exec: []const u8, buf: []u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < exec.len and o < buf.len) : (i += 1) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            i += 1;
            if (exec[i] == '%') {
                buf[o] = '%';
                o += 1;
            }
            continue;
        }
        buf[o] = exec[i];
        o += 1;
    }
    return std.mem.trim(u8, buf[0..o], " ");
}

/// [Desktop Entry] セクションだけを読む。表示しないもの(NoDisplay/Hidden/Type≠Application)は null。
fn parseDesktop(a: std.mem.Allocator, id: []const u8, data: []const u8) ?Entry {
    var e = Entry{ .id = id, .name = "" };
    var in_main = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var is_app = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_main = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_main) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " ");
        const v = std.mem.trim(u8, line[eq + 1 ..], " ");
        const dup = a.dupe(u8, v) catch continue;
        if (std.mem.eql(u8, k, "Name")) e.name = dup else if (std.mem.eql(u8, k, "Name[ja]")) e.name_ja = dup else if (std.mem.eql(u8, k, "GenericName") and e.generic.len == 0) e.generic = dup else if (std.mem.eql(u8, k, "GenericName[ja]")) e.generic = dup else if (std.mem.eql(u8, k, "Comment") and e.comment.len == 0) e.comment = dup else if (std.mem.eql(u8, k, "Comment[ja]")) e.comment = dup else if (std.mem.eql(u8, k, "Keywords")) e.keywords = dup else if (std.mem.eql(u8, k, "Exec")) e.exec = dup else if (std.mem.eql(u8, k, "Icon")) e.icon = dup else if (std.mem.eql(u8, k, "Terminal")) e.terminal = std.mem.eql(u8, v, "true") else if (std.mem.eql(u8, k, "Type")) is_app = std.mem.eql(u8, v, "Application") else if (std.mem.eql(u8, k, "NoDisplay") or std.mem.eql(u8, k, "Hidden")) {
            if (std.mem.eql(u8, v, "true")) return null;
        }
    }
    if (!is_app or e.name.len == 0 or e.exec.len == 0) return null;
    return e;
}

// ---------------------------------------------------------------------------
// アイコン・サムネイルの非同期読み込み
//
// 巨大な PNG/JPEG はデコードだけで 100ms 近くかかり、描画スレッドでやるとフレームが止まる。
// ワーカースレッドで「探す → デコード → 縮小」まで行い、結果を pipe 経由で epoll に知らせる。
// ワーカーはランチャーのデータに一切触れず、(世代, 種類, 番号, 画素) を返すだけなので、
// 途中で再走査されても古い結果を捨てれば安全。
// ---------------------------------------------------------------------------

const ICON_PX = 64;

const IconJob = struct { idx: u32, name: []u8, thumb: bool, photo: bool = false };
const Cached = struct { tex: c.GLuint, gen: u32 };
const IconResult = struct { idx: u32, gen: u32, thumb: bool, photo: bool = false, px: ?[*]u8 };

const IconWorker = struct {
    mutex: std.Thread.Mutex = .{},
    results: std.ArrayList(IconResult),
    pipe_r: c_int,
    pipe_w: c_int,

    fn create() !*IconWorker {
        const w = try std.heap.c_allocator.create(IconWorker);
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.Pipe;
        w.* = .{ .results = std.ArrayList(IconResult).init(std.heap.c_allocator), .pipe_r = fds[0], .pipe_w = fds[1] };
        return w;
    }

    fn run(self: *IconWorker, jobs: []IconJob, gen: u32) void {
        const a = std.heap.c_allocator;
        for (jobs) |j| {
            var px: ?[*]u8 = null;
            if (j.thumb) {
                var zb: [600]u8 = undefined;
                if (std.fmt.bufPrintZ(&zb, "{s}", .{j.name})) |p| {
                    // 動画は ffmpeg で 1 コマ取り出した PNG から(GIF は stb_image で直接読める)
                    var tb: [600]u8 = undefined;
                    const src = if (video.isVideoPath(p) and !std.ascii.endsWithIgnoreCase(p, ".gif")) video.thumbnail(p, &tb) else p;
                    if (src) |sp| px = icons.decode(sp, THUMB_W, THUMB_H, true);
                } else |_| {}
            } else {
                var buf: [600]u8 = undefined;
                if (icons.lookup(j.name, &buf)) |p| px = icons.decode(p, ICON_PX, ICON_PX, false);
            }
            a.free(j.name);
            self.mutex.lock();
            self.results.append(.{ .idx = j.idx, .gen = gen, .thumb = j.thumb, .photo = j.photo, .px = px }) catch if (px) |p| std.c.free(p);
            self.mutex.unlock();
            // まとめて通知されても良い(読む側は全部取り出す)。満杯の EAGAIN は無視。
            _ = c.write(self.pipe_w, "i", 1);
        }
        a.free(jobs);
    }
};

fn onIconsReady(ctx: *anyopaque, fd: c_int, _: u32) void {
    const self: *Launcher = @ptrCast(@alignCast(ctx));
    var drain: [256]u8 = undefined;
    while (c.read(fd, &drain, drain.len) > 0) {}
    const w = self.icons;
    w.mutex.lock();
    defer w.mutex.unlock();
    for (w.results.items) |r| {
        if (r.gen == self.gen and !r.thumb and r.idx < self.entries.items.len) {
            const e = &self.entries.items[r.idx];
            e.icon_px = r.px;
            e.icon_state = if (r.px != null) 2 else 1;
            if (r.px == null) self.cachePut("i:", e.icon, 0);
        } else if (r.gen == self.gen and r.photo and r.idx < self.photos.items.len) {
            const ph = &self.photos.items[r.idx];
            ph.px = r.px;
            ph.state = if (r.px != null) 2 else 1;
            if (r.px == null) self.cachePut("t:", ph.path, 0);
        } else if (r.gen == self.gen and r.thumb and !r.photo and r.idx < self.walls.items.len) {
            const wl = &self.walls.items[r.idx];
            wl.px = r.px;
            wl.state = if (r.px != null) 2 else 1;
            if (r.px == null) self.cachePut("t:", wl.path, 0);
        } else if (r.px) |p| std.c.free(p); // 古い走査の結果
    }
    w.results.clearRetainingCapacity();
    self.redraw();
}

fn startIconWorkerImpl(self: *Launcher) void {
    self.gen +%= 1;
    const a = std.heap.c_allocator;
    // アプリのアイコンと、壁紙・写真のサムネイルは別のスレッドで(動画のサムネイルは ffmpeg で数百 ms
    // かかるので、同じ列に並べるとアイコンがその後ろで待たされる)。読み込み済みのものはキャッシュから
    var icon_jobs = std.ArrayList(IconJob).init(a);
    var thumb_jobs = std.ArrayList(IconJob).init(a);
    for (self.entries.items, 0..) |*e, i| {
        if (e.icon.len == 0) {
            e.icon_state = 1;
            continue;
        }
        if (self.cacheGet("i:", e.icon)) |tex| {
            e.icon_tex = tex;
            e.icon_state = if (tex != 0) 2 else 1;
            continue;
        }
        const name = a.dupe(u8, e.icon) catch continue;
        icon_jobs.append(.{ .idx = @intCast(i), .name = name, .thumb = false }) catch a.free(name);
    }
    for (self.walls.items, 0..) |*wl, i| {
        if (wl.path.len == 0) {
            wl.state = 1;
            continue;
        }
        if (self.cacheGet("t:", wl.path)) |tex| {
            wl.tex = tex;
            wl.state = if (tex != 0) 2 else 1;
            continue;
        }
        const name = a.dupe(u8, wl.path) catch continue;
        thumb_jobs.append(.{ .idx = @intCast(i), .name = name, .thumb = true }) catch a.free(name);
    }
    for (self.photos.items, 0..) |*ph, i| {
        if (self.cacheGet("t:", ph.path)) |tex| {
            ph.tex = tex;
            ph.state = if (tex != 0) 2 else 1;
            continue;
        }
        const name = a.dupe(u8, ph.path) catch continue;
        thumb_jobs.append(.{ .idx = @intCast(i), .name = name, .thumb = true, .photo = true }) catch a.free(name);
    }
    // 今回の一覧で使われなくなったもの(消えたアプリ・壁紙)を捨てる
    var it = self.tex_cache.iterator();
    var stale: [64][]const u8 = undefined;
    var n_stale: usize = 0;
    while (it.next()) |kv| {
        if (kv.value_ptr.gen == self.gen or n_stale == stale.len) continue;
        if (kv.value_ptr.tex != 0) c.glDeleteTextures(1, &kv.value_ptr.tex);
        stale[n_stale] = kv.key_ptr.*;
        n_stale += 1;
    }
    for (stale[0..n_stale]) |k| {
        _ = self.tex_cache.remove(k);
        a.free(k);
    }
    for ([_]*std.ArrayList(IconJob){ &icon_jobs, &thumb_jobs }) |jobs| {
        if (jobs.items.len == 0) {
            jobs.deinit();
            continue;
        }
        const owned = jobs.toOwnedSlice() catch continue;
        const t = std.Thread.spawn(.{}, IconWorker.run, .{ self.icons, owned, self.gen }) catch {
            for (owned) |j| a.free(j.name);
            a.free(owned);
            continue;
        };
        t.detach();
    }
}

/// よく使う順の点数: 起動回数 × 最近使ったかどうかの重み(Firefox の frecency の考え方を簡略化)
fn frecency(e: *const Entry) i32 {
    if (e.uses == 0) return 0;
    const age = std.time.timestamp() - e.last_used;
    const day: i64 = 86400;
    const w: f32 = if (e.last_used == 0) 0.5 else if (age < day) 1.0 else if (age < 7 * day) 0.75 else if (age < 30 * day) 0.5 else 0.25;
    return @intFromFloat(@min(@as(f32, @floatFromInt(e.uses)), 200) * w * 6);
}

fn favoritesPath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| return std.fmt.bufPrint(buf, "{s}/ame-shell/favorites", .{x}) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/ame-shell/favorites", .{home}) catch null;
}
