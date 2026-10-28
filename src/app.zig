// ame-shell 本体の状態と Wayland 接続。
//
// 1プロセス・1 EGL コンテキストで、出力ごとに「壁紙」と「バー」、全体で1つずつ
// 「OSD」「ランチャー」「ダッシュボード」「通知」「ロック画面」を持つ。
const std = @import("std");

const anim = @import("anim.zig");
const Audio = @import("audio.zig").Audio;
const Avatar = @import("avatar.zig").Avatar;
const Bar = @import("bar.zig").Bar;
const c = @import("c.zig");
const cfgmod = @import("config.zig");
const Dashboard = @import("dashboard.zig").Dashboard;
const Frame = @import("frame/frame.zig").Frame;
const gfx = @import("gfx.zig");
const ipc = @import("ipc.zig");
const Launcher = @import("launcher.zig").Launcher;
const Lock = @import("lock.zig").Lock;
const Media = @import("media.zig").Media;
const Notifs = @import("notify.zig").Notifs;
const Osd = @import("osd.zig").Osd;
const loop_mod = @import("platform/loop.zig");
const SuperTap = @import("platform/supertap.zig").SuperTap;
const sys = @import("platform/sys.zig");
const surface = @import("surface.zig");
const Surface = surface.Surface;
const SysWatch = @import("syswatch.zig").SysWatch;
const text = @import("text.zig");
const Toplevels = @import("toplevels.zig").Toplevels;
const Wallpaper = @import("wallpaper.zig").Wallpaper;
const WallPick = @import("wallpick.zig").WallPick;
const Touchpad = @import("wm/touchpad.zig");
const Wm = @import("wm/wm.zig").Wm;

const log = std.log.scoped(.app);

pub const Output = struct {
    app: *App,
    wl: *c.struct_wl_output,
    global: u32,
    scale: i32 = 1,
    refresh_mhz: i32 = 60000,
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    /// 論理サイズ(壁紙サーフェスの configure から確定)
    width: u32 = 0,
    height: u32 = 0,
    name: cfgmod.Str = .{},
    done: bool = false,
    river: ?*c.struct_zriver_output_status_v1 = null,
    focused_tags: u32 = 1,
    view_tags: u32 = 0,
    /// 各ビュー(ウィンドウ)のタグ(river-status の view_tags をそのまま)。今のタグの窓の数を数えるため
    view_list: [64]u32 = undefined,
    n_views: usize = 0,
    urgent_tags: u32 = 0,
    layout: cfgmod.Str = .{},
    backdrop: gfx.Backdrop = .{},
    bar: ?*Bar = null,
    /// caelestia レイアウトの枠(classic では null)
    frame: ?*Frame = null,
    wall: ?*Wallpaper = null,

    pub fn logicalSize(self: *const Output) [2]u32 {
        if (self.width > 0) return .{ self.width, self.height };
        const s: i32 = @max(self.scale, 1);
        return .{ @intCast(@max(@divTrunc(self.mode_w, s), 1)), @intCast(@max(@divTrunc(self.mode_h, s), 1)) };
    }
};

/// フレーム時間の統計(perf.md 用、`ame-ctl stats` で取得)
pub const FrameStats = struct {
    frames: u64 = 0,
    sum_dt: f64 = 0,
    max_dt: f32 = 0,
    render_us_max: u64 = 0,
    render_us_sum: u64 = 0,
    renders: u64 = 0,

    /// 1回の描画(シェル側の CPU 時間: 状態更新 + 命令生成 + GL 発行 + swap)
    pub fn recordRender(self: *FrameStats, us: u64) void {
        self.renders += 1;
        self.render_us_sum += us;
        if (self.renders > 5) self.render_us_max = @max(self.render_us_max, us); // 起動直後のシェーダコンパイルは除外
    }

    pub fn record(self: *FrameStats, dt: f32) void {
        self.frames += 1;
        self.sum_dt += dt;
        if (dt < 0.1) self.max_dt = @max(self.max_dt, dt);
    }
};

pub const SysState = struct {
    battery: sys.Battery = .{},
    volume: sys.Volume = .{},
    brightness: ?f32 = null,
    net: sys.Net = .{},
    cpu_prev: sys.CpuSample = .{},
    cpu: f32 = 0,
    mem: f32 = 0,
    temp: ?f32 = null,
};

/// 他のモジュール(ウィジェットのホットリロード)からも同じ inotify を使う
pub const InotifyHook = struct { wd: c_int, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque, name: []const u8) void };

pub const App = struct {
    alloc: std.mem.Allocator,
    display: *c.struct_wl_display,
    registry: *c.struct_wl_registry = undefined,
    compositor: ?*c.struct_wl_compositor = null,
    compositor_version: u32 = 0,
    layer_shell: ?*c.struct_zwlr_layer_shell_v1 = null,
    river_status: ?*c.struct_zriver_status_manager_v1 = null,
    river_control: ?*c.struct_zriver_control_v1 = null,
    lock_mgr: ?*c.struct_ext_session_lock_manager_v1 = null,
    cursor_mgr: ?*c.struct_wp_cursor_shape_manager_v1 = null,
    idle_mgr: ?*c.struct_zwp_idle_inhibit_manager_v1 = null,
    /// River 0.5 以降: ame-shell 自身がウィンドウマネージャ(src/wm)
    wm: ?*Wm = null,
    wm_xkb: ?*c.struct_river_xkb_bindings_v1 = null,
    wm_lsh: ?*c.struct_river_layer_shell_v1 = null,
    /// River 0.3: 開いているアプリの一覧(ワークスペースごとのアプリ名の推測用)
    toplevels: ?*Toplevels = null,
    touchpad: ?*Touchpad = null,
    seat: ?*c.struct_wl_seat = null,
    seat_status: ?*c.struct_zriver_seat_status_v1 = null,
    pointer: ?*c.struct_wl_pointer = null,
    cursor_dev: ?*c.struct_wp_cursor_shape_device_v1 = null,
    keyboard: ?*c.struct_wl_keyboard = null,
    xkb_ctx: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,

    outputs: std.ArrayList(*Output),
    focused_output: ?*Output = null,
    focused_title: cfgmod.Str = .{},
    title_serial: u32 = 0,

    gpu: gfx.Gpu = undefined,
    fonts: *text.Fonts = undefined,
    canvas: gfx.Canvas = undefined,
    cfg: cfgmod.Config = .{},
    config_path: [512]u8 = undefined,
    config_path_len: usize = 0,
    share_dir: [512]u8 = undefined,
    share_dir_len: usize = 0,

    loop: loop_mod.Loop,
    clock_timer: loop_mod.Timer = undefined,
    sys_timer: loop_mod.Timer = undefined,
    repeat_timer: loop_mod.Timer = undefined,
    warm_timer: loop_mod.Timer = undefined,
    warmer: text.Warmer = undefined,
    warm_started: bool = false,
    inotify_fd: c_int = -1,
    config_wd: c_int = -1,
    pactl_fd: c_int = -1,
    pactl_pid: c_int = 0,
    start_ms: u64,
    frame_stats: FrameStats = .{},
    startup_ms: u64 = 0,
    sys: SysState = .{},
    running: bool = true,
    restart_requested: bool = false,
    /// コンポジタとの接続が切れて終わった(監督ループに再起動させるため異常終了で返す)
    disconnected: bool = false,

    // 入力
    ptr_surface: ?*Surface = null,
    ptr_x: f32 = 0,
    ptr_y: f32 = 0,
    kb_surface: ?*Surface = null,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    repeat_key: u32 = 0,
    mods_ctrl: bool = false,
    mods_shift: bool = false,

    // 部品
    osd: *Osd = undefined,
    launcher: *Launcher = undefined,
    dashboard: *Dashboard = undefined,
    notifs: *Notifs = undefined,
    lock: *Lock = undefined,
    media: *Media = undefined,
    syswatch: *SysWatch = undefined,
    wallpick: *WallPick = undefined,
    /// ダッシュボードのユーザーの写真
    avatar: *Avatar = undefined,
    /// 音の出力先・入力先
    audio: *Audio = undefined,
    ipc_server: ipc.Server = undefined,
    supertap: SuperTap = undefined,
    initialized: bool = false,
    /// 描画中にサーフェスを消せないので、消したいものはループの最後にまとめて片付ける
    reap_pending: bool = false,
    read_done: bool = false,
    ptr_serial: u32 = 0,
    inotify_hooks: [8]InotifyHook = undefined,
    n_hooks: usize = 0,

    // ---------------------------------------------------------------------

    pub fn init(alloc: std.mem.Allocator) !*App {
        const display = c.wl_display_connect(null) orelse {
            log.err("Wayland ディスプレイに接続できません(WAYLAND_DISPLAY を確認)", .{});
            return error.NoDisplay;
        };
        const app = try alloc.create(App);
        app.* = .{
            .alloc = alloc,
            .display = display,
            .outputs = std.ArrayList(*Output).init(alloc),
            .loop = try loop_mod.Loop.init(alloc),
            .start_ms = loop_mod.nowMs(),
        };
        app.loadConfig(true);

        app.registry = c.wl_display_get_registry(display).?;
        _ = c.wl_registry_add_listener(app.registry, &registry_listener, app);
        _ = c.wl_display_roundtrip(display); // グローバル一覧
        if (app.compositor == null or app.layer_shell == null) {
            log.err("コンポジタが wl_compositor / zwlr_layer_shell_v1 に対応していません", .{});
            return error.MissingGlobals;
        }
        _ = c.wl_display_roundtrip(display); // 出力の情報(mode, scale, name)

        logRss("before-egl");
        app.gpu = try gfx.Gpu.init(display);
        logRss("after-egl");
        app.fonts = try text.Fonts.init(alloc, app.cfg.font_ui.get(), app.cfg.font_icon.get());
        logRss("after-fonts");
        app.fonts.initGl();
        logRss("after-atlas");
        app.canvas = gfx.Canvas.init(alloc, &app.gpu, app.fonts);

        app.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);

        // データ源
        app.refreshSys(true);
        app.clock_timer = try loop_mod.Timer.init();
        try app.loop.add(app.clock_timer.fd, c.EPOLLIN, app, onClockTimer);
        app.armClock();
        app.sys_timer = try loop_mod.Timer.init();
        try app.loop.add(app.sys_timer.fd, c.EPOLLIN, app, onSysTimer);
        app.sys_timer.arm(20_000, 20_000);
        app.repeat_timer = try loop_mod.Timer.init();
        try app.loop.add(app.repeat_timer.fd, c.EPOLLIN, app, onRepeatTimer);
        app.startPactl();
        app.warmer = text.Warmer.init(alloc);
        app.warmer.add(text.common_chars);
        app.warmer.add(@import("frame/warm_strings.zig").warm);
        app.warm_timer = try loop_mod.Timer.init();
        try app.loop.add(app.warm_timer.fd, c.EPOLLIN, app, onWarmTimer);
        app.warm_timer.arm(400, 0);
        app.watchConfig();

        // 部品
        app.osd = try Osd.create(app);
        app.launcher = try Launcher.create(app);
        app.dashboard = try Dashboard.create(app);
        app.notifs = try Notifs.create(app);
        app.lock = try Lock.create(app);
        app.media = try Media.create(app);
        app.wallpick = try WallPick.create(app);
        app.avatar = try Avatar.create(app);
        app.syswatch = try SysWatch.create(app);
        app.audio = try Audio.create(app);
        // 操作の窓口(ame-ctl)が作れなくてもシェル自体は動かす
        app.ipc_server = ipc.Server.init(app) catch |e| blk: {
            log.warn("ame-ctl のソケットを作れません({s})。ame-ctl は使えません", .{@errorName(e)});
            break :blk .{ .app = app };
        };
        if (app.ipc_server.fd >= 0) app.ipc_server.register();
        app.supertap = .{ .loop = &app.loop, .ctx = app, .on_tap = onSuperTap, .enabled = app.cfg.super_launcher };
        app.supertap.start();

        for (app.outputs.items) |o| app.setupOutput(o);
        app.initialized = true;
        logRss("after-surfaces");
        return app;
    }

    pub fn run(self: *App) void {
        const fd = c.wl_display_get_fd(self.display);
        self.loop.add(fd, c.EPOLLIN, self, onWaylandFd) catch {};
        while (self.running) {
            // Wayland のイベントキューを空にしてから待つ(取りこぼし防止の定石)
            while (c.wl_display_prepare_read(self.display) != 0) _ = c.wl_display_dispatch_pending(self.display);
            _ = c.wl_display_flush(self.display);
            self.loop.dispatch(-1);
            // onWaylandFd で読んでいなければ読み取り予約を取り消す
            if (!self.read_done) c.wl_display_cancel_read(self.display);
            self.read_done = false;
            if (c.wl_display_dispatch_pending(self.display) < 0) {
                var err_if: ?*const c.struct_wl_interface = null;
                var id: u32 = 0;
                const perr = c.wl_display_get_protocol_error(self.display, @ptrCast(&err_if), &id);
                log.err("Wayland 接続が切れました(errno={d} protocol_error={d} {s}#{d})", .{ c.wl_display_get_error(self.display), perr, if (err_if) |i| std.mem.sliceTo(i.name, 0) else "-", id });
                self.disconnected = true;
                break;
            }
            if (self.reap_pending) {
                self.reap_pending = false;
                self.osd.reap();
                self.launcher.reap();
                self.dashboard.reap();
                self.notifs.reap();
                self.lock.reap();
                self.wallpick.reap();
            }
        }
    }
    fn onWaylandFd(ctx: *anyopaque, _: c_int, events: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (events & (c.EPOLLERR | c.EPOLLHUP) != 0) {
            self.running = false;
        }
        _ = c.wl_display_read_events(self.display);
        self.read_done = true;
    }

    pub fn timeSec(self: *App) f32 {
        return @as(f32, @floatFromInt(loop_mod.nowMs() - self.start_ms)) / 1000.0;
    }

    // ---------------------------------------------------------------------
    // 出力
    // ---------------------------------------------------------------------

    pub fn setupOutput(self: *App, o: *Output) void {
        if (self.river_status) |rs| {
            if (o.river == null) {
                o.river = c.zriver_status_manager_v1_get_river_output_status(rs, o.wl);
                _ = c.zriver_output_status_v1_add_listener(o.river, &river_output_listener, o);
            }
        }
        if (o.wall == null) o.wall = Wallpaper.create(self, o) catch null;
        self.setupShell(o);
        if (self.focused_output == null) self.focused_output = o;
    }

    pub fn outputFor(_: *App, s: *Surface) ?*Output {
        return if (s.output) |p| @ptrCast(@alignCast(p)) else null;
    }

    pub fn outputByWl(self: *App, wl: ?*c.struct_wl_output) ?*Output {
        for (self.outputs.items) |o| if (o.wl == wl) return o;
        return null;
    }

    /// ランチャー等のポップアップを出す出力(River のフォーカス出力)
    pub fn activeOutput(self: *App) ?*Output {
        if (self.focused_output) |o| return o;
        return if (self.outputs.items.len > 0) self.outputs.items[0] else null;
    }

    pub fn forgetSurface(self: *App, s: *Surface) void {
        if (self.ptr_surface == s) self.ptr_surface = null;
        if (self.kb_surface == s) {
            self.kb_surface = null;
            self.repeat_timer.disarm();
        }
    }

    /// 表示中の全サーフェスを描き直す(グリフアトラスを作り直したときなど)
    pub fn redrawAll(self: *App) void {
        self.redrawBars();
        self.osd.backdropChanged();
        self.launcher.backdropChanged();
        self.dashboard.backdropChanged();
        self.notifs.backdropChanged();
        self.lock.tick();
    }

    /// 全てのバーを描き直す(状態が変わったとき)
    /// レイアウトに応じてバー(classic)か枠(caelestia)を作る
    fn setupShell(self: *App, o: *Output) void {
        if (self.cfg.layout == .caelestia) {
            if (o.bar) |b| b.destroy();
            if (o.frame) |f| f.destroy();
            o.bar = null;
            if (o.frame == null) o.frame = Frame.create(self, o) catch |e| blk: {
                log.err("枠を作れません: {s}", .{@errorName(e)});
                break :blk null;
            };
        } else {
            if (o.frame) |f| f.destroy();
            o.frame = null;
            if (o.bar == null) o.bar = Bar.create(self, o) catch null;
        }
    }

    /// ランチャー等を出す出力の枠(caelestia のときだけ)
    pub fn activeFrame(self: *App) ?*Frame {
        if (self.cfg.layout != .caelestia) return null;
        const o = self.activeOutput() orelse return null;
        return o.frame;
    }

    pub fn redrawBars(self: *App) void {
        for (self.outputs.items) |o| {
            if (o.bar) |b| b.surf.schedule();
            if (o.frame) |f| f.schedule();
        }
    }

    /// 壁紙が変わったとき、その出力のガラス面を全て描き直す
    pub fn backdropChanged(self: *App, o: *Output) void {
        if (o.bar) |b| b.surf.schedule();
        if (o.frame) |f| f.schedule();
        self.osd.backdropChanged();
        self.launcher.backdropChanged();
        self.dashboard.backdropChanged();
        self.notifs.backdropChanged();
    }

    // ---------------------------------------------------------------------
    // 設定
    // ---------------------------------------------------------------------

    pub fn loadConfig(self: *App, first: bool) void {
        // 探索順: $AME_CONFIG → ~/.config/ame-shell/config.ame → <share>/config.ame
        self.resolveShareDir();
        var path_buf: [512]u8 = undefined;
        var path: []const u8 = "";
        if (std.posix.getenv("AME_CONFIG")) |p| {
            path = p;
        } else {
            const home = std.posix.getenv("HOME") orelse "/";
            if (std.posix.getenv("XDG_CONFIG_HOME")) |x|
                path = std.fmt.bufPrint(&path_buf, "{s}/ame-shell/config.ame", .{x}) catch ""
            else
                path = std.fmt.bufPrint(&path_buf, "{s}/.config/ame-shell/config.ame", .{home}) catch "";
        }
        self.config_path_len = @min(path.len, self.config_path.len);
        @memcpy(self.config_path[0..self.config_path_len], path[0..self.config_path_len]);

        var cfg = cfgmod.Config{};
        var diag = cfgmod.Diag{};
        const data = std.fs.cwd().readFileAlloc(self.alloc, path, 1 << 20) catch blk: {
            var share_cfg: [600]u8 = undefined;
            const sp = std.fmt.bufPrint(&share_cfg, "{s}/config.ame", .{self.shareDir()}) catch break :blk null;
            break :blk std.fs.cwd().readFileAlloc(self.alloc, sp, 1 << 20) catch null;
        };
        if (data) |d| {
            defer self.alloc.free(d);
            cfg = cfgmod.parse(d, cfg, &diag);
            if (diag.len > 0) log.warn("設定の警告:\n{s}", .{diag.get()});
        }
        const old = self.cfg;
        self.cfg = cfg;
        anim.speed_scale = cfg.anim_speed;
        if (!first) {
            log.info("設定を再読込しました", .{});
            if (old.layout != cfg.layout) {
                for (self.outputs.items) |o| self.setupShell(o);
            } else if (self.cfg.layout == .caelestia and (old.frame_thickness != cfg.frame_thickness or old.frame_bar_width != cfg.frame_bar_width or old.ui_scale != cfg.ui_scale)) {
                for (self.outputs.items) |o| if (o.frame) |f| f.geometryChanged();
            }
            if (old.bar_position != cfg.bar_position) {
                // 上下の入れ替えはアンカーが変わるので作り直す(入場アニメもやり直し)
                for (self.outputs.items) |o| if (o.bar) |b| {
                    b.destroy();
                    o.bar = Bar.create(self, o) catch null;
                };
            } else if (old.bar_height != cfg.bar_height or old.bar_margin != cfg.bar_margin) {
                for (self.outputs.items) |o| if (o.bar) |b| b.applyGeometry();
            }
            for (self.outputs.items) |o| if (o.wall) |w| w.configChanged(&old);
            self.redrawBars();
            self.armClock();
            if (self.initialized) self.supertap.enabled = cfg.super_launcher;
        }
    }

    /// Super キー単体のタップ → ランチャーの開閉(ロック中は何もしない)
    fn onSuperTap(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.lock.locked) return;
        self.launcher.toggle();
        _ = c.wl_display_flush(self.display);
    }

    fn resolveShareDir(self: *App) void {
        // 実行ファイルの隣の ../share/ame-shell を優先(zig-out でも /usr/local でも動く)
        var exe_buf: [512]u8 = undefined;
        const exe = std.fs.selfExePath(&exe_buf) catch "";
        const bin_dir = std.fs.path.dirname(exe) orelse ".";
        const s = std.fmt.bufPrint(&self.share_dir, "{s}/../share/ame-shell", .{bin_dir}) catch "";
        self.share_dir_len = s.len;
        if (std.posix.getenv("AME_SHARE_DIR")) |d| {
            self.share_dir_len = @min(d.len, self.share_dir.len);
            @memcpy(self.share_dir[0..self.share_dir_len], d[0..self.share_dir_len]);
        }
    }

    pub fn shareDir(self: *App) []const u8 {
        return self.share_dir[0..self.share_dir_len];
    }

    fn watchConfig(self: *App) void {
        self.inotify_fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
        if (self.inotify_fd < 0) return;
        // エディタは「別名で書いて rename」することが多いのでディレクトリごと監視する
        const dir = std.fs.path.dirname(self.config_path[0..self.config_path_len]) orelse return;
        var buf: [512]u8 = undefined;
        const dz = std.fmt.bufPrintZ(&buf, "{s}", .{dir}) catch return;
        std.fs.cwd().makePath(dz) catch {};
        self.config_wd = c.inotify_add_watch(self.inotify_fd, dz.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_CREATE);
        self.loop.add(self.inotify_fd, c.EPOLLIN, self, onInotify) catch {};
    }

    pub fn addWatch(self: *App, dir: [:0]const u8, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque, name: []const u8) void) void {
        if (self.inotify_fd < 0 or self.n_hooks >= self.inotify_hooks.len) return;
        const wd = c.inotify_add_watch(self.inotify_fd, dir.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO);
        if (wd < 0) return;
        self.inotify_hooks[self.n_hooks] = .{ .wd = wd, .ctx = ctx, .cb = cb };
        self.n_hooks += 1;
    }

    fn onInotify(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
        var reload = false;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            var off: usize = 0;
            while (off < @as(usize, @intCast(n))) {
                const ev: *const c.struct_inotify_event = @ptrCast(@alignCast(&buf[off]));
                const name_ptr: [*]const u8 = @ptrCast(&buf[off + @sizeOf(c.struct_inotify_event)]);
                const name = std.mem.sliceTo(name_ptr[0..ev.len], 0);
                if (ev.wd == self.config_wd) {
                    const base = std.fs.path.basename(self.config_path[0..self.config_path_len]);
                    if (std.mem.eql(u8, name, base)) reload = true;
                } else {
                    for (self.inotify_hooks[0..self.n_hooks]) |h| if (h.wd == ev.wd) h.cb(h.ctx, name);
                }
                off += @sizeOf(c.struct_inotify_event) + ev.len;
            }
        }
        if (reload) self.loadConfig(false);
    }

    // ---------------------------------------------------------------------
    // システム状態
    // ---------------------------------------------------------------------

    pub fn refreshSys(self: *App, all: bool) void {
        const prev_ac = self.sys.battery.on_ac;
        self.sys.battery = sys.battery();
        self.sys.brightness = sys.brightness();
        self.sys.net = sys.network();
        if (all) self.sys.volume = sys.volume();
        if (prev_ac != self.sys.battery.on_ac) {
            // 電源が変わったら壁紙の FPS/解像度を切り替える
            for (self.outputs.items) |o| if (o.wall) |w| w.powerChanged();
        }
    }

    pub fn sampleCpu(self: *App) void {
        const s = sys.cpuSample();
        const dt = s.total -% self.sys.cpu_prev.total;
        const di = s.idle -% self.sys.cpu_prev.idle;
        if (dt > 0 and self.sys.cpu_prev.total != 0) self.sys.cpu = 1 - @as(f32, @floatFromInt(di)) / @as(f32, @floatFromInt(dt));
        self.sys.cpu_prev = s;
        self.sys.mem = sys.memUsage();
        self.sys.temp = sys.cpuTemp();
    }

    fn armClock(self: *App) void {
        // 次の分(秒表示なら次の秒)の境目ちょうどに起きる。毎秒ポーリングしない。
        var ts: std.posix.timespec = undefined;
        std.posix.clock_gettime(std.posix.CLOCK.REALTIME, &ts) catch return;
        const ms_in: u64 = @intCast(@divTrunc(ts.tv_nsec, 1_000_000));
        const wait: u64 = if (self.cfg.show_seconds)
            1000 - ms_in
        else
            (60 - @as(u64, @intCast(@mod(ts.tv_sec, 60)))) * 1000 - ms_in;
        self.clock_timer.arm(@max(wait, 1) + 5, 0);
    }

    fn onClockTimer(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.clock_timer.ack();
        self.armClock();
        self.redrawBars();
        self.dashboard.tick();
        self.lock.tick();
    }

    /// 起動後のアイドル時間にグリフを先読みする(6ms ずつ、12ms おき。数秒で終わる)。
    fn onWarmTimer(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.warm_timer.ack();
        if (!self.warm_started) {
            // 最初の1回でランチャーの一覧も読み、アプリ名を先読み対象に加える
            self.warm_started = true;
            self.launcher.prescan(&self.warmer);
        }
        _ = c.eglMakeCurrent(self.gpu.dpy, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, self.gpu.ctx);
        self.warmer.step(self.fonts, 6000);
        if (self.fonts.needs_redraw) {
            self.fonts.needs_redraw = false;
            self.redrawAll();
        }
        if (self.warmer.pending()) {
            self.warm_timer.arm(12, 0);
        } else if (!self.dashboard.loaded) {
            // 最後に WASM ウィジェットを読み、1回実行しておく(wasm3 は関数を初回呼び出し時にコンパイルする)
            self.dashboard.prewarm();
        }
    }

    fn onSysTimer(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.sys_timer.ack();
        self.refreshSys(false);
        self.redrawBars();
    }

    /// `pactl subscribe` を常駐させ、シンクの変化行が来たときだけ音量を読み直す。
    fn startPactl(self: *App) void {
        const fd = sys.spawnReader(&.{ "pactl", "subscribe" }, &self.pactl_pid) orelse return;
        self.pactl_fd = fd;
        self.loop.add(fd, c.EPOLLIN, self, onPactl) catch {};
    }

    fn onPactl(ctx: *anyopaque, fd: c_int, events: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        var buf: [2048]u8 = undefined;
        var changed = false;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) {
                if (n == 0 or events & c.EPOLLHUP != 0) {
                    // pactl が終了した(PipeWire 再起動など)。監視をやめる。
                    self.loop.remove(fd);
                    _ = c.close(fd);
                    self.pactl_fd = -1;
                }
                break;
            }
            if (std.mem.indexOf(u8, buf[0..@intCast(n)], "sink") != null or std.mem.indexOf(u8, buf[0..@intCast(n)], "server") != null) changed = true;
        }
        if (changed) {
            const old = self.sys.volume;
            self.sys.volume = sys.volume();
            if (old.known and (old.level != self.sys.volume.level or old.muted != self.sys.volume.muted)) {
                self.osd.show(.volume);
            }
            self.redrawBars();
            self.dashboard.dataChanged();
        }
    }

    // ---------------------------------------------------------------------
    // River 操作
    // ---------------------------------------------------------------------

    pub fn riverCommand(self: *App, args: []const [:0]const u8) void {
        if (self.wm) |w| {
            // River 0.5: riverctl の代わりに内蔵 WM へ
            const eq = std.mem.eql;
            if (args.len >= 1 and eq(u8, args[0], "exit")) {
                std.log.info("wm: セッション終了(ログアウトボタン/ランチャーから)", .{});
                w.push(.exit);
            }
            if (args.len >= 2 and eq(u8, args[0], "toggle-focused-tags")) {
                const m = std.fmt.parseInt(u32, args[1], 10) catch return;
                w.push(.{ .toggle_tags = m });
            }
            return;
        }
        const ctl = self.river_control orelse return;
        const seat = self.seat orelse return;
        for (args) |a| c.zriver_control_v1_add_argument(ctl, a.ptr);
        const cb = c.zriver_control_v1_run_command(ctl, seat);
        _ = c.zriver_command_callback_v1_add_listener(cb, &river_cmd_listener, null);
    }

    pub fn focusTags(self: *App, mask: u32) void {
        if (self.wm) |w| return w.push(.{ .set_tags_on = .{ .out = null, .mask = mask } });
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{mask}) catch return;
        self.riverCommand(&.{ "set-focused-tags", s });
    }

    pub const WsApp = struct { app_id: []const u8, title: []const u8 };

    /// ワークスペース(タグ)ごとの開いているアプリ。River 0.5 は内蔵 WM の正確な情報、0.3 は推測
    pub fn workspaceApps(self: *App, out: *Output, tag: u5, buf: []WsApp) usize {
        if (self.wm) |w| return w.appsOnTag(out, tag, buf);
        const t = self.toplevels orelse return 0;
        var tl: [32]*@import("toplevels.zig").Toplevel = undefined;
        const n = t.onTag(out, tag, tl[0..@min(buf.len, tl.len)]);
        for (tl[0..n], 0..) |x, i| buf[i] = .{ .app_id = x.appId(), .title = x.titleStr() };
        return n;
    }

    pub fn spawn(self: *App, cmd: [:0]const u8) void {
        _ = self;
        sys.spawnDetached(cmd.ptr);
    }

    // ---------------------------------------------------------------------
    // 入力のヘルパ
    // ---------------------------------------------------------------------

    pub fn setCursor(self: *App, serial: u32, shape: u32) void {
        if (self.cursor_dev) |d| c.wp_cursor_shape_device_v1_set_shape(d, serial, shape);
    }
};

// ===========================================================================
// Wayland リスナ
// ===========================================================================

fn iface(name: [*c]const u8, i: *const c.struct_wl_interface) bool {
    return std.mem.orderZ(u8, name, i.name) == .eq;
}

fn bind(reg: ?*c.struct_wl_registry, name: u32, i: *const c.struct_wl_interface, ver: u32, want: u32) ?*anyopaque {
    return c.wl_registry_bind(reg, name, i, @min(ver, want));
}

fn onGlobal(data: ?*anyopaque, reg: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, ver: u32) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    if (iface(interface, &c.wl_compositor_interface)) {
        app.compositor = @ptrCast(bind(reg, name, &c.wl_compositor_interface, ver, 6));
        app.compositor_version = @min(ver, 6);
    } else if (iface(interface, &c.zwlr_layer_shell_v1_interface)) {
        app.layer_shell = @ptrCast(bind(reg, name, &c.zwlr_layer_shell_v1_interface, ver, 4));
    } else if (iface(interface, &c.zriver_status_manager_v1_interface)) {
        app.river_status = @ptrCast(bind(reg, name, &c.zriver_status_manager_v1_interface, ver, 4));
        for (app.outputs.items) |o| if (o.river == null) {
            o.river = c.zriver_status_manager_v1_get_river_output_status(app.river_status, o.wl);
            _ = c.zriver_output_status_v1_add_listener(o.river, &river_output_listener, o);
        };
        if (app.seat != null and app.seat_status == null) bindSeatStatus(app);
    } else if (iface(interface, &c.river_window_manager_v1_interface)) {
        const mgr: *c.struct_river_window_manager_v1 = @ptrCast(bind(reg, name, &c.river_window_manager_v1_interface, ver, 6) orelse return);
        app.wm = Wm.create(app, mgr) catch null;
        if (app.wm) |w| {
            if (app.wm_xkb) |x| w.setXkb(x);
            if (app.wm_lsh) |l| w.setLayerShell(l);
        }
    } else if (iface(interface, &c.zwlr_foreign_toplevel_manager_v1_interface)) {
        const m: *c.struct_zwlr_foreign_toplevel_manager_v1 = @ptrCast(bind(reg, name, &c.zwlr_foreign_toplevel_manager_v1_interface, ver, 3) orelse return);
        app.toplevels = Toplevels.create(app, m) catch null;
    } else if (iface(interface, &c.river_libinput_config_v1_interface)) {
        const lc: *c.struct_river_libinput_config_v1 = @ptrCast(bind(reg, name, &c.river_libinput_config_v1_interface, ver, 1) orelse return);
        app.touchpad = Touchpad.create(app.alloc, lc, app.cfg.tap_to_click) catch null;
    } else if (iface(interface, &c.river_xkb_bindings_v1_interface)) {
        app.wm_xkb = @ptrCast(bind(reg, name, &c.river_xkb_bindings_v1_interface, ver, 3));
        if (app.wm) |w| w.setXkb(app.wm_xkb.?);
    } else if (iface(interface, &c.river_layer_shell_v1_interface)) {
        app.wm_lsh = @ptrCast(bind(reg, name, &c.river_layer_shell_v1_interface, ver, 1));
        if (app.wm) |w| w.setLayerShell(app.wm_lsh.?);
    } else if (iface(interface, &c.zriver_control_v1_interface)) {
        app.river_control = @ptrCast(bind(reg, name, &c.zriver_control_v1_interface, ver, 1));
    } else if (iface(interface, &c.ext_session_lock_manager_v1_interface)) {
        app.lock_mgr = @ptrCast(bind(reg, name, &c.ext_session_lock_manager_v1_interface, ver, 1));
    } else if (iface(interface, &c.zwp_idle_inhibit_manager_v1_interface)) {
        app.idle_mgr = @ptrCast(bind(reg, name, &c.zwp_idle_inhibit_manager_v1_interface, ver, 1));
    } else if (iface(interface, &c.wp_cursor_shape_manager_v1_interface)) {
        app.cursor_mgr = @ptrCast(bind(reg, name, &c.wp_cursor_shape_manager_v1_interface, ver, 1));
    } else if (iface(interface, &c.wl_seat_interface)) {
        if (app.seat == null) {
            app.seat = @ptrCast(bind(reg, name, &c.wl_seat_interface, ver, 7));
            _ = c.wl_seat_add_listener(app.seat, &seat_listener, app);
            if (app.river_status != null) bindSeatStatus(app);
        }
    } else if (iface(interface, &c.wl_output_interface)) {
        const wl: *c.struct_wl_output = @ptrCast(bind(reg, name, &c.wl_output_interface, ver, 4) orelse return);
        const o = app.alloc.create(Output) catch return;
        o.* = .{ .app = app, .wl = wl, .global = name };
        _ = c.wl_output_add_listener(wl, &output_listener, o);
        app.outputs.append(o) catch return;
    }
}

fn bindSeatStatus(app: *App) void {
    app.seat_status = c.zriver_status_manager_v1_get_river_seat_status(app.river_status, app.seat);
    _ = c.zriver_seat_status_v1_add_listener(app.seat_status, &river_seat_listener, app);
}

fn onGlobalRemove(data: ?*anyopaque, _: ?*c.struct_wl_registry, name: u32) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    for (app.outputs.items, 0..) |o, i| {
        if (o.global != name) continue;
        // 出力が抜かれた: その出力のサーフェスを片付ける
        if (o.bar) |b| b.destroy();
        if (o.wall) |w| w.destroy();
        if (o.river) |r| c.zriver_output_status_v1_destroy(r);
        if (app.focused_output == o) app.focused_output = null;
        if (app.toplevels) |t| for (t.items.items) |x| {
            if (x.out == o) x.out = null;
        };
        app.dashboard.outputRemoved(o);
        app.launcher.outputRemoved(o);
        app.osd.outputRemoved(o);
        app.notifs.outputRemoved(o);
        app.wallpick.outputRemoved(o);
        c.wl_output_release(o.wl);
        _ = app.outputs.orderedRemove(i);
        app.alloc.destroy(o);
        if (app.focused_output == null and app.outputs.items.len > 0) app.focused_output = app.outputs.items[0];
        return;
    }
}
const registry_listener = c.struct_wl_registry_listener{ .global = onGlobal, .global_remove = onGlobalRemove };

// ---- wl_output ----
fn oGeometry(_: ?*anyopaque, _: ?*c.struct_wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.C) void {}
fn oMode(data: ?*anyopaque, _: ?*c.struct_wl_output, flags: u32, w: i32, h: i32, refresh: i32) callconv(.C) void {
    const o: *Output = @ptrCast(@alignCast(data.?));
    if (flags & c.WL_OUTPUT_MODE_CURRENT != 0) {
        o.mode_w = w;
        o.mode_h = h;
        o.refresh_mhz = refresh;
    }
}
fn oDone(data: ?*anyopaque, _: ?*c.struct_wl_output) callconv(.C) void {
    const o: *Output = @ptrCast(@alignCast(data.?));
    const first = !o.done;
    o.done = true;
    // 起動後にホットプラグされた出力はここでサーフェスを作る
    if (first and o.app.initialized) o.app.setupOutput(o);
}
fn oScale(data: ?*anyopaque, _: ?*c.struct_wl_output, f: i32) callconv(.C) void {
    const o: *Output = @ptrCast(@alignCast(data.?));
    o.scale = f;
}
fn oName(data: ?*anyopaque, _: ?*c.struct_wl_output, name: [*c]const u8) callconv(.C) void {
    const o: *Output = @ptrCast(@alignCast(data.?));
    o.name.set(std.mem.sliceTo(name, 0));
}
fn oDesc(_: ?*anyopaque, _: ?*c.struct_wl_output, _: [*c]const u8) callconv(.C) void {}
const output_listener = c.struct_wl_output_listener{ .geometry = oGeometry, .mode = oMode, .done = oDone, .scale = oScale, .name = oName, .description = oDesc };

// ---- River status ----
fn rFocusedTags(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1, tags: u32) callconv(.C) void {
    const o: *Output = @ptrCast(@alignCast(data.?));
    o.focused_tags = tags;
    if (o.bar) |b| b.tagsChanged();
    if (o.frame) |f| f.bar.tagsChanged(f);
}
fn rViewTags(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1, arr: [*c]c.struct_wl_array) callconv(.C) void {
    const o: *Output = @ptrCast(@alignCast(data.?));
    var mask: u32 = 0;
    const n = arr.*.size / 4;
    const items: [*]const u32 = @ptrCast(@alignCast(arr.*.data));
    o.n_views = @min(n, o.view_list.len);
    for (0..n) |i| {
        mask |= items[i];
        if (i < o.view_list.len) o.view_list[i] = items[i];
    }
    o.view_tags = mask;
    if (o.app.toplevels) |t| t.viewTagsChanged(o);
    if (o.bar) |b| b.tagsChanged();
    if (o.frame) |f| f.bar.tagsChanged(f);
}
fn rUrgent(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1, tags: u32) callconv(.C) void {
    const o: *Output = @ptrCast(@alignCast(data.?));
    o.urgent_tags = tags;
    if (o.bar) |b| b.tagsChanged();
    if (o.frame) |f| f.bar.tagsChanged(f);
}
fn rLayout(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1, name: [*c]const u8) callconv(.C) void {
    const o: *Output = @ptrCast(@alignCast(data.?));
    o.layout.set(std.mem.sliceTo(name, 0));
}
fn rLayoutClear(data: ?*anyopaque, _: ?*c.struct_zriver_output_status_v1) callconv(.C) void {
    const o: *Output = @ptrCast(@alignCast(data.?));
    o.layout.set("");
}
const river_output_listener = c.struct_zriver_output_status_v1_listener{
    .focused_tags = rFocusedTags,
    .view_tags = rViewTags,
    .urgent_tags = rUrgent,
    .layout_name = rLayout,
    .layout_name_clear = rLayoutClear,
};

fn sFocusedOutput(data: ?*anyopaque, _: ?*c.struct_zriver_seat_status_v1, out: ?*c.struct_wl_output) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.outputByWl(out)) |o| app.focused_output = o;
}
fn sUnfocusedOutput(_: ?*anyopaque, _: ?*c.struct_zriver_seat_status_v1, _: ?*c.struct_wl_output) callconv(.C) void {}
fn sFocusedView(data: ?*anyopaque, _: ?*c.struct_zriver_seat_status_v1, title: [*c]const u8) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const t = std.mem.sliceTo(title, 0);
    if (std.mem.eql(u8, t, app.focused_title.get())) return;
    app.focused_title.set(t);
    app.title_serial +%= 1;
    for (app.outputs.items) |o| {
        if (o.bar) |b| b.titleChanged();
        if (o.frame) |f| f.bar.titleChanged(f);
    }
}
fn sMode(_: ?*anyopaque, _: ?*c.struct_zriver_seat_status_v1, _: [*c]const u8) callconv(.C) void {}
const river_seat_listener = c.struct_zriver_seat_status_v1_listener{
    .focused_output = sFocusedOutput,
    .unfocused_output = sUnfocusedOutput,
    .focused_view = sFocusedView,
    .mode = sMode,
};

fn cmdSuccess(_: ?*anyopaque, cb: ?*c.struct_zriver_command_callback_v1, _: [*c]const u8) callconv(.C) void {
    c.zriver_command_callback_v1_destroy(cb);
}
fn cmdFailure(_: ?*anyopaque, cb: ?*c.struct_zriver_command_callback_v1, msg: [*c]const u8) callconv(.C) void {
    log.warn("river コマンド失敗: {s}", .{std.mem.sliceTo(msg, 0)});
    c.zriver_command_callback_v1_destroy(cb);
}
const river_cmd_listener = c.struct_zriver_command_callback_v1_listener{ .success = cmdSuccess, .failure = cmdFailure };

// ---- seat / pointer / keyboard ----
fn seatCaps(data: ?*anyopaque, seat: ?*c.struct_wl_seat, caps: u32) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    if (caps & c.WL_SEAT_CAPABILITY_POINTER != 0 and app.pointer == null) {
        app.pointer = c.wl_seat_get_pointer(seat);
        _ = c.wl_pointer_add_listener(app.pointer, &pointer_listener, app);
        if (app.cursor_mgr) |m| app.cursor_dev = c.wp_cursor_shape_manager_v1_get_pointer(m, app.pointer);
    }
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0 and app.keyboard == null) {
        app.keyboard = c.wl_seat_get_keyboard(seat);
        _ = c.wl_keyboard_add_listener(app.keyboard, &keyboard_listener, app);
    }
    // キーボード・マウスが一度無くなってから再び現れた(抜き差し等)ときは作り直す。古いオブジェクトは何も届かない
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD == 0) if (app.keyboard) |k| {
        c.wl_keyboard_release(k);
        app.keyboard = null;
        app.kb_surface = null;
        app.repeat_timer.disarm();
    };
    if (caps & c.WL_SEAT_CAPABILITY_POINTER == 0) if (app.pointer) |p| {
        if (app.cursor_dev) |d| c.wp_cursor_shape_device_v1_destroy(d);
        app.cursor_dev = null;
        c.wl_pointer_release(p);
        app.pointer = null;
        app.ptr_surface = null;
    };
}
fn seatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.C) void {}
const seat_listener = c.struct_wl_seat_listener{ .capabilities = seatCaps, .name = seatName };

fn surfOf(wl: ?*c.struct_wl_surface) ?*Surface {
    const p = c.wl_surface_get_user_data(wl) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn sendPtr(app: *App, kind: surface.PointerKind, button: u32, scroll: f32) void {
    const s = app.ptr_surface orelse return;
    if (s.handler.pointer) |f| f(s.handler.ctx, s, .{ .kind = kind, .x = app.ptr_x, .y = app.ptr_y, .button = button, .scroll = scroll });
}

fn pEnter(data: ?*anyopaque, _: ?*c.struct_wl_pointer, serial: u32, wl: ?*c.struct_wl_surface, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.ptr_surface = surfOf(wl);
    app.ptr_x = @floatCast(c.wl_fixed_to_double(x));
    app.ptr_y = @floatCast(c.wl_fixed_to_double(y));
    app.ptr_serial = serial;
    app.setCursor(serial, c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT);
    sendPtr(app, .enter, 0, 0);
}
fn pLeave(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    sendPtr(app, .leave, 0, 0);
    app.ptr_surface = null;
}
fn pMotion(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.ptr_x = @floatCast(c.wl_fixed_to_double(x));
    app.ptr_y = @floatCast(c.wl_fixed_to_double(y));
    sendPtr(app, .motion, 0, 0);
}
fn pButton(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    sendPtr(app, if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) .press else .release, button, 0);
}
fn pAxis(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, axis: u32, value: c.wl_fixed_t) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    if (axis != c.WL_POINTER_AXIS_VERTICAL_SCROLL) return;
    sendPtr(app, .scroll, 0, @floatCast(c.wl_fixed_to_double(value)));
}
fn pFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.C) void {}
fn pAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.C) void {}
fn pAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.C) void {}
fn pAxisDiscrete(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.C) void {}
fn pAxisValue120(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.C) void {}
fn pAxisRelDir(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.C) void {}
const pointer_listener = c.struct_wl_pointer_listener{
    .enter = pEnter,
    .leave = pLeave,
    .motion = pMotion,
    .button = pButton,
    .axis = pAxis,
    .frame = pFrame,
    .axis_source = pAxisSource,
    .axis_stop = pAxisStop,
    .axis_discrete = pAxisDiscrete,
    .axis_value120 = pAxisValue120,
    .axis_relative_direction = pAxisRelDir,
};

fn kKeymap(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, format: u32, fd: i32, size: u32) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    defer _ = c.close(fd);
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
    const map = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    if (map == c.MAP_FAILED) return;
    defer _ = c.munmap(map, size);
    const km = c.xkb_keymap_new_from_string(app.xkb_ctx, @ptrCast(map), c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
    if (app.xkb_state) |s| c.xkb_state_unref(s);
    if (app.xkb_keymap) |k| c.xkb_keymap_unref(k);
    app.xkb_keymap = km;
    app.xkb_state = c.xkb_state_new(km);
}
fn kEnter(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, wl: ?*c.struct_wl_surface, _: [*c]c.struct_wl_array) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.kb_surface = surfOf(wl);
}
fn kLeave(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.kb_surface = null;
    app.repeat_timer.disarm();
}

fn deliverKey(app: *App, key: u32) void {
    const st = app.xkb_state orelse return;
    const s = app.kb_surface orelse return;
    const f = s.handler.key orelse return;
    const code = key + 8;
    const sym = c.xkb_state_key_get_one_sym(st, code);
    var buf: [16]u8 = undefined;
    const n = c.xkb_state_key_get_utf8(st, code, &buf, buf.len);
    const len: usize = if (n > 0) @intCast(@min(n, 15)) else 0;
    f(s.handler.ctx, s, .{ .sym = sym, .utf8 = buf[0..len], .ctrl = app.mods_ctrl, .shift = app.mods_shift });
}

fn kKey(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    if (state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
        deliverKey(app, key);
        // キーリピート(タイマー駆動)
        if (app.xkb_keymap != null and c.xkb_keymap_key_repeats(app.xkb_keymap, key + 8) != 0 and app.repeat_rate > 0) {
            app.repeat_key = key;
            app.repeat_timer.arm(@intCast(app.repeat_delay), @intCast(@divTrunc(1000, app.repeat_rate)));
        }
    } else if (key == app.repeat_key) {
        app.repeat_timer.disarm();
    }
}
fn onRepeatTimer(ctx: *anyopaque, _: c_int, _: u32) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.repeat_timer.ack();
    if (app.kb_surface == null) {
        app.repeat_timer.disarm();
        return;
    }
    deliverKey(app, app.repeat_key);
}
fn kMods(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, dep: u32, lat: u32, lock: u32, group: u32) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const st = app.xkb_state orelse return;
    _ = c.xkb_state_update_mask(st, dep, lat, lock, 0, 0, group);
    app.mods_ctrl = c.xkb_state_mod_name_is_active(st, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) > 0;
    app.mods_shift = c.xkb_state_mod_name_is_active(st, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) > 0;
}
fn kRepeat(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, rate: i32, delay: i32) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.repeat_rate = rate;
    app.repeat_delay = delay;
}
const keyboard_listener = c.struct_wl_keyboard_listener{
    .keymap = kKeymap,
    .enter = kEnter,
    .leave = kLeave,
    .key = kKey,
    .modifiers = kMods,
    .repeat_info = kRepeat,
};

/// 起動時のメモリ計測用(AME_DEBUG_MEM=1 のときだけ出力)
fn logRss(stage: []const u8) void {
    if (std.posix.getenv("AME_DEBUG_MEM") == null) return;
    var buf: [256]u8 = undefined;
    const s = sys.readFile("/proc/self/statm", &buf) orelse return;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    _ = it.next();
    const pages = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    log.info("mem {s}: rss={d}MB", .{ stage, pages * 4096 / (1024 * 1024) });
}
