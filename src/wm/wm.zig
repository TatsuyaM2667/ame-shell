// ame-shell 内蔵のウィンドウマネージャ(River 0.4 以降の river-window-management-v1)。
//
// River 0.4 以降は「合成(描画・入力)」が River、「どこに何を置くか」がウィンドウマネージャ(WM)
// という分担になっている。ame-shell はシェル(バー・ドロワー)と同じプロセスで WM も担当する。
//
//   配置: Hyprland の dwindle と同じ考え方。並び順の先頭から、残りの領域を長い辺で 2 分割していく。
//         新しいウィンドウはフォーカス中のウィンドウの次に入る(Hyprland と同じ)。
//   アニメーション(全て Odin のスプリング):
//         開く → 中心から広がる(clip box で「popin」)/ 位置の変化 → 滑らかに移動 /
//         ワークスペース切替 → 横にスライド / Super+Q で閉じる → 中心へ縮んでから閉じる
//   アニメーション中だけ manage_dirty を毎フレーム送って render sequence を回し、位置と clip を更新する。
//   何も動いていなければ River とのやりとりは発生しない(待機時の負荷 0)。
//
// プロトコルの規則: ウィンドウ管理の状態(大きさの提案・フォーカス・閉じる要求等)は manage sequence
// の中でしか変えられない。キー操作や ame-ctl からの要求はいったん queue に積み、manage_dirty で
// manage sequence を起こしてから処理する。
const std = @import("std");
const c = @import("../c.zig");
const anim = @import("../anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const appmod = @import("../app.zig");
const App = appmod.App;
const sys = @import("../platform/sys.zig");
const loop = @import("../platform/loop.zig");
const theme = @import("../theme.zig");
const binds = @import("binds.zig");

const MOD_SHIFT = c.RIVER_SEAT_V1_MODIFIERS_SHIFT;
const MOD_CTRL = c.RIVER_SEAT_V1_MODIFIERS_CTRL;
const MOD_ALT = c.RIVER_SEAT_V1_MODIFIERS_MOD1;
const MOD_SUPER = c.RIVER_SEAT_V1_MODIFIERS_MOD4;
const BTN_LEFT = 0x110;
const BTN_RIGHT = 0x111;
const BTN_MIDDLE = 0x112;
const ALL_EDGES = c.RIVER_WINDOW_V1_EDGES_TOP | c.RIVER_WINDOW_V1_EDGES_BOTTOM | c.RIVER_WINDOW_V1_EDGES_LEFT | c.RIVER_WINDOW_V1_EDGES_RIGHT;
const SCRATCH_TAG: u32 = 1 << 20;

pub const Window = struct {
    wm: *Wm,
    obj: *c.struct_river_window_v1,
    node: ?*c.struct_river_node_v1 = null,
    app_id: [96]u8 = undefined,
    app_id_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    tags: u32 = 1,
    out: ?*WOut = null,
    floating: bool = false,
    fullscreen: bool = false,
    want_fullscreen: ?bool = null,
    /// サーバから届いた実際の中身の大きさ(0 = まだ)
    w: i32 = 0,
    h: i32 = 0,
    min_w: i32 = 0,
    min_h: i32 = 0,
    max_w: i32 = 0,
    max_h: i32 = 0,
    /// 置きたい矩形(グローバル座標、中身の範囲)
    tx: f32 = 0,
    ty: f32 = 0,
    tw: f32 = 0,
    th: f32 = 0,
    float_rect: [4]f32 = .{ 0, 0, 0, 0 },
    proposed: [2]i32 = .{ -1, -1 },
    // アニメーション
    px: Spring = Spring.init(0, 0.36, 0.80),
    py: Spring = Spring.init(0, 0.36, 0.80),
    cw: Spring = Spring.init(0, 0.30, 0.90),
    ch: Spring = Spring.init(0, 0.30, 0.90),
    reveal: Spring = Spring.init(0, 0.30, 0.68),
    slide: Spring = Spring.init(0, 0.42, 0.92),
    placed: bool = false,
    wait_frames: u8 = 0,
    /// 最後にフォーカスされた順(ワークスペースに戻ったとき、そこで最後に使っていた窓へ)
    focus_serial: u64 = 0,
    border_sent: [4]u32 = .{ 1, 1, 1, 1 },
    is_new: bool = true,
    shown: bool = true,
    /// Super+Q: 縮むアニメーションの後で close を送る
    closing: bool = false,
    close_sent_ms: u64 = 0,
    /// ワークスペース切替で画面外へ出ていく途中(終わったら hide)
    leaving: bool = false,

    fn titleStr(self: *const Window) []const u8 {
        return self.title[0..self.title_len];
    }
    fn visible(self: *const Window) bool {
        const o = self.out orelse return false;
        return self.tags & o.tags != 0;
    }
};

pub const WOut = struct {
    wm: *Wm,
    obj: *c.struct_river_output_v1,
    lsh: ?*c.struct_river_layer_shell_output_v1 = null,
    wl_name: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    /// 層シェルの排他領域を除いた使える範囲(グローバル)。無ければ出力全体
    area: ?[4]i32 = null,
    tags: u32 = 1,
    prev_tags: u32 = 1,
    removed: bool = false,
    ame: ?*appmod.Output = null,
};

const Op = enum { none, move, resize };

pub const WSeat = struct {
    wm: *Wm,
    obj: *c.struct_river_seat_v1,
    lsh: ?*c.struct_river_layer_shell_seat_v1 = null,
    focused: ?*Window = null,
    sent_focus: ?*Window = null,
    sent_clear: bool = false,
    /// 層シェル(ランチャー等)がキーボードを持っている間は窓にフォーカスを渡さない。
    /// 非排他(on_demand)のときだけ、窓のクリック・キー操作など明示的な操作(force_focus)で窓へ戻す
    layer_focus: enum { none, exclusive, non_exclusive } = .none,
    force_focus: bool = false,
    pointer_window: ?*Window = null,
    op: Op = .none,
    op_window: ?*Window = null,
    op_start: [4]f32 = .{ 0, 0, 0, 0 },
    op_dx: i32 = 0,
    op_dy: i32 = 0,
    op_end_pending: bool = false,
    enter_pending: bool = false,
    ptr_moved: bool = false,
};

pub const Action = union(enum) {
    spawn: []const u8, // binds の文字列(静的または設定の領域を指す)
    ame: []const u8, // ame-ctl のコマンドを内部で実行
    close,
    exit,
    fullscreen,
    float,
    focus_next,
    focus_prev,
    swap_next,
    swap_prev,
    ratio: f32,
    tags: u32,
    toggle_tags: u32,
    move_tags: u32,
    toggle_view_tags: u32,
    move_follow: u32,
    focus_output: i32,
    send_output: i32,
    // ポインタ
    op_move,
    op_resize,
    // 外部から(バー・ame-ctl)
    set_tags_on: struct { out: ?*WOut, mask: u32 },
    focus_window: *Window,
};

const PtrBind = struct { wm: *Wm, obj: *c.struct_river_pointer_binding_v1, action: Action };
const KeyBind = struct { wm: *Wm, obj: *c.struct_river_xkb_binding_v1, action: Action };

pub const Wm = struct {
    app: *App,
    mgr: *c.struct_river_window_manager_v1,
    xkb: ?*c.struct_river_xkb_bindings_v1 = null,
    lsh: ?*c.struct_river_layer_shell_v1 = null,
    windows: std.ArrayList(*Window),
    outputs: std.ArrayList(*WOut),
    seats: std.ArrayList(*WSeat),
    keybinds: std.ArrayList(*KeyBind),
    ptrbinds: std.ArrayList(*PtrBind),
    queue: std.ArrayList(Action),
    binds_enabled: bool = false,
    in_manage: bool = false,
    anim_timer: loop.Timer,
    last_render_ms: u64 = 0,
    animating: bool = false,
    dirty_sent: bool = false,
    ratio: f32 = 0.5,
    gap_in: f32 = 10,
    gap_out: f32 = 14,
    border: i32 = 3,
    locked: bool = false,
    focus_counter: u64 = 0,
    theme_fading: bool = false,

    pub fn create(app: *App, mgr: *c.struct_river_window_manager_v1) !*Wm {
        const self = try app.alloc.create(Wm);
        self.* = .{
            .app = app,
            .mgr = mgr,
            .windows = std.ArrayList(*Window).init(app.alloc),
            .outputs = std.ArrayList(*WOut).init(app.alloc),
            .seats = std.ArrayList(*WSeat).init(app.alloc),
            .keybinds = std.ArrayList(*KeyBind).init(app.alloc),
            .ptrbinds = std.ArrayList(*PtrBind).init(app.alloc),
            .queue = std.ArrayList(Action).init(app.alloc),
            .anim_timer = try loop.Timer.init(),
        };
        _ = c.river_window_manager_v1_add_listener(mgr, &mgr_listener, self);
        try app.loop.add(self.anim_timer.fd, c.EPOLLIN, self, onAnimTimer);
        return self;
    }

    pub fn setXkb(self: *Wm, xkb: *c.struct_river_xkb_bindings_v1) void {
        self.xkb = xkb;
    }
    pub fn setLayerShell(self: *Wm, l: *c.struct_river_layer_shell_v1) void {
        self.lsh = l;
        // 先に届いていた出力・seat にも層シェルの状態を付ける
        for (self.outputs.items) |o| if (o.lsh == null) {
            o.lsh = c.river_layer_shell_v1_get_output(l, o.obj);
            if (o.lsh) |lo| _ = c.river_layer_shell_output_v1_add_listener(lo, &lsh_output_listener, o);
        };
        for (self.seats.items) |s| if (s.lsh == null) {
            s.lsh = c.river_layer_shell_v1_get_seat(l, s.obj);
            if (s.lsh) |ls| _ = c.river_layer_shell_seat_v1_add_listener(ls, &lsh_seat_listener, s);
        };
    }

    // ---------------------------------------------------------------------
    // 外部からの要求(バーのクリック・ame-ctl・キーバインド)
    // ---------------------------------------------------------------------

    pub fn push(self: *Wm, a: Action) void {
        self.queue.append(a) catch return;
        self.requestManage();
    }

    fn requestManage(self: *Wm) void {
        if (self.in_manage or self.dirty_sent) return;
        self.dirty_sent = true;
        c.river_window_manager_v1_manage_dirty(self.mgr);
        _ = c.wl_display_flush(self.app.display);
    }

    pub fn focusedOutput(self: *Wm) ?*WOut {
        if (self.seat()) |s| if (s.focused) |w| if (w.out) |o| return o;
        // ame-shell が把握している「アクティブな出力」に合わせる
        if (self.app.focused_output) |ao| for (self.outputs.items) |o| if (o.ame == ao) return o;
        return if (self.outputs.items.len > 0) self.outputs.items[0] else null;
    }

    fn seat(self: *Wm) ?*WSeat {
        return if (self.seats.items.len > 0) self.seats.items[0] else null;
    }

    pub fn focusedWindow(self: *Wm) ?*Window {
        const s = self.seat() orelse return null;
        return s.focused;
    }

    // ---------------------------------------------------------------------
    // manage sequence
    // ---------------------------------------------------------------------

    fn manage(self: *Wm) void {
        self.in_manage = true;
        self.dirty_sent = false;
        defer self.in_manage = false;
        const s = self.seat();

        // 1. 新しいウィンドウ: 出力とタグを決め、フォーカス中の窓の次に並べる
        for (self.windows.items) |w| {
            if (!w.is_new) continue;
            w.is_new = false;
            const o = self.focusedOutput();
            w.out = o;
            w.tags = if (o) |oo| oo.tags else 1;
            if (w.node == null) w.node = c.river_window_v1_get_node(w.obj);
            // タイル型なのでサーバー側の枠(タイトルバー無し)を使ってもらう
            c.river_window_v1_use_ssd(w.obj);
            c.river_window_v1_set_tiled(w.obj, ALL_EDGES);
            // 提案した大きさで描かれるまでは隠しておく(初回の仮の大きさが一瞬見えないように)
            c.river_window_v1_hide(w.obj);
            w.shown = false;
            // 並び: フォーカス中の窓の直後へ
            self.moveAfterFocused(w);
            if (s) |ss| {
                ss.focused = w;
                ss.force_focus = true;
            }
            // 大きさの決まっている小窓(ダイアログ等)は浮かせる
            if (w.max_w > 0 and w.max_w == w.min_w and w.max_h > 0 and w.max_h == w.min_h) w.floating = true;
        }

        // 2. キーバインドの作成と有効化(最初の 1 回)
        if (!self.binds_enabled) self.setupBindings();

        // 3. 溜まっていた操作を実行
        const q = self.queue.toOwnedSlice() catch &[_]Action{};
        defer self.app.alloc.free(q);
        for (q) |a| self.apply(a);

        // 4. Super+Q で閉じる途中の窓: 縮み終わったら close
        for (self.windows.items) |w| {
            if (w.closing and w.close_sent_ms == 0 and w.reveal.x < 0.1) {
                c.river_window_v1_close(w.obj);
                w.close_sent_ms = loop.nowMs();
            }
            // 閉じなかった(保存確認のダイアログ等)→ 元に戻す
            if (w.close_sent_ms != 0 and loop.nowMs() - w.close_sent_ms > 600) {
                w.closing = false;
                w.close_sent_ms = 0;
                w.reveal.set(1);
            }
        }

        // 5. 全画面
        for (self.windows.items) |w| {
            const want = w.want_fullscreen orelse continue;
            w.want_fullscreen = null;
            if (want and !w.fullscreen) {
                if (w.out) |o| {
                    c.river_window_v1_fullscreen(w.obj, o.obj);
                    c.river_window_v1_inform_fullscreen(w.obj);
                    w.fullscreen = true;
                }
            } else if (!want and w.fullscreen) {
                c.river_window_v1_exit_fullscreen(w.obj);
                c.river_window_v1_inform_not_fullscreen(w.obj);
                w.fullscreen = false;
                w.proposed = .{ -1, -1 };
            }
        }

        // 6. 配置
        for (self.outputs.items) |o| self.layout(o);

        // 7. フォーカス(見えていない窓からは外す)
        if (s) |ss| {
            if (ss.enter_pending and ss.ptr_moved and ss.op == .none) {
                if (ss.pointer_window) |pw| if (pw.visible() and !pw.closing) {
                    ss.focused = pw;
                };
            }
            ss.enter_pending = false;
            ss.ptr_moved = false;
            if (ss.op_end_pending) {
                c.river_seat_v1_op_end(ss.obj);
                ss.op_end_pending = false;
            }
            if (ss.focused) |f| if (!f.visible() or f.closing) {
                ss.focused = self.firstVisible(self.focusedOutput());
            };
            if (ss.focused == null) ss.focused = self.firstVisible(self.focusedOutput());
            const may_send = switch (ss.layer_focus) {
                .none => true,
                .exclusive => false,
                .non_exclusive => ss.force_focus,
            };
            if (may_send) {
                if (ss.focused) |f| {
                    if (ss.sent_focus != f or ss.force_focus) {
                        self.focus_counter += 1;
                        f.focus_serial = self.focus_counter;
                        c.river_seat_v1_focus_window(ss.obj, f.obj);
                        ss.sent_focus = f;
                        ss.sent_clear = false;
                    }
                } else if (!ss.sent_clear) {
                    c.river_seat_v1_clear_focus(ss.obj);
                    ss.sent_clear = true;
                    ss.sent_focus = null;
                }
            }
            ss.force_focus = false;
        }

        // 8. 枠線(フォーカス中はテーマのアクセント色)
        self.applyBorders();
        // 9. シェル側(バー・ダッシュボード)へ状態を伝える
        self.publish();
        c.river_window_manager_v1_manage_finish(self.mgr);
    }

    fn firstVisible(self: *Wm, o: ?*WOut) ?*Window {
        var best: ?*Window = null;
        for (self.windows.items) |w| if (w.out == o and w.visible() and !w.closing) {
            if (best == null or w.focus_serial > best.?.focus_serial) best = w;
        };
        return best;
    }

    fn moveAfterFocused(self: *Wm, w: *Window) void {
        const s = self.seat() orelse return;
        const f = s.focused orelse return;
        if (f == w) return;
        const wi = std.mem.indexOfScalar(*Window, self.windows.items, w) orelse return;
        _ = self.windows.orderedRemove(wi);
        const fi = std.mem.indexOfScalar(*Window, self.windows.items, f) orelse {
            self.windows.append(w) catch {};
            return;
        };
        self.windows.insert(fi + 1, w) catch {};
    }

    fn apply(self: *Wm, a: Action) void {
        const s = self.seat();
        const fw = if (s) |ss| ss.focused else null;
        const o = self.focusedOutput();
        switch (a) {
            .spawn => |cmd| {
                var buf: [512]u8 = undefined;
                const z = std.fmt.bufPrintZ(&buf, "{s}", .{cmd}) catch return;
                sys.spawnDetached(z.ptr);
            },
            .ame => |cmd| @import("../ipc.zig").runCommand(self.app, cmd),
            .close => if (fw) |w| {
                // まず縮むアニメーション、縮み終わったら manage で close
                w.closing = true;
                w.reveal.response = 0.18;
                w.reveal.set(0);
                self.kick();
            },
            .exit => c.river_window_manager_v1_exit_session(self.mgr),
            .fullscreen => if (fw) |w| {
                w.want_fullscreen = !w.fullscreen;
            },
            .float => if (fw) |w| {
                w.floating = !w.floating;
                if (w.floating) {
                    // 今の位置・大きさのまま浮かせる(少し小さくして中央寄りに)
                    w.float_rect = .{ w.tx + w.tw * 0.08, w.ty + w.th * 0.08, w.tw * 0.84, w.th * 0.84 };
                }
            },
            .focus_next, .focus_prev => if (s) |ss| {
                const list = self.visibleList(o, false);
                if (list.len == 0) return;
                var idx: usize = 0;
                if (ss.focused) |f| idx = std.mem.indexOfScalar(*Window, list, f) orelse 0;
                const n = list.len;
                ss.focused = list[if (a == .focus_next) (idx + 1) % n else (idx + n - 1) % n];
                ss.force_focus = true;
            },
            .swap_next, .swap_prev => if (fw) |w| {
                const list = self.visibleList(o, true);
                const idx = std.mem.indexOfScalar(*Window, list, w) orelse return;
                if (list.len < 2) return;
                const other = list[if (a == .swap_next) (idx + 1) % list.len else (idx + list.len - 1) % list.len];
                const ia = std.mem.indexOfScalar(*Window, self.windows.items, w).?;
                const ib = std.mem.indexOfScalar(*Window, self.windows.items, other).?;
                std.mem.swap(*Window, &self.windows.items[ia], &self.windows.items[ib]);
            },
            .ratio => |d| self.ratio = std.math.clamp(self.ratio + d, 0.15, 0.85),
            .tags => |m| if (o) |oo| self.setTags(oo, m),
            .toggle_tags => |m| if (o) |oo| {
                const nt = oo.tags ^ m;
                if (nt != 0) self.setTags(oo, nt);
            },
            .move_tags => |m| if (fw) |w| {
                w.tags = m;
            },
            .toggle_view_tags => |m| if (fw) |w| {
                const nt = w.tags ^ m;
                if (nt != 0) w.tags = nt;
            },
            .move_follow => |m| if (fw) |w| {
                w.tags = m;
                if (o) |oo| self.setTags(oo, m);
                if (s) |ss| ss.focused = w;
            },
            .focus_output, .send_output => |dir| {
                if (self.outputs.items.len < 2) return;
                const cur = o orelse return;
                const i = std.mem.indexOfScalar(*WOut, self.outputs.items, cur) orelse 0;
                const n = self.outputs.items.len;
                const next = self.outputs.items[@intCast(@mod(@as(i32, @intCast(i)) + dir, @as(i32, @intCast(n))))];
                if (a == .send_output) {
                    if (fw) |w| {
                        w.out = next;
                        w.tags = next.tags;
                    }
                } else if (s) |ss| ss.focused = self.firstVisible(next);
                if (next.ame) |ao| self.app.focused_output = ao;
            },
            .op_move, .op_resize => if (s) |ss| {
                const w = ss.pointer_window orelse return;
                if (w.fullscreen) return;
                if (!w.floating) {
                    w.floating = true;
                    w.float_rect = .{ w.tx, w.ty, w.tw, w.th };
                }
                ss.op = if (a == .op_move) .move else .resize;
                ss.op_window = w;
                ss.op_start = w.float_rect;
                ss.op_dx = 0;
                ss.op_dy = 0;
                ss.focused = w;
                c.river_seat_v1_op_start_pointer(ss.obj);
                if (a == .op_resize) c.river_window_v1_inform_resize_start(w.obj);
            },
            .set_tags_on => |st| {
                const oo = st.out orelse o orelse return;
                self.setTags(oo, st.mask);
            },
            .focus_window => |w| if (s) |ss| {
                ss.focused = w;
                ss.force_focus = true;
            },
        }
    }

    /// ワークスペース(タグ)の切替。出ていく窓は横へスライドして消え、入ってくる窓は反対側から入る
    fn setTags(self: *Wm, o: *WOut, mask: u32) void {
        if (mask == o.tags) return;
        const old = o.tags;
        // 右のタグへ移るなら、今の窓は左へ出て、新しい窓は右から入る
        const dir: f32 = if (@ctz(mask) > @ctz(old)) -1 else 1;
        const dist = @as(f32, @floatFromInt(o.w)) + 40;
        o.prev_tags = old;
        o.tags = mask;
        for (self.windows.items) |w| {
            if (w.out != o) continue;
            const was = w.tags & old != 0;
            const now = w.tags & mask != 0;
            if (was and !now) {
                w.leaving = true;
                w.slide.set(dir * dist);
            } else if (!was and now) {
                w.leaving = false;
                w.slide.snap(-dir * dist);
                w.slide.set(0);
            }
        }
        self.kick();
    }

    fn visibleList(self: *Wm, o: ?*WOut, tiled_only: bool) []*Window {
        const S = struct {
            var buf: [128]*Window = undefined;
        };
        var n: usize = 0;
        for (self.windows.items) |w| {
            if (w.out != o or !w.visible() or w.closing or w.w == 0) continue;
            if (tiled_only and (w.floating or w.fullscreen)) continue;
            if (n < S.buf.len) {
                S.buf[n] = w;
                n += 1;
            }
        }
        return S.buf[0..n];
    }

    /// dwindle: 残りの領域を長い辺で分け、i 番目の窓は前半、残りは後半へ
    fn layout(self: *Wm, o: *WOut) void {
        var area: [4]f32 = if (o.area) |a| .{ @floatFromInt(a[0]), @floatFromInt(a[1]), @floatFromInt(a[2]), @floatFromInt(a[3]) } else .{ @floatFromInt(o.x), @floatFromInt(o.y), @floatFromInt(o.w), @floatFromInt(o.h) };
        const g = self.gap_out;
        area = .{ area[0] + g, area[1] + g, area[2] - g * 2, area[3] - g * 2 };
        var tiled: [128]*Window = undefined;
        var n: usize = 0;
        for (self.windows.items) |w| {
            if (w.out != o or !w.visible() or w.floating or w.fullscreen or w.closing) continue;
            if (n < tiled.len) {
                tiled[n] = w;
                n += 1;
            }
        }
        const gi = self.gap_in;
        var r = area;
        for (tiled[0..n], 0..) |w, i| {
            var cell = r;
            if (i + 1 < n) {
                const ratio = if (i == 0) self.ratio else 0.5;
                if (r[2] >= r[3]) {
                    const lw = (r[2] - gi) * ratio;
                    cell = .{ r[0], r[1], lw, r[3] };
                    r = .{ r[0] + lw + gi, r[1], r[2] - lw - gi, r[3] };
                } else {
                    const th = (r[3] - gi) * ratio;
                    cell = .{ r[0], r[1], r[2], th };
                    r = .{ r[0], r[1] + th + gi, r[2], r[3] - th - gi };
                }
            }
            self.place(w, cell);
        }
        // 浮いている窓
        for (self.windows.items) |w| {
            if (w.out != o or !w.visible() or !w.floating or w.fullscreen) continue;
            if (w.float_rect[2] <= 0) {
                // 初めて浮いた: 中身の希望サイズで中央に
                const fw: f32 = if (w.w > 0) @floatFromInt(w.w) else area[2] * 0.5;
                const fh: f32 = if (w.h > 0) @floatFromInt(w.h) else area[3] * 0.5;
                w.float_rect = .{ area[0] + (area[2] - fw) / 2, area[1] + (area[3] - fh) / 2, fw, fh };
            }
            self.place(w, w.float_rect);
        }
    }

    fn place(self: *Wm, w: *Window, cell: [4]f32) void {
        const b: f32 = @floatFromInt(self.border);
        // 枠線の分だけ内側に(枠線が隣の窓と重ならないように)
        w.tx = cell[0] + b;
        w.ty = cell[1] + b;
        w.tw = @max(cell[2] - b * 2, 1);
        w.th = @max(cell[3] - b * 2, 1);
        const pw: i32 = @intFromFloat(@round(w.tw));
        const ph: i32 = @intFromFloat(@round(w.th));
        if (pw != w.proposed[0] or ph != w.proposed[1]) {
            c.river_window_v1_propose_dimensions(w.obj, pw, ph);
            w.proposed = .{ pw, ph };
        }
        if (w.placed) {
            // 位置はスプリングで追いかける(移動・入れ替え・レイアウト変化が滑らかに)
            w.px.set(w.tx);
            w.py.set(w.ty);
        }
        self.kick();
    }

    fn applyBorders(self: *Wm) void {
        const s = self.seat();
        const f = if (s) |ss| ss.focused else null;
        const acc = theme.accent(self.app);
        const un = theme.tint(self.app).lighten(0.12);
        for (self.windows.items) |w| {
            const col = if (w == f) acc else un;
            const to32 = struct {
                fn conv(v: f32) u32 {
                    return @intFromFloat(@as(f64, std.math.clamp(v, 0, 1)) * 4294967295.0);
                }
            }.conv;
            const v = [4]u32{ to32(col.r), to32(col.g), to32(col.b), to32(1) };
            if (std.mem.eql(u32, &v, &w.border_sent)) continue;
            w.border_sent = v;
            c.river_window_v1_set_borders(w.obj, ALL_EDGES, self.border, v[0], v[1], v[2], v[3]);
        }
    }

    // ---------------------------------------------------------------------
    // render sequence: スプリングを進めて位置・clip を指定
    // ---------------------------------------------------------------------

    fn render(self: *Wm) void {
        const now = loop.nowMs();
        var dt: f32 = if (self.last_render_ms == 0) 1.0 / 60.0 else @as(f32, @floatFromInt(now - self.last_render_ms)) / 1000.0;
        if (dt > 0.05) dt = 1.0 / 60.0;
        self.last_render_ms = now;
        var moving = false;
        const s = self.seat();
        const f = if (s) |ss| ss.focused else null;

        for (self.windows.items) |w| {
            if (w.w == 0 or w.h == 0) continue; // まだ大きさが決まっていない
            const node = w.node orelse continue;
            if (!w.placed) {
                // 提案した大きさになるまで待つ(応じないクライアントのため 12 フレームで諦める)
                const ok = w.proposed[0] < 0 or (w.w == w.proposed[0] and w.h == w.proposed[1]);
                w.wait_frames += 1;
                if (!ok and w.wait_frames < 12) {
                    moving = true;
                    continue;
                }
                // 初めて表示: その場で「中心から広がる」(Hyprland の popin)
                w.placed = true;
                w.px.snap(w.tx);
                w.py.snap(w.ty);
                w.cw.snap(@floatFromInt(w.w));
                w.ch.snap(@floatFromInt(w.h));
                w.reveal.snap(0.55);
                w.reveal.set(1);
            }
            // 大きくなったときは前の大きさから clip を広げていく(縮むときは即時)
            const fw: f32 = @floatFromInt(w.w);
            const fh: f32 = @floatFromInt(w.h);
            if (w.cw.target != fw) {
                if (fw < w.cw.x) w.cw.snap(fw) else w.cw.set(fw);
            }
            if (w.ch.target != fh) {
                if (fh < w.ch.x) w.ch.snap(fh) else w.ch.set(fh);
            }
            var springs = [_]*Spring{ &w.px, &w.py, &w.cw, &w.ch, &w.reveal, &w.slide };
            if (anim.stepAll(&springs, dt)) moving = true;

            // ワークスペース切替で出ていった窓は、スライドが終わったら隠す
            const on = w.visible() and !(w.leaving);
            if (w.leaving and !w.slide.moving()) {
                w.leaving = false;
                w.slide.snap(0);
            }
            const show = on or w.leaving;
            if (show != w.shown) {
                if (show) c.river_window_v1_show(w.obj) else c.river_window_v1_hide(w.obj);
                w.shown = show;
            }
            if (!show) continue;
            if (w.fullscreen) continue; // 全画面中の位置・clip はコンポジタ任せ

            const sc = std.math.clamp(w.reveal.x, 0, 1.2);
            const vw = @min(w.cw.x, fw);
            const vh = @min(w.ch.x, fh);
            const bw = vw * @min(sc, 1);
            const bh = vh * @min(sc, 1);
            const x = w.px.x + w.slide.x;
            const y = w.py.x;
            c.river_node_v1_set_position(node, @intFromFloat(@round(x)), @intFromFloat(@round(y)));
            const full = sc >= 0.999 and vw >= fw - 0.5 and vh >= fh - 0.5;
            if (full) {
                c.river_window_v1_set_clip_box(w.obj, 0, 0, 0, 0);
            } else {
                const cx: i32 = @intFromFloat(@round((vw - bw) / 2));
                const cy: i32 = @intFromFloat(@round((vh - bh) / 2));
                c.river_window_v1_set_clip_box(w.obj, cx, cy, @max(1, @as(i32, @intFromFloat(@round(bw)))), @max(1, @as(i32, @intFromFloat(@round(bh)))));
            }
        }
        // 重なり順: タイル → 浮いている窓 → フォーカス中の浮いている窓
        for (self.windows.items) |w| if (!w.floating) if (w.node) |n| c.river_node_v1_place_top(n);
        for (self.windows.items) |w| if (w.floating and w != f) if (w.node) |n| c.river_node_v1_place_top(n);
        if (f) |w| if (w.floating) if (w.node) |n| c.river_node_v1_place_top(n);

        if (self.theme_fading) {
            if (theme.accentAnimating()) moving = true else self.theme_fading = false;
        }
        c.river_window_manager_v1_render_finish(self.mgr);
        // 動いている間は次のフレームでもう一度 render sequence を回す
        self.animating = moving;
        if (moving) self.anim_timer.arm(8, 0);
    }

    /// 壁紙・アルバムアートでアクセント色が変わった: 色が移り変わる間、枠線の色も毎フレーム追従させる
    pub fn themeChanged(self: *Wm) void {
        self.theme_fading = true;
        self.kick();
    }

    /// アニメーションを始める(次のフレームで manage→render を回す)
    fn kick(self: *Wm) void {
        if (!self.animating) {
            self.animating = true;
            self.anim_timer.arm(1, 0);
        }
    }

    fn onAnimTimer(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *Wm = @ptrCast(@alignCast(ctx));
        self.anim_timer.ack();
        if (self.animating) self.requestManage();
    }

    // ---------------------------------------------------------------------
    // ame-shell 側へ状態を渡す(バーのタグ・タイトル)
    // ---------------------------------------------------------------------

    fn publish(self: *Wm) void {
        const app = self.app;
        for (self.outputs.items) |o| {
            if (o.ame == null) for (app.outputs.items) |x| if (x.global == o.wl_name) {
                o.ame = x;
            };
            const ao = o.ame orelse continue;
            var occupied: u32 = 0;
            ao.n_views = 0;
            for (self.windows.items) |w| {
                if (w.out != o) continue;
                occupied |= w.tags;
                if (ao.n_views < ao.view_list.len) {
                    ao.view_list[ao.n_views] = w.tags;
                    ao.n_views += 1;
                }
            }
            const changed = ao.focused_tags != o.tags or ao.view_tags != occupied;
            ao.focused_tags = o.tags;
            ao.view_tags = occupied;
            if (changed) {
                if (ao.frame) |fr| fr.bar.tagsChanged(fr);
                if (ao.bar) |b| b.tagsChanged();
            }
        }
        const f = self.focusedWindow();
        const t: []const u8 = if (f) |w| w.titleStr() else "";
        if (!std.mem.eql(u8, t, app.focused_title.get())) {
            app.focused_title.set(t);
            app.title_serial +%= 1;
            for (app.outputs.items) |ao| {
                if (ao.bar) |b| b.titleChanged();
                if (ao.frame) |fr| fr.bar.titleChanged(fr);
            }
        }
        if (self.focusedOutput()) |o| if (o.ame) |ao| {
            app.focused_output = ao;
        };
    }

    // ---------------------------------------------------------------------
    // キー・ポインタのバインド
    // ---------------------------------------------------------------------

    fn setupBindings(self: *Wm) void {
        const s = self.seat() orelse return;
        self.binds_enabled = true;
        const xkb = self.xkb orelse {
            std.log.warn("wm: river_xkb_bindings_v1 が無いのでキーバインド無し", .{});
            return;
        };
        for (binds.all) |b| {
            const obj = c.river_xkb_bindings_v1_get_xkb_binding(xkb, s.obj, b.keysym, b.mods) orelse continue;
            const kb = self.app.alloc.create(KeyBind) catch continue;
            kb.* = .{ .wm = self, .obj = obj, .action = b.action };
            _ = c.river_xkb_binding_v1_add_listener(obj, &key_listener, kb);
            c.river_xkb_binding_v1_enable(obj);
            self.keybinds.append(kb) catch {};
        }
        // Super+左ドラッグ: 移動 / Super+右ドラッグ: 大きさ変更 / Super+中クリック: 浮かせる
        const pbs = [_]struct { btn: u32, action: Action }{
            .{ .btn = BTN_LEFT, .action = .op_move },
            .{ .btn = BTN_RIGHT, .action = .op_resize },
            .{ .btn = BTN_MIDDLE, .action = .float },
        };
        for (pbs) |p| {
            const obj = c.river_seat_v1_get_pointer_binding(s.obj, p.btn, MOD_SUPER) orelse continue;
            const pb = self.app.alloc.create(PtrBind) catch continue;
            pb.* = .{ .wm = self, .obj = obj, .action = p.action };
            _ = c.river_pointer_binding_v1_add_listener(obj, &ptr_listener, pb);
            c.river_pointer_binding_v1_enable(obj);
            self.ptrbinds.append(pb) catch {};
        }
        std.log.info("wm: キーバインド {d} 個を登録", .{self.keybinds.items.len});
    }

    fn findWindow(self: *Wm, obj: ?*c.struct_river_window_v1) ?*Window {
        for (self.windows.items) |w| if (w.obj == obj) return w;
        return null;
    }
};

// ===========================================================================
// リスナ
// ===========================================================================

fn mgrUnavailable(data: ?*anyopaque, _: ?*c.struct_river_window_manager_v1) callconv(.C) void {
    const self: *Wm = @ptrCast(@alignCast(data.?));
    _ = self;
    std.log.warn("wm: 別のウィンドウマネージャが動いているため WM 機能は無効", .{});
}
fn mgrFinished(_: ?*anyopaque, _: ?*c.struct_river_window_manager_v1) callconv(.C) void {}
fn mgrManageStart(data: ?*anyopaque, _: ?*c.struct_river_window_manager_v1) callconv(.C) void {
    const self: *Wm = @ptrCast(@alignCast(data.?));
    self.manage();
}
fn mgrRenderStart(data: ?*anyopaque, _: ?*c.struct_river_window_manager_v1) callconv(.C) void {
    const self: *Wm = @ptrCast(@alignCast(data.?));
    self.render();
}
fn mgrLocked(data: ?*anyopaque, _: ?*c.struct_river_window_manager_v1) callconv(.C) void {
    const self: *Wm = @ptrCast(@alignCast(data.?));
    self.locked = true;
}
fn mgrUnlocked(data: ?*anyopaque, _: ?*c.struct_river_window_manager_v1) callconv(.C) void {
    const self: *Wm = @ptrCast(@alignCast(data.?));
    self.locked = false;
}
fn mgrWindow(data: ?*anyopaque, _: ?*c.struct_river_window_manager_v1, obj: ?*c.struct_river_window_v1) callconv(.C) void {
    const self: *Wm = @ptrCast(@alignCast(data.?));
    const w = self.app.alloc.create(Window) catch return;
    w.* = .{ .wm = self, .obj = obj.? };
    _ = c.river_window_v1_add_listener(obj, &window_listener, w);
    self.windows.append(w) catch {};
}
fn mgrOutput(data: ?*anyopaque, _: ?*c.struct_river_window_manager_v1, obj: ?*c.struct_river_output_v1) callconv(.C) void {
    const self: *Wm = @ptrCast(@alignCast(data.?));
    const o = self.app.alloc.create(WOut) catch return;
    o.* = .{ .wm = self, .obj = obj.? };
    _ = c.river_output_v1_add_listener(obj, &output_listener, o);
    if (self.lsh) |l| {
        o.lsh = c.river_layer_shell_v1_get_output(l, obj);
        if (o.lsh) |lo| _ = c.river_layer_shell_output_v1_add_listener(lo, &lsh_output_listener, o);
    }
    self.outputs.append(o) catch {};
}
fn mgrSeat(data: ?*anyopaque, _: ?*c.struct_river_window_manager_v1, obj: ?*c.struct_river_seat_v1) callconv(.C) void {
    const self: *Wm = @ptrCast(@alignCast(data.?));
    const s = self.app.alloc.create(WSeat) catch return;
    s.* = .{ .wm = self, .obj = obj.? };
    _ = c.river_seat_v1_add_listener(obj, &seat_listener, s);
    if (self.lsh) |l| {
        s.lsh = c.river_layer_shell_v1_get_seat(l, obj);
        if (s.lsh) |ls| _ = c.river_layer_shell_seat_v1_add_listener(ls, &lsh_seat_listener, s);
    }
    self.seats.append(s) catch {};
}
const mgr_listener = c.struct_river_window_manager_v1_listener{
    .unavailable = mgrUnavailable,
    .finished = mgrFinished,
    .manage_start = mgrManageStart,
    .render_start = mgrRenderStart,
    .session_locked = mgrLocked,
    .session_unlocked = mgrUnlocked,
    .window = mgrWindow,
    .output = mgrOutput,
    .seat = mgrSeat,
};

// ---- window ----
fn wClosed(data: ?*anyopaque, obj: ?*c.struct_river_window_v1) callconv(.C) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    const self = w.wm;
    for (self.seats.items) |s| {
        // 次の manage で、このワークスペースで直前に使っていた窓へフォーカスが戻る
        if (s.focused == w) s.focused = null;
        if (s.sent_focus == w) s.sent_focus = null;
        if (s.pointer_window == w) s.pointer_window = null;
        if (s.op_window == w) {
            s.op_window = null;
            s.op = .none;
        }
    }
    if (std.mem.indexOfScalar(*Window, self.windows.items, w)) |i| _ = self.windows.orderedRemove(i);
    if (w.node) |n| c.river_node_v1_destroy(n);
    c.river_window_v1_destroy(obj);
    self.app.alloc.destroy(w);
}
fn wDimHint(data: ?*anyopaque, _: ?*c.struct_river_window_v1, min_w: i32, min_h: i32, max_w: i32, max_h: i32) callconv(.C) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    w.min_w = min_w;
    w.min_h = min_h;
    w.max_w = max_w;
    w.max_h = max_h;
}
fn wDims(data: ?*anyopaque, _: ?*c.struct_river_window_v1, width: i32, height: i32) callconv(.C) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    w.w = width;
    w.h = height;
}
fn wAppId(data: ?*anyopaque, _: ?*c.struct_river_window_v1, s: [*c]const u8) callconv(.C) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    const v = if (s != null) std.mem.sliceTo(s, 0) else "";
    w.app_id_len = @min(v.len, w.app_id.len);
    @memcpy(w.app_id[0..w.app_id_len], v[0..w.app_id_len]);
}
fn wTitle(data: ?*anyopaque, _: ?*c.struct_river_window_v1, s: [*c]const u8) callconv(.C) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    const v = if (s != null) std.mem.sliceTo(s, 0) else "";
    w.title_len = @min(v.len, w.title.len);
    @memcpy(w.title[0..w.title_len], v[0..w.title_len]);
    while (w.title_len > 0 and w.title_len < v.len and (w.title[w.title_len - 1] & 0xC0) == 0x80) w.title_len -= 1;
}
fn wParent(data: ?*anyopaque, _: ?*c.struct_river_window_v1, parent: ?*c.struct_river_window_v1) callconv(.C) void {
    // 親を持つ窓(ダイアログ)は浮かせる
    const w: *Window = @ptrCast(@alignCast(data.?));
    if (parent != null) w.floating = true;
}
fn wDecoHint(_: ?*anyopaque, _: ?*c.struct_river_window_v1, _: u32) callconv(.C) void {}
fn wMoveReq(data: ?*anyopaque, _: ?*c.struct_river_window_v1, _: ?*c.struct_river_seat_v1) callconv(.C) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    // CSD のタイトルバーをドラッグ → 浮かせて移動
    for (w.wm.seats.items) |s| s.pointer_window = w;
    w.wm.push(.op_move);
}
fn wResizeReq(data: ?*anyopaque, _: ?*c.struct_river_window_v1, _: ?*c.struct_river_seat_v1, _: u32) callconv(.C) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    for (w.wm.seats.items) |s| s.pointer_window = w;
    w.wm.push(.op_resize);
}
fn wMenu(_: ?*anyopaque, _: ?*c.struct_river_window_v1, _: i32, _: i32) callconv(.C) void {}
fn wMax(_: ?*anyopaque, _: ?*c.struct_river_window_v1) callconv(.C) void {}
fn wFsReq(data: ?*anyopaque, _: ?*c.struct_river_window_v1, _: ?*c.struct_river_output_v1) callconv(.C) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    w.want_fullscreen = true;
}
fn wFsExit(data: ?*anyopaque, _: ?*c.struct_river_window_v1) callconv(.C) void {
    const w: *Window = @ptrCast(@alignCast(data.?));
    w.want_fullscreen = false;
}
fn wPid(_: ?*anyopaque, _: ?*c.struct_river_window_v1, _: i32) callconv(.C) void {}
fn wPres(_: ?*anyopaque, _: ?*c.struct_river_window_v1, _: u32) callconv(.C) void {}
fn wIdent(_: ?*anyopaque, _: ?*c.struct_river_window_v1, _: [*c]const u8) callconv(.C) void {}
fn wCap(_: ?*anyopaque, _: ?*c.struct_river_window_v1, _: u32) callconv(.C) void {}
fn wTouchMove(_: ?*anyopaque, _: ?*c.struct_river_window_v1, _: ?*c.struct_river_seat_v1, _: i32) callconv(.C) void {}
fn wTouchResize(_: ?*anyopaque, _: ?*c.struct_river_window_v1, _: ?*c.struct_river_seat_v1, _: i32, _: u32) callconv(.C) void {}
const window_listener = c.struct_river_window_v1_listener{
    .closed = wClosed,
    .dimensions_hint = wDimHint,
    .dimensions = wDims,
    .app_id = wAppId,
    .title = wTitle,
    .parent = wParent,
    .decoration_hint = wDecoHint,
    .pointer_move_requested = wMoveReq,
    .pointer_resize_requested = wResizeReq,
    .show_window_menu_requested = wMenu,
    .maximize_requested = wMax,
    .unmaximize_requested = wMax,
    .fullscreen_requested = wFsReq,
    .exit_fullscreen_requested = wFsExit,
    .minimize_requested = wMax,
    .unreliable_pid = wPid,
    .presentation_hint = wPres,
    .identifier = wIdent,
    .capture_sessions = wCap,
    .touch_move_requested = wTouchMove,
    .touch_resize_requested = wTouchResize,
};

// ---- output ----
fn oRemoved(data: ?*anyopaque, obj: ?*c.struct_river_output_v1) callconv(.C) void {
    const o: *WOut = @ptrCast(@alignCast(data.?));
    const self = o.wm;
    // この出力の窓は残りの出力へ
    const other: ?*WOut = for (self.outputs.items) |x| {
        if (x != o) break x;
    } else null;
    for (self.windows.items) |w| if (w.out == o) {
        w.out = other;
        if (other) |ot| w.tags = ot.tags;
    };
    if (std.mem.indexOfScalar(*WOut, self.outputs.items, o)) |i| _ = self.outputs.orderedRemove(i);
    if (o.lsh) |l| c.river_layer_shell_output_v1_destroy(l);
    c.river_output_v1_destroy(obj);
    self.app.alloc.destroy(o);
}
fn oWlOutput(data: ?*anyopaque, _: ?*c.struct_river_output_v1, name: u32) callconv(.C) void {
    const o: *WOut = @ptrCast(@alignCast(data.?));
    o.wl_name = name;
    for (o.wm.app.outputs.items) |ao| if (ao.global == name) {
        o.ame = ao;
    };
}
fn oPos(data: ?*anyopaque, _: ?*c.struct_river_output_v1, x: i32, y: i32) callconv(.C) void {
    const o: *WOut = @ptrCast(@alignCast(data.?));
    o.x = x;
    o.y = y;
}
fn oDims(data: ?*anyopaque, _: ?*c.struct_river_output_v1, w: i32, h: i32) callconv(.C) void {
    const o: *WOut = @ptrCast(@alignCast(data.?));
    o.w = w;
    o.h = h;
}
fn oCap(_: ?*anyopaque, _: ?*c.struct_river_output_v1, _: u32) callconv(.C) void {}
const output_listener = c.struct_river_output_v1_listener{ .removed = oRemoved, .wl_output = oWlOutput, .position = oPos, .dimensions = oDims, .capture_sessions = oCap };

fn lsArea(data: ?*anyopaque, _: ?*c.struct_river_layer_shell_output_v1, x: i32, y: i32, w: i32, h: i32) callconv(.C) void {
    const o: *WOut = @ptrCast(@alignCast(data.?));
    o.area = .{ x, y, w, h };
}
const lsh_output_listener = c.struct_river_layer_shell_output_v1_listener{ .non_exclusive_area = lsArea };

fn lsFocusExcl(data: ?*anyopaque, _: ?*c.struct_river_layer_shell_seat_v1) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    s.layer_focus = .exclusive;
}
fn lsFocusNonExcl(data: ?*anyopaque, _: ?*c.struct_river_layer_shell_seat_v1) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    s.layer_focus = .non_exclusive;
}
fn lsFocusNone(data: ?*anyopaque, _: ?*c.struct_river_layer_shell_seat_v1) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    // 層シェルがキーボードを手放した → 窓へフォーカスを渡し直す
    if (s.layer_focus != .none) s.sent_focus = null;
    s.layer_focus = .none;
    s.wm.requestManage();
}
const lsh_seat_listener = c.struct_river_layer_shell_seat_v1_listener{ .focus_exclusive = lsFocusExcl, .focus_non_exclusive = lsFocusNonExcl, .focus_none = lsFocusNone };

// ---- seat ----
fn sRemoved(data: ?*anyopaque, obj: ?*c.struct_river_seat_v1) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    const self = s.wm;
    if (std.mem.indexOfScalar(*WSeat, self.seats.items, s)) |i| _ = self.seats.orderedRemove(i);
    c.river_seat_v1_destroy(obj);
    self.app.alloc.destroy(s);
}
fn sWlSeat(_: ?*anyopaque, _: ?*c.struct_river_seat_v1, _: u32) callconv(.C) void {}
fn sPtrEnter(data: ?*anyopaque, _: ?*c.struct_river_seat_v1, win: ?*c.struct_river_window_v1) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    s.pointer_window = s.wm.findWindow(win);
    // フォーカスはマウスに追従(今の River 設定と同じ focus-follows-cursor)。
    // ただし窓の方が動いてカーソルの下に来ただけ(ワークスペース切替のスライド等)では移さない → manage で判定
    s.enter_pending = true;
    s.wm.requestManage();
}
fn sPtrLeave(data: ?*anyopaque, _: ?*c.struct_river_seat_v1) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    s.pointer_window = null;
}
fn sInteract(data: ?*anyopaque, _: ?*c.struct_river_seat_v1, win: ?*c.struct_river_window_v1) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    if (s.wm.findWindow(win)) |w| s.wm.push(.{ .focus_window = w });
}
fn sShellInteract(_: ?*anyopaque, _: ?*c.struct_river_seat_v1, _: ?*c.struct_river_shell_surface_v1) callconv(.C) void {}
fn sOpDelta(data: ?*anyopaque, _: ?*c.struct_river_seat_v1, dx: i32, dy: i32) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    const w = s.op_window orelse return;
    const fx: f32 = @floatFromInt(dx);
    const fy: f32 = @floatFromInt(dy);
    if (s.op == .move) {
        w.float_rect = .{ s.op_start[0] + fx, s.op_start[1] + fy, s.op_start[2], s.op_start[3] };
    } else {
        w.float_rect = .{ s.op_start[0], s.op_start[1], @max(s.op_start[2] + fx, 80), @max(s.op_start[3] + fy, 60) };
    }
    s.wm.requestManage();
}
fn sOpRelease(data: ?*anyopaque, _: ?*c.struct_river_seat_v1) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    if (s.op == .resize) if (s.op_window) |w| c.river_window_v1_inform_resize_end(w.obj);
    s.op = .none;
    s.op_window = null;
    // op_end は manage sequence の中で送る必要がある
    s.op_end_pending = true;
    s.wm.requestManage();
}
fn sPtrPos(data: ?*anyopaque, _: ?*c.struct_river_seat_v1, _: i32, _: i32) callconv(.C) void {
    const s: *WSeat = @ptrCast(@alignCast(data.?));
    s.ptr_moved = true;
}
fn sTouchDelta(_: ?*anyopaque, _: ?*c.struct_river_seat_v1, _: i32, _: i32, _: i32) callconv(.C) void {}
fn sTouchRel(_: ?*anyopaque, _: ?*c.struct_river_seat_v1, _: i32) callconv(.C) void {}
const seat_listener = c.struct_river_seat_v1_listener{
    .removed = sRemoved,
    .wl_seat = sWlSeat,
    .pointer_enter = sPtrEnter,
    .pointer_leave = sPtrLeave,
    .window_interaction = sInteract,
    .shell_surface_interaction = sShellInteract,
    .op_delta = sOpDelta,
    .op_release = sOpRelease,
    .pointer_position = sPtrPos,
    .op_delta_touch = sTouchDelta,
    .op_release_touch = sTouchRel,
    .op_cancel_touch = sTouchRel,
};

// ---- bindings ----
fn kbPressed(data: ?*anyopaque, _: ?*c.struct_river_xkb_binding_v1) callconv(.C) void {
    const kb: *KeyBind = @ptrCast(@alignCast(data.?));
    kb.wm.push(kb.action);
}
fn kbReleased(_: ?*anyopaque, _: ?*c.struct_river_xkb_binding_v1) callconv(.C) void {}
fn kbStopRepeat(_: ?*anyopaque, _: ?*c.struct_river_xkb_binding_v1) callconv(.C) void {}
const key_listener = c.struct_river_xkb_binding_v1_listener{ .pressed = kbPressed, .released = kbReleased, .stop_repeat = kbStopRepeat };

fn pbPressed(data: ?*anyopaque, _: ?*c.struct_river_pointer_binding_v1) callconv(.C) void {
    const pb: *PtrBind = @ptrCast(@alignCast(data.?));
    pb.wm.push(pb.action);
}
fn pbReleased(_: ?*anyopaque, _: ?*c.struct_river_pointer_binding_v1) callconv(.C) void {}
const ptr_listener = c.struct_river_pointer_binding_v1_listener{ .pressed = pbPressed, .released = pbReleased };
