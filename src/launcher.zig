// ランチャー: 画面中央のガラスパネル。.desktop を検索してアプリを起動する。
//
// アニメーション:
//  * 開閉: 拡大(0.92→1)・上昇・フェードを1本のスプリングで
//  * 結果の行: 連鎖スプリング。前の行がある程度出てから次の行の目標を 1 にするので、
//    上から順に「とととっ」と出てくる
//  * 選択ハイライト: 縦位置のスプリングで行間をすべる
//  * パネルの高さ: 結果数に合わせてスプリングで伸縮
//
// 検索: Odin 製ファジーマッチ(anim.fuzzy)。名前・日本語名・汎用名・キーワード・コマンド名を対象に、
// 起動回数(~/.local/state/ame-shell/launcher-history)を加点。空クエリのときはよく使う順。
// 先頭が ">" ならシェルコマンドとして実行する。
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

const SW: u32 = 720;
const SH: u32 = 600;
const PW: f32 = 640;
const SEARCH_H: f32 = 62;
const ROW_H: f32 = 58;
const MAX_ROWS = 7;

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
    icon_tex: c.GLuint = 0,
    icon_state: u8 = 0, // 0=読み込み中 1=無し 2=画素あり(icon_px)
    icon_px: ?[*]u8 = null, // 64x64 RGBA(c_allocator)

    fn display(self: *const Entry) []const u8 {
        return if (self.name_ja.len > 0) self.name_ja else self.name;
    }
};

const Result = struct { idx: u32, score: i32 };

pub const Launcher = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry),
    results: std.ArrayList(Result),
    surf: ?*Surface = null,
    out: ?*Output = null,
    is_open: bool = false,
    query: [256]u8 = undefined,
    qlen: usize = 0,
    sel: usize = 0,
    scroll: usize = 0,
    scanned_ms: u64 = 0,
    // アニメーション
    open_s: Spring = Spring.init(0, 0.38, 0.78),
    sel_y: Spring = Spring.init(0, 0.22, 0.82),
    height_s: Spring = Spring.init(SEARCH_H, 0.34, 0.85),
    rows: [MAX_ROWS]Spring = [_]Spring{Spring.init(0, 0.30, 0.72)} ** MAX_ROWS,
    caret: Spring = Spring.init(0, 0.15, 1.0),
    hover_row: ?usize = null,
    icons: *IconWorker = undefined,
    gen: u32 = 0,

    pub fn create(app: *App) !*Launcher {
        const self = try app.alloc.create(Launcher);
        self.* = .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(app.alloc),
            .entries = std.ArrayList(Entry).init(app.alloc),
            .results = std.ArrayList(Result).init(app.alloc),
        };
        self.icons = try IconWorker.create();
        try app.loop.add(self.icons.pipe_r, c.EPOLLIN, self, onIconsReady);
        return self;
    }

    // ---------------------------------------------------------------------
    // .desktop の読み込み
    // ---------------------------------------------------------------------

    fn scan(self: *Launcher) void {
        // アイコンテクスチャを解放してから作り直す
        for (self.entries.items) |e| {
            if (e.icon_tex != 0) c.glDeleteTextures(1, &e.icon_tex);
            if (e.icon_px) |p| std.c.free(p);
        }
        self.entries.clearRetainingCapacity();
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
        self.loadHistory();
        self.scanned_ms = loop.nowMs();
        self.startIconWorker();
        std.log.info("launcher: {d} 件のアプリ", .{self.entries.items.len});
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
            for (self.entries.items) |*e| if (std.mem.eql(u8, e.id, id)) {
                e.uses = n;
            };
        }
    }

    fn saveHistory(self: *Launcher) void {
        var pbuf: [512]u8 = undefined;
        const p = historyPath(&pbuf) orelse return;
        if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
        const f = std.fs.cwd().createFile(p, .{}) catch return;
        defer f.close();
        const w = f.writer();
        for (self.entries.items) |e| if (e.uses > 0) w.print("{d} {s}\n", .{ e.uses, e.id }) catch {};
    }

    // ---------------------------------------------------------------------
    // 検索
    // ---------------------------------------------------------------------

    fn search(self: *Launcher) void {
        self.results.clearRetainingCapacity();
        const q = self.query[0..self.qlen];
        if (q.len > 0 and q[0] == '>') {
            // コマンド実行モード: 結果は「実行」1行だけ
            self.results.append(.{ .idx = std.math.maxInt(u32), .score = 0 }) catch {};
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
                best += @as(i32, @intCast(@min(e.uses, 50))) * 3;
                self.results.append(.{ .idx = @intCast(i), .score = best }) catch {};
            }
            const Ctx = struct {
                entries: []const Entry,
                fn lt(ctx: @This(), a: Result, b: Result) bool {
                    if (a.score != b.score) return a.score > b.score;
                    return std.ascii.lessThanIgnoreCase(ctx.entries[a.idx].display(), ctx.entries[b.idx].display());
                }
            };
            std.mem.sort(Result, self.results.items, Ctx{ .entries = self.entries.items }, Ctx.lt);
        }
        self.sel = 0;
        self.scroll = 0;
        self.sel_y.set(0);
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
        self.is_open = true;
        self.qlen = 0;
        self.search();
        self.open_s.set(1);
        self.surf.?.schedule();
    }

    pub fn close(self: *Launcher) void {
        if (!self.is_open) return;
        self.is_open = false;
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

    fn launch(self: *Launcher, i: usize) void {
        if (i >= self.results.items.len) return;
        const r = self.results.items[i];
        var buf: [1024]u8 = undefined;
        if (r.idx == std.math.maxInt(u32)) {
            const cmd = std.mem.trim(u8, self.query[1..self.qlen], " ");
            if (cmd.len == 0) return;
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{cmd}) catch return;
            self.app.spawn(z);
        } else {
            const e = &self.entries.items[r.idx];
            var exec_buf: [1024]u8 = undefined;
            const cmd = stripFieldCodes(e.exec, &exec_buf);
            const z = if (e.terminal)
                std.fmt.bufPrintZ(&buf, "{s} -e {s}", .{ self.app.cfg.terminal.get(), cmd }) catch return
            else
                std.fmt.bufPrintZ(&buf, "{s}", .{cmd}) catch return;
            self.app.spawn(z);
            e.uses += 1;
            self.saveHistory();
        }
        self.close();
    }

    // ---------------------------------------------------------------------
    // 入力
    // ---------------------------------------------------------------------

    fn key(ctx: *anyopaque, s: *Surface, ev: surface.KeyEvent) void {
        const self: *Launcher = @ptrCast(@alignCast(ctx));
        if (!self.is_open) return;
        const n = self.results.items.len;
        switch (ev.sym) {
            c.XKB_KEY_Escape => self.close(),
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => self.launch(self.sel),
            c.XKB_KEY_Down, c.XKB_KEY_Tab => if (n > 0) self.select(@min(self.sel + 1, n - 1)),
            c.XKB_KEY_Up, c.XKB_KEY_ISO_Left_Tab => if (self.sel > 0) self.select(self.sel - 1),
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
    }

    fn startIconWorker(self: *Launcher) void {
        startIconWorkerImpl(self);
    }

    /// 起動直後のアイドル時に一覧を読み、表示名をグリフ先読みに回す
    pub fn prescan(self: *Launcher, warmer: *@import("text.zig").Warmer) void {
        self.scan();
        for (self.entries.items) |e| {
            warmer.add(e.display());
            if (e.comment.len > 0) warmer.add(e.comment);
        }
    }

    /// 外部(ame-ctl)から検索語を入れる
    pub fn setQuery(self: *Launcher, q: []const u8) void {
        self.qlen = @min(q.len, self.query.len);
        @memcpy(self.query[0..self.qlen], q[0..self.qlen]);
        self.search();
        if (self.surf) |s| s.schedule();
    }

    fn select(self: *Launcher, i: usize) void {
        self.sel = i;
        if (i < self.scroll) self.scroll = i;
        if (i >= self.scroll + MAX_ROWS) self.scroll = i + 1 - MAX_ROWS;
        self.sel_y.set(@floatFromInt(i - self.scroll));
    }

    fn panelX(s: *Surface) f32 {
        return (@as(f32, @floatFromInt(s.width)) - PW) / 2;
    }

    fn rowAt(self: *Launcher, s: *Surface, x: f32, y: f32) ?usize {
        const px = panelX(s);
        const py: f32 = 30;
        if (x < px or x > px + PW) return null;
        const ry = y - (py + SEARCH_H + 6);
        if (ry < 0) return null;
        const r: usize = @intFromFloat(ry / ROW_H);
        if (r >= MAX_ROWS or self.scroll + r >= self.results.items.len) return null;
        return r;
    }

    fn pointer(ctx: *anyopaque, s: *Surface, ev: surface.PointerEvent) void {
        const self: *Launcher = @ptrCast(@alignCast(ctx));
        if (!self.is_open) return;
        switch (ev.kind) {
            .motion, .enter => {
                const r = self.rowAt(s, ev.x, ev.y);
                if (r != self.hover_row) {
                    self.hover_row = r;
                    if (r) |ri| self.select(self.scroll + ri);
                    s.schedule();
                }
            },
            .press => {
                if (self.rowAt(s, ev.x, ev.y)) |r| {
                    self.launch(self.scroll + r);
                } else {
                    // パネルの外をクリックしたら閉じる
                    const px = panelX(s);
                    if (ev.x < px or ev.x > px + PW or ev.y < 30 or ev.y > 30 + self.height_s.x) self.close();
                }
            },
            .scroll => {
                const n = self.results.items.len;
                if (n == 0) return;
                if (ev.scroll > 0) self.select(@min(self.sel + 1, n - 1)) else if (self.sel > 0) self.select(self.sel - 1);
                s.schedule();
            },
            else => {},
        }
    }

    // ---------------------------------------------------------------------
    // 描画
    // ---------------------------------------------------------------------

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *Launcher = @ptrCast(@alignCast(ctx));
        const app = self.app;
        const n_vis = @min(self.results.items.len -| self.scroll, MAX_ROWS);
        self.height_s.set(SEARCH_H + (if (n_vis > 0) @as(f32, @floatFromInt(n_vis)) * ROW_H + 14 else 0));

        var animating = false;
        var springs = [_]*Spring{ &self.open_s, &self.sel_y, &self.height_s, &self.caret };
        if (anim.stepAll(&springs, dt)) animating = true;
        // 連鎖: 前の行が 0.35 を超えたら次の行を出す
        for (0..MAX_ROWS) |i| {
            if (i < n_vis) {
                if (i == 0 or self.rows[i - 1].x > 0.35) self.rows[i].set(1);
            } else self.rows[i].set(0);
            if (self.rows[i].step(dt)) animating = true;
        }
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

        // ---- 検索欄 ----
        const sx = px + 22;
        const base = py + SEARCH_H / 2 + 8;
        _ = cv.text(sx, base + 1, 22, acc, "\u{F0349}", .{ .glow = 4, .glow_color = acc.alpha(0.4) }); // 虫眼鏡
        const q = self.query[0..self.qlen];
        const qx = sx + 40;
        var caret_x = qx;
        if (q.len == 0) {
            _ = cv.text(qx, base, 20, sub.alpha(0.7), "アプリを検索…  ( > でコマンド実行)", .{});
        } else {
            caret_x += cv.text(qx, base, 20, txt, q, .{ .max_w = PW - 90 });
        }
        // キャレット(入力時に少し弾む)
        const ch: f32 = 24 + self.caret.x * 0.06;
        cv.rect(caret_x + 2, base - 19 - self.caret.x * 0.03, 2, ch, 1, acc);
        if (n_vis > 0) cv.rect(px + 18, py + SEARCH_H, PW - 36, 1, 0.5, Color.hex(0xffffff).alpha(0.10 * t));

        // ---- 結果 ----
        const ly = py + SEARCH_H + 6;
        cv.setClip(px, ly, PW, ph - SEARCH_H - 6);
        if (n_vis > 0) {
            // 選択ハイライト
            const hy = ly + self.sel_y.x * ROW_H;
            cv.shadow(px + 10, hy + 4, PW - 20, ROW_H - 6, 14, 10, acc.alpha(0.25));
            cv.rectGrad(px + 10, hy + 3, PW - 20, ROW_H - 6, 14, acc.alpha(0.30), acc.alpha(0.18));
            cv.rectBorder(px + 10, hy + 3, PW - 20, ROW_H - 6, 14, .{ .a = 0 }, acc.lighten(0.4).alpha(0.45), 1);
        }
        for (0..n_vis) |i| {
            const rt = self.rows[i].x;
            if (rt < 0.01) continue;
            const res = self.results.items[self.scroll + i];
            const ry = ly + @as(f32, @floatFromInt(i)) * ROW_H;
            cv.save();
            cv.translate((1 - rt) * 28, 0);
            cv.opacity(rt);
            const ix = px + 24;
            const iy = ry + (ROW_H - 38) / 2;
            if (res.idx == std.math.maxInt(u32)) {
                cv.rect(ix, iy, 38, 38, 11, acc.alpha(0.25));
                _ = cv.text(ix + 19, iy + 27, 20, txt, "\u{F018D}", .{ .alignment = .center });
                _ = cv.text(ix + 54, ry + 26, 17, txt, "コマンドを実行", .{ .bold = true });
                _ = cv.text(ix + 54, ry + 46, 13, sub, std.mem.trim(u8, q[1..], " "), .{ .max_w = PW - 120 });
            } else {
                const e = &self.entries.items[res.idx];
                self.drawIcon(cv, e, ix, iy, 38);
                const name = e.display();
                _ = cv.text(ix + 54, ry + 26, 17, txt, name, .{ .bold = true, .max_w = PW - 120 });
                const desc = if (e.comment.len > 0) e.comment else if (e.generic.len > 0) e.generic else firstWord(e.exec);
                _ = cv.text(ix + 54, ry + 46, 13, sub, desc, .{ .max_w = PW - 120 });
            }
            cv.restore();
        }
        if (self.results.items.len == 0 and q.len > 0) {
            _ = cv.text(px + PW / 2, py + SEARCH_H + 40, 15, sub, "見つかりません", .{ .alignment = .center });
        }
        cv.setClip(0, 0, 0, 0);
        cv.restore();
        return animating;
    }

    /// アイコン: PNG が見つかればそれを、無ければ頭文字の丸アイコン(名前から色を決める)。
    fn drawIcon(self: *Launcher, cv: *gfx.Canvas, e: *Entry, x: f32, y: f32, size: f32) void {
        _ = self;
        // 縮小済み 64x64 の転送は数十µs なので描画中に行ってよい
        if (e.icon_state == 2 and e.icon_tex == 0) e.icon_tex = gfx.uploadImage(e.icon_px.?, ICON_PX, ICON_PX);
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

/// アイコン名から PNG のパスを探す(SVG は未対応 → 頭文字アイコンにフォールバック)。
fn findIcon(name: []const u8, buf: []u8) ?[:0]const u8 {
    if (name.len == 0) return null;
    var path: ?[:0]const u8 = null;
    if (name[0] == '/') {
        if (std.mem.endsWith(u8, name, ".png")) path = std.fmt.bufPrintZ(buf, "{s}", .{name}) catch null;
    } else {
        const home = std.posix.getenv("HOME") orelse "";
        const sizes = [_][]const u8{ "64x64", "48x48", "128x128", "96x96", "256x256", "32x32" };
        const bases = [_][]const u8{ "/usr/share/icons/hicolor", "/usr/local/share/icons/hicolor", "/var/lib/flatpak/exports/share/icons/hicolor" };
        outer: for (bases) |b| for (sizes) |sz| {
            const p = std.fmt.bufPrintZ(buf, "{s}/{s}/apps/{s}.png", .{ b, sz, name }) catch continue;
            if (c.access(p.ptr, c.R_OK) == 0) {
                path = p;
                break :outer;
            }
        };
        if (path == null) {
            const p = std.fmt.bufPrintZ(buf, "{s}/.local/share/icons/hicolor/48x48/apps/{s}.png", .{ home, name }) catch null;
            if (p) |pp| if (c.access(pp.ptr, c.R_OK) == 0) {
                path = pp;
            };
        }
        if (path == null) {
            const p = std.fmt.bufPrintZ(buf, "/usr/share/pixmaps/{s}.png", .{name}) catch null;
            if (p) |pp| if (c.access(pp.ptr, c.R_OK) == 0) {
                path = pp;
            };
        }
    }
    return path;
}

// ---------------------------------------------------------------------------
// アイコンの非同期読み込み
//
// 巨大な PNG(例: 1000px 超の pixmaps)はデコードだけで 100ms 近くかかり、描画スレッドで
// やるとフレームが止まる。そこでワーカースレッドで「探す → デコード → 64x64 に縮小」まで行い、
// 結果を pipe 経由で epoll に知らせる。ワーカーはランチャーのデータに一切触れず、
// (世代番号, 行番号, 画素) を返すだけなので、途中で再走査されても古い結果を捨てれば安全。
// ---------------------------------------------------------------------------

const ICON_PX = 64;

const IconJob = struct { idx: u32, name: []u8 };
const IconResult = struct { idx: u32, gen: u32, px: ?[*]u8 };

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
            var buf: [600]u8 = undefined;
            const px = if (findIcon(j.name, &buf)) |p| decodeIcon(p) else null;
            a.free(j.name);
            self.mutex.lock();
            self.results.append(.{ .idx = j.idx, .gen = gen, .px = px }) catch if (px) |p| std.c.free(p);
            self.mutex.unlock();
            // まとめて通知されても良い(読む側は全部取り出す)。満杯の EAGAIN は無視。
            _ = c.write(self.pipe_w, "i", 1);
        }
        a.free(jobs);
    }
};

/// PNG を読み、縦横比を保って 64x64 に収める(余白は透明)。箱フィルタで縮小。
fn decodeIcon(path: [:0]const u8) ?[*]u8 {
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const src = c.stbi_load(path.ptr, &w, &h, &n, 4) orelse return null;
    defer c.stbi_image_free(src);
    const out: [*]u8 = @ptrCast(std.c.malloc(ICON_PX * ICON_PX * 4) orelse return null);
    @memset(out[0 .. ICON_PX * ICON_PX * 4], 0);
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const scale = @as(f32, @floatFromInt(@max(sw, sh))) / ICON_PX;
    const dw: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(sw)) / scale)));
    const dh: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(sh)) / scale)));
    const ox = (ICON_PX - @min(dw, ICON_PX)) / 2;
    const oy = (ICON_PX - @min(dh, ICON_PX)) / 2;
    for (0..@min(dh, ICON_PX)) |y| for (0..@min(dw, ICON_PX)) |x| {
        // この出力画素に対応する入力の矩形を平均(乗算済みアルファで平均して縁のにじみを防ぐ)
        const x0: usize = @intFromFloat(@as(f32, @floatFromInt(x)) * scale);
        const y0: usize = @intFromFloat(@as(f32, @floatFromInt(y)) * scale);
        const x1 = @min(sw, @max(x0 + 1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(x + 1)) * scale))));
        const y1 = @min(sh, @max(y0 + 1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(y + 1)) * scale))));
        var acc = [4]u32{ 0, 0, 0, 0 };
        var cnt: u32 = 0;
        for (y0..y1) |yy| for (x0..x1) |xx| {
            const i = (yy * sw + xx) * 4;
            const al: u32 = src[i + 3];
            acc[0] += @as(u32, src[i]) * al;
            acc[1] += @as(u32, src[i + 1]) * al;
            acc[2] += @as(u32, src[i + 2]) * al;
            acc[3] += al;
            cnt += 1;
        };
        const o = ((y + oy) * ICON_PX + (x + ox)) * 4;
        if (acc[3] > 0) {
            out[o] = @intCast(acc[0] / acc[3]);
            out[o + 1] = @intCast(acc[1] / acc[3]);
            out[o + 2] = @intCast(acc[2] / acc[3]);
        }
        out[o + 3] = @intCast(acc[3] / cnt);
    };
    return out;
}

fn onIconsReady(ctx: *anyopaque, fd: c_int, _: u32) void {
    const self: *Launcher = @ptrCast(@alignCast(ctx));
    var drain: [256]u8 = undefined;
    while (c.read(fd, &drain, drain.len) > 0) {}
    const w = self.icons;
    w.mutex.lock();
    defer w.mutex.unlock();
    for (w.results.items) |r| {
        if (r.gen == self.gen and r.idx < self.entries.items.len) {
            const e = &self.entries.items[r.idx];
            e.icon_px = r.px;
            e.icon_state = if (r.px != null) 2 else 1;
        } else if (r.px) |p| std.c.free(p); // 古い走査の結果
    }
    w.results.clearRetainingCapacity();
    if (self.surf) |s| s.schedule();
}

fn startIconWorkerImpl(self: *Launcher) void {
    self.gen +%= 1;
    const a = std.heap.c_allocator;
    var jobs = std.ArrayList(IconJob).init(a);
    for (self.entries.items, 0..) |e, i| {
        if (e.icon.len == 0) {
            self.entries.items[i].icon_state = 1;
            continue;
        }
        const name = a.dupe(u8, e.icon) catch continue;
        jobs.append(.{ .idx = @intCast(i), .name = name }) catch a.free(name);
    }
    const owned = jobs.toOwnedSlice() catch return;
    const t = std.Thread.spawn(.{}, IconWorker.run, .{ self.icons, owned, self.gen }) catch {
        for (owned) |j| a.free(j.name);
        a.free(owned);
        return;
    };
    t.detach();
}
