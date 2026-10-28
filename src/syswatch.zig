// 電源・ネットワーク・Bluetooth の変化を「起きたときに」知る(定期的に調べに行かない)。
//
//   電源・ネットワーク・USB: Linux はカーネルの uevent(netlink)。AC アダプタの抜き差し・充電の開始/停止・
//                      インターフェースの up/down・USB の機器の抜き差しで届く。
//                      FreeBSD は devd のソケット(/var/run/devd.seqpacket.pipe)の ACPI・IFNET・USB の知らせ。
//   Wi-Fi・Bluetooth : システムの D-Bus の NetworkManager / BlueZ のシグナル(PropertiesChanged など)。
//
// USB の機器の抜き差しと、バッテリーの残りが少なくなったこと(20% / 10% / 5%)は通知で知らせる。
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
    devd_fd: c_int = -1,
    /// バッテリーの通知: 0 = まだ / 1 = 20% / 2 = 10% / 3 = 5% を知らせた(電源につなぐと 0 に戻る)
    bat_level: u8 = 0,
    bat_notif: u32 = 0,
    /// 接続中の USB 機器の名前(抜いたときに名前を出すため。キーは sysfs の DEVPATH / FreeBSD の ugenX.Y)
    usb: [24]UsbDev = [_]UsbDev{.{}} ** 24,

    pub fn create(app: *App) !*SysWatch {
        const self = try app.alloc.create(SysWatch);
        self.* = .{ .app = app, .debounce = try loop.Timer.init() };
        try app.loop.add(self.debounce.fd, c.EPOLLIN, self, onDebounce);
        if (builtin.os.tag == .linux) {
            self.openUevent();
            self.seedUsb();
        }
        if (builtin.os.tag == .freebsd) self.openDevd();
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
            if (std.mem.indexOf(u8, msg, "SUBSYSTEM=usb\x00") != null) self.usbUevent(msg);
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
            if (self.wifiEnabled()) |on| app.dashboard.store.wifi_on = @intFromBool(on);
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
    /// (FreeBSD に BlueZ は無い。Bluetooth は netgraph + hcsecd)
    pub fn bluezRunning(self: *SysWatch) bool {
        if (builtin.os.tag == .freebsd) return false;
        const conn = self.conn orelse return sys.hasCommand("bluetoothctl");
        return c.dbus_bus_name_has_owner(conn, "org.bluez", null) != 0;
    }

    /// アダプタの電源が入っているか(FreeBSD: ng_ubt が付いたアダプタがあるか)
    pub fn btPowered(self: *SysWatch) bool {
        if (builtin.os.tag == .freebsd) {
            var b: [256]u8 = undefined;
            return sys.run(&.{ "sysctl", "-n", "dev.ubt.0.%desc" }, &b) != null;
        }
        if (!self.bluezRunning()) return false;
        var out: [512]u8 = undefined;
        const s = sys.run(&.{ "bluetoothctl", "show" }, &out) orelse return false;
        return std.mem.indexOf(u8, s, "Powered: yes") != null;
    }

    /// Wi-Fi が使える状態か(Linux: NetworkManager のラジオ / FreeBSD: wpa_supplicant が切断状態でない)
    pub fn wifiEnabled(_: *SysWatch) ?bool {
        var out: [1024]u8 = undefined;
        if (builtin.os.tag == .freebsd) {
            const s = sys.run(&.{ "wpa_cli", "status" }, &out) orelse return null;
            const i = std.mem.indexOf(u8, s, "wpa_state=") orelse return null;
            const st = s[i + 10 ..];
            return !(std.mem.startsWith(u8, st, "DISCONNECTED") or std.mem.startsWith(u8, st, "INTERFACE_DISABLED"));
        }
        const s = sys.run(&.{ "nmcli", "radio", "wifi" }, &out) orelse return null;
        return std.mem.startsWith(u8, s, "enabled");
    }

    // ---------------- バッテリーの通知 ----------------

    /// 電源の状態を読み直した後に呼ぶ(App.refreshSys)。残りが 20% / 10% / 5% を下回ったら 1 回ずつ知らせ、
    /// 10% 以下は消すまで残る緊急の通知にする。電源につないだら通知を消して数え直す
    pub fn checkBattery(self: *SysWatch) void {
        const app = self.app;
        const b = app.sys.battery;
        if (!app.cfg.notify_battery or !b.present) return;
        if (b.on_ac) {
            if (self.bat_notif != 0) app.notifs.dismiss(self.bat_notif, 3);
            self.bat_notif = 0;
            self.bat_level = 0;
            return;
        }
        const lvl: u8 = if (b.percent <= 5) 3 else if (b.percent <= 10) 2 else if (b.percent <= 20) 1 else 0;
        if (lvl <= self.bat_level) return;
        self.bat_level = lvl;
        var sb: [96]u8 = undefined;
        var tb: [48]u8 = undefined;
        var bb: [200]u8 = undefined;
        const summary = std.fmt.bufPrint(&sb, "バッテリーの残りが {d}% です", .{b.percent}) catch "バッテリーの残りが少なくなっています";
        const t = @import("bar.zig").batteryTime(&tb, b);
        const advice: []const u8 = switch (lvl) {
            1 => "電源につなぐと安心です",
            2 => "そろそろ電源につないでください",
            else => "まもなく電源が切れます。作業を保存して、電源につないでください",
        };
        const body = (if (t.len > 0) std.fmt.bufPrint(&bb, "{s}({s})", .{ advice, t }) else std.fmt.bufPrint(&bb, "{s}", .{advice})) catch advice;
        self.bat_notif = app.notifs.postUrgency("バッテリー", summary, body, self.bat_notif, if (lvl >= 2) 2 else 1);
    }

    // ---------------- USB(Linux: uevent) ----------------

    /// 起動時に挿さっている機器を覚えておく(抜いたときに名前を出すため)
    fn seedUsb(self: *SysWatch) void {
        var dir = std.fs.cwd().openDir("/sys/bus/usb/devices", .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            var pb: [256]u8 = undefined;
            const link = std.fmt.bufPrint(&pb, "/sys/bus/usb/devices/{s}", .{ent.name}) catch continue;
            var rb: [512]u8 = undefined;
            const real = std.fs.cwd().realpath(link, &rb) catch continue;
            if (!std.mem.startsWith(u8, real, "/sys")) continue;
            var nb: [128]u8 = undefined;
            const info = usbInfo(real[4..], &nb) orelse continue;
            self.usbRemember(real[4..], info.name);
        }
        var n: usize = 0;
        for (self.usb) |u| n += @intFromBool(u.key_len > 0);
        std.log.info("syswatch: USB の機器 {d} 台(ハブ・内蔵を除く)", .{n});
    }

    const UsbInfo = struct { name: []const u8, kind: []const u8 };

    /// sysfs から機器の名前と種類。ハブと、ノート PC に内蔵の機器(removable = fixed)は null
    fn usbInfo(devpath: []const u8, nb: []u8) ?UsbInfo {
        var pb: [384]u8 = undefined;
        var vb: [96]u8 = undefined;
        var mb: [96]u8 = undefined;
        const attr = struct {
            fn get(p: []u8, dp: []const u8, name: []const u8, out: []u8) ?[]const u8 {
                const path = std.fmt.bufPrintZ(p, "/sys{s}/{s}", .{ dp, name }) catch return null;
                return sys.readFile(path, out);
            }
        }.get;
        const cls = attr(&pb, devpath, "bDeviceClass", &vb) orelse return null;
        if (std.mem.eql(u8, cls, "09")) return null; // ハブ
        if (attr(&pb, devpath, "removable", &vb)) |r| if (std.mem.eql(u8, r, "fixed")) return null;
        const vendor = attr(&pb, devpath, "manufacturer", &mb) orelse "";
        var prb: [96]u8 = undefined;
        const product = attr(&pb, devpath, "product", &prb) orelse "";
        var name: []const u8 = undefined;
        if (product.len > 0) {
            name = (if (vendor.len > 0 and std.mem.indexOf(u8, product, vendor) == null)
                std.fmt.bufPrint(nb, "{s} {s}", .{ vendor, product })
            else
                std.fmt.bufPrint(nb, "{s}", .{product})) catch product;
        } else {
            var ib: [16]u8 = undefined;
            var pib: [16]u8 = undefined;
            const vid = attr(&pb, devpath, "idVendor", &ib) orelse "?";
            const pid = attr(&pb, devpath, "idProduct", &pib) orelse "?";
            name = std.fmt.bufPrint(nb, "USB 機器({s}:{s})", .{ vid, pid }) catch "USB 機器";
        }
        // 最初のインターフェースの種類(ストレージ・入力・音声・映像)
        var kb: [16]u8 = undefined;
        const base = std.fs.path.basename(devpath);
        var ip: [128]u8 = undefined;
        const iface = std.fmt.bufPrint(&ip, "{s}:1.0/bInterfaceClass", .{base}) catch "";
        const icls = attr(&pb, devpath, iface, &kb) orelse cls;
        const kind: []const u8 = if (std.mem.eql(u8, icls, "08")) "ストレージ" else if (std.mem.eql(u8, icls, "03")) "入力機器" else if (std.mem.eql(u8, icls, "01")) "オーディオ機器" else if (std.mem.eql(u8, icls, "0e")) "カメラ" else if (std.mem.eql(u8, icls, "e0")) "無線の機器" else if (std.mem.eql(u8, icls, "02") or std.mem.eql(u8, icls, "0a")) "通信機器" else "USB 機器";
        return .{ .name = name, .kind = kind };
    }

    fn ueventField(msg: []const u8, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, msg, 0);
        while (it.next()) |kv| {
            if (kv.len > key.len and std.mem.startsWith(u8, kv, key) and kv[key.len] == '=') return kv[key.len + 1 ..];
        }
        return null;
    }

    pub fn usbUeventPub(self: *SysWatch, msg: []const u8) void {
        self.usbUevent(msg);
    }

    fn usbUevent(self: *SysWatch, msg: []const u8) void {
        if (!self.app.cfg.notify_usb) return;
        const devtype = ueventField(msg, "DEVTYPE") orelse return;
        if (!std.mem.eql(u8, devtype, "usb_device")) return;
        const action = ueventField(msg, "ACTION") orelse return;
        const devpath = ueventField(msg, "DEVPATH") orelse return;
        if (std.mem.eql(u8, action, "add")) {
            var nb: [128]u8 = undefined;
            const info = usbInfo(devpath, &nb) orelse return;
            self.usbRemember(devpath, info.name);
            var sb: [96]u8 = undefined;
            self.app.notifs.post("USB", std.fmt.bufPrint(&sb, "{s}を接続しました", .{info.kind}) catch "USB 機器を接続しました", info.name, 0);
        } else if (std.mem.eql(u8, action, "remove")) {
            const name = self.usbForget(devpath) orelse return; // 覚えていない = ハブ・内蔵の機器
            self.app.notifs.post("USB", "USB 機器を取り外しました", name, 0);
        }
    }

    const UsbDev = struct {
        key: [96]u8 = undefined,
        key_len: usize = 0,
        name: [128]u8 = undefined,
        name_len: usize = 0,
    };

    fn usbRemember(self: *SysWatch, key: []const u8, name: []const u8) void {
        var slot: ?*UsbDev = null;
        for (&self.usb) |*u| {
            if (u.key_len > 0 and std.mem.eql(u8, u.key[0..u.key_len], key)) {
                slot = u;
                break;
            }
            if (slot == null and u.key_len == 0) slot = u;
        }
        const u = slot orelse &self.usb[0];
        u.key_len = @min(key.len, u.key.len);
        @memcpy(u.key[0..u.key_len], key[0..u.key_len]);
        u.name_len = @min(name.len, u.name.len);
        @memcpy(u.name[0..u.name_len], name[0..u.name_len]);
    }

    /// 覚えていた名前を返して忘れる(返り値は次の usbRemember まで有効)
    fn usbForget(self: *SysWatch, key: []const u8) ?[]const u8 {
        for (&self.usb) |*u| if (u.key_len > 0 and std.mem.eql(u8, u.key[0..u.key_len], key)) {
            u.key_len = 0;
            return u.name[0..u.name_len];
        };
        return null;
    }

    // ---------------- FreeBSD: devd ----------------

    fn openDevd(self: *SysWatch) void {
        const fd = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
        if (fd < 0) return;
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        const path = "/var/run/devd.seqpacket.pipe";
        @memcpy(addr.sun_path[0..path.len], path);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
            std.log.info("syswatch: devd に接続できません(電源・USB の変化は 20 秒ごとに調べます)", .{});
            _ = c.close(fd);
            return;
        }
        self.devd_fd = fd;
        self.app.loop.add(fd, c.EPOLLIN, self, onDevd) catch {};
    }

    /// devd の知らせ: "!system=USB subsystem=DEVICE type=ATTACH ugen=ugen0.2 vendor=0x046d product=0xc52b devclass=0x00 …"
    fn onDevd(ctx: *anyopaque, fd: c_int, events: u32) void {
        const self: *SysWatch = @ptrCast(@alignCast(ctx));
        if (events & (c.EPOLLHUP | c.EPOLLERR) != 0) {
            self.app.loop.remove(fd);
            _ = c.close(fd);
            self.devd_fd = -1;
            return;
        }
        var buf: [2048]u8 = undefined;
        while (true) {
            const n = c.recv(fd, &buf, buf.len, 0);
            if (n <= 0) break;
            const msg = std.mem.trim(u8, buf[0..@intCast(n)], " \n");
            if (msg.len == 0 or msg[0] != '!') continue;
            const system = devdField(msg, "system") orelse continue;
            if (std.mem.eql(u8, system, "ACPI")) {
                const sub = devdField(msg, "subsystem") orelse "";
                if (std.mem.eql(u8, sub, "ACAD") or std.mem.eql(u8, sub, "CMBAT")) self.mark(.power);
            } else if (std.mem.eql(u8, system, "IFNET")) {
                self.mark(.net);
            } else if (std.mem.eql(u8, system, "USB") and self.app.cfg.notify_usb) {
                const sub = devdField(msg, "subsystem") orelse "";
                if (!std.mem.eql(u8, sub, "DEVICE")) continue;
                const typ = devdField(msg, "type") orelse "";
                const ugen = devdField(msg, "ugen") orelse continue;
                if (std.mem.eql(u8, typ, "ATTACH")) {
                    if (std.mem.eql(u8, devdField(msg, "devclass") orelse "", "0x09")) continue; // ハブ
                    var nb: [128]u8 = undefined;
                    const name = usbconfigName(ugen, &nb) orelse (std.fmt.bufPrint(&nb, "USB 機器({s}:{s})", .{ devdField(msg, "vendor") orelse "?", devdField(msg, "product") orelse "?" }) catch "USB 機器");
                    self.usbRemember(ugen, name);
                    self.app.notifs.post("USB", "USB 機器を接続しました", name, 0);
                } else if (std.mem.eql(u8, typ, "DETACH")) {
                    const name = self.usbForget(ugen) orelse continue;
                    self.app.notifs.post("USB", "USB 機器を取り外しました", name, 0);
                }
            }
        }
    }

    fn devdField(msg: []const u8, key: []const u8) ?[]const u8 {
        var it = std.mem.tokenizeAny(u8, msg[1..], " ");
        while (it.next()) |kv| {
            if (kv.len > key.len and std.mem.startsWith(u8, kv, key) and kv[key.len] == '=') return std.mem.trim(u8, kv[key.len + 1 ..], "\"");
        }
        return null;
    }

    /// usbconfig の 1 行目 "ugen0.2: <Logitech USB Receiver> at usbus0, …" から名前(読めなければ null)
    fn usbconfigName(ugen: []const u8, nb: []u8) ?[]const u8 {
        var ub: [32]u8 = undefined;
        const u = std.fmt.bufPrintZ(&ub, "{s}", .{ugen}) catch return null;
        var out: [512]u8 = undefined;
        const s = sys.run(&.{ "usbconfig", "-d", u.ptr }, &out) orelse return null;
        const a = std.mem.indexOfScalar(u8, s, '<') orelse return null;
        const b = std.mem.indexOfScalarPos(u8, s, a, '>') orelse return null;
        const name = std.mem.trim(u8, s[a + 1 .. b], " ");
        if (name.len == 0) return null;
        return std.fmt.bufPrint(nb, "{s}", .{name}) catch null;
    }
};
