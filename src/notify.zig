// 通知: org.freedesktop.Notifications を内蔵実装し、右上にガラスのカードを積む。
//
// D-Bus は libdbus を private 接続で使い、その fd を epoll に載せる(スレッド不要)。
// すでに別の通知デーモン(swaync, mako 等)が名前を持っている場合は奪わず、
// D-Bus 側だけ無効にする(ame-ctl notify によるローカル通知は引き続き表示できる)。
//
// アニメーション: カードは右から滑り込み、上のカードが消えると下のカードがスプリングで詰める。
// 消えるときは右へ流れてフェードアウト。
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

/// libdbus の DBusError(ビットフィールドを含むため translate-c では不透明型になる)と同じレイアウト。
const DBusError = extern struct { name: ?[*:0]const u8 = null, message: ?[*:0]const u8 = null, dummy: c_uint = 0, padding1: ?*anyopaque = null };

const SW: u32 = 420;
const SH: u32 = 660;
const CARD_W: f32 = 380;
const MAX_CARDS = 5;
const HISTORY = 50;

pub const Notif = struct {
    id: u32,
    app_name: [64]u8 = undefined,
    app_len: usize = 0,
    summary: [256]u8 = undefined,
    sum_len: usize = 0,
    body: [512]u8 = undefined,
    body_len: usize = 0,
    has_default_action: bool = false,
    urgency: u8 = 1,
    expire_at: u64 = 0, // 0 = 自動では消えない
    time_str: [8]u8 = undefined,
    // アニメーション
    slide: Spring = Spring.init(1, 0.40, 0.78), // 1=右に隠れている, 0=表示
    ypos: Spring = Spring.init(0, 0.35, 0.82),
    leaving: bool = false,
    height: f32 = 90,

    pub fn appName(self: *const Notif) []const u8 {
        return self.app_name[0..self.app_len];
    }
    pub fn summaryText(self: *const Notif) []const u8 {
        return self.summary[0..self.sum_len];
    }
    pub fn bodyText(self: *const Notif) []const u8 {
        return self.body[0..self.body_len];
    }
};

fn copyTo(dst: []u8, len: *usize, src: []const u8) void {
    // マークアップ(<b> 等)は表示できないのでタグを取り除く
    var o: usize = 0;
    var in_tag = false;
    for (src) |ch| {
        if (ch == '<') {
            in_tag = true;
            continue;
        }
        if (ch == '>' and in_tag) {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;
        if (o >= dst.len) break;
        dst[o] = if (ch == '\n' or ch == '\t') ' ' else ch;
        o += 1;
    }
    // UTF-8 の途中で切れていたら直前の文字境界まで戻す
    while (o > 0 and o < src.len and (dst[o - 1] & 0xC0) == 0x80) o -= 1;
    if (o > 0 and dst[o - 1] >= 0xC0) o -= 1;
    len.* = o;
}

pub const Notifs = struct {
    app: *App,
    conn: ?*c.DBusConnection = null,
    dbus_fd: c_int = -1,
    owner: bool = false,
    next_id: u32 = 1,
    active: std.ArrayList(Notif),
    history: std.ArrayList(Notif),
    surf: ?*Surface = null,
    out: ?*Output = null,
    timer: loop.Timer,
    hover_idx: ?usize = null,
    unread: u32 = 0,

    pub fn create(app: *App) !*Notifs {
        const self = try app.alloc.create(Notifs);
        self.* = .{
            .app = app,
            .active = std.ArrayList(Notif).init(app.alloc),
            .history = std.ArrayList(Notif).init(app.alloc),
            .timer = try loop.Timer.init(),
        };
        try app.loop.add(self.timer.fd, c.EPOLLIN, self, onTimer);
        self.connect();
        return self;
    }

    fn connect(self: *Notifs) void {
        var err = DBusError{};
        const errp: *c.DBusError = @ptrCast(&err);
        c.dbus_error_init(errp);
        const conn = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, errp) orelse {
            std.log.warn("notify: セッションバスに接続できません: {s}", .{if (err.message) |m| std.mem.sliceTo(m, 0) else "?"});
            c.dbus_error_free(errp);
            return;
        };
        c.dbus_connection_set_exit_on_disconnect(conn, 0);
        self.conn = conn;
        const r = c.dbus_bus_request_name(conn, "org.freedesktop.Notifications", c.DBUS_NAME_FLAG_DO_NOT_QUEUE, errp);
        if (r != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
            std.log.info("notify: 既に別の通知デーモンが動いています。ame-shell の通知サーバは無効にします", .{});
            c.dbus_error_free(errp);
        } else {
            self.owner = true;
        }
        var fd: c_int = -1;
        if (c.dbus_connection_get_unix_fd(conn, &fd) != 0 and fd >= 0) {
            self.dbus_fd = fd;
            self.app.loop.add(fd, c.EPOLLIN, self, onDbus) catch {};
        }
    }

    /// 他モジュール(media)も同じ接続でメソッド呼び出しできるように公開
    pub fn connection(self: *Notifs) ?*c.DBusConnection {
        return self.conn;
    }

    fn onDbus(ctx: *anyopaque, _: c_int, events: u32) void {
        const self: *Notifs = @ptrCast(@alignCast(ctx));
        const conn = self.conn orelse return;
        if (events & (c.EPOLLHUP | c.EPOLLERR) != 0) {
            self.app.loop.remove(self.dbus_fd);
            return;
        }
        _ = c.dbus_connection_read_write(conn, 0);
        while (c.dbus_connection_pop_message(conn)) |msg| {
            defer c.dbus_message_unref(msg);
            self.handleMessage(msg);
        }
        c.dbus_connection_flush(conn);
    }

    fn handleMessage(self: *Notifs, msg: *c.DBusMessage) void {
        if (!self.owner) return;
        const conn = self.conn.?;
        const NS = "org.freedesktop.Notifications";
        if (c.dbus_message_is_method_call(msg, "org.freedesktop.DBus.Introspectable", "Introspect") != 0) {
            const reply = c.dbus_message_new_method_return(msg) orelse return;
            defer c.dbus_message_unref(reply);
            var s: [*c]const u8 = introspect_xml;
            _ = c.dbus_message_append_args(reply, c.DBUS_TYPE_STRING, &s, c.DBUS_TYPE_INVALID);
            _ = c.dbus_connection_send(conn, reply, null);
        } else if (c.dbus_message_is_method_call(msg, NS, "GetCapabilities") != 0) {
            const reply = c.dbus_message_new_method_return(msg) orelse return;
            defer c.dbus_message_unref(reply);
            var it: c.DBusMessageIter = undefined;
            var arr: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(reply, &it);
            _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "s", &arr);
            for ([_][*c]const u8{ "body", "actions", "persistence" }) |cap| {
                var p = cap;
                _ = c.dbus_message_iter_append_basic(&arr, c.DBUS_TYPE_STRING, @ptrCast(&p));
            }
            _ = c.dbus_message_iter_close_container(&it, &arr);
            _ = c.dbus_connection_send(conn, reply, null);
        } else if (c.dbus_message_is_method_call(msg, NS, "GetServerInformation") != 0) {
            const reply = c.dbus_message_new_method_return(msg) orelse return;
            defer c.dbus_message_unref(reply);
            var a: [*c]const u8 = "ame-shell";
            var b: [*c]const u8 = "ame";
            var v: [*c]const u8 = "0.1.0";
            var sv: [*c]const u8 = "1.2";
            _ = c.dbus_message_append_args(reply, c.DBUS_TYPE_STRING, &a, c.DBUS_TYPE_STRING, &b, c.DBUS_TYPE_STRING, &v, c.DBUS_TYPE_STRING, &sv, c.DBUS_TYPE_INVALID);
            _ = c.dbus_connection_send(conn, reply, null);
        } else if (c.dbus_message_is_method_call(msg, NS, "CloseNotification") != 0) {
            var id: u32 = 0;
            var it: c.DBusMessageIter = undefined;
            if (c.dbus_message_iter_init(msg, &it) != 0 and c.dbus_message_iter_get_arg_type(&it) == c.DBUS_TYPE_UINT32)
                c.dbus_message_iter_get_basic(&it, &id);
            self.dismiss(id, 3);
            const reply = c.dbus_message_new_method_return(msg) orelse return;
            defer c.dbus_message_unref(reply);
            _ = c.dbus_connection_send(conn, reply, null);
        } else if (c.dbus_message_is_method_call(msg, NS, "Notify") != 0) {
            const id = self.handleNotify(msg);
            const reply = c.dbus_message_new_method_return(msg) orelse return;
            defer c.dbus_message_unref(reply);
            var v = id;
            _ = c.dbus_message_append_args(reply, c.DBUS_TYPE_UINT32, &v, c.DBUS_TYPE_INVALID);
            _ = c.dbus_connection_send(conn, reply, null);
        }
    }

    fn handleNotify(self: *Notifs, msg: *c.DBusMessage) u32 {
        var it: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(msg, &it) == 0) return 0;
        var app_name: [*c]const u8 = "";
        var replaces: u32 = 0;
        var summary: [*c]const u8 = "";
        var body: [*c]const u8 = "";
        var expire: i32 = -1;
        var has_default = false;
        var urgency: u8 = 1;
        var idx: usize = 0;
        while (true) : (idx += 1) {
            const t = c.dbus_message_iter_get_arg_type(&it);
            if (t == c.DBUS_TYPE_INVALID) break;
            switch (idx) {
                0 => if (t == c.DBUS_TYPE_STRING) c.dbus_message_iter_get_basic(&it, @ptrCast(&app_name)),
                1 => if (t == c.DBUS_TYPE_UINT32) c.dbus_message_iter_get_basic(&it, &replaces),
                3 => if (t == c.DBUS_TYPE_STRING) c.dbus_message_iter_get_basic(&it, @ptrCast(&summary)),
                4 => if (t == c.DBUS_TYPE_STRING) c.dbus_message_iter_get_basic(&it, @ptrCast(&body)),
                5 => if (t == c.DBUS_TYPE_ARRAY) {
                    // actions: [key, label, key, label, ...]。"default" があればクリックで発火
                    var sub: c.DBusMessageIter = undefined;
                    c.dbus_message_iter_recurse(&it, &sub);
                    var k: usize = 0;
                    while (c.dbus_message_iter_get_arg_type(&sub) == c.DBUS_TYPE_STRING) : (k += 1) {
                        var s: [*c]const u8 = null;
                        c.dbus_message_iter_get_basic(&sub, @ptrCast(&s));
                        if (k % 2 == 0 and std.mem.eql(u8, std.mem.sliceTo(s, 0), "default")) has_default = true;
                        _ = c.dbus_message_iter_next(&sub);
                    }
                },
                6 => if (t == c.DBUS_TYPE_ARRAY) {
                    // hints: a{sv} から urgency(byte) だけ読む
                    var sub: c.DBusMessageIter = undefined;
                    c.dbus_message_iter_recurse(&it, &sub);
                    while (c.dbus_message_iter_get_arg_type(&sub) == c.DBUS_TYPE_DICT_ENTRY) {
                        var entry: c.DBusMessageIter = undefined;
                        c.dbus_message_iter_recurse(&sub, &entry);
                        var key: [*c]const u8 = null;
                        c.dbus_message_iter_get_basic(&entry, @ptrCast(&key));
                        if (std.mem.eql(u8, std.mem.sliceTo(key, 0), "urgency")) {
                            _ = c.dbus_message_iter_next(&entry);
                            var variant: c.DBusMessageIter = undefined;
                            c.dbus_message_iter_recurse(&entry, &variant);
                            if (c.dbus_message_iter_get_arg_type(&variant) == c.DBUS_TYPE_BYTE) c.dbus_message_iter_get_basic(&variant, &urgency);
                        }
                        _ = c.dbus_message_iter_next(&sub);
                    }
                },
                7 => if (t == c.DBUS_TYPE_INT32) c.dbus_message_iter_get_basic(&it, &expire),
                else => {},
            }
            _ = c.dbus_message_iter_next(&it);
        }
        var timeout: u32 = self.app.cfg.notify_timeout_ms;
        if (expire > 0) timeout = @intCast(expire) else if (expire == 0 or urgency == 2) timeout = 0;
        return self.postFull(std.mem.sliceTo(app_name, 0), std.mem.sliceTo(summary, 0), std.mem.sliceTo(body, 0), replaces, timeout, urgency, has_default);
    }

    /// ローカルから通知を出す(ame-ctl notify、ロック不可の警告など)
    pub fn post(self: *Notifs, app_name: []const u8, summary: []const u8, body: []const u8, replaces: u32) void {
        _ = self.postFull(app_name, summary, body, replaces, self.app.cfg.notify_timeout_ms, 1, false);
    }

    fn postFull(self: *Notifs, app_name: []const u8, summary: []const u8, body: []const u8, replaces: u32, timeout: u32, urgency: u8, has_default: bool) u32 {
        var n = Notif{ .id = 0, .urgency = urgency, .has_default_action = has_default };
        copyTo(&n.app_name, &n.app_len, app_name);
        copyTo(&n.summary, &n.sum_len, summary);
        copyTo(&n.body, &n.body_len, body);
        n.expire_at = if (timeout > 0) loop.nowMs() + timeout else 0;
        _ = @import("bar.zig").formatClock(&n.time_str, true, false);
        n.height = if (n.body_len > 0) 104 else 74;

        // 置き換え(同じ ID が表示中なら中身だけ差し替え、位置はそのまま)
        if (replaces != 0) {
            for (self.active.items) |*a| if (a.id == replaces and !a.leaving) {
                n.id = replaces;
                n.slide = a.slide;
                n.ypos = a.ypos;
                a.* = n;
                self.armTimer();
                if (self.surf) |s| s.schedule();
                return replaces;
            };
        }
        n.id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        n.slide.snap(1);
        n.slide.set(0);
        n.ypos.snap(-20); // 少し上から落ちてくる
        // 古いものから溢れた分を退場させる
        var visible: usize = 0;
        for (self.active.items) |a| if (!a.leaving) {
            visible += 1;
        };
        if (visible >= MAX_CARDS) {
            for (self.active.items) |*a| if (!a.leaving) {
                a.leaving = true;
                a.slide.set(1);
                break;
            };
        }
        self.active.insert(0, n) catch return 0;
        // 履歴(通知センター用)
        self.history.insert(0, n) catch {};
        if (self.history.items.len > HISTORY) _ = self.history.pop();
        self.unread += 1;
        // 通知停止中(ダッシュボードのトグル)は履歴にだけ残し、ポップアップは出さない
        if (self.app.dashboard.dnd and urgency < 2) {
            _ = self.active.orderedRemove(0);
            self.app.dashboard.dataChanged();
            return n.id;
        }
        self.layout();
        self.ensureSurface();
        self.armTimer();
        self.app.dashboard.dataChanged();
        return n.id;
    }

    fn layout(self: *Notifs) void {
        var y: f32 = 0;
        for (self.active.items) |*a| {
            if (a.leaving) continue;
            a.ypos.set(y);
            y += a.height + 10;
        }
    }

    /// reason: 1=期限切れ 2=ユーザーが閉じた 3=CloseNotification
    pub fn dismiss(self: *Notifs, id: u32, reason: u32) void {
        for (self.active.items) |*a| if (a.id == id and !a.leaving) {
            a.leaving = true;
            a.slide.set(1);
            self.emitClosed(id, reason);
        };
        self.layout();
        if (self.surf) |s| s.schedule();
        if (self.app.cfg.layout == .caelestia) self.app.redrawBars();
    }

    pub fn clearAll(self: *Notifs) void {
        for (self.active.items) |a| if (!a.leaving) self.dismiss(a.id, 2);
        self.history.clearRetainingCapacity();
        self.unread = 0;
        self.app.dashboard.dataChanged();
    }

    pub fn toggleCenter(self: *Notifs) void {
        self.unread = 0;
        if (self.app.activeFrame()) |f| {
            f.toggleSidebar();
            return;
        }
        self.app.dashboard.toggle();
    }

    fn emitClosed(self: *Notifs, id: u32, reason: u32) void {
        if (!self.owner) return;
        const conn = self.conn orelse return;
        const sig = c.dbus_message_new_signal("/org/freedesktop/Notifications", "org.freedesktop.Notifications", "NotificationClosed") orelse return;
        defer c.dbus_message_unref(sig);
        var i = id;
        var r = reason;
        _ = c.dbus_message_append_args(sig, c.DBUS_TYPE_UINT32, &i, c.DBUS_TYPE_UINT32, &r, c.DBUS_TYPE_INVALID);
        _ = c.dbus_connection_send(conn, sig, null);
        c.dbus_connection_flush(conn);
    }

    fn emitAction(self: *Notifs, id: u32, key: [*c]const u8) void {
        if (!self.owner) return;
        const conn = self.conn orelse return;
        const sig = c.dbus_message_new_signal("/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked") orelse return;
        defer c.dbus_message_unref(sig);
        var i = id;
        var k = key;
        _ = c.dbus_message_append_args(sig, c.DBUS_TYPE_UINT32, &i, c.DBUS_TYPE_STRING, &k, c.DBUS_TYPE_INVALID);
        _ = c.dbus_connection_send(conn, sig, null);
        c.dbus_connection_flush(conn);
    }

    /// 次に期限が来る通知の時刻にタイマーを合わせる(毎秒チェックしない)
    fn armTimer(self: *Notifs) void {
        var next: u64 = 0;
        for (self.active.items) |a| {
            if (a.leaving or a.expire_at == 0) continue;
            if (next == 0 or a.expire_at < next) next = a.expire_at;
        }
        if (next == 0) {
            self.timer.disarm();
            return;
        }
        const now = loop.nowMs();
        self.timer.arm(if (next > now) next - now else 1, 0);
    }

    fn onTimer(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *Notifs = @ptrCast(@alignCast(ctx));
        self.timer.ack();
        const now = loop.nowMs();
        for (self.active.items, 0..) |a, i| {
            if (a.leaving or a.expire_at == 0 or a.expire_at > now) continue;
            // マウスが乗っている通知は消さない(読んでいる最中)
            if (self.hover_idx == i) continue;
            self.dismiss(a.id, 1);
        }
        self.armTimer();
    }

    fn ensureSurface(self: *Notifs) void {
        // caelestia: 通知は枠の右上のドロワーに描く(専用サーフェスは作らない)
        if (self.app.cfg.layout == .caelestia) {
            self.app.redrawBars();
            return;
        }
        if (self.surf != null) {
            self.surf.?.schedule();
            return;
        }
        const app = self.app;
        const out = app.activeOutput() orelse return;
        self.out = out;
        const top = app.cfg.bar_position == .top;
        const bar_space: i32 = @intFromFloat(app.cfg.bar_height + app.cfg.bar_margin);
        self.surf = Surface.createLayer(app, .{ .ctx = self, .draw = draw, .pointer = pointer, .configured = configured }, .{
            .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            .anchor = @intCast(c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT | (if (top) c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP else c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM)),
            .width = SW,
            .height = SH,
            .margin = if (top) .{ 4, 0, 0, 0 } else .{ 0, 0, 4, 0 },
            .namespace = "ame-notifications",
            .output = out.wl,
        }) catch return;
        _ = bar_space;
        self.surf.?.output = out;
        self.surf.?.setInputRect(0, 0, 0, 0);
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        const self: *Notifs = @ptrCast(@alignCast(ctx));
        const o = self.out orelse return;
        const sz = o.logicalSize();
        const top = self.app.cfg.bar_position == .top;
        s.origin = .{ @as(f32, @floatFromInt(sz[0])) - SW, if (top) 4 else @as(f32, @floatFromInt(sz[1])) - SH - 4 };
    }

    pub fn reap(self: *Notifs) void {
        // 退場が終わったカードを片付け、何も無ければサーフェスごと消す
        var i: usize = 0;
        while (i < self.active.items.len) {
            const a = self.active.items[i];
            if (a.leaving and a.slide.x > 0.98) _ = self.active.orderedRemove(i) else i += 1;
        }
        if (self.active.items.len == 0) {
            if (self.surf) |s| s.destroy();
            self.surf = null;
            self.out = null;
            self.hover_idx = null;
        }
    }

    pub fn backdropChanged(self: *Notifs) void {
        if (self.surf) |s| s.schedule();
    }

    pub fn outputRemoved(self: *Notifs, o: *Output) void {
        if (self.out == o) {
            if (self.surf) |s| s.destroy();
            self.surf = null;
            self.out = null;
        }
    }

    fn cardY(self: *Notifs, a: *const Notif) f32 {
        _ = self;
        return 50 + a.ypos.x;
    }

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *Notifs = @ptrCast(@alignCast(ctx));
        const app = self.app;
        var animating = theme.accentAnimating();
        var need_reap = false;
        for (self.active.items) |*a| {
            if (a.slide.step(dt)) animating = true;
            if (a.ypos.step(dt)) animating = true;
            if (a.leaving and a.slide.x > 0.98) need_reap = true;
        }
        if (need_reap) app.reap_pending = true;

        const acc = theme.accent(app);
        const txt = theme.text(app);
        const sub = theme.subtext(app);
        const gl = theme.glassStrong(app);
        const x0 = @as(f32, @floatFromInt(s.width)) - CARD_W - 16;
        // 入力領域 = 表示中カードの外接矩形(それ以外はクリック透過)
        var max_y: f32 = 0;
        for (self.active.items, 0..) |*a, i| {
            const t = a.slide.x;
            if (t > 0.99) continue;
            const y = self.cardY(a);
            const h = a.height;
            const crit = a.urgency == 2;
            const col = if (crit) Color.hex(0xff7a90) else acc;
            cv.save();
            cv.translate(t * (CARD_W + 40), 0);
            cv.opacity(1 - t);
            const hv: f32 = if (self.hover_idx == i) 1 else 0;
            cv.shadow(x0, y + 6, CARD_W, h, 18, 18, theme.shadow());
            cv.glass(x0, y, CARD_W, h, 18, gl);
            // 左端のアクセントの帯
            cv.rectGrad(x0 + 10, y + 14, 3, h - 28, 1.5, col.lighten(0.3), col);
            if (hv > 0) cv.rectBorder(x0, y, CARD_W, h, 18, .{ .a = 0 }, col.alpha(0.6), 1.2);
            _ = cv.text(x0 + 26, y + 26, 12.5, col, a.appName(), .{ .bold = true, .max_w = CARD_W - 120 });
            _ = cv.text(x0 + CARD_W - 18, y + 26, 12, sub, a.time_str[0..5], .{ .alignment = .right });
            _ = cv.text(x0 + 26, y + 50, 16, txt, a.summaryText(), .{ .bold = true, .max_w = CARD_W - 50 });
            if (a.body_len > 0) {
                cv.textWrap(x0 + 26, y + 73, 13.5, sub, a.bodyText(), CARD_W - 50, 2, 19);
            }
            cv.restore();
            max_y = @max(max_y, y + h + 6);
        }
        s.setInputRect(@intFromFloat(x0), 50, @intFromFloat(CARD_W), @intFromFloat(@max(0, max_y - 50)));
        return animating;
    }

    fn hitCard(self: *Notifs, s: *Surface, x: f32, y: f32) ?usize {
        const x0 = @as(f32, @floatFromInt(s.width)) - CARD_W - 16;
        if (x < x0 or x > x0 + CARD_W) return null;
        for (self.active.items, 0..) |*a, i| {
            if (a.leaving) continue;
            const cy = self.cardY(a);
            if (y >= cy and y <= cy + a.height) return i;
        }
        return null;
    }

    fn pointer(ctx: *anyopaque, s: *Surface, ev: surface.PointerEvent) void {
        const self: *Notifs = @ptrCast(@alignCast(ctx));
        const h = if (ev.kind == .leave) null else self.hitCard(s, ev.x, ev.y);
        if (h != self.hover_idx) {
            self.hover_idx = h;
            s.schedule();
            if (h == null) self.onTimerCheck();
        }
        if (ev.kind == .press) {
            const i = h orelse return;
            const a = self.active.items[i];
            if (ev.button == 0x110 and a.has_default_action) self.emitAction(a.id, "default");
            self.dismiss(a.id, 2);
        }
    }

    fn onTimerCheck(self: *Notifs) void {
        // ホバーで止めていた期限切れを、離れたときに処理する
        self.armTimer();
    }
};

const introspect_xml =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node name="/org/freedesktop/Notifications">
    \\ <interface name="org.freedesktop.Notifications">
    \\  <method name="GetCapabilities"><arg direction="out" type="as"/></method>
    \\  <method name="Notify">
    \\   <arg direction="in" type="s"/><arg direction="in" type="u"/><arg direction="in" type="s"/>
    \\   <arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="in" type="as"/>
    \\   <arg direction="in" type="a{sv}"/><arg direction="in" type="i"/><arg direction="out" type="u"/>
    \\  </method>
    \\  <method name="CloseNotification"><arg direction="in" type="u"/></method>
    \\  <method name="GetServerInformation">
    \\   <arg direction="out" type="s"/><arg direction="out" type="s"/><arg direction="out" type="s"/><arg direction="out" type="s"/>
    \\  </method>
    \\  <signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
    \\  <signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
    \\ </interface>
    \\</node>
;
