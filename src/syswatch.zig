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
const netdbus = @import("platform/netdbus.zig");
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
    /// 充電器の抜き差しの通知(電源の状態の前回の値・通知の番号・満充電までの時間を出せたか)
    prev_ac: ?bool = null,
    /// 充電のアニメーション用(電池の通知を切っていても出す)
    anim_ac: ?bool = null,
    chg_notif: u32 = 0,
    chg_has_time: bool = false,
    chg_tries: u8 = 0,
    /// 挿した直後は消費電力が落ち着かず時間を出せないので、少し後にもう一度読む
    chg_timer: loop.Timer,
    /// 挿した機器: 名前・種類・ボリュームの名前がそろうまで少し待ってから知らせる(Linux)
    pend: [6]Pending = [_]Pending{.{}} ** 6,
    n_pend: usize = 0,
    pend_timer: loop.Timer,
    /// FreeBSD: 直前にディスク(USB メモリ・SD カード)が現れた時刻。USB の「接続しました」を重ねて出さないため
    bsd_disk_ms: u64 = 0,
    /// 接続中の USB 機器の名前(抜いたときに名前を出すため。キーは sysfs の DEVPATH / FreeBSD の ugenX.Y)
    usb: [24]UsbDev = [_]UsbDev{.{}} ** 24,

    pub fn create(app: *App) !*SysWatch {
        const self = try app.alloc.create(SysWatch);
        self.* = .{ .app = app, .debounce = try loop.Timer.init(), .chg_timer = try loop.Timer.init(), .pend_timer = try loop.Timer.init() };
        try app.loop.add(self.pend_timer.fd, c.EPOLLIN, self, onPend);
        try app.loop.add(self.debounce.fd, c.EPOLLIN, self, onDebounce);
        try app.loop.add(self.chg_timer.fd, c.EPOLLIN, self, onChgTimer);
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
        // socket / bind は std.posix で(glibc の transparent union の sockaddr を避ける)
        const fd = std.posix.socket(linux.AF.NETLINK, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, linux.NETLINK.KOBJECT_UEVENT) catch return;
        var sa = std.mem.zeroes(linux.sockaddr.nl);
        sa.family = linux.AF.NETLINK;
        sa.groups = 1; // カーネルからの uevent
        std.posix.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.nl)) catch {
            std.posix.close(fd);
            return;
        };
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
            if (std.mem.indexOf(u8, msg, "SUBSYSTEM=block\x00") != null) self.blockUevent(msg);
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
            // スリープの前後(logind・elogind / ConsoleKit): 戻ったらイヤホンをつなぎ直す(btresume.zig)
            "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'",
            "type='signal',interface='org.freedesktop.ConsoleKit.Manager',member='PrepareForSleep'",
            "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.bluez'",
            "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.NetworkManager'",
        };
        for (rules) |r| c.dbus_bus_add_match(conn, r, null);
        c.dbus_connection_flush(conn);
        @import("btresume.zig").init(self.app, conn);
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
            if (c.dbus_message_is_signal(msg, "org.freedesktop.login1.Manager", "PrepareForSleep") != 0 or
                c.dbus_message_is_signal(msg, "org.freedesktop.ConsoleKit.Manager", "PrepareForSleep") != 0)
            {
                var b: c.dbus_bool_t = 0;
                if (c.dbus_message_get_args(msg, null, c.DBUS_TYPE_BOOLEAN, &b, c.DBUS_TYPE_INVALID) != 0)
                    @import("btresume.zig").prepareForSleep(self.app, conn, b != 0);
                continue;
            }
            const path = std.mem.sliceTo(c.dbus_message_get_path(msg) orelse continue, 0);
            if (std.mem.startsWith(u8, path, "/org/bluez")) {
                self.mark(.bt);
                // つながった・切れた: AirPods ならカード(airpodspopup.zig)、ほかは通知(notify_usb のとき)
                if (std.mem.indexOf(u8, path, "/dev_") != null and
                    c.dbus_message_is_signal(msg, "org.freedesktop.DBus.Properties", "PropertiesChanged") != 0)
                    self.btConnectedSignal(msg, path);
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

    /// Bluetooth の機器がつながった・切れた(BlueZ の Device1 の Connected)。名前と種類を通知する
    fn btConnectedSignal(self: *SysWatch, msg: *c.DBusMessage, path: []const u8) void {
        var it: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(msg, &it) == 0 or c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_STRING) return;
        var iface: [*c]const u8 = null;
        c.dbus_message_iter_get_basic(&it, @ptrCast(&iface));
        if (iface == null or !std.mem.eql(u8, std.mem.sliceTo(iface, 0), "org.bluez.Device1")) return;
        _ = c.dbus_message_iter_next(&it);
        if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_ARRAY) return;
        var a: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&it, &a);
        var connected: ?bool = null;
        while (c.dbus_message_iter_get_arg_type(&a) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&a)) {
            var e: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&a, &e);
            var k: [*c]const u8 = null;
            c.dbus_message_iter_get_basic(&e, @ptrCast(&k));
            if (k == null or !std.mem.eql(u8, std.mem.sliceTo(k, 0), "Connected")) continue;
            _ = c.dbus_message_iter_next(&e);
            var v: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&e, &v);
            if (c.dbus_message_iter_get_arg_type(&v) != c.DBUS_TYPE_BOOLEAN) continue;
            var b: c.dbus_bool_t = 0;
            c.dbus_message_iter_get_basic(&v, &b);
            connected = b != 0;
        }
        const on = connected orelse return;
        var nb: [96]u8 = undefined;
        var ib: [48]u8 = undefined;
        const name = self.bluezProp(path, "Alias", &nb) orelse "Bluetooth の機器";
        // AirPods(Apple の機器 ID v004C のヘッドホン)をつないだ: iPhone のようなカードで知らせる
        if (on and self.app.cfg.airpods_popup) {
            var mb: [64]u8 = undefined;
            var ab: [24]u8 = undefined;
            var ib2: [48]u8 = undefined;
            const modalias = self.bluezProp(path, "Modalias", &mb) orelse "";
            const icon2 = self.bluezProp(path, "Icon", &ib2) orelse "";
            if (std.mem.indexOf(u8, modalias, "v004C") != null and std.mem.startsWith(u8, icon2, "audio")) {
                if (self.bluezProp(path, "Address", &ab)) |addr| if (self.app.airpods_popup) |pp| {
                    pp.show(addr, name);
                    return;
                };
            }
        }
        if (!self.app.cfg.notify_usb) return;
        const icon = self.bluezProp(path, "Icon", &ib) orelse "";
        const kind: []const u8 = if (std.mem.startsWith(u8, icon, "audio-head")) "ヘッドホン" else if (std.mem.startsWith(u8, icon, "audio")) "オーディオ機器" else if (std.mem.eql(u8, icon, "input-mouse")) "マウス" else if (std.mem.eql(u8, icon, "input-keyboard")) "キーボード" else if (std.mem.startsWith(u8, icon, "input-gaming")) "ゲームパッド" else if (std.mem.startsWith(u8, icon, "phone")) "スマートフォン" else "Bluetooth の機器";
        var sb: [96]u8 = undefined;
        const summary = std.fmt.bufPrint(&sb, "{s}を{s}", .{ kind, if (on) "接続しました" else "切断しました" }) catch "Bluetooth";
        self.app.notifs.post("Bluetooth", summary, name, 0);
    }

    /// BlueZ の機器の文字列のプロパティ(同期。すぐ返る)
    fn bluezProp(self: *SysWatch, path: []const u8, prop: [*:0]const u8, buf: []u8) ?[]const u8 {
        const conn = self.conn orelse return null;
        var pz: [160]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return null;
        const m = c.dbus_message_new_method_call("org.bluez", p.ptr, "org.freedesktop.DBus.Properties", "Get") orelse return null;
        var i: [*c]const u8 = "org.bluez.Device1";
        var pr: [*c]const u8 = prop;
        _ = c.dbus_message_append_args(m, c.DBUS_TYPE_STRING, &i, c.DBUS_TYPE_STRING, &pr, c.DBUS_TYPE_INVALID);
        const r = c.dbus_connection_send_with_reply_and_block(conn, m, 500, null);
        c.dbus_message_unref(m);
        const reply = r orelse return null;
        defer c.dbus_message_unref(reply);
        var it: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &it) == 0 or c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_VARIANT) return null;
        var v: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&it, &v);
        if (c.dbus_message_iter_get_arg_type(&v) != c.DBUS_TYPE_STRING) return null;
        var s: [*c]const u8 = null;
        c.dbus_message_iter_get_basic(&v, @ptrCast(&s));
        if (s == null) return null;
        const str = std.mem.sliceTo(s, 0);
        const n = @min(str.len, buf.len);
        @memcpy(buf[0..n], str[0..n]);
        return buf[0..n];
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

    /// BlueZ が動いているか。動いていないときに BlueZ を呼ぶと、デーモンを待って返ってこない
    /// (FreeBSD に BlueZ は無い。Bluetooth は netgraph + hcsecd)
    pub fn bluezRunning(self: *SysWatch) bool {
        if (builtin.os.tag == .freebsd) return false;
        const conn = self.conn orelse return false;
        return c.dbus_bus_name_has_owner(conn, "org.bluez", null) != 0;
    }

    /// NetworkManager が動いているか(Wi-Fi の設定パネル用)
    pub fn nmRunning(self: *SysWatch) bool {
        if (builtin.os.tag == .freebsd) return false;
        const conn = self.conn orelse return false;
        return c.dbus_bus_name_has_owner(conn, "org.freedesktop.NetworkManager", null) != 0;
    }

    /// アダプタの電源が入っているか(FreeBSD: ng_ubt が付いたアダプタがあるか)
    pub fn btPowered(self: *SysWatch) bool {
        if (builtin.os.tag == .freebsd) {
            var b: [256]u8 = undefined;
            return sys.run(&.{ "sysctl", "-n", "dev.ubt.0.%desc" }, &b) != null;
        }
        if (!self.bluezRunning()) return false;
        var out: [512]u8 = undefined;
        const s = netdbus.run(&.{ "bluetoothctl", "show" }, &out) orelse return false;
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
        const s = netdbus.run(&.{ "nmcli", "radio", "wifi" }, &out) orelse return null;
        return std.mem.startsWith(u8, s, "enabled");
    }

    // ---------------- バッテリーの通知 ----------------

    /// 電源の状態を読み直した後に呼ぶ(App.refreshSys)。残りが 20% / 10% / 5% を下回ったら 1 回ずつ知らせ、
    /// 10% 以下は消すまで残る緊急の通知にする。電源につないだら通知を消して数え直す
    pub fn checkBattery(self: *SysWatch) void {
        const app = self.app;
        const b = app.sys.battery;
        // 充電器を挿した・外した: 画面全体のアニメーション(iPhone の MagSafe のように)。電池の通知の設定とは別
        if (b.present) {
            if (self.anim_ac) |pa| if (pa != b.on_ac) if (app.charge) |ch| ch.play(b.percent, if (b.on_ac) .plug else .unplug);
            self.anim_ac = b.on_ac;
        }
        if (!app.cfg.notify_battery or !b.present) return;
        // 充電器を挿した・抜いた(状態が変わったときだけ)
        if (self.prev_ac) |pa| if (pa != b.on_ac) self.acChanged(b);
        self.prev_ac = b.on_ac;
        // 挿したときに時間が分からなかった: 分かったら同じ通知を書き換える(1 回だけ)
        if (self.chg_notif != 0 and b.on_ac and !self.chg_has_time and b.minutes != null) self.postCharging(b);
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

    fn acChanged(self: *SysWatch, b: sys.Battery) void {
        const app = self.app;
        // 画面全体のアニメーションで知らせるときは、抜き差しの通知は出さない(前の通知が残っていれば消す)
        if (app.cfg.charge_anim) {
            self.chg_timer.disarm();
            if (self.chg_notif != 0) app.notifs.dismiss(self.chg_notif, 3);
            self.chg_notif = 0;
            return;
        }
        if (b.on_ac) {
            self.chg_has_time = false;
            self.chg_tries = 0;
            self.postCharging(b);
            // 挿した直後は消費電力の値が落ち着かないので、8 秒後と 30 秒後に読み直して時間を出す
            self.chg_timer.arm(8_000, 22_000);
        } else {
            self.chg_timer.disarm();
            var sb: [96]u8 = undefined;
            var tb: [48]u8 = undefined;
            var bb: [128]u8 = undefined;
            const t = @import("bar.zig").batteryTime(&tb, b);
            const summary = std.fmt.bufPrint(&sb, "電源から外しました · {d}%", .{b.percent}) catch "電源から外しました";
            const body = (if (t.len > 0) std.fmt.bufPrint(&bb, "バッテリーで動作しています({s})", .{t}) else std.fmt.bufPrint(&bb, "バッテリーで動作しています", .{})) catch "";
            // 充電の通知と同じ枠を使い回す(挿す・抜くを繰り返しても積み重ならない)
            self.chg_notif = app.notifs.postUrgency("電源", summary, body, self.chg_notif, 1);
        }
    }

    /// 「充電しています · 72% / 満充電まであと 1 時間 12 分(14:35 ごろ)」
    fn postCharging(self: *SysWatch, b: sys.Battery) void {
        var sb: [96]u8 = undefined;
        var bb: [160]u8 = undefined;
        const summary = if (b.full or b.percent >= 100)
            "充電器を接続しました · 満充電です"
        else if (!b.charging)
            (std.fmt.bufPrint(&sb, "充電器を接続しました · {d}%", .{b.percent}) catch "充電器を接続しました")
        else
            (std.fmt.bufPrint(&sb, "充電しています · {d}%", .{b.percent}) catch "充電しています");
        var body: []const u8 = "";
        if (b.full or b.percent >= 100) {
            body = "電源から動作しています";
        } else if (!b.charging) {
            body = "充電は止まっています(充電の上限・保護モード)";
        } else if (b.minutes) |m| {
            // 終わる時刻
            var t: c.time_t = c.time(null) + @as(c.time_t, @intCast(m)) * 60;
            var tm: c.struct_tm = undefined;
            _ = c.localtime_r(&t, &tm);
            body = (if (m >= 60)
                std.fmt.bufPrint(&bb, "満充電まであと {d} 時間 {d} 分({d}:{d:0>2} ごろ)", .{ m / 60, m % 60, @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) })
            else
                std.fmt.bufPrint(&bb, "満充電まであと {d} 分({d}:{d:0>2} ごろ)", .{ m, @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) })) catch "";
        } else {
            body = "満充電までの時間を計算しています…";
        }
        self.chg_has_time = b.minutes != null or b.full or !b.charging;
        self.chg_notif = self.app.notifs.postUrgency("電源", summary, body, self.chg_notif, 1);
    }

    fn onChgTimer(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *SysWatch = @ptrCast(@alignCast(ctx));
        self.chg_timer.ack();
        self.chg_tries += 1;
        if (self.chg_has_time or self.chg_tries > 6) {
            self.chg_timer.disarm();
            return;
        }
        self.app.refreshSys(false); // → checkBattery が時間の分かった通知に書き換える
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

    const Pending = struct {
        devpath: [256]u8 = undefined,
        len: usize = 0,
        /// ブロックデバイス(USB メモリ・SD カード)なら sdb などの名前
        blk: [32]u8 = undefined,
        blk_len: usize = 0,
    };

    fn pushPending(self: *SysWatch, devpath: []const u8, blk: []const u8, delay_ms: u64) void {
        if (self.n_pend >= self.pend.len) return;
        const p = &self.pend[self.n_pend];
        p.len = @min(devpath.len, p.devpath.len);
        @memcpy(p.devpath[0..p.len], devpath[0..p.len]);
        p.blk_len = @min(blk.len, p.blk.len);
        @memcpy(p.blk[0..p.blk_len], blk[0..p.blk_len]);
        self.n_pend += 1;
        self.pend_timer.arm(delay_ms, 0);
    }

    fn usbUevent(self: *SysWatch, msg: []const u8) void {
        if (!self.app.cfg.notify_usb) return;
        const devtype = ueventField(msg, "DEVTYPE") orelse return;
        if (!std.mem.eql(u8, devtype, "usb_device")) return;
        const action = ueventField(msg, "ACTION") orelse return;
        const devpath = ueventField(msg, "DEVPATH") orelse return;
        if (std.mem.eql(u8, action, "add")) {
            // 挿した瞬間は製品名・インターフェース(種類)がまだ無いことがあるので、少し待ってから読む
            self.pushPending(devpath, "", 900);
        } else if (std.mem.eql(u8, action, "remove")) {
            const name = self.usbForget(devpath) orelse return; // 覚えていない = ハブ・内蔵・ストレージ(ブロックの方で知らせる)
            self.app.notifs.post("USB", "USB 機器を取り外しました", name, 0);
        }
    }

    /// USB メモリ・SD カード・外付けディスク(ブロックデバイスの disk)
    fn blockUevent(self: *SysWatch, msg: []const u8) void {
        if (!self.app.cfg.notify_usb) return;
        const devtype = ueventField(msg, "DEVTYPE") orelse return;
        if (!std.mem.eql(u8, devtype, "disk")) return;
        const name = ueventField(msg, "DEVNAME") orelse return;
        const action = ueventField(msg, "ACTION") orelse return;
        const devpath = ueventField(msg, "DEVPATH") orelse return;
        for ([_][]const u8{ "loop", "ram", "zram", "dm-", "md", "nbd" }) |p| if (std.mem.startsWith(u8, name, p)) return;
        var kb: [40]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "blk:{s}", .{name}) catch return;
        if (std.mem.eql(u8, action, "add")) {
            // ボリュームの名前(/dev/disk/by-label)は udev がパーティションを調べてから作るので長めに待つ
            self.pushPending(devpath, name, 2000);
        } else if (std.mem.eql(u8, action, "remove")) {
            const disp = self.usbForget(key) orelse return;
            var sb: [96]u8 = undefined;
            const summary = std.fmt.bufPrint(&sb, "{s}を取り外しました", .{if (std.mem.startsWith(u8, name, "mmcblk")) "SD カード" else "ストレージ"}) catch "取り外しました";
            self.app.notifs.post("ストレージ", summary, disp, 0);
        } else if (std.mem.eql(u8, action, "change")) {
            // カードリーダーにカードを入れた(大きさが 0 から変わる)
            var szb: [32]u8 = undefined;
            var pz: [96]u8 = undefined;
            const p = std.fmt.bufPrintZ(&pz, "/sys/block/{s}/size", .{name}) catch return;
            const sz = std.fmt.parseInt(u64, sys.readFile(p, &szb) orelse "0", 10) catch 0;
            if (sz > 0) {
                for (self.usb) |u| if (u.key_len > 0 and std.mem.eql(u8, u.key[0..u.key_len], key)) return;
                self.pushPending(devpath, name, 2000);
            }
        }
    }

    fn onPend(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *SysWatch = @ptrCast(@alignCast(ctx));
        self.pend_timer.ack();
        const n = self.n_pend;
        self.n_pend = 0;
        for (self.pend[0..n]) |*p| {
            const devpath = p.devpath[0..p.len];
            // FreeBSD の USB 機器: すぐ後にディスクが現れていればストレージ(ディスクの方で知らせる)
            if (builtin.os.tag == .freebsd and std.mem.startsWith(u8, devpath, "bsd:")) {
                if (loop.nowMs() -| self.bsd_disk_ms < 5000) continue;
                const ugen = devpath[4..];
                var nb: [128]u8 = undefined;
                const name = usbconfigName(ugen, &nb) orelse "USB 機器";
                self.usbRemember(ugen, name);
                self.app.notifs.post("USB", "USB 機器を接続しました", name, 0);
                continue;
            }
            if (p.blk_len > 0) {
                self.notifyBlock(p.blk[0..p.blk_len], devpath);
                continue;
            }
            var nb: [128]u8 = undefined;
            const info = usbInfo(devpath, &nb) orelse continue;
            // ストレージはブロックデバイスの方で、容量・ボリュームの名前つきで知らせる
            if (std.mem.eql(u8, info.kind, "ストレージ")) continue;
            self.usbRemember(devpath, info.name);
            var sb: [96]u8 = undefined;
            self.app.notifs.post("USB", std.fmt.bufPrint(&sb, "{s}を接続しました", .{info.kind}) catch "USB 機器を接続しました", info.name, 0);
        }
    }

    /// 「USB メモリを接続しました / KIOXIA TransMemory · 32 GB · 「BACKUP」」
    /// FreeBSD: ディスク(da0 / mmcsd0 など)が現れた。diskinfo の容量・説明と、glabel の名前で知らせる
    fn notifyBlockBsd(self: *SysWatch, name: []const u8) void {
        var zb: [48]u8 = undefined;
        const dev = std.fmt.bufPrintZ(&zb, "/dev/{s}", .{name}) catch return;
        var out: [2048]u8 = undefined;
        // diskinfo -v: "# mediasize in bytes" と "# Disk descr." の行
        const info = sys.run(&.{ "diskinfo", "-v", dev.ptr }, &out) orelse return;
        var size: u64 = 0;
        var descr: []const u8 = "";
        var it = std.mem.splitScalar(u8, info, '\n');
        while (it.next()) |line| {
            const l = std.mem.trim(u8, line, " \t");
            const hash = std.mem.indexOf(u8, l, "#") orelse continue;
            const val = std.mem.trim(u8, l[0..hash], " \t");
            const what = l[hash..];
            if (std.mem.indexOf(u8, what, "mediasize in bytes") != null) {
                var n: usize = 0;
                while (n < val.len and std.ascii.isDigit(val[n])) n += 1;
                size = std.fmt.parseInt(u64, val[0..n], 10) catch 0;
            } else if (std.mem.indexOf(u8, what, "Disk descr.") != null) descr = val;
        }
        if (size == 0) return; // メディアの入っていないカードリーダー
        var db: [96]u8 = undefined;
        const disp_src = if (descr.len > 0) descr else name;
        const disp_len = @min(disp_src.len, db.len);
        @memcpy(db[0..disp_len], disp_src[0..disp_len]);
        const disp = db[0..disp_len];
        // ボリュームの名前: glabel status -s の「msdosfs/BACKUP  N/A  da0s1」
        var lb: [160]u8 = undefined;
        var ll: usize = 0;
        var gb: [4096]u8 = undefined;
        if (sys.run(&.{ "glabel", "status", "-s" }, &gb)) |gs| {
            var gi = std.mem.splitScalar(u8, gs, '\n');
            while (gi.next()) |line| {
                var f = std.mem.tokenizeAny(u8, line, " \t");
                const label = f.next() orelse continue;
                _ = f.next();
                const prov = f.next() orelse continue;
                if (!std.mem.startsWith(u8, prov, name)) continue;
                // gpt/・gptid/・diskid/ は機械的な名前なので出さない
                if (std.mem.startsWith(u8, label, "gptid/") or std.mem.startsWith(u8, label, "diskid/")) continue;
                const slash = std.mem.lastIndexOfScalar(u8, label, '/');
                const short = if (slash) |s| label[s + 1 ..] else label;
                if (ll > 0) ll += (std.fmt.bufPrint(lb[ll..], "・", .{}) catch "").len;
                const k = @min(short.len, lb.len - ll);
                @memcpy(lb[ll..][0..k], short[0..k]);
                ll += k;
            }
        }
        const gbs = @as(f64, @floatFromInt(size)) / 1e9;
        var szb: [24]u8 = undefined;
        const size_s = (if (gbs >= 1000) std.fmt.bufPrint(&szb, "{d:.1} TB", .{gbs / 1000}) else if (gbs >= 10) std.fmt.bufPrint(&szb, "{d:.0} GB", .{gbs}) else std.fmt.bufPrint(&szb, "{d:.1} GB", .{gbs})) catch "";
        var bb: [256]u8 = undefined;
        const body = (if (ll > 0) std.fmt.bufPrint(&bb, "{s} · {s} · 「{s}」", .{ disp, size_s, lb[0..ll] }) else std.fmt.bufPrint(&bb, "{s} · {s}", .{ disp, size_s })) catch disp;
        const sd = std.mem.startsWith(u8, name, "mmcsd") or std.mem.startsWith(u8, name, "sdda");
        const summary: []const u8 = if (sd) "SD カードを挿しました" else if (gbs < 300) "USB メモリを接続しました" else "外付けのストレージを接続しました";
        var kb: [40]u8 = undefined;
        if (std.fmt.bufPrint(&kb, "blk:{s}", .{name})) |key| self.usbRemember(key, disp) else |_| {}
        self.app.notifs.post("ストレージ", summary, body, 0);
    }

    fn notifyBlock(self: *SysWatch, name: []const u8, devpath: []const u8) void {
        if (builtin.os.tag == .freebsd) return self.notifyBlockBsd(name);
        var pz: [128]u8 = undefined;
        var rb: [64]u8 = undefined;
        const is_usb = std.mem.indexOf(u8, devpath, "/usb") != null;
        const is_mmc = std.mem.startsWith(u8, name, "mmcblk");
        const removable = blk: {
            const p = std.fmt.bufPrintZ(&pz, "/sys/block/{s}/removable", .{name}) catch break :blk false;
            break :blk std.mem.eql(u8, sys.readFile(p, &rb) orelse "0", "1");
        };
        if (!is_usb and !is_mmc and !removable) return; // 内蔵のディスク
        const size: u64 = blk: {
            const p = std.fmt.bufPrintZ(&pz, "/sys/block/{s}/size", .{name}) catch break :blk 0;
            break :blk (std.fmt.parseInt(u64, sys.readFile(p, &rb) orelse "0", 10) catch 0) * 512;
        };
        if (size == 0) return; // メディアの入っていないカードリーダー
        var vb: [64]u8 = undefined;
        var mb: [64]u8 = undefined;
        const vendor = if (std.fmt.bufPrintZ(&pz, "/sys/block/{s}/device/vendor", .{name})) |p| sys.readFile(p, &vb) orelse "" else |_| "";
        const model = if (std.fmt.bufPrintZ(&pz, "/sys/block/{s}/device/model", .{name})) |p| sys.readFile(p, &mb) orelse "" else |_| "";
        // ボリュームの名前(/dev/disk/by-label のうち、この機器のパーティションを指すもの)
        var lb: [160]u8 = undefined;
        var ll: usize = 0;
        if (std.fs.cwd().openDir("/dev/disk/by-label", .{ .iterate = true })) |dir_| {
            var dir = dir_;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |ent| {
                var tb: [256]u8 = undefined;
                const target = dir.readLink(ent.name, &tb) catch continue;
                if (!std.mem.startsWith(u8, std.fs.path.basename(target), name)) continue;
                if (ll > 0) ll += (std.fmt.bufPrint(lb[ll..], "・", .{}) catch "").len;
                // udev は空白などを \x20 のように書く
                var i: usize = 0;
                while (i < ent.name.len and ll < lb.len) : (i += 1) {
                    if (ent.name[i] == '\\' and i + 3 < ent.name.len and ent.name[i + 1] == 'x') {
                        lb[ll] = std.fmt.parseInt(u8, ent.name[i + 2 .. i + 4], 16) catch '?';
                        i += 3;
                    } else lb[ll] = ent.name[i];
                    ll += 1;
                }
            }
        } else |_| {}
        var db: [96]u8 = undefined;
        const disp = (if (vendor.len > 0 and model.len > 0 and std.mem.indexOf(u8, model, vendor) == null)
            std.fmt.bufPrint(&db, "{s} {s}", .{ vendor, model })
        else if (model.len > 0)
            std.fmt.bufPrint(&db, "{s}", .{model})
        else if (ll > 0)
            std.fmt.bufPrint(&db, "{s}", .{lb[0..ll]})
        else
            std.fmt.bufPrint(&db, "{s}", .{name})) catch name;
        const gb = @as(f64, @floatFromInt(size)) / 1e9;
        var szb: [24]u8 = undefined;
        const size_s = (if (gb >= 1000) std.fmt.bufPrint(&szb, "{d:.1} TB", .{gb / 1000}) else if (gb >= 10) std.fmt.bufPrint(&szb, "{d:.0} GB", .{gb}) else std.fmt.bufPrint(&szb, "{d:.1} GB", .{gb})) catch "";
        var bb: [256]u8 = undefined;
        const body = (if (ll > 0) std.fmt.bufPrint(&bb, "{s} · {s} · 「{s}」", .{ disp, size_s, lb[0..ll] }) else std.fmt.bufPrint(&bb, "{s} · {s}", .{ disp, size_s })) catch disp;
        const summary: []const u8 = if (is_mmc) "SD カードを挿しました" else if (is_usb and gb < 300) "USB メモリを接続しました" else "外付けのストレージを接続しました";
        var kb: [40]u8 = undefined;
        if (std.fmt.bufPrint(&kb, "blk:{s}", .{name})) |key| self.usbRemember(key, disp) else |_| {}
        self.app.notifs.post("ストレージ", summary, body, 0);
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
        // socket / connect は std.posix で(sockaddr の型を C に合わせない)
        const addr = @import("ipc_path.zig").unixAddr("/var/run/devd.seqpacket.pipe") orelse return;
        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0) catch return;
        std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
            std.log.info("syswatch: devd に接続できません(電源・USB の変化は 20 秒ごとに調べます)", .{});
            std.posix.close(fd);
            return;
        };
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
            } else if (std.mem.eql(u8, system, "DEVFS") and self.app.cfg.notify_usb) {
                // ディスクの出入り(cdev=da0 / mmcsd0 など。パーティション da0s1・da0p1 は見ない)
                const typ = devdField(msg, "type") orelse "";
                const cdev = devdField(msg, "cdev") orelse continue;
                if (!isBsdDisk(cdev)) continue;
                if (std.mem.eql(u8, typ, "CREATE")) {
                    self.bsd_disk_ms = loop.nowMs();
                    self.pushPending(cdev, cdev, 2000);
                } else if (std.mem.eql(u8, typ, "DESTROY")) {
                    var kb: [40]u8 = undefined;
                    const key = std.fmt.bufPrint(&kb, "blk:{s}", .{cdev}) catch continue;
                    const disp = self.usbForget(key) orelse continue;
                    self.app.notifs.post("ストレージ", if (std.mem.startsWith(u8, cdev, "mmcsd") or std.mem.startsWith(u8, cdev, "sdda")) "SD カードを取り外しました" else "ストレージを取り外しました", disp, 0);
                }
            } else if (std.mem.eql(u8, system, "USB") and self.app.cfg.notify_usb) {
                const sub = devdField(msg, "subsystem") orelse "";
                if (!std.mem.eql(u8, sub, "DEVICE")) continue;
                const typ = devdField(msg, "type") orelse "";
                const ugen = devdField(msg, "ugen") orelse continue;
                if (std.mem.eql(u8, typ, "ATTACH")) {
                    if (std.mem.eql(u8, devdField(msg, "devclass") orelse "", "0x09")) continue; // ハブ
                    // ストレージなら、すぐ後にディスクとして(容量・名前つきで)知らせるので、少し待ってから決める
                    var kb: [48]u8 = undefined;
                    const key = std.fmt.bufPrint(&kb, "bsd:{s}", .{ugen}) catch continue;
                    self.pushPending(key, "", 2500);
                    continue;
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

/// FreeBSD のディスクの装置名か(da0・mmcsd0・sdda0・nda0。パーティションの da0s1・da0p1 などは違う)
fn isBsdDisk(cdev: []const u8) bool {
    for ([_][]const u8{ "da", "mmcsd", "sdda", "nda", "cd" }) |p| {
        if (!std.mem.startsWith(u8, cdev, p)) continue;
        const rest = cdev[p.len..];
        if (rest.len == 0) return false;
        for (rest) |ch| if (!std.ascii.isDigit(ch)) return false;
        return true;
    }
    return false;
}
