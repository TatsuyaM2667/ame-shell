// caelestia 風レイアウトの中心:「枠(Frame)」。
//
// 出力ごとに全画面の layer surface を 1 枚持ち、そこに
//   * 画面の縁(細い枠)と左の縦バー
//   * 縁から生えてくるドロワー(ダッシュボード・ランチャー・通知・OSD・セッション・サイドバー・
//     ユーティリティ・バーのポップアウト)
// を全部描く。枠とドロワーは 1 つの SDF(smooth-min で融合)なので、ドロワーが開くと付け根に
// 凹の丸みができて「縁がニョキッと伸びた」ように見える(gfx.zig の frame_fs)。
//
// 入力: 入力領域を「バー・縁・見えているドロワー」の矩形だけにするので、それ以外のクリックは
// 下のウィンドウへそのまま届く。縁(10px)にマウスが乗ったことでホバーを検知し、ドロワーを開く。
// 排他領域(ウィンドウを避けさせる幅)は、各辺に貼った幅 1px の透明サーフェスで確保する
// (全面アンカーのサーフェスには排他領域を設定できないため)。
const std = @import("std");
const c = @import("../c.zig");
const anim = @import("../anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("../gfx.zig");
const theme = @import("../theme.zig");
const appmod = @import("../app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("../surface.zig");
const Surface = surface.Surface;
const loop = @import("../platform/loop.zig");
const sys = @import("../platform/sys.zig");
const data = @import("data.zig");
const vbar = @import("vbar.zig");
const dash = @import("dash.zig");
const side = @import("side.zig");

/// 1 つのドロワーの状態。t は開き具合(0..1、少し行き過ぎてから戻る)、w/h は中身の大きさ。
pub const Drawer = struct {
    open: bool = false,
    /// キー操作(ショートカット)で開いた。ホバーが外れても閉じない
    by_key: bool = false,
    t: Spring = Spring.init(0, 0.40, 0.70),
    w: Spring = Spring.init(0, 0.34, 0.88),
    h: Spring = Spring.init(0, 0.34, 0.88),
    /// 最後に描いた「見えている矩形」(入力判定・クリップ用)
    vis: [4]f32 = .{ 0, 0, 0, 0 },
    /// 中身の左上(content 座標の原点)
    ox: f32 = 0,
    oy: f32 = 0,

    pub fn show(self: *Drawer, by_key: bool) void {
        if (!self.open) self.by_key = by_key;
        self.open = true;
        self.t.set(1);
    }
    pub fn hide(self: *Drawer) void {
        self.open = false;
        self.by_key = false;
        self.t.set(0);
    }
    pub fn toggle(self: *Drawer) void {
        if (self.open) self.hide() else self.show(true);
    }
    pub fn visible(self: *const Drawer) bool {
        return self.open or self.t.x > 0.002 or self.t.v != 0;
    }
    /// 中身の大きさ。閉じている間は即座に合わせる(開くときに大きさまで伸び縮みしないように)
    pub fn setSize(self: *Drawer, w: f32, h: f32) void {
        if (!self.visible()) {
            self.w.snap(w);
            self.h.snap(h);
        } else {
            self.w.set(w);
            self.h.set(h);
        }
    }
    pub fn step(self: *Drawer, dt: f32) bool {
        const a = self.t.step(dt);
        const b = self.w.step(dt);
        const d = self.h.step(dt);
        return a or b or d;
    }
    pub fn contains(self: *const Drawer, x: f32, y: f32, pad: f32) bool {
        const r = self.vis;
        return self.visible() and x >= r[0] - pad and x < r[0] + r[2] + pad and y >= r[1] - pad and y < r[1] + r[3] + pad;
    }
};

pub const Frame = struct {
    app: *App,
    out: *Output,
    surf: *Surface,
    excl: [4]?*Surface = .{ null, null, null, null },
    /// 表示倍率(shell.ui-scale)。レイアウトは「論理 px / S」の仮想座標で行い、描画と入力で S 倍・1/S 倍する
    S: f32 = 1,
    W: f32 = 0,
    H: f32 = 0,

    dash: Drawer = .{},
    launch: Drawer = .{},
    osd: Drawer = .{},
    session: Drawer = .{},
    side: Drawer = .{},
    util: Drawer = .{},
    notif: Drawer = .{},
    pop: Drawer = .{},

    bar: vbar.Bar = .{},
    dashv: dash.View = .{},
    sidev: side.State = .{},
    pop_kind: vbar.Pop = .none,
    pop_cy: Spring = Spring.init(0, 0.28, 0.86),

    // ポインタ
    ptr_in: bool = false,
    px: f32 = -1,
    py: f32 = -1,
    pressed: bool = false,
    press_x: f32 = 0,
    press_y: f32 = 0,
    kb_mode: u32 = c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,

    osd_timer: loop.Timer,
    tick_timer: loop.Timer,
    perf: data.Perf = .{},
    weather: data.Weather,
    cava: data.Cava,
    inhibitor: ?*c.struct_zwp_idle_inhibitor_v1 = null,
    hw: data.HwInfo = .{},
    util_queried: bool = false,

    pub fn create(app: *App, out: *Output) !*Frame {
        const self = try app.alloc.create(Frame);
        self.* = .{
            .app = app,
            .out = out,
            .surf = undefined,
            .osd_timer = try loop.Timer.init(),
            .tick_timer = try loop.Timer.init(),
            .weather = .{ .app = app },
            .cava = .{ .app = app },
        };
        self.weather.ctx = self;
        self.weather.on_update = redrawCb;
        self.cava.ctx = self;
        self.cava.on_frame = redrawCb;
        try app.loop.add(self.osd_timer.fd, c.EPOLLIN, self, onOsdTimer);
        try app.loop.add(self.tick_timer.fd, c.EPOLLIN, self, onTick);
        const all = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        self.surf = try Surface.createLayer(app, .{
            .ctx = self,
            .draw = draw,
            .pointer = pointer,
            .key = key,
            .configured = configured,
        }, .{
            .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            .anchor = @intCast(all),
            .exclusive = -1, // 他の排他領域(自分の枠も含む)を無視して全面を覆う
            .namespace = "ame-frame",
            .output = out.wl,
        });
        self.surf.output = out;
        self.makeExclusions();
        // GPU 名は GL から(共有コンテキストを current にして読む)
        _ = c.eglMakeCurrent(app.gpu.dpy, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, app.gpu.ctx);
        const r = c.glGetString(c.GL_RENDERER);
        self.hw.load(if (r != null) std.mem.sliceTo(r, 0) else "");
        self.bar.enter.snap(0);
        self.bar.enter.set(1);
        return self;
    }

    pub fn destroy(self: *Frame) void {
        self.cava.stop();
        self.app.loop.remove(self.osd_timer.fd);
        self.app.loop.remove(self.tick_timer.fd);
        _ = c.close(self.osd_timer.fd);
        _ = c.close(self.tick_timer.fd);
        if (self.inhibitor) |i| c.zwp_idle_inhibitor_v1_destroy(i);
        for (&self.excl) |*e| {
            if (e.*) |s| s.destroy();
            e.* = null;
        }
        self.surf.destroy();
        self.app.alloc.destroy(self);
    }

    // ---------------------------------------------------------------------
    // 幾何
    // ---------------------------------------------------------------------

    pub fn T(self: *const Frame) f32 {
        return self.app.cfg.frame_thickness;
    }
    pub fn R(self: *const Frame) f32 {
        return self.app.cfg.frame_rounding;
    }
    pub fn BW(self: *const Frame) f32 {
        return self.app.cfg.frame_bar_width;
    }
    fn K(self: *const Frame) f32 {
        return self.app.cfg.frame_smoothing;
    }

    /// 縁の 4 辺に幅 1px の透明サーフェスを置き、排他領域だけを確保する
    fn makeExclusions(self: *Frame) void {
        const L = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
        const Rt = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        const Tp = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
        const Bt = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
        const specs = [4]struct { anchor: c_int, w: u32, h: u32, zone: f32 }{
            .{ .anchor = L | Tp | Bt, .w = 1, .h = 0, .zone = self.BW() * self.app.cfg.ui_scale },
            .{ .anchor = Tp | L | Rt, .w = 0, .h = 1, .zone = self.T() * self.app.cfg.ui_scale },
            .{ .anchor = Rt | Tp | Bt, .w = 1, .h = 0, .zone = self.T() * self.app.cfg.ui_scale },
            .{ .anchor = Bt | L | Rt, .w = 0, .h = 1, .zone = self.T() * self.app.cfg.ui_scale },
        };
        for (specs, 0..) |sp, i| {
            const s = Surface.createLayer(self.app, .{ .ctx = self, .draw = drawNothing }, .{
                .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
                .anchor = @intCast(sp.anchor),
                .width = sp.w,
                .height = sp.h,
                .exclusive = @intFromFloat(sp.zone),
                .namespace = "ame-frame-exclusion",
                .output = self.out.wl,
            }) catch continue;
            s.output = self.out;
            s.setInputRect(0, 0, 0, 0);
            self.excl[i] = s;
        }
    }

    pub fn geometryChanged(self: *Frame) void {
        for (&self.excl) |*e| {
            if (e.*) |s| s.destroy();
            e.* = null;
        }
        self.makeExclusions();
        self.surf.schedule();
    }

    fn drawNothing(_: *anyopaque, _: *Surface, _: *gfx.Canvas, _: f32) bool {
        return false;
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        const self: *Frame = @ptrCast(@alignCast(ctx));
        self.S = self.app.cfg.ui_scale;
        self.W = @as(f32, @floatFromInt(s.width)) / self.S;
        self.H = @as(f32, @floatFromInt(s.height)) / self.S;
        s.origin = .{ 0, 0 };
        // 全面サーフェスなので、壁紙より先に configure されたらここで出力サイズを決める
        if (self.out.width == 0) {
            self.out.width = s.width;
            self.out.height = s.height;
        }
    }

    pub fn schedule(self: *Frame) void {
        self.surf.schedule();
    }

    fn redrawCb(ctx: *anyopaque) void {
        const self: *Frame = @ptrCast(@alignCast(ctx));
        self.surf.schedule();
    }

    // ---------------------------------------------------------------------
    // 外部からの操作(ame-ctl / キーバインド / 他モジュール)
    // ---------------------------------------------------------------------

    pub fn toggleDashboard(self: *Frame) void {
        self.dash.toggle();
        // 大きなドロワー同士(ダッシュボードとランチャー)は重ならないよう、片方を開いたらもう片方を閉じる
        if (self.dash.open and self.app.launcher.is_open) self.app.launcher.close();
        self.afterOpenChange();
    }
    pub fn toggleSession(self: *Frame) void {
        self.session.toggle();
        self.sidev.confirm = null;
        self.afterOpenChange();
    }
    pub fn toggleSidebar(self: *Frame) void {
        self.side.toggle();
        self.app.notifs.unread = 0;
        self.afterOpenChange();
    }
    pub fn toggleUtilities(self: *Frame) void {
        self.util.toggle();
        self.afterOpenChange();
    }
    pub fn launcherChanged(self: *Frame) void {
        if (self.app.launcher.is_open) {
            self.launch.show(true);
            self.dash.hide();
        } else self.launch.hide();
        self.afterOpenChange();
    }
    pub fn showOsd(self: *Frame) void {
        // 音量・明るさが変わった: 右端に OSD を出し、1.5 秒後に閉じる(マウスが乗っていれば閉じない)
        if (!self.osd.open) self.osd.show(true);
        self.osd_timer.arm(1500, 0);
        self.surf.schedule();
    }

    fn afterOpenChange(self: *Frame) void {
        self.updateKeyboard();
        self.updateTick();
        if (self.dash.open) self.weather.refresh();
        if (self.util.open and !self.util_queried) {
            // 開いた瞬間に一度だけ(nmcli/bluetoothctl/powerprofilesctl は数十 ms かかるので毎フレームは呼ばない)
            self.util_queried = true;
            self.sidev.profile = data.powerProfile();
            self.app.dashboard.queryRadiosPub();
            self.bar.bt_on = self.app.dashboard.store.bt_on != 0;
        }
        if (!self.util.open) self.util_queried = false;
        self.surf.schedule();
    }

    /// ランチャーとセッションはキーボードを奪う(Esc や入力のため)。それ以外は奪わない。
    fn updateKeyboard(self: *Frame) void {
        const want: u32 = if (self.launch.open or (self.session.open and self.session.by_key))
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE
        else
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE;
        if (want == self.kb_mode) return;
        self.kb_mode = want;
        if (self.surf.layer) |l| c.zwlr_layer_surface_v1_set_keyboard_interactivity(l, want);
    }

    /// CPU/GPU やメディア進捗の更新は、それを表示するドロワーが開いている間だけ 1 秒ごと
    fn updateTick(self: *Frame) void {
        if (self.dash.open or self.util.open or self.pop_kind != .none) self.tick_timer.arm(1000, 1000) else self.tick_timer.disarm();
    }

    fn onTick(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *Frame = @ptrCast(@alignCast(ctx));
        self.tick_timer.ack();
        self.app.sampleCpu();
        if (self.dash.open) self.perf.sample();
        // 歌詞を見ている間は再生位置のずれを補正する
        if (self.dash.open and self.dashv.tab <= 1) self.app.media.resyncPosition();
        self.surf.schedule();
    }

    fn onOsdTimer(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *Frame = @ptrCast(@alignCast(ctx));
        self.osd_timer.ack();
        // マウスが OSD の上にあるならホバー操作に切り替えて開いたままにする
        if (self.osd.contains(self.px, self.py, self.R()) and self.ptr_in) {
            self.osd.by_key = false;
            return;
        }
        if (self.osd.by_key) self.osd.hide();
        self.surf.schedule();
    }

    pub fn setIdleInhibit(self: *Frame, on: bool) void {
        if (on and self.inhibitor == null) {
            if (self.app.idle_mgr) |m| self.inhibitor = c.zwp_idle_inhibit_manager_v1_create_inhibitor(m, self.surf.wl);
        } else if (!on) {
            if (self.inhibitor) |i| c.zwp_idle_inhibitor_v1_destroy(i);
            self.inhibitor = null;
        }
        self.surf.schedule();
    }

    pub fn closeAll(self: *Frame) void {
        inline for (.{ &self.dash, &self.osd, &self.session, &self.side, &self.util, &self.pop }) |d| d.hide();
        self.app.launcher.close();
        self.pop_kind = .none;
        self.afterOpenChange();
    }

    // ---------------------------------------------------------------------
    // ホバー/ドラッグの規則(caelestia の Interactions を参考に再設計)
    // ---------------------------------------------------------------------

    fn applyHover(self: *Frame, x: f32, y: f32) void {
        const T_ = self.T();
        const R_ = self.R();
        const W = self.W;
        const H = self.H;
        var changed = false;

        // ダッシュボード: 上の縁の中央(ダッシュボードの幅の範囲)
        {
            const d = &self.dash;
            const w = d.w.target;
            const x0 = self.BW() + (W - self.BW() - T_) / 2 - w / 2;
            const reach = @max(T_, T_ + d.h.x * d.t.x) + 1;
            const inside = self.ptr_in and y < reach and x >= x0 - R_ and x <= x0 + w + R_;
            if (inside and d.by_key) d.by_key = false;
            if (!d.by_key and inside != d.open) {
                if (inside) d.show(false) else d.hide();
                changed = true;
            }
        }
        // OSD: 右の縁の縦中央
        {
            const d = &self.osd;
            const h = d.h.target;
            const right_off = self.side.w.x * self.side.t.x + self.session.w.x * self.session.t.x;
            const inside = self.ptr_in and x > W - @max(T_, T_ + right_off + d.w.x * d.t.x) - 1 and y >= H / 2 - h / 2 - R_ and y <= H / 2 + h / 2 + R_;
            if (inside and d.by_key) d.by_key = false;
            if (!d.by_key and inside != d.open) {
                if (inside) d.show(false) else d.hide();
                changed = true;
            }
        }
        // ユーティリティ: 右下の角
        {
            const d = &self.util;
            const w = d.w.target;
            const reach = @max(T_, T_ + d.h.x * d.t.x) + R_;
            const inside = self.ptr_in and y > H - reach and x >= W - T_ - w - R_;
            if (inside and d.by_key) d.by_key = false;
            if (!d.by_key and inside != d.open) {
                if (inside) d.show(false) else d.hide();
                changed = true;
            }
        }
        // バーのポップアウト: バーの項目に乗ったら右に出す。バーにもポップアウトにも居なければ閉じる
        {
            var kind: vbar.Pop = .none;
            var cy: f32 = 0;
            if (self.ptr_in and x < self.BW()) {
                const hit = self.bar.popoutAt(y);
                kind = hit.kind;
                cy = hit.cy;
            } else if (self.ptr_in and self.pop.contains(x, y, R_ / 2)) {
                kind = self.pop_kind; // ポップアウトの上ではそのまま
                cy = self.pop_cy.target;
            }
            if (kind != self.pop_kind or (kind != .none and cy != self.pop_cy.target)) {
                if (kind == .none) {
                    self.pop.hide();
                } else {
                    if (self.pop_kind == .none) self.pop_cy.snap(cy) else self.pop_cy.set(cy);
                    self.pop.show(false);
                    self.pop_kind = kind;
                }
                if (kind == .none and self.pop.t.x < 0.02) self.pop_kind = .none;
                changed = true;
            }
        }
        if (changed) self.afterOpenChange();
    }

    fn applyDrag(self: *Frame, x: f32, y: f32) void {
        const T_ = self.T();
        const dx = x - self.press_x;
        const dy = y - self.press_y;
        // 下の縁の中央から上へ 50px ドラッグ → ランチャー
        if (self.press_y > self.H - T_ - 2 and dy < -50 and !self.app.launcher.is_open) {
            self.app.launcher.open();
        }
        // 右の縁から左へドラッグ: 縦中央付近ならセッション、それ以外はサイドバー
        if (self.press_x > self.W - T_ - 2) {
            const mid = @abs(self.press_y - self.H / 2) < self.session.h.target / 2;
            if (dx < -40 and mid and !self.session.open) {
                self.session.show(false);
                self.afterOpenChange();
            } else if (dx < -80 and !mid and !self.side.open) {
                self.side.show(true);
                self.afterOpenChange();
            }
        }
        // 開いたサイドバーを右へドラッグ → 閉じる
        if (self.side.open and self.side.contains(self.press_x, self.press_y, 0) and dx > 80) {
            self.side.hide();
            self.afterOpenChange();
        }
    }

    // ---------------------------------------------------------------------
    // 入力
    // ---------------------------------------------------------------------

    fn pointer(ctx: *anyopaque, s: *Surface, ev_raw: surface.PointerEvent) void {
        const self: *Frame = @ptrCast(@alignCast(ctx));
        // 仮想座標に直す
        var ev = ev_raw;
        ev.x /= self.S;
        ev.y /= self.S;
        switch (ev.kind) {
            .enter => {
                self.ptr_in = true;
                self.px = ev.x;
                self.py = ev.y;
            },
            .leave => {
                self.ptr_in = false;
                self.pressed = false;
                self.px = -1;
                self.py = -1;
            },
            .motion => {
                self.px = ev.x;
                self.py = ev.y;
                if (self.pressed) self.applyDrag(ev.x, ev.y);
            },
            .press => {
                self.pressed = true;
                self.press_x = ev.x;
                self.press_y = ev.y;
            },
            .release => self.pressed = false,
            .scroll => {},
        }
        self.applyHover(self.px, self.py);
        // 中身への配送: 見えているドロワー → バー の順で、座標を各ドロワーの中身の座標に直して渡す
        var redraw = false;
        if (self.routePointer(ev)) redraw = true;
        if (ev.kind == .leave or ev.kind == .enter or redraw) s.schedule();
        if (ev.kind == .motion) s.schedule(); // ホバーのハイライト
    }

    fn routePointer(self: *Frame, ev: surface.PointerEvent) bool {
        const x = self.px;
        const y = self.py;
        if (ev.kind == .leave) {
            _ = self.bar.pointer(self, ev, -1, -1);
            _ = dash.pointer(self, ev, -1, -1);
            self.sidev.hover = -1;
            self.app.notifs.hover_idx = null;
            return true;
        }
        if (x < self.BW()) {
            return self.bar.pointer(self, ev, x, y);
        }
        _ = self.bar.pointer(self, .{ .kind = .leave, .x = 0, .y = 0 }, -1, -1);
        const D = struct { d: *Drawer, which: side.Which };
        const list = [_]D{
            .{ .d = &self.launch, .which = .launcher },
            .{ .d = &self.dash, .which = .dashboard },
            .{ .d = &self.notif, .which = .notifs },
            .{ .d = &self.session, .which = .session },
            .{ .d = &self.osd, .which = .osd },
            .{ .d = &self.side, .which = .sidebar },
            .{ .d = &self.util, .which = .utilities },
            .{ .d = &self.pop, .which = .popout },
        };
        for (list) |it| {
            if (!it.d.contains(x, y, 0)) continue;
            const lx = x - it.d.ox;
            const ly = y - it.d.oy;
            return switch (it.which) {
                .dashboard => dash.pointer(self, ev, lx, ly),
                .launcher => self.app.launcher.panelPointer(ev, lx, ly, it.d.w.x, it.d.h.x),
                else => side.pointer(self, it.which, ev, lx, ly),
            };
        }
        return false;
    }

    fn key(ctx: *anyopaque, s: *Surface, ev: surface.KeyEvent) void {
        const self: *Frame = @ptrCast(@alignCast(ctx));
        if (self.launch.open) {
            self.app.launcher.frameKey(s, ev);
            return;
        }
        if (ev.sym == c.XKB_KEY_Escape) self.closeAll();
        if (self.session.open) side.sessionKey(self, ev);
        s.schedule();
    }

    // ---------------------------------------------------------------------
    // 描画
    // ---------------------------------------------------------------------

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *Frame = @ptrCast(@alignCast(ctx));
        const app = self.app;
        if (s.width == 0) return false;
        // 倍率は設定の再読込で変わりうるので毎回求め直す
        self.S = app.cfg.ui_scale;
        self.W = @as(f32, @floatFromInt(s.width)) / self.S;
        self.H = @as(f32, @floatFromInt(s.height)) / self.S;
        const S_ = self.S;
        const W = self.W;
        const H = self.H;
        const T_ = self.T();
        const R_ = self.R();
        const K_ = self.K();
        const BW_ = self.BW();
        var animating = theme.accentAnimating();

        // ---- 中身の大きさを決める ----
        const dsz = dash.size(self);
        self.dash.setSize(dsz[0], dsz[1]);
        const lsz = app.launcher.panelSize();
        self.launch.setSize(lsz[0], lsz[1]);
        self.osd.setSize(66, 300);
        self.session.setSize(100, 5 * 76 + 24);
        const nh = side.notifHeight(self);
        const notif_w: f32 = if (self.side.open) 400 else 380;
        if (nh > 0 and !self.notif.open) self.notif.show(false);
        if (nh <= 0 and self.notif.open) self.notif.hide();
        self.notif.setSize(notif_w, @max(nh, 1));
        self.util.setSize(360, 206);
        self.side.setSize(400, self.side.h.x);
        const psz = vbar.popSize(self, self.pop_kind);
        self.pop.setSize(psz[0], psz[1]);
        if (!self.pop.open and self.pop.t.x < 0.01 and self.pop_kind != .none) {
            self.pop_kind = .none;
            self.updateTick();
        }

        inline for (.{ &self.dash, &self.launch, &self.osd, &self.session, &self.side, &self.util, &self.notif, &self.pop }) |d| {
            if (d.step(dt)) animating = true;
        }
        if (self.pop_cy.step(dt)) animating = true;

        // ---- 位置を決め、枠の形を作る ----
        var sh = gfx.FrameShape{};
        sh.hole = .{ BW_, T_, W - BW_ - T_, H - 2 * T_ };
        sh.hole_r = R_;
        const g = theme.glass(app);
        sh.tint = theme.tint(app);
        sh.tint.a = app.cfg.frame_opacity;
        sh.rim = g.rim;
        sh.sheen = g.sheen;
        sh.sparkle = app.cfg.sparkle * 0.8;
        const kf = struct {
            fn k(base: f32, ext: f32) f32 {
                return base * std.math.clamp(ext / base, 0, 1);
            }
        }.k;

        // 右側の積み重ね: サイドバー → セッション → OSD の順に左へ
        const side_vw = self.side.w.x * @max(self.side.t.x, 0);
        const sess_vw = self.session.w.x * @max(self.session.t.x, 0);
        const util_vh = self.util.h.x * @max(self.util.t.x, 0);
        const notif_vh = self.notif.h.x * @max(self.notif.t.x, 0);

        // ダッシュボード(上・中央)
        {
            const d = &self.dash;
            const w = d.w.x;
            const vh = d.h.x * @max(d.t.x, 0);
            const x = BW_ + (W - BW_ - T_) / 2 - w / 2;
            d.vis = .{ x, T_, w, vh };
            d.ox = x;
            d.oy = T_ + vh - d.h.x;
            sh.add(x, -R_, w, T_ + R_ + vh, R_, kf(K_, vh));
        }
        // ランチャー(下・中央)
        {
            const d = &self.launch;
            const w = d.w.x;
            const vh = d.h.x * @max(d.t.x, 0);
            const x = BW_ + (W - BW_ - T_) / 2 - w / 2;
            d.vis = .{ x, H - T_ - vh, w, vh };
            d.ox = x;
            d.oy = H - T_ - vh;
            sh.add(x, H - T_ - vh, w, vh + T_ + R_, R_, kf(K_, vh));
        }
        // 通知(右上)。サイドバーが開いているときはその幅に合わせる
        {
            const d = &self.notif;
            const w = d.w.x;
            const x = W - T_ - w;
            d.vis = .{ x, T_, w, notif_vh };
            d.ox = x;
            d.oy = T_ + notif_vh - d.h.x;
            sh.add(x, -R_, w + T_ + R_, T_ + R_ + notif_vh, R_, kf(K_, notif_vh));
        }
        // ユーティリティ(右下)
        {
            const d = &self.util;
            const w = d.w.x;
            const x = W - T_ - w;
            d.vis = .{ x, H - T_ - util_vh, w, util_vh };
            d.ox = x;
            d.oy = H - T_ - util_vh;
            sh.add(x, H - T_ - util_vh, w + T_ + R_, util_vh + T_ + R_, R_, kf(K_, util_vh));
        }
        // サイドバー(右、通知とユーティリティの間)
        {
            const d = &self.side;
            const top = T_ + notif_vh;
            const bottom = H - T_ - util_vh;
            const x = W - T_ - side_vw;
            d.vis = .{ x, top, side_vw, bottom - top };
            d.ox = x;
            d.oy = top;
            d.h.snap(bottom - top);
            sh.add(x, top - R_ * 0.5, side_vw + T_ + R_, bottom - top + R_, R_, kf(K_, side_vw));
        }
        // 右辺の中央に出すものは、通知とユーティリティの間に収まるよう縦位置を寄せる
        const midY = struct {
            fn f(h: f32, top: f32, bottom: f32, Hh: f32) f32 {
                const lo = top + h / 2 + 6;
                const hi = bottom - h / 2 - 6;
                if (lo > hi) return (top + bottom) / 2;
                return std.math.clamp(Hh / 2, lo, hi);
            }
        }.f;
        // セッション(右・縦中央、サイドバーの左)
        {
            const d = &self.session;
            const h = d.h.x;
            const x = W - T_ - side_vw - sess_vw;
            const cy = midY(h, T_ + notif_vh, H - T_ - util_vh, H);
            d.vis = .{ x, cy - h / 2, sess_vw, h };
            d.ox = x;
            d.oy = cy - h / 2;
            sh.add(x, cy - h / 2, sess_vw + side_vw + T_ + R_, h, R_, kf(K_, sess_vw));
        }
        // OSD(右・縦中央、さらに左)
        {
            const d = &self.osd;
            const h = d.h.x;
            const vw = d.w.x * @max(d.t.x, 0);
            const x = W - T_ - side_vw - sess_vw - vw;
            const cy = midY(h, T_ + notif_vh, H - T_ - util_vh, H);
            d.vis = .{ x, cy - h / 2, vw, h };
            d.ox = x;
            d.oy = cy - h / 2;
            sh.add(x, cy - h / 2, vw + sess_vw + side_vw + T_ + R_, h, R_, kf(K_, vw));
        }
        // バーのポップアウト(左、ホバー中の項目の高さ)
        {
            const d = &self.pop;
            const h = d.h.x;
            const vw = d.w.x * @max(d.t.x, 0);
            const cy = std.math.clamp(self.pop_cy.x, T_ + h / 2 + 4, H - T_ - h / 2 - 4);
            d.vis = .{ BW_, cy - h / 2, vw, h };
            d.ox = BW_ + vw - d.w.x;
            d.oy = cy - h / 2;
            sh.add(-R_, cy - h / 2, BW_ + R_ + vw, h, R_, kf(K_, vw));
        }

        // ---- 枠 ----
        sh.scale(S_);
        cv.frameBg(&sh);
        cv.save();
        cv.scaleAbout(0, 0, S_);

        // ---- バー ----
        if (self.bar.draw(self, cv, dt)) animating = true;

        // ---- ドロワーの中身(見えている部分でクリップ) ----
        if (self.dash.visible() and self.dash.vis[3] > 1) {
            cv.save();
            cv.setClip(self.dash.vis[0], self.dash.vis[1], self.dash.vis[2], self.dash.vis[3]);
            cv.translate(self.dash.ox, self.dash.oy);
            if (dash.draw(self, cv, dt)) animating = true;
            cv.restore();
            cv.setClip(0, 0, 0, 0);
        } else if (self.cava.running()) self.cava.stop();
        if (self.launch.visible() and self.launch.vis[3] > 1) {
            cv.save();
            cv.setClip(self.launch.vis[0], self.launch.vis[1], self.launch.vis[2], self.launch.vis[3]);
            cv.translate(self.launch.ox, self.launch.oy);
            if (app.launcher.drawPanel(cv, self.launch.w.x, self.launch.h.x, dt)) animating = true;
            cv.restore();
            cv.setClip(0, 0, 0, 0);
        }
        const panels = [_]struct { d: *Drawer, which: side.Which }{
            .{ .d = &self.notif, .which = .notifs },
            .{ .d = &self.util, .which = .utilities },
            .{ .d = &self.side, .which = .sidebar },
            .{ .d = &self.session, .which = .session },
            .{ .d = &self.osd, .which = .osd },
            .{ .d = &self.pop, .which = .popout },
        };
        for (panels) |p| {
            if (!p.d.visible() or p.d.vis[2] < 1 or p.d.vis[3] < 1) continue;
            cv.save();
            cv.setClip(p.d.vis[0], p.d.vis[1], p.d.vis[2], p.d.vis[3]);
            cv.translate(p.d.ox, p.d.oy);
            if (side.draw(self, p.which, cv, p.d.w.x, p.d.h.x, dt)) animating = true;
            cv.restore();
            cv.setClip(0, 0, 0, 0);
        }
        // 通知カードのスプリングは通知ドロワーが閉じていても進める(片付けのため)
        if (side.stepNotifs(self, dt)) animating = true;

        cv.restore();
        // ---- 入力領域: バー + 縁 + 見えているドロワー ----
        var rects: [16][4]f32 = undefined;
        var n: usize = 0;
        rects[n] = .{ 0, 0, BW_, H };
        n += 1;
        rects[n] = .{ 0, 0, W, T_ };
        n += 1;
        rects[n] = .{ W - T_, 0, T_, H };
        n += 1;
        rects[n] = .{ 0, H - T_, W, T_ };
        n += 1;
        inline for (.{ &self.dash, &self.launch, &self.notif, &self.util, &self.side, &self.session, &self.osd, &self.pop }) |d| {
            if (d.visible() and n < rects.len) {
                rects[n] = d.vis;
                n += 1;
            }
        }
        for (rects[0..n]) |*r| {
            for (r) |*v| v.* *= S_;
        }
        s.setInputRects(rects[0..n]);
        return animating;
    }
};
