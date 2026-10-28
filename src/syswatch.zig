// 電源・ネットワーク・Bluetooth の変化を「起きたときに」知る(定期的に調べに行かない)。
//
//   電源・ネットワーク: カーネルの uevent(netlink、Linux のみ)。AC アダプタの抜き差し・充電の開始/停止・
//                      インターフェースの up/down で届く。FreeBSD は従来どおり 20 秒ごと(app.sys_timer)。
//   Wi-Fi・Bluetooth : システムの D-Bus の NetworkManager / BlueZ のシグナル(PropertiesChanged など)。
//
// シグナルは続けて来る(スキャン中・接続の途中)ので、150 ms まとめてから 1 回だけ読み直す。
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const App = @import("app.zig").App;
const loop = @import("platform/loop.zig");
const sys = @import("platform/sys.zig");
const netpanel = @import("frame/netpanel.zig");

/// libdbus の DBusError と同じレイアウト(notify.zig と同じ理由)
const DBusError = extern struct { name: ?[*:0]const u8 = null, message: ?[*:0]const u8 = null, dummy: c_uint = 0, padding1: ?*anyopaque = null };

pub const SysWatch = struct {
    app: *App,
    uevent_fd: c_int = -1,
    conn: ?*c.DBusConnection = null,
    dbus_fd: c_int = -1,
    debounce: loop.Timer,
    dirty_power: bool = false,
    dirty_net: bool = false,
    dirty_bt: bool = false,

    pub fn create(app: *App) !*SysWatch {
        const self = try app.alloc.create(SysWatch);
        self.* = .{ .app = app, .debounce = try loop.Timer.init() };
        try app.loop.add(self.debounce.fd, c.EPOLLIN, self, onDebounce);
        if (builtin.os.tag == .linux) self.openUevent();
        self.openSystemBus();
        // 起動直後の状態(バーの Bluetooth のアイコンなど)。描画が落ち着いてから 1 回だけ
        self.dirty_net = true;
        self.dirty_bt = true;
        self.debounce.arm(1500, 0);
        return self;
    }

    fn openUevent(self: *SysWatch) void {
        const linux = std.os.linux;
        const fd = c.socket(linux.AF.NETLINK, c.SOCK_DGRAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, linux.NETLINK.KOBJECT_UEVENT);
        if (fd < 0) return;
        var sa = std.mem.zeroes(linux.sockaddr.nl);
        sa.family = linux.AF.NETLINK;
        sa.groups = 1; // カーネルからの uevent
        if (c.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.nl)) != 0) {
            _ = c.close(fd);
            return;
        }
        self.uevent_fd = fd;
        self.app.loop.add(fd, c.EPOLLIN, self, onUevent) catch {};
    }

    fn onUevent(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *SysWatch = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = c.recv(fd, &buf, buf.len, 0);
            if (n <= 0) break;
            // "action@devpath\0KEY=VALUE\0..."
            const msg = buf[0..@intCast(n)];
            if (std.mem.indexOf(u8, msg, "SUBSYSTEM=power_supply") != null) self.mark(.power);
            if (std.mem.indexOf(u8, msg, "SUBSYSTEM=net\x00") != null) self.mark(.net);
        }
    }

    fn openSystemBus(self: *SysWatch) void {
        var err = DBusError{};
        const errp: *c.DBusError = @ptrCast(&err);
        c.dbus_error_init(errp);
        const conn = c.dbus_bus_get_private(c.DBUS_BUS_SYSTEM, errp) orelse {
            std.log.info("syswatch: システムの D-Bus に接続できません(Wi-Fi・Bluetooth の変化は開いたときに調べます)", .{});
            c.dbus_error_free(errp);
            return;
        };
        c.dbus_connection_set_exit_on_disconnect(conn, 0);
        self.conn = conn;
        const rules = [_][*:0]const u8{
            // BlueZ: 電源・接続・ペアリング・見つかった機器
            "type='signal',sender='org.bluez'",
            // NetworkManager: 全体(Wi-Fi のオン/オフ・接続の状態)と、デバイス(つながっている AP・スキャン完了)。
            // AP ごとの電波の強さの変化(頻繁)は拾わない
            "type='signal',sender='org.freedesktop.NetworkManager',path='/org/freedesktop/NetworkManager'",
            "type='signal',sender='org.freedesktop.NetworkManager',path_namespace='/org/freedesktop/NetworkManager/Devices'",
            // デーモンの起動・終了
            "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.bluez'",
            "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.NetworkManager'",
        };
        for (rules) |r| c.dbus_bus_add_match(conn, r, null);
        c.dbus_connection_flush(conn);
        var fd: c_int = -1;
        if (c.dbus_connection_get_unix_fd(conn, &fd) != 0 and fd >= 0) {
            self.dbus_fd = fd;
            self.app.loop.add(fd, c.EPOLLIN, self, onDbus) catch {};
        }
    }

    fn onDbus(ctx: *anyopaque, fd: c_int, events: u32) void {
        const self: *SysWatch = @ptrCast(@alignCast(ctx));
        const conn = self.conn orelse return;
        if (events & (c.EPOLLHUP | c.EPOLLERR) != 0) {
            self.app.loop.remove(fd);
            self.dbus_fd = -1;
            return;
        }
        _ = c.dbus_connection_read_write(conn, 0);
        while (c.dbus_connection_pop_message(conn)) |msg| {
            defer c.dbus_message_unref(msg);
            if (c.dbus_message_get_type(msg) != c.DBUS_MESSAGE_TYPE_SIGNAL) continue;
            const path = std.mem.sliceTo(c.dbus_message_get_path(msg) orelse continue, 0);
            if (std.mem.startsWith(u8, path, "/org/bluez")) {
                self.mark(.bt);
            } else if (std.mem.startsWith(u8, path, "/org/freedesktop/NetworkManager")) {
                self.mark(.net);
            } else if (c.dbus_message_is_signal(msg, "org.freedesktop.DBus", "NameOwnerChanged") != 0) {
                var name: [*c]const u8 = null;
                if (c.dbus_message_get_args(msg, null, c.DBUS_TYPE_STRING, &name, c.DBUS_TYPE_INVALID) != 0 and name != null) {
                    if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "org.bluez")) self.mark(.bt) else self.mark(.net);
                }
            }
        }
    }

    const Kind = enum { power, net, bt };

    fn mark(self: *SysWatch, k: Kind) void {
        switch (k) {
            .power => self.dirty_power = true,
            .net => self.dirty_net = true,
            .bt => self.dirty_bt = true,
        }
        self.debounce.arm(150, 0);
    }

    fn onDebounce(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *SysWatch = @ptrCast(@alignCast(ctx));
        self.debounce.ack();
        const app = self.app;
        if (self.dirty_power or self.dirty_net) app.refreshSys(false);
        if (self.dirty_net) {
            var out: [64]u8 = undefined;
            if (sys.run(&.{ "nmcli", "radio", "wifi" }, &out)) |s| app.dashboard.store.wifi_on = @intFromBool(std.mem.startsWith(u8, s, "enabled"));
        }
        if (self.dirty_bt) {
            const on = self.btPowered();
            app.dashboard.store.bt_on = @intFromBool(on);
            for (app.outputs.items) |o| if (o.frame) |f| {
                f.bar.bt_on = on;
            };
        }
        // 開いているネットワークのパネルの一覧も新しく(キャッシュを読むだけなのですぐ終わる)
        for (app.outputs.items) |o| if (o.frame) |f| {
            if (!f.net.open) continue;
            if (self.dirty_net and f.netv.tab == 0) netpanel.refreshWifi(&f.netv, false);
            if (self.dirty_bt and f.netv.tab == 1) netpanel.refreshBt(&f.netv);
        };
        self.dirty_power = false;
        self.dirty_net = false;
        self.dirty_bt = false;
        app.redrawBars();
        if (app.dashboard.surf) |s| s.schedule();
    }

    /// BlueZ が動いているか。動いていないときに bluetoothctl を呼ぶと、デーモンを待って返ってこない
    pub fn bluezRunning(self: *SysWatch) bool {
        const conn = self.conn orelse return sys.hasCommand("bluetoothctl");
        return c.dbus_bus_name_has_owner(conn, "org.bluez", null) != 0;
    }

    /// アダプタの電源が入っているか
    pub fn btPowered(self: *SysWatch) bool {
        if (!self.bluezRunning()) return false;
        var out: [512]u8 = undefined;
        const s = sys.run(&.{ "bluetoothctl", "show" }, &out) orelse return false;
        return std.mem.indexOf(u8, s, "Powered: yes") != null;
    }
};
