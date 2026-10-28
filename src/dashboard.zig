// ダッシュボード(コントロールセンター + 通知センター): 右側から滑り込むガラスの縦パネル。
//
// 中身は WASM ウィジェット(時計・メディア・クイックコントロール・システムモニタ・カレンダー)と、
// ネイティブの通知履歴。ウィジェットは share/ame-shell/widgets/*.wasm(~/.config/ame-shell/widgets/
// に同名があればそちらを優先)から読み、ファイルが更新されると状態を保ったまま差し替える。
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
const loop = @import("platform/loop.zig");
const sys = @import("platform/sys.zig");
const wasm = @import("wasm.zig");
const abi = @import("widget_abi.zig");
const bar = @import("bar.zig");

const PANEL_W: f32 = 420;
const SW: u32 = 460;
const PAD: f32 = 16;
const GAP: f32 = 12;
const WIDGETS = [_][]const u8{ "clock", "media", "controls", "sysmon", "calendar" };

const Card = struct {
    widget: ?*wasm.Widget = null,
    h: Spring = Spring.init(60, 0.38, 0.86),
    appear: Spring = Spring.init(0, 0.42, 0.76),
    y: f32 = 0, // 最後に描いた位置(入力判定用)
};

pub const Dashboard = struct {
    app: *App,
    surf: ?*Surface = null,
    out: ?*Output = null,
    is_open: bool = false,
    open_s: Spring = Spring.init(0, 0.42, 0.80),
    scroll: Spring = Spring.init(0, 0.3, 1.0),
    cards: [WIDGETS.len]Card = [_]Card{.{}} ** WIDGETS.len,
    store: abi.Store = .{},
    tick_timer: loop.Timer,
    hover_card: ?usize = null,
    notif_y: f32 = 0,
    clear_hover: bool = false,
    content_h: f32 = 0,
    dnd: bool = false,
    loaded: bool = false,
    watch_added: bool = false,

    pub fn create(app: *App) !*Dashboard {
        const self = try app.alloc.create(Dashboard);
        self.* = .{ .app = app, .tick_timer = try loop.Timer.init() };
        try app.loop.add(self.tick_timer.fd, c.EPOLLIN, self, onTick);
        return self;
    }

    // ---------------------------------------------------------------------
    // ウィジェットの読み込みとホットリロード
    // ---------------------------------------------------------------------

    fn widgetPath(self: *Dashboard, name: []const u8, buf: []u8) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse "";
        const cfg_dir = std.posix.getenv("XDG_CONFIG_HOME");
        const user = if (cfg_dir) |d|
            std.fmt.bufPrint(buf, "{s}/ame-shell/widgets/{s}.wasm", .{ d, name }) catch null
        else
            std.fmt.bufPrint(buf, "{s}/.config/ame-shell/widgets/{s}.wasm", .{ home, name }) catch null;
        if (user) |p| if (std.fs.cwd().access(p, .{})) |_| return p else |_| {};
        return std.fmt.bufPrint(buf, "{s}/widgets/{s}.wasm", .{ self.app.shareDir(), name }) catch null;
    }

    fn loadWidgets(self: *Dashboard) void {
        for (WIDGETS, 0..) |name, i| {
            if (self.cards[i].widget != null) continue;
            var buf: [600]u8 = undefined;
            const p = self.widgetPath(name, &buf) orelse continue;
            self.cards[i].widget = wasm.Widget.load(self.app.alloc, p, name, self, onAction) catch |e| blk: {
                std.log.err("widget {s} を読み込めません: {s}", .{ name, @errorName(e) });
                break :blk null;
            };
        }
        self.loaded = true;
        if (!self.watch_added) {
            self.watch_added = true;
            var buf: [600]u8 = undefined;
            const d = std.fmt.bufPrintZ(&buf, "{s}/widgets", .{self.app.shareDir()}) catch return;
            self.app.addWatch(d, self, onWidgetFile);
            const home = std.posix.getenv("HOME") orelse return;
            var buf2: [600]u8 = undefined;
            const ud = std.fmt.bufPrintZ(&buf2, "{s}/.config/ame-shell/widgets", .{home}) catch return;
            std.fs.cwd().makePath(ud) catch {};
            self.app.addWatch(ud, self, onWidgetFile);
        }
    }

    fn onWidgetFile(ctx: *anyopaque, name: []const u8) void {
        const self: *Dashboard = @ptrCast(@alignCast(ctx));
        if (!std.mem.endsWith(u8, name, ".wasm")) return;
        const base = name[0 .. name.len - 5];
        for (WIDGETS, 0..) |w, i| {
            if (!std.mem.eql(u8, w, base)) continue;
            if (self.cards[i].widget) |wd| {
                // ユーザー側に新しく置かれたらパスを切り替える
                var buf: [600]u8 = undefined;
                if (self.widgetPath(w, &buf)) |p| {
                    wd.path_len = @min(p.len, wd.path.len);
                    @memcpy(wd.path[0..wd.path_len], p[0..wd.path_len]);
                }
                wd.reload();
            } else self.loadWidgets();
        }
        if (self.surf) |s| s.schedule();
    }

    /// アイドル時に読み込み+1回実行(初回オープン時の wasm3 コンパイル待ちを無くす)
    pub fn prewarm(self: *Dashboard) void {
        self.loadWidgets();
        self.fillStore();
        for (&self.cards) |*cd| if (cd.widget) |w| {
            w.writeStore(&self.store);
            _ = w.height(PANEL_W - PAD * 2 - 24);
            _ = w.frame(0, PANEL_W - PAD * 2 - 24, 100);
            _ = w.pointer(.leave, 0, 0);
        };
    }

    pub fn reloadWidgets(self: *Dashboard) void {
        for (&self.cards) |*cd| if (cd.widget) |w| w.reload();
        self.loadWidgets();
        if (self.surf) |s| s.schedule();
    }

    /// ウィジェットからの操作要求(import "ame.action")
    fn onAction(ctx: *anyopaque, action: abi.Action, v: f32) void {
        const self: *Dashboard = @ptrCast(@alignCast(ctx));
        const app = self.app;
        switch (action) {
            .media_toggle => app.media.toggle(),
            .media_next => app.media.next(),
            .media_prev => app.media.prev(),
            .set_volume => {
                sys.setVolume(v);
                app.sys.volume = sys.volume();
                app.redrawBars();
            },
            .mute => {
                sys.toggleMute();
                app.sys.volume = sys.volume();
            },
            .set_brightness => {
                var arg: [16]u8 = undefined;
                const a = std.fmt.bufPrintZ(&arg, "{d}%", .{@as(u32, @intFromFloat(std.math.clamp(v, 0.01, 1) * 100))}) catch return;
                var out: [8]u8 = undefined;
                _ = sys.run(&.{ "brightnessctl", "-q", "set", a.ptr }, &out);
                app.sys.brightness = sys.brightness();
            },
            // 切り替えは待たずに(アダプタの電源を入れるのに 1 秒近くかかることがある)表示だけ先に変える。
            // 実際の状態は syswatch が NetworkManager / BlueZ のシグナルで受け取って直す
            .toggle_wifi => {
                if (@import("builtin").os.tag == .freebsd)
                    // wpa_supplicant: 切断して自動接続も止める / 再接続
                    sys.spawnDetached(if (self.store.wifi_on != 0) "wpa_cli disconnect" else "wpa_cli reconnect")
                else
                    sys.spawnDetached(if (self.store.wifi_on != 0) "nmcli radio wifi off" else "nmcli radio wifi on");
                self.store.wifi_on ^= 1;
            },
            .toggle_bt => if (app.syswatch.bluezRunning()) {
                sys.spawnDetached(if (self.store.bt_on != 0) "bluetoothctl power off" else "bluetoothctl power on");
                self.store.bt_on ^= 1;
            },
            .toggle_dnd => self.dnd = !self.dnd,
            .open_launcher => {
                self.close();
                app.launcher.open();
            },
            _ => {},
        }
        if (self.surf) |s| s.schedule();
    }

    /// Wi-Fi / Bluetooth の状態(開いたときと切り替え後だけ問い合わせる)
    fn queryRadios(self: *Dashboard) void {
        if (self.app.syswatch.wifiEnabled()) |on| self.store.wifi_on = @intFromBool(on);
        self.store.bt_on = @intFromBool(self.app.syswatch.btPowered());
    }

    fn fillStore(self: *Dashboard) void {
        const app = self.app;
        const st = &self.store;
        const tm = bar.localTime();
        st.year = tm.tm_year + 1900;
        st.month = tm.tm_mon + 1;
        st.mday = tm.tm_mday;
        st.wday = tm.tm_wday;
        st.hour = tm.tm_hour;
        st.min = tm.tm_min;
        st.sec = tm.tm_sec;
        st.cpu = app.sys.cpu;
        st.mem = app.sys.mem;
        st.temp = app.sys.temp orelse -1;
        st.volume = app.sys.volume.level;
        st.muted = @intFromBool(app.sys.volume.muted);
        st.brightness = app.sys.brightness orelse -1;
        st.battery = if (app.sys.battery.present) @as(f32, @floatFromInt(app.sys.battery.percent)) / 100 else -1;
        st.charging = @intFromBool(app.sys.battery.charging);
        st.dnd = @intFromBool(self.dnd);
        const m = app.media;
        st.media_status = @intFromEnum(m.status);
        st.media_pos = m.position();
        st.media_len = m.length_s;
        st.has_art = @intFromBool(m.art_tex != 0);
        const acc = theme.accent(app);
        st.accent = rgb(acc);
        st.text = rgb(theme.text(app));
        st.subtext = rgb(theme.subtext(app));
        st.title_len = @intCast(m.title_len);
        @memcpy(st.title[0..m.title_len], m.title[0..m.title_len]);
        st.artist_len = @intCast(m.artist_len);
        @memcpy(st.artist[0..m.artist_len], m.artist[0..m.artist_len]);
        st.player_len = @intCast(m.player_len);
        @memcpy(st.player[0..m.player_len], m.player[0..m.player_len]);
    }

    fn rgb(col: Color) u32 {
        const r: u32 = @intFromFloat(std.math.clamp(col.r, 0, 1) * 255);
        const g: u32 = @intFromFloat(std.math.clamp(col.g, 0, 1) * 255);
        const b: u32 = @intFromFloat(std.math.clamp(col.b, 0, 1) * 255);
        return (r << 16) | (g << 8) | b;
    }

    // ---------------------------------------------------------------------
    // 開閉
    // ---------------------------------------------------------------------

    pub fn toggle(self: *Dashboard) void {
        if (self.app.activeFrame()) |f| {
            f.toggleDashboard();
            return;
        }
        if (self.is_open) self.close() else self.open();
    }

    // ---- 枠(caelestia)から WASM ウィジェットを使うための口 ----
    pub fn widgetByName(self: *Dashboard, name: []const u8) ?*wasm.Widget {
        if (!self.loaded) self.loadWidgets();
        for (WIDGETS, 0..) |w, i| if (std.mem.eql(u8, w, name)) return self.cards[i].widget;
        return null;
    }
    pub fn refreshStore(self: *Dashboard) void {
        self.fillStore();
    }
    pub fn runCmdsPub(self: *Dashboard, cv: *gfx.Canvas, w: *wasm.Widget, cmds: []align(1) const abi.Cmd, h: f32) void {
        self.runCmds(cv, w, cmds, h);
    }
    pub fn queryRadiosPub(self: *Dashboard) void {
        self.queryRadios();
    }

    pub fn open(self: *Dashboard) void {
        if (self.app.activeFrame()) |f| {
            if (!f.dash.open) f.toggleDashboard();
            return;
        }
        if (self.is_open) return;
        const app = self.app;
        if (!self.loaded) self.loadWidgets();
        if (self.surf == null) {
            const out = app.activeOutput() orelse return;
            self.out = out;
            const top = app.cfg.bar_position == .top;
            const bar_space: i32 = @intFromFloat(app.cfg.bar_height + app.cfg.bar_margin);
            self.surf = Surface.createLayer(app, .{ .ctx = self, .draw = draw, .pointer = pointer, .key = key, .configured = configured }, .{
                .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
                .anchor = @intCast(c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM),
                .width = SW,
                .height = 0,
                .margin = if (top) .{ bar_space, 0, 0, 0 } else .{ 0, 0, bar_space, 0 },
                .keyboard = c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_ON_DEMAND,
                .namespace = "ame-dashboard",
                .output = out.wl,
            }) catch return;
            self.surf.?.output = out;
            self.open_s.snap(0);
            for (&self.cards) |*cd| cd.appear.snap(0);
        }
        self.queryRadios();
        app.sampleCpu();
        self.is_open = true;
        self.open_s.set(1);
        self.app.notifs.unread = 0;
        // CPU・メディア進捗の更新は開いている間だけ 1 秒ごと
        self.tick_timer.arm(1000, 1000);
        self.surf.?.schedule();
    }

    pub fn close(self: *Dashboard) void {
        if (self.app.activeFrame()) |f| {
            if (f.dash.open) f.toggleDashboard();
        }
        if (!self.is_open) return;
        self.is_open = false;
        self.open_s.set(0);
        self.tick_timer.disarm();
        if (self.surf) |s| {
            s.setInputRect(0, 0, 0, 0);
            if (s.layer) |l| c.zwlr_layer_surface_v1_set_keyboard_interactivity(l, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
            s.schedule();
        }
    }

    pub fn reap(self: *Dashboard) void {
        if (!self.is_open and self.open_s.x < 0.01 and self.surf != null) {
            self.surf.?.destroy();
            self.surf = null;
            self.out = null;
        }
    }

    fn onTick(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *Dashboard = @ptrCast(@alignCast(ctx));
        self.tick_timer.ack();
        self.app.sampleCpu();
        if (self.surf) |s| s.schedule();
    }

    pub fn tick(self: *Dashboard) void {
        if (self.surf) |s| s.schedule();
    }

    pub fn dataChanged(self: *Dashboard) void {
        if (self.surf) |s| s.schedule();
        if (self.app.cfg.layout == .caelestia) self.app.redrawBars();
    }

    pub fn backdropChanged(self: *Dashboard) void {
        if (self.surf) |s| s.schedule();
    }

    pub fn outputRemoved(self: *Dashboard, o: *Output) void {
        if (self.out == o) {
            if (self.surf) |s| s.destroy();
            self.surf = null;
            self.out = null;
            self.is_open = false;
        }
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        const self: *Dashboard = @ptrCast(@alignCast(ctx));
        const o = self.out orelse return;
        const sz = o.logicalSize();
        const top = self.app.cfg.bar_position == .top;
        const bar_space = self.app.cfg.bar_height + self.app.cfg.bar_margin;
        s.origin = .{ @as(f32, @floatFromInt(sz[0])) - SW, if (top) bar_space else 0 };
    }

    // ---------------------------------------------------------------------
    // 描画
    // ---------------------------------------------------------------------

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *Dashboard = @ptrCast(@alignCast(ctx));
        const app = self.app;
        var animating = theme.accentAnimating();
        if (self.open_s.step(dt)) animating = true;
        if (self.scroll.step(dt)) animating = true;
        if (!self.is_open and self.open_s.x < 0.01 and !self.open_s.moving()) {
            app.reap_pending = true;
            return false;
        }
        self.fillStore();

        const t = self.open_s.x;
        const H: f32 = @floatFromInt(s.height);
        const px = @as(f32, @floatFromInt(s.width)) - PANEL_W - 12;
        const py: f32 = 8;
        const ph = H - 20;
        const r = app.cfg.radius + 4;
        const inner_w = PANEL_W - PAD * 2;

        cv.save();
        cv.translate((1 - t) * (PANEL_W + 30), 0);
        cv.opacity(std.math.clamp(t * 1.4, 0, 1));
        cv.shadow(px, py + 8, PANEL_W, ph, r, 28, theme.shadow().alpha(1.2));
        cv.glass(px, py, PANEL_W, ph, r, theme.glassStrong(app));
        cv.setClip(px, py, PANEL_W, ph);

        var y = py + PAD - self.scroll.x;
        // ---- ウィジェットのカード(上から順に連鎖して出現) ----
        for (&self.cards, 0..) |*cd, i| {
            const w = cd.widget orelse continue;
            if (self.is_open and (i == 0 or self.cards[i - 1].appear.x > 0.3)) cd.appear.set(1);
            if (!self.is_open) cd.appear.set(0);
            if (cd.appear.step(dt)) animating = true;
            w.writeStore(&self.store);
            const want_h = w.height(inner_w - 24);
            if (cd.h.target != want_h) cd.h.set(want_h);
            if (cd.h.x == 60 and cd.h.target != 60 and !cd.h.moving()) cd.h.snap(want_h);
            if (cd.h.step(dt)) animating = true;
            const ch = cd.h.x;
            const a = cd.appear.x;
            cd.y = y;
            cv.save();
            cv.translate((1 - a) * 40, 0);
            cv.opacity(a);
            // カードの下地(パネルの上に重ねる薄い面)
            cv.rectGrad(px + PAD, y, inner_w, ch + 24, 16, Color.hex(0xffffff).alpha(0.06), Color.hex(0xffffff).alpha(0.025));
            cv.rectBorder(px + PAD, y, inner_w, ch + 24, 16, .{ .a = 0 }, Color.hex(0xffffff).alpha(0.08), 1);
            cv.save();
            cv.translate(px + PAD + 12, y + 12);
            const res = w.frame(dt, inner_w - 24, ch);
            if (res.animating) animating = true;
            self.runCmds(cv, w, res.cmds, ch);
            cv.restore();
            cv.restore();
            y += ch + 24 + GAP;
        }

        // ---- 通知センター ----
        self.notif_y = y;
        const txt = theme.text(app);
        const sub = theme.subtext(app);
        const acc = theme.accent(app);
        _ = cv.text(px + PAD + 4, y + 20, 15, txt, "通知", .{ .bold = true });
        const hist = app.notifs.history.items;
        if (hist.len > 0) {
            const cw = cv.measure("すべて消去", 12.5, false) + 20;
            const cx = px + PANEL_W - PAD - cw;
            cv.rect(cx, y + 3, cw, 24, 12, acc.alpha(if (self.clear_hover) 0.30 else 0.14));
            _ = cv.text(cx + cw / 2, y + 20, 12.5, txt, "すべて消去", .{ .alignment = .center });
        }
        if (self.dnd) _ = cv.text(px + PAD + 44, y + 20, 12, Color.hex(0xffb35c), "通知停止中", .{});
        y += 34;
        if (hist.len == 0) {
            _ = cv.text(px + PANEL_W / 2, y + 26, 13, sub, "新しい通知はありません", .{ .alignment = .center });
            y += 50;
        }
        for (hist) |n| {
            cv.rect(px + PAD, y, inner_w, 62, 14, Color.hex(0xffffff).alpha(0.05));
            _ = cv.text(px + PAD + 12, y + 20, 11.5, acc, n.appName(), .{ .bold = true, .max_w = inner_w - 80 });
            _ = cv.text(px + PANEL_W - PAD - 12, y + 20, 11, sub, n.time_str[0..5], .{ .alignment = .right });
            _ = cv.text(px + PAD + 12, y + 39, 14, txt, n.summaryText(), .{ .bold = true, .max_w = inner_w - 24 });
            _ = cv.text(px + PAD + 12, y + 56, 12, sub, n.bodyText(), .{ .max_w = inner_w - 24 });
            y += 70;
        }
        self.content_h = y + self.scroll.x - py;
        cv.setClip(0, 0, 0, 0);
        cv.restore();

        if (self.is_open) s.setInputRect(@intFromFloat(px), @intFromFloat(py), @intFromFloat(PANEL_W), @intFromFloat(ph));
        return animating;
    }

    /// ウィジェットの描画コマンドを Canvas 呼び出しに変換する
    fn runCmds(self: *Dashboard, cv: *gfx.Canvas, w: *wasm.Widget, cmds: []align(1) const abi.Cmd, h: f32) void {
        const app = self.app;
        for (cmds) |cmd| {
            const col = Color.rgba(cmd.col);
            const col2 = Color.rgba(cmd.col2);
            switch (@as(abi.CmdKind, @enumFromInt(cmd.kind))) {
                .rect => cv.rect(cmd.x, cmd.y, cmd.w, cmd.h, cmd.r, col),
                .grad => cv.rectGrad(cmd.x, cmd.y, cmd.w, cmd.h, cmd.r, col, col2),
                .border => cv.rectBorder(cmd.x, cmd.y, cmd.w, cmd.h, cmd.r, .{ .a = 0 }, col, cmd.a),
                .glass => cv.glass(cmd.x, cmd.y, cmd.w, cmd.h, cmd.r, theme.glass(app)),
                .shadow => cv.shadow(cmd.x, cmd.y, cmd.w, cmd.h, cmd.r, cmd.a, col),
                .text => {
                    const s = w.str(cmd.str_ptr, cmd.str_len);
                    const al: gfx.Align = switch ((cmd.flags >> 1) & 3) {
                        1 => .center,
                        2 => .right,
                        else => .left,
                    };
                    _ = cv.text(cmd.x, cmd.y, cmd.a, col, s, .{ .bold = cmd.flags & 1 != 0, .alignment = al, .max_w = cmd.w, .glow = cmd.b, .glow_color = col2 });
                },
                .wrap => cv.textWrap(cmd.x, cmd.y, cmd.a, col, w.str(cmd.str_ptr, cmd.str_len), cmd.w, 3, cmd.a * 1.4),
                .arc => cv.arc(cmd.x, cmd.y, cmd.w, cmd.a, cmd.b, col, col2),
                .art => if (app.media.art_tex != 0) cv.image(app.media.art_tex, cmd.x, cmd.y, cmd.w, cmd.h, cmd.r),
                .clip => {
                    // ウィジェット内のクリップはカードの範囲を超えないようにする
                    if (cmd.w <= 0) cv.setClip(0, 0, 0, 0) else cv.setClip(cmd.x, @max(cmd.y, -12), cmd.w, @min(cmd.h, h + 12));
                },
                _ => {},
            }
        }
        cv.setClip(0, 0, 0, 0);
    }

    // ---------------------------------------------------------------------
    // 入力
    // ---------------------------------------------------------------------

    fn panelX(s: *Surface) f32 {
        return @as(f32, @floatFromInt(s.width)) - PANEL_W - 12;
    }

    fn cardAt(self: *Dashboard, s: *Surface, x: f32, y: f32) ?usize {
        const px = panelX(s);
        if (x < px + PAD or x > px + PANEL_W - PAD) return null;
        for (self.cards, 0..) |cd, i| {
            if (cd.widget == null) continue;
            if (y >= cd.y and y < cd.y + cd.h.x + 24) return i;
        }
        return null;
    }

    fn pointer(ctx: *anyopaque, s: *Surface, ev: surface.PointerEvent) void {
        const self: *Dashboard = @ptrCast(@alignCast(ctx));
        if (!self.is_open) return;
        const px = panelX(s);
        const ci = if (ev.kind == .leave) null else self.cardAt(s, ev.x, ev.y);
        var redraw = false;
        if (ci != self.hover_card) {
            if (self.hover_card) |old| if (self.cards[old].widget) |w| {
                redraw = w.pointer(.leave, 0, 0) or redraw;
            };
            self.hover_card = ci;
        }
        // 「すべて消去」ボタン
        const ch = ev.y >= self.notif_y and ev.y < self.notif_y + 30 and ev.x > px + PANEL_W - PAD - 110 and ev.x < px + PANEL_W - PAD;
        if (ch != self.clear_hover) {
            self.clear_hover = ch;
            redraw = true;
        }
        if (ci) |i| {
            const cd = &self.cards[i];
            const lx = ev.x - (px + PAD + 12);
            const ly = ev.y - (cd.y + 12);
            const kind: ?abi.PointerKind = switch (ev.kind) {
                .motion, .enter => .motion,
                .press => .press,
                .release => .release,
                .scroll => if (ev.scroll < 0) .scroll_up else .scroll_down,
                .leave => .leave,
            };
            if (kind) |k| if (cd.widget) |w| {
                if (w.pointer(k, lx, ly)) redraw = true;
            };
            if (ev.kind == .scroll and i == WIDGETS.len - 1) {} // カレンダーはホイールで月送りに使う
        } else if (ev.kind == .scroll) {
            // パネルのスクロール
            const max = @max(0, self.content_h - @as(f32, @floatFromInt(s.height)) + 40);
            self.scroll.set(std.math.clamp(self.scroll.target + ev.scroll * 4, 0, max));
            redraw = true;
        }
        if (ev.kind == .press and ch) {
            self.app.notifs.clearAll();
            redraw = true;
        }
        if (ev.kind == .press and (ev.x < px or ev.x > px + PANEL_W)) self.close();
        if (redraw) s.schedule();
    }

    fn key(ctx: *anyopaque, _: *Surface, ev: surface.KeyEvent) void {
        const self: *Dashboard = @ptrCast(@alignCast(ctx));
        if (ev.sym == c.XKB_KEY_Escape) self.close();
    }
};
