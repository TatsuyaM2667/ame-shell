// Wi-Fi(NetworkManager)と Bluetooth(BlueZ)を D-Bus で直接操作する。nmcli / bluetoothctl / bt-connect.sh の代わり。
// (Linux 専用。FreeBSD は wpa_cli と netgraph を使う: netpanel.zig の *Bsd)
//
// 押すたびにコマンドを起動していた(1 回 30〜100ms、bluetoothctl はデーモン待ちで止まることも)のをやめ、
// システムバスへの呼び出しだけにした。呼び出しは時間のかかるもの(接続・ペアリング・スキャン)があるので
// ワーカースレッドで行い、結果は pipe に書いて閉じる(呼ぶ側は従来どおり EOF で完了を知る)。
//
// 結果の文字列は、それまで読んでいた nmcli -t / bluetoothctl の出力と同じ形にしてある(netpanel.zig の解釈をそのまま使う):
//   nmcli radio wifi                                     → "enabled" / "disabled"
//   nmcli radio wifi on|off                              → "" / "Error: …"
//   nmcli -t -f NAME,TYPE connection show                → "名前:802-11-wireless"(値の ':' は "\:")
//   nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY dev wifi list → "*:SSID:70:WPA2" / " :SSID:40:"
//   nmcli dev wifi rescan                                → "" / "Error: …"
//   nmcli dev wifi connect <SSID> [password <PW>]        → "" / "Error: …"(つながるか失敗するまで待つ)
//   nmcli connection up|down id <名前>                   → 同上
//   bluetoothctl show                                    → "Powered: yes|no" "PowerState: …"
//   bluetoothctl devices [Paired|Connected]              → "Device AA:BB:… 名前"
//   bluetoothctl disconnect|power …                      → "" / "Failed: …"
//   ame-bt power on|off                                  → "ok" / "Failed: …"(on は rfkill のブロックも外す)
//   ame-bt scan <秒>                                     → "ok"(見つかった機器は BlueZ の信号で syswatch が拾う)
//   ame-bt remove <MAC>                                  → "Device has been removed" / "Failed: …"(登録を消す)
//   ame-bt connect|pair <MAC> <bt-connect.sh>            → "Connection successful" / "Failed: …"
//                                                          (音の出力先の切り替えは bt-connect.sh --audio で pactl)
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig");
const sys = @import("sys.zig");

const log = std.log.scoped(.netdbus);

const NM = "org.freedesktop.NetworkManager";
const NM_PATH = "/org/freedesktop/NetworkManager";
const NM_SETTINGS = "/org/freedesktop/NetworkManager/Settings";
const NM_DEV = "org.freedesktop.NetworkManager.Device";
const NM_WIFI = "org.freedesktop.NetworkManager.Device.Wireless";
const NM_AP = "org.freedesktop.NetworkManager.AccessPoint";
const NM_ACTIVE = "org.freedesktop.NetworkManager.Connection.Active";
const NM_CONN = "org.freedesktop.NetworkManager.Settings.Connection";
const BLUEZ = "org.bluez";
const ADAPTER = "org.bluez.Adapter1";
const DEVICE = "org.bluez.Device1";
const PROPS = "org.freedesktop.DBus.Properties";

const DBusError = extern struct { name: ?[*:0]const u8 = null, message: ?[*:0]const u8 = null, dummy: c_uint = 0, padding1: ?*anyopaque = null };

/// このモジュールが引き受けるコマンドか
pub fn handles(argv0: []const u8) bool {
    if (builtin.os.tag != .linux) return false;
    return std.mem.eql(u8, argv0, "nmcli") or std.mem.eql(u8, argv0, "bluetoothctl") or std.mem.eql(u8, argv0, "ame-bt");
}

// ---------------------------------------------------------------------------
// 呼び出し口
// ---------------------------------------------------------------------------

const MAX_ARGS = 10;
const Args = struct {
    buf: [MAX_ARGS][160]u8 = undefined,
    len: [MAX_ARGS]usize = undefined,
    n: usize = 0,
    fn init(argv: []const []const u8) Args {
        var a = Args{};
        for (argv[0..@min(argv.len, MAX_ARGS)]) |s| {
            const l = @min(s.len, 159);
            @memcpy(a.buf[a.n][0..l], s[0..l]);
            a.buf[a.n][l] = 0;
            a.len[a.n] = l;
            a.n += 1;
        }
        return a;
    }
    fn get(self: *const Args, i: usize) []const u8 {
        return if (i < self.n) self.buf[i][0..self.len[i]] else "";
    }
    fn z(self: *Args, i: usize) [*:0]const u8 {
        return @ptrCast(&self.buf[i]);
    }
    fn is(self: *const Args, i: usize, s: []const u8) bool {
        return std.mem.eql(u8, self.get(i), s);
    }
    /// パスワードはメモリに残さない
    fn wipe(self: *Args) void {
        @memset(std.mem.asBytes(&self.buf), 0);
    }
};

const Out = struct {
    buf: [16384]u8 = undefined,
    len: usize = 0,
    fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
        self.len += s.len;
    }
    fn add(self: *Out, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }
    /// nmcli -t と同じく ':' と '\' を '\' で逃がす
    fn esc(self: *Out, s: []const u8) void {
        for (s) |ch| {
            if (ch == ':' or ch == '\\') self.add("\\");
            if (ch == '\n') continue;
            self.add(&.{ch});
        }
    }
    fn get(self: *const Out) []const u8 {
        return self.buf[0..self.len];
    }
};

const Job = struct { args: Args, wfd: c_int };

/// ワーカースレッドで実行し、結果を書いた pipe の読み口を返す(終わると書き口が閉じられ EOF になる)
pub fn spawn(argv: []const []const u8) ?c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return null;
    const job = std.heap.c_allocator.create(Job) catch {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return null;
    };
    job.* = .{ .args = Args.init(argv), .wfd = fds[1] };
    const th = std.Thread.spawn(.{}, worker, .{job}) catch {
        std.heap.c_allocator.destroy(job);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return null;
    };
    th.detach();
    _ = c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK);
    return fds[0];
}

/// 結果を待たない(ダッシュボードのオン/オフなど)
pub fn detached(argv: []const []const u8) void {
    const fd = spawn(argv) orelse return;
    // 読む人がいないと書き込みが EPIPE になるだけなので、すぐ閉じてよい
    _ = c.close(fd);
}

/// その場で実行して結果を返す(すぐ終わる問い合わせだけに使う: 状態の読み取り)
pub fn run(argv: []const []const u8, out: []u8) ?[]const u8 {
    var a = Args.init(argv);
    const o = std.heap.c_allocator.create(Out) catch return null;
    defer std.heap.c_allocator.destroy(o);
    o.* = .{};
    exec(&a, o);
    const n = @min(o.len, out.len);
    @memcpy(out[0..n], o.buf[0..n]);
    return out[0..n];
}

fn worker(job: *Job) void {
    defer std.heap.c_allocator.destroy(job);
    defer _ = c.close(job.wfd);
    const o = std.heap.c_allocator.create(Out) catch return;
    defer std.heap.c_allocator.destroy(o);
    o.* = .{};
    exec(&job.args, o);
    job.args.wipe();
    var off: usize = 0;
    const s = o.get();
    while (off < s.len) {
        const n = std.posix.write(job.wfd, s[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}

fn exec(a: *Args, o: *Out) void {
    var bus = Bus.open() orelse {
        o.add(if (a.is(0, "nmcli")) "Error: システムの D-Bus に接続できません" else "Failed: システムの D-Bus に接続できません");
        return;
    };
    defer bus.close();
    if (a.is(0, "nmcli")) nmcli(&bus, a, o) else if (a.is(0, "bluetoothctl")) btctl(&bus, a, o) else if (a.is(0, "ame-bt")) ameBt(&bus, a, o);
}

// ---------------------------------------------------------------------------
// D-Bus の薄い包み
// ---------------------------------------------------------------------------

const Iter = c.DBusMessageIter;

const Bus = struct {
    conn: *c.DBusConnection,
    err_name: [96]u8 = undefined,
    err_name_len: usize = 0,
    err_msg: [200]u8 = undefined,
    err_msg_len: usize = 0,

    fn open() ?Bus {
        var err = DBusError{};
        const errp: *c.DBusError = @ptrCast(&err);
        c.dbus_error_init(errp);
        const conn = c.dbus_bus_get_private(c.DBUS_BUS_SYSTEM, errp) orelse {
            c.dbus_error_free(errp);
            return null;
        };
        c.dbus_connection_set_exit_on_disconnect(conn, 0);
        return .{ .conn = conn };
    }

    fn close(self: *Bus) void {
        c.dbus_connection_close(self.conn);
        c.dbus_connection_unref(self.conn);
    }

    fn errName(self: *const Bus) []const u8 {
        return self.err_name[0..self.err_name_len];
    }
    fn errMsg(self: *const Bus) []const u8 {
        return self.err_msg[0..self.err_msg_len];
    }

    /// m を送って返事を待つ。失敗なら null(理由は err_name / err_msg)
    fn send(self: *Bus, m: *c.DBusMessage, timeout_ms: c_int) ?*c.DBusMessage {
        defer c.dbus_message_unref(m);
        var err = DBusError{};
        const errp: *c.DBusError = @ptrCast(&err);
        c.dbus_error_init(errp);
        const r = c.dbus_connection_send_with_reply_and_block(self.conn, m, timeout_ms, errp);
        if (r == null) {
            const n = if (err.name) |p| std.mem.sliceTo(p, 0) else "Error";
            const msg = if (err.message) |p| std.mem.sliceTo(p, 0) else "";
            self.err_name_len = @min(n.len, self.err_name.len);
            @memcpy(self.err_name[0..self.err_name_len], n[0..self.err_name_len]);
            self.err_msg_len = @min(msg.len, self.err_msg.len);
            @memcpy(self.err_msg[0..self.err_msg_len], msg[0..self.err_msg_len]);
            c.dbus_error_free(errp);
            return null;
        }
        return r;
    }

    fn call(dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8) ?*c.DBusMessage {
        return c.dbus_message_new_method_call(dest, path, iface, method);
    }

    /// 引数なしのメソッド
    fn simple(self: *Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, timeout_ms: c_int) ?*c.DBusMessage {
        const m = call(dest, path, iface, method) orelse return null;
        return self.send(m, timeout_ms);
    }

    /// Properties.Get。返事の中の値を it に開く(返事は呼んだ側が unref)
    fn getProp(self: *Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8, it: *Iter) ?*c.DBusMessage {
        const m = call(dest, path, PROPS, "Get") orelse return null;
        var i: [*c]const u8 = iface;
        var p: [*c]const u8 = prop;
        _ = c.dbus_message_append_args(m, c.DBUS_TYPE_STRING, &i, c.DBUS_TYPE_STRING, &p, c.DBUS_TYPE_INVALID);
        const r = self.send(m, 3000) orelse return null;
        var top: Iter = undefined;
        if (c.dbus_message_iter_init(r, &top) == 0 or c.dbus_message_iter_get_arg_type(&top) != c.DBUS_TYPE_VARIANT) {
            c.dbus_message_unref(r);
            return null;
        }
        c.dbus_message_iter_recurse(&top, it);
        return r;
    }

    fn getBool(self: *Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8) ?bool {
        var it: Iter = undefined;
        const r = self.getProp(dest, path, iface, prop, &it) orelse return null;
        defer c.dbus_message_unref(r);
        return getB(&it);
    }

    fn getU32(self: *Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8) ?u32 {
        var it: Iter = undefined;
        const r = self.getProp(dest, path, iface, prop, &it) orelse return null;
        defer c.dbus_message_unref(r);
        return getU(&it);
    }

    /// 文字列 / オブジェクトパスの値を buf に写す
    fn getStr(self: *Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8, buf: []u8) ?[]const u8 {
        var it: Iter = undefined;
        const r = self.getProp(dest, path, iface, prop, &it) orelse return null;
        defer c.dbus_message_unref(r);
        const s = getS(&it) orelse return null;
        const n = @min(s.len, buf.len);
        @memcpy(buf[0..n], s[0..n]);
        return buf[0..n];
    }

    fn setBool(self: *Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8, v: bool) bool {
        const m = call(dest, path, PROPS, "Set") orelse return false;
        var w: Iter = undefined;
        c.dbus_message_iter_init_append(m, &w);
        var i: [*c]const u8 = iface;
        var p: [*c]const u8 = prop;
        _ = c.dbus_message_iter_append_basic(&w, c.DBUS_TYPE_STRING, @ptrCast(&i));
        _ = c.dbus_message_iter_append_basic(&w, c.DBUS_TYPE_STRING, @ptrCast(&p));
        var vi: Iter = undefined;
        _ = c.dbus_message_iter_open_container(&w, c.DBUS_TYPE_VARIANT, "b", &vi);
        var b: c.dbus_bool_t = @intFromBool(v);
        _ = c.dbus_message_iter_append_basic(&vi, c.DBUS_TYPE_BOOLEAN, @ptrCast(&b));
        _ = c.dbus_message_iter_close_container(&w, &vi);
        const r = self.send(m, 5000) orelse return false;
        c.dbus_message_unref(r);
        return true;
    }

    /// オブジェクトパスの配列(ao)の値を paths に写す
    fn getPaths(self: *Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8, paths: *Paths) void {
        var it: Iter = undefined;
        const r = self.getProp(dest, path, iface, prop, &it) orelse return;
        defer c.dbus_message_unref(r);
        paths.fromArray(&it);
    }
};

const Paths = struct {
    p: [48][128:0]u8 = undefined,
    n: usize = 0,
    fn add(self: *Paths, s: []const u8) void {
        if (self.n >= self.p.len or s.len >= 128) return;
        @memcpy(self.p[self.n][0..s.len], s);
        self.p[self.n][s.len] = 0;
        self.n += 1;
    }
    fn fromArray(self: *Paths, it: *Iter) void {
        if (c.dbus_message_iter_get_arg_type(it) != c.DBUS_TYPE_ARRAY) return;
        var a: Iter = undefined;
        c.dbus_message_iter_recurse(it, &a);
        while (c.dbus_message_iter_get_arg_type(&a) == c.DBUS_TYPE_OBJECT_PATH) {
            if (getS(&a)) |s| self.add(s);
            _ = c.dbus_message_iter_next(&a);
        }
    }
    fn z(self: *Paths, i: usize) [*:0]const u8 {
        return &self.p[i];
    }
    fn get(self: *const Paths, i: usize) []const u8 {
        return std.mem.sliceTo(&self.p[i], 0);
    }
};

fn getS(it: *Iter) ?[]const u8 {
    const t = c.dbus_message_iter_get_arg_type(it);
    if (t != c.DBUS_TYPE_STRING and t != c.DBUS_TYPE_OBJECT_PATH) return null;
    var s: [*c]const u8 = null;
    c.dbus_message_iter_get_basic(it, @ptrCast(&s));
    if (s == null) return null;
    return std.mem.sliceTo(s, 0);
}
fn getB(it: *Iter) ?bool {
    if (c.dbus_message_iter_get_arg_type(it) != c.DBUS_TYPE_BOOLEAN) return null;
    var b: c.dbus_bool_t = 0;
    c.dbus_message_iter_get_basic(it, &b);
    return b != 0;
}
fn getU(it: *Iter) ?u32 {
    switch (c.dbus_message_iter_get_arg_type(it)) {
        c.DBUS_TYPE_UINT32 => {
            var v: u32 = 0;
            c.dbus_message_iter_get_basic(it, &v);
            return v;
        },
        c.DBUS_TYPE_BYTE => {
            var v: u8 = 0;
            c.dbus_message_iter_get_basic(it, &v);
            return v;
        },
        else => return null,
    }
}
/// バイト列(ay: SSID)
fn getBytes(it: *Iter, buf: []u8) []const u8 {
    if (c.dbus_message_iter_get_arg_type(it) != c.DBUS_TYPE_ARRAY) return buf[0..0];
    var a: Iter = undefined;
    c.dbus_message_iter_recurse(it, &a);
    var n: usize = 0;
    while (c.dbus_message_iter_get_arg_type(&a) == c.DBUS_TYPE_BYTE and n < buf.len) {
        var v: u8 = 0;
        c.dbus_message_iter_get_basic(&a, &v);
        buf[n] = v;
        n += 1;
        _ = c.dbus_message_iter_next(&a);
    }
    return buf[0..n];
}

/// a{sv} を 1 つずつたどる。f(ctx, key, 値の Iter)
fn eachDict(it: *Iter, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8, *Iter) void) void {
    if (c.dbus_message_iter_get_arg_type(it) != c.DBUS_TYPE_ARRAY) return;
    var a: Iter = undefined;
    c.dbus_message_iter_recurse(it, &a);
    while (c.dbus_message_iter_get_arg_type(&a) == c.DBUS_TYPE_DICT_ENTRY) {
        var e: Iter = undefined;
        c.dbus_message_iter_recurse(&a, &e);
        if (getS(&e)) |k| {
            _ = c.dbus_message_iter_next(&e);
            var v: Iter = undefined;
            if (c.dbus_message_iter_get_arg_type(&e) == c.DBUS_TYPE_VARIANT) {
                c.dbus_message_iter_recurse(&e, &v);
                f(ctx, k, &v);
            } else f(ctx, k, &e);
        }
        _ = c.dbus_message_iter_next(&a);
    }
}

fn sleepMs(ms: u64) void {
    std.time.sleep(ms * std.time.ns_per_ms);
}

// ---------------------------------------------------------------------------
// NetworkManager(nmcli の代わり)
// ---------------------------------------------------------------------------

fn nmcli(bus: *Bus, a: *Args, o: *Out) void {
    // radio wifi [on|off]
    if (a.is(1, "radio") and a.is(2, "wifi")) {
        if (a.n <= 3) {
            const on = bus.getBool(NM, NM_PATH, NM, "WirelessEnabled") orelse return nmErr(bus, o);
            o.add(if (on) "enabled" else "disabled");
        } else if (!bus.setBool(NM, NM_PATH, NM, "WirelessEnabled", a.is(3, "on"))) nmErr(bus, o);
        return;
    }
    // -t -f <fields> ...
    if (a.is(1, "-t") and a.is(2, "-f")) {
        if (a.is(4, "connection") and a.is(5, "show")) return listConnections(bus, o);
        if (a.is(4, "dev") and a.is(5, "wifi") and a.is(6, "list")) {
            // --rescan yes: 古い一覧にならないよう、頼んでから少し待つ
            if (a.is(8, "yes")) {
                _ = requestScan(bus);
                sleepMs(3000);
            }
            return listAps(bus, o, a.get(3));
        }
    }
    if (a.is(1, "dev") and a.is(2, "wifi") and a.is(3, "rescan")) {
        if (!requestScan(bus)) nmErr(bus, o);
        return;
    }
    if (a.is(1, "dev") and a.is(2, "wifi") and a.is(3, "connect")) return wifiConnect(bus, a, o);
    if (a.is(1, "connection") and a.is(3, "id")) {
        if (a.is(2, "up")) return connectionUp(bus, a.get(4), o);
        if (a.is(2, "down")) return connectionDown(bus, a.get(4), o);
    }
    o.print("Error: 対応していない操作です({s} {s})", .{ a.get(1), a.get(2) });
}

fn nmErr(bus: *const Bus, o: *Out) void {
    if (bus.errName().len == 0) {
        o.add("Error: NetworkManager が応答しません");
    } else o.print("Error: {s} ({s})", .{ bus.errMsg(), bus.errName() });
}

/// Wi-Fi の機器(DeviceType = 2)
fn wifiDevices(bus: *Bus, out: *Paths) void {
    var all = Paths{};
    const r = bus.simple(NM, NM_PATH, NM, "GetDevices", 3000) orelse return;
    defer c.dbus_message_unref(r);
    var it: Iter = undefined;
    if (c.dbus_message_iter_init(r, &it) == 0) return;
    all.fromArray(&it);
    for (0..all.n) |i| {
        if ((bus.getU32(NM, all.z(i), NM_DEV, "DeviceType") orelse 0) == 2) out.add(all.get(i));
    }
}

fn requestScan(bus: *Bus) bool {
    var devs = Paths{};
    wifiDevices(bus, &devs);
    if (devs.n == 0) return false;
    var ok = false;
    for (0..devs.n) |i| {
        const m = Bus.call(NM, devs.z(i), NM_WIFI, "RequestScan") orelse continue;
        var w: Iter = undefined;
        c.dbus_message_iter_init_append(m, &w);
        var d: Iter = undefined;
        _ = c.dbus_message_iter_open_container(&w, c.DBUS_TYPE_ARRAY, "{sv}", &d);
        _ = c.dbus_message_iter_close_container(&w, &d);
        if (bus.send(m, 5000)) |r| {
            c.dbus_message_unref(r);
            ok = true;
        }
    }
    return ok;
}

const ApInfo = struct {
    ssid: [64]u8 = undefined,
    ssid_len: usize = 0,
    strength: u32 = 0,
    flags: u32 = 0,
    wpa: u32 = 0,
    rsn: u32 = 0,
    fn ssidStr(self: *const ApInfo) []const u8 {
        return self.ssid[0..self.ssid_len];
    }
    fn secure(self: *const ApInfo) bool {
        return self.flags != 0 or self.wpa != 0 or self.rsn != 0;
    }
};

fn apField(ap: *ApInfo, k: []const u8, v: *Iter) void {
    if (std.mem.eql(u8, k, "Ssid")) {
        ap.ssid_len = getBytes(v, &ap.ssid).len;
    } else if (std.mem.eql(u8, k, "Strength")) {
        ap.strength = getU(v) orelse 0;
    } else if (std.mem.eql(u8, k, "Flags")) {
        ap.flags = getU(v) orelse 0;
    } else if (std.mem.eql(u8, k, "WpaFlags")) {
        ap.wpa = getU(v) orelse 0;
    } else if (std.mem.eql(u8, k, "RsnFlags")) {
        ap.rsn = getU(v) orelse 0;
    }
}

fn readAp(bus: *Bus, path: [*:0]const u8) ?ApInfo {
    const m = Bus.call(NM, path, PROPS, "GetAll") orelse return null;
    var i: [*c]const u8 = NM_AP;
    _ = c.dbus_message_append_args(m, c.DBUS_TYPE_STRING, &i, c.DBUS_TYPE_INVALID);
    const r = bus.send(m, 3000) orelse return null;
    defer c.dbus_message_unref(r);
    var it: Iter = undefined;
    if (c.dbus_message_iter_init(r, &it) == 0) return null;
    var ap = ApInfo{};
    eachDict(&it, &ap, apField);
    return ap;
}

/// fields: "IN-USE,SSID,SIGNAL,SECURITY"(設定パネル)/ "ACTIVE,SSID"(バーの SSID)
fn listAps(bus: *Bus, o: *Out, fields: []const u8) void {
    const active_ssid_only = std.mem.eql(u8, fields, "ACTIVE,SSID");
    var devs = Paths{};
    wifiDevices(bus, &devs);
    for (0..devs.n) |d| {
        var abuf: [128]u8 = undefined;
        const active = bus.getStr(NM, devs.z(d), NM_WIFI, "ActiveAccessPoint", &abuf) orelse "/";
        var aps = Paths{};
        const r = bus.simple(NM, devs.z(d), NM_WIFI, "GetAllAccessPoints", 3000) orelse continue;
        var it: Iter = undefined;
        if (c.dbus_message_iter_init(r, &it) != 0) aps.fromArray(&it);
        c.dbus_message_unref(r);
        for (0..aps.n) |i| {
            const is_active = std.mem.eql(u8, aps.get(i), active);
            if (active_ssid_only and !is_active) continue;
            const ap = readAp(bus, aps.z(i)) orelse continue;
            if (active_ssid_only) {
                o.add("yes:");
                o.esc(ap.ssidStr());
                o.add("\n");
                continue;
            }
            o.add(if (is_active) "*:" else " :");
            o.esc(ap.ssidStr());
            o.print(":{d}:", .{ap.strength});
            if (ap.secure()) o.add(if (ap.rsn != 0) "WPA2" else if (ap.wpa != 0) "WPA1" else "WEP");
            o.add("\n");
        }
    }
}

/// 保存済みの接続: Settings.ListConnections → 各 GetSettings の connection.id / connection.type
const ConnInfo = struct {
    id: [96]u8 = undefined,
    id_len: usize = 0,
    typ: [32]u8 = undefined,
    typ_len: usize = 0,
};

fn connSection(ci: *ConnInfo, k: []const u8, v: *Iter) void {
    if (!std.mem.eql(u8, k, "connection")) return;
    eachDict(v, ci, struct {
        fn f(x: *ConnInfo, key: []const u8, val: *Iter) void {
            const s = getS(val) orelse return;
            if (std.mem.eql(u8, key, "id")) {
                x.id_len = @min(s.len, x.id.len);
                @memcpy(x.id[0..x.id_len], s[0..x.id_len]);
            } else if (std.mem.eql(u8, key, "type")) {
                x.typ_len = @min(s.len, x.typ.len);
                @memcpy(x.typ[0..x.typ_len], s[0..x.typ_len]);
            }
        }
    }.f);
}

fn readConn(bus: *Bus, path: [*:0]const u8) ?ConnInfo {
    const r = bus.simple(NM, path, NM_CONN, "GetSettings", 3000) orelse return null;
    defer c.dbus_message_unref(r);
    var it: Iter = undefined;
    if (c.dbus_message_iter_init(r, &it) == 0) return null;
    var ci = ConnInfo{};
    eachDict(&it, &ci, connSection);
    return ci;
}

fn savedConnections(bus: *Bus, out: *Paths) void {
    const r = bus.simple(NM, NM_SETTINGS, "org.freedesktop.NetworkManager.Settings", "ListConnections", 3000) orelse return;
    defer c.dbus_message_unref(r);
    var it: Iter = undefined;
    if (c.dbus_message_iter_init(r, &it) != 0) out.fromArray(&it);
}

fn listConnections(bus: *Bus, o: *Out) void {
    var conns = Paths{};
    savedConnections(bus, &conns);
    for (0..conns.n) |i| {
        const ci = readConn(bus, conns.z(i)) orelse continue;
        o.esc(ci.id[0..ci.id_len]);
        o.add(":");
        o.esc(ci.typ[0..ci.typ_len]);
        o.add("\n");
    }
}

/// 保存済みの接続を名前(id)で探す
fn findConnection(bus: *Bus, id: []const u8, buf: *[128:0]u8) ?[*:0]const u8 {
    var conns = Paths{};
    savedConnections(bus, &conns);
    for (0..conns.n) |i| {
        const ci = readConn(bus, conns.z(i)) orelse continue;
        if (std.mem.eql(u8, ci.id[0..ci.id_len], id)) {
            const p = conns.get(i);
            @memcpy(buf[0..p.len], p);
            buf[p.len] = 0;
            return buf;
        }
    }
    return null;
}

/// つながる(ACTIVATED)か、失敗する(DEACTIVATED / 消えた)まで待つ
fn waitActive(bus: *Bus, active: [*:0]const u8, dev: ?[*:0]const u8, o: *Out) bool {
    var waited: u32 = 0;
    while (waited < 45_000) : (waited += 300) {
        const st = bus.getU32(NM, active, NM_ACTIVE, "State") orelse break;
        if (st == 2) return true; // ACTIVATED
        if (st == 4) break; // DEACTIVATED
        sleepMs(300);
    }
    // 理由: 機器の StateReason(パスワード違いは 7 = NO_SECRETS / 8 = SUPPLICANT_DISCONNECT)
    var reason: u32 = 0;
    if (dev) |d| {
        var it: Iter = undefined;
        if (bus.getProp(NM, d, NM_DEV, "StateReason", &it)) |r| {
            defer c.dbus_message_unref(r);
            if (c.dbus_message_iter_get_arg_type(&it) == c.DBUS_TYPE_STRUCT) {
                var s: Iter = undefined;
                c.dbus_message_iter_recurse(&it, &s);
                _ = c.dbus_message_iter_next(&s);
                reason = getU(&s) orelse 0;
            }
        }
    }
    switch (reason) {
        7, 8, 9, 10, 11 => o.add("Error: Connection activation failed: Secrets were required (802-11-wireless-security.psk)"),
        else => o.print("Error: Connection activation failed (reason {d})", .{reason}),
    }
    return false;
}

fn wifiConnect(bus: *Bus, a: *Args, o: *Out) void {
    const ssid = a.get(4);
    const pw: ?[]const u8 = if (a.is(5, "password")) a.get(6) else null;
    // その SSID が見えている機器とアクセスポイント(電波の強いもの)
    var devs = Paths{};
    wifiDevices(bus, &devs);
    if (devs.n == 0) return o.add("Error: Wi-Fi の機器がありません");
    var best_dev: usize = 0;
    var best_ap: [128:0]u8 = undefined;
    var best: ?ApInfo = null;
    for (0..devs.n) |d| {
        var aps = Paths{};
        const r = bus.simple(NM, devs.z(d), NM_WIFI, "GetAllAccessPoints", 3000) orelse continue;
        var it: Iter = undefined;
        if (c.dbus_message_iter_init(r, &it) != 0) aps.fromArray(&it);
        c.dbus_message_unref(r);
        for (0..aps.n) |i| {
            const ap = readAp(bus, aps.z(i)) orelse continue;
            if (!std.mem.eql(u8, ap.ssidStr(), ssid)) continue;
            if (best != null and best.?.strength >= ap.strength) continue;
            best = ap;
            best_dev = d;
            const p = aps.get(i);
            @memcpy(best_ap[0..p.len], p);
            best_ap[p.len] = 0;
        }
    }
    const ap = best orelse return o.print("Error: No network with SSID '{s}' found.", .{ssid});

    // 設定: SSID と(あれば)パスワード。WPA3 だけの所は sae、それ以外は wpa-psk。残りは NetworkManager が補う
    const m = Bus.call(NM, NM_PATH, NM, "AddAndActivateConnection") orelse return;
    var w: Iter = undefined;
    c.dbus_message_iter_init_append(m, &w);
    var outer: Iter = undefined;
    _ = c.dbus_message_iter_open_container(&w, c.DBUS_TYPE_ARRAY, "{sa{sv}}", &outer);
    appendSection(&outer, "802-11-wireless", &.{.{ .key = "ssid", .bytes = ssid }});
    if (pw) |p| {
        const sae_only = (ap.rsn & 0x400) != 0 and (ap.rsn & 0x100) == 0;
        appendSection(&outer, "802-11-wireless-security", &.{
            .{ .key = "key-mgmt", .str = if (sae_only) "sae" else "wpa-psk" },
            .{ .key = "psk", .str = p },
        });
    }
    _ = c.dbus_message_iter_close_container(&w, &outer);
    var dev_p: [*c]const u8 = devs.z(best_dev);
    var ap_p: [*c]const u8 = &best_ap;
    _ = c.dbus_message_iter_append_basic(&w, c.DBUS_TYPE_OBJECT_PATH, @ptrCast(&dev_p));
    _ = c.dbus_message_iter_append_basic(&w, c.DBUS_TYPE_OBJECT_PATH, @ptrCast(&ap_p));
    const r = bus.send(m, 30_000) orelse return nmErr(bus, o);
    defer c.dbus_message_unref(r);
    var it: Iter = undefined;
    if (c.dbus_message_iter_init(r, &it) == 0) return;
    var conn_buf: [128:0]u8 = undefined;
    const conn = getS(&it) orelse "";
    @memcpy(conn_buf[0..@min(conn.len, 127)], conn[0..@min(conn.len, 127)]);
    conn_buf[@min(conn.len, 127)] = 0;
    _ = c.dbus_message_iter_next(&it);
    var act_buf: [128:0]u8 = undefined;
    const act = getS(&it) orelse "";
    @memcpy(act_buf[0..@min(act.len, 127)], act[0..@min(act.len, 127)]);
    act_buf[@min(act.len, 127)] = 0;
    if (!waitActive(bus, &act_buf, devs.z(best_dev), o)) {
        // nmcli と同じく、つながらなかった新しい接続の設定は消す(違うパスワードを保存しない)
        if (conn.len > 0) if (bus.simple(NM, &conn_buf, NM_CONN, "Delete", 5000)) |d| c.dbus_message_unref(d);
    }
}

const Kv = struct { key: [*:0]const u8, str: ?[]const u8 = null, bytes: ?[]const u8 = null };

fn appendSection(outer: *Iter, name: [*:0]const u8, kvs: []const Kv) void {
    var e: Iter = undefined;
    _ = c.dbus_message_iter_open_container(outer, c.DBUS_TYPE_DICT_ENTRY, null, &e);
    var n: [*c]const u8 = name;
    _ = c.dbus_message_iter_append_basic(&e, c.DBUS_TYPE_STRING, @ptrCast(&n));
    var d: Iter = undefined;
    _ = c.dbus_message_iter_open_container(&e, c.DBUS_TYPE_ARRAY, "{sv}", &d);
    for (kvs) |kv| {
        var de: Iter = undefined;
        _ = c.dbus_message_iter_open_container(&d, c.DBUS_TYPE_DICT_ENTRY, null, &de);
        var k: [*c]const u8 = kv.key;
        _ = c.dbus_message_iter_append_basic(&de, c.DBUS_TYPE_STRING, @ptrCast(&k));
        var v: Iter = undefined;
        if (kv.bytes) |b| {
            _ = c.dbus_message_iter_open_container(&de, c.DBUS_TYPE_VARIANT, "ay", &v);
            var arr: Iter = undefined;
            _ = c.dbus_message_iter_open_container(&v, c.DBUS_TYPE_ARRAY, "y", &arr);
            var p: [*c]const u8 = b.ptr;
            _ = c.dbus_message_iter_append_fixed_array(&arr, c.DBUS_TYPE_BYTE, @ptrCast(&p), @intCast(b.len));
            _ = c.dbus_message_iter_close_container(&v, &arr);
        } else {
            _ = c.dbus_message_iter_open_container(&de, c.DBUS_TYPE_VARIANT, "s", &v);
            var zb: [160]u8 = undefined;
            const s = kv.str orelse "";
            const l = @min(s.len, zb.len - 1);
            @memcpy(zb[0..l], s[0..l]);
            zb[l] = 0;
            var p: [*c]const u8 = &zb;
            _ = c.dbus_message_iter_append_basic(&v, c.DBUS_TYPE_STRING, @ptrCast(&p));
            @memset(&zb, 0);
        }
        _ = c.dbus_message_iter_close_container(&de, &v);
        _ = c.dbus_message_iter_close_container(&d, &de);
    }
    _ = c.dbus_message_iter_close_container(&e, &d);
    _ = c.dbus_message_iter_close_container(outer, &e);
}

fn connectionUp(bus: *Bus, id: []const u8, o: *Out) void {
    var cb: [128:0]u8 = undefined;
    const conn = findConnection(bus, id, &cb) orelse return o.print("Error: unknown connection '{s}'.", .{id});
    const m = Bus.call(NM, NM_PATH, NM, "ActivateConnection") orelse return;
    var p1: [*c]const u8 = conn;
    var p2: [*c]const u8 = "/";
    var p3: [*c]const u8 = "/";
    _ = c.dbus_message_append_args(m, c.DBUS_TYPE_OBJECT_PATH, &p1, c.DBUS_TYPE_OBJECT_PATH, &p2, c.DBUS_TYPE_OBJECT_PATH, &p3, c.DBUS_TYPE_INVALID);
    const r = bus.send(m, 30_000) orelse return nmErr(bus, o);
    defer c.dbus_message_unref(r);
    var it: Iter = undefined;
    if (c.dbus_message_iter_init(r, &it) == 0) return;
    var ab: [128:0]u8 = undefined;
    const act = getS(&it) orelse return;
    const l = @min(act.len, 127);
    @memcpy(ab[0..l], act[0..l]);
    ab[l] = 0;
    // 失敗の理由を読むための機器(Devices の最初)
    var devs = Paths{};
    bus.getPaths(NM, &ab, NM_ACTIVE, "Devices", &devs);
    _ = waitActive(bus, &ab, if (devs.n > 0) devs.z(0) else null, o);
}

fn connectionDown(bus: *Bus, id: []const u8, o: *Out) void {
    var acts = Paths{};
    bus.getPaths(NM, NM_PATH, NM, "ActiveConnections", &acts);
    for (0..acts.n) |i| {
        var ib: [128]u8 = undefined;
        const aid = bus.getStr(NM, acts.z(i), NM_ACTIVE, "Id", &ib) orelse continue;
        if (!std.mem.eql(u8, aid, id)) continue;
        const m = Bus.call(NM, NM_PATH, NM, "DeactivateConnection") orelse return;
        var p: [*c]const u8 = acts.z(i);
        _ = c.dbus_message_append_args(m, c.DBUS_TYPE_OBJECT_PATH, &p, c.DBUS_TYPE_INVALID);
        const r = bus.send(m, 10_000) orelse return nmErr(bus, o);
        c.dbus_message_unref(r);
        return;
    }
    o.print("Error: '{s}' is not an active connection.", .{id});
}

/// バーに出す SSID(つながっている Wi-Fi のアクセスポイント)
pub fn activeSsid(buf: []u8) ?[]const u8 {
    // つながっているアクセスポイントだけを読む(見えている全部を読むと数十回の往復になり、バーの更新のたびに止まる)
    var bus = Bus.open() orelse return null;
    defer bus.close();
    var devs = Paths{};
    wifiDevices(&bus, &devs);
    for (0..devs.n) |d| {
        var abuf: [128:0]u8 = undefined;
        const active = bus.getStr(NM, devs.z(d), NM_WIFI, "ActiveAccessPoint", abuf[0..127]) orelse continue;
        if (active.len < 2) continue; // "/" = つながっていない
        abuf[active.len] = 0;
        const ap = readAp(&bus, @ptrCast(&abuf)) orelse continue;
        const s = ap.ssidStr();
        const n = @min(s.len, buf.len);
        @memcpy(buf[0..n], s[0..n]);
        return buf[0..n];
    }
    return null;
}

// ---------------------------------------------------------------------------
// BlueZ(bluetoothctl / bt-connect.sh の代わり)
// ---------------------------------------------------------------------------

const BtDev = struct {
    path: [128:0]u8 = undefined,
    addr: [17]u8 = undefined,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    paired: bool = false,
    connected: bool = false,
    audio: bool = false,
};

const BtState = struct {
    adapter: [128:0]u8 = undefined,
    has_adapter: bool = false,
    powered: bool = false,
    power_state: [24]u8 = undefined,
    power_state_len: usize = 0,
    devs: [48]BtDev = undefined,
    n: usize = 0,
};

/// ObjectManager.GetManagedObjects で、アダプタ(最初の 1 つ)と機器を読む
fn readBluez(bus: *Bus, st: *BtState) bool {
    const r = bus.simple(BLUEZ, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", 5000) orelse return false;
    defer c.dbus_message_unref(r);
    var top: Iter = undefined;
    if (c.dbus_message_iter_init(r, &top) == 0 or c.dbus_message_iter_get_arg_type(&top) != c.DBUS_TYPE_ARRAY) return false;
    var objs: Iter = undefined;
    c.dbus_message_iter_recurse(&top, &objs);
    while (c.dbus_message_iter_get_arg_type(&objs) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&objs)) {
        var oe: Iter = undefined;
        c.dbus_message_iter_recurse(&objs, &oe);
        const path = getS(&oe) orelse continue;
        if (path.len >= 128) continue;
        _ = c.dbus_message_iter_next(&oe);
        if (c.dbus_message_iter_get_arg_type(&oe) != c.DBUS_TYPE_ARRAY) continue;
        var ifs: Iter = undefined;
        c.dbus_message_iter_recurse(&oe, &ifs);
        while (c.dbus_message_iter_get_arg_type(&ifs) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&ifs)) {
            var ie: Iter = undefined;
            c.dbus_message_iter_recurse(&ifs, &ie);
            const iface = getS(&ie) orelse continue;
            _ = c.dbus_message_iter_next(&ie);
            if (std.mem.eql(u8, iface, ADAPTER) and !st.has_adapter) {
                st.has_adapter = true;
                @memcpy(st.adapter[0..path.len], path);
                st.adapter[path.len] = 0;
                eachDict(&ie, st, struct {
                    fn f(s: *BtState, k: []const u8, v: *Iter) void {
                        if (std.mem.eql(u8, k, "Powered")) s.powered = getB(v) orelse false;
                        if (std.mem.eql(u8, k, "PowerState")) if (getS(v)) |ps| {
                            s.power_state_len = @min(ps.len, s.power_state.len);
                            @memcpy(s.power_state[0..s.power_state_len], ps[0..s.power_state_len]);
                        };
                    }
                }.f);
            } else if (std.mem.eql(u8, iface, DEVICE) and st.n < st.devs.len) {
                var d = BtDev{};
                @memcpy(d.path[0..path.len], path);
                d.path[path.len] = 0;
                @memset(&d.addr, '0');
                var have_alias = false;
                const Ctx = struct { d: *BtDev, alias: *bool };
                eachDict(&ie, Ctx{ .d = &d, .alias = &have_alias }, struct {
                    fn f(x: Ctx, k: []const u8, v: *Iter) void {
                        if (std.mem.eql(u8, k, "Address")) {
                            if (getS(v)) |s| if (s.len == 17) @memcpy(&x.d.addr, s);
                        } else if (std.mem.eql(u8, k, "Alias") or (std.mem.eql(u8, k, "Name") and !x.alias.*)) {
                            if (getS(v)) |s| {
                                x.d.name_len = @min(s.len, x.d.name.len);
                                @memcpy(x.d.name[0..x.d.name_len], s[0..x.d.name_len]);
                                if (k[0] == 'A') x.alias.* = true;
                            }
                        } else if (std.mem.eql(u8, k, "Paired")) {
                            x.d.paired = getB(v) orelse false;
                        } else if (std.mem.eql(u8, k, "Connected")) {
                            x.d.connected = getB(v) orelse false;
                        } else if (std.mem.eql(u8, k, "UUIDs")) {
                            if (c.dbus_message_iter_get_arg_type(v) != c.DBUS_TYPE_ARRAY) return;
                            var a: Iter = undefined;
                            c.dbus_message_iter_recurse(v, &a);
                            while (getS(&a)) |u| : (_ = c.dbus_message_iter_next(&a)) {
                                // 0000110b = Audio Sink(イヤホン・スピーカー)
                                if (std.ascii.startsWithIgnoreCase(u, "0000110b")) x.d.audio = true;
                            }
                        }
                    }
                }.f);
                st.devs[st.n] = d;
                st.n += 1;
            }
        }
    }
    return true;
}

fn btErr(bus: *const Bus, o: *Out, what: []const u8) void {
    if (bus.errName().len == 0) {
        o.print("Failed to {s}: BlueZ が応答しません\n", .{what});
    } else o.print("Failed to {s}: {s} {s}\n", .{ what, bus.errName(), bus.errMsg() });
}

fn btctl(bus: *Bus, a: *Args, o: *Out) void {
    var st = std.heap.c_allocator.create(BtState) catch return;
    defer std.heap.c_allocator.destroy(st);
    st.* = .{};
    if (!readBluez(bus, st)) return o.add("Failed: BlueZ(bluetoothd)が応答しません\n");
    if (a.is(1, "show")) {
        if (!st.has_adapter) return o.add("No default controller available\n");
        o.print("Controller {s}\n\tPowered: {s}\n\tPowerState: {s}\n", .{ st.adapter[0..std.mem.indexOfScalar(u8, &st.adapter, 0).?], if (st.powered) "yes" else "no", st.power_state[0..st.power_state_len] });
        return;
    }
    if (a.is(1, "devices")) {
        const want_paired = a.is(2, "Paired");
        const want_conn = a.is(2, "Connected");
        for (st.devs[0..st.n]) |*d| {
            if (want_paired and !d.paired) continue;
            if (want_conn and !d.connected) continue;
            o.print("Device {s} {s}\n", .{ &d.addr, d.name[0..d.name_len] });
        }
        return;
    }
    if (a.is(1, "power")) {
        if (!st.has_adapter) return o.add("Failed: No default controller available\n");
        if (a.is(2, "on")) rfkillUnblockBt();
        if (!bus.setBool(BLUEZ, &st.adapter, ADAPTER, "Powered", a.is(2, "on"))) return btErr(bus, o, "set power");
        o.add("Changing power succeeded\n");
        return;
    }
    if (a.is(1, "disconnect")) {
        const d = findDev(st, a.get(2)) orelse return o.add("Failed: Device not available\n");
        const r = bus.simple(BLUEZ, &d.path, DEVICE, "Disconnect", 10_000) orelse return btErr(bus, o, "disconnect");
        c.dbus_message_unref(r);
        o.add("Successful disconnected\n");
        return;
    }
    o.print("Failed: 対応していない操作です({s})\n", .{a.get(1)});
}

fn findDev(st: *BtState, mac: []const u8) ?*BtDev {
    for (st.devs[0..st.n]) |*d| if (std.ascii.eqlIgnoreCase(&d.addr, mac)) return d;
    return null;
}

/// rfkill のソフトブロックを外す(/dev/rfkill に CHANGE_ALL を書く。rfkill unblock bluetooth と同じ)
fn rfkillUnblockBt() void {
    if (builtin.os.tag != .linux) return;
    const fd = std.posix.open("/dev/rfkill", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch return;
    defer std.posix.close(fd);
    // struct rfkill_event { u32 idx; u8 type; u8 op; u8 soft; u8 hard; }  type 2 = BLUETOOTH, op 3 = CHANGE_ALL
    var ev = [_]u8{ 0, 0, 0, 0, 2, 3, 0, 0 };
    _ = std.posix.write(fd, &ev) catch {};
}

/// 電源を入れる(ブロックされていれば外してから。外した直後はアダプタの準備に少しかかる)
fn powerOn(bus: *Bus, st: *BtState, o: *Out) bool {
    if (!st.has_adapter) {
        o.add("Failed: Bluetooth のアダプタがありません\n");
        return false;
    }
    if (st.powered) return true;
    rfkillUnblockBt();
    var tries: u32 = 0;
    while (tries < 4) : (tries += 1) {
        if (bus.setBool(BLUEZ, &st.adapter, ADAPTER, "Powered", true)) {
            st.powered = true;
            return true;
        }
        sleepMs(700);
    }
    if (std.mem.indexOf(u8, bus.errName(), "Blocked") != null) {
        o.add("Failed: Bluetooth がブロックされています(rfkill unblock bluetooth を試してください)\n");
    } else o.print("Failed: 電源を入れられません: {s} {s}\n", .{ bus.errName(), bus.errMsg() });
    return false;
}

fn ameBt(bus: *Bus, a: *Args, o: *Out) void {
    var st = std.heap.c_allocator.create(BtState) catch return;
    defer std.heap.c_allocator.destroy(st);
    st.* = .{};
    if (!readBluez(bus, st)) return o.add("Failed: BlueZ(bluetoothd)が応答しません\n");
    if (a.is(1, "power")) {
        if (a.is(2, "off")) {
            if (!st.has_adapter or bus.setBool(BLUEZ, &st.adapter, ADAPTER, "Powered", false)) o.add("ok\n") else o.add("Failed: 電源を切れません\n");
        } else if (powerOn(bus, st, o)) o.add("ok\n");
        return;
    }
    if (a.is(1, "scan")) {
        if (!powerOn(bus, st, o)) return;
        const secs = std.fmt.parseInt(u32, a.get(2), 10) catch 10;
        discover(bus, st, secs);
        o.add("ok\n");
        return;
    }
    if (a.is(1, "remove")) {
        // 登録(ペアリング)を消す。つながっていれば BlueZ が切ってから消す
        if (!st.has_adapter) return o.add("Failed: Bluetooth のアダプタがありません\n");
        const d = findDev(st, a.get(2)) orelse return o.add("Failed: Device not available\n");
        const m = Bus.call(BLUEZ, &st.adapter, ADAPTER, "RemoveDevice") orelse return o.add("Failed: D-Bus のメッセージを作れません\n");
        var p: [*c]const u8 = &d.path;
        _ = c.dbus_message_append_args(m, c.DBUS_TYPE_OBJECT_PATH, &p, c.DBUS_TYPE_INVALID);
        const r = bus.send(m, 10_000) orelse return btErr(bus, o, "remove");
        c.dbus_message_unref(r);
        o.add("Device has been removed\n");
        return;
    }
    const pair = a.is(1, "pair");
    if (!pair and !a.is(1, "connect")) return o.print("Failed: 対応していない操作です({s})\n", .{a.get(1)});
    const mac = a.get(2);
    const script = a.get(3);
    if (!powerOn(bus, st, o)) return;
    var d = (findDev(st, mac) orelse return o.add("Failed: Device not available\n")).*;
    if (pair and !d.paired) {
        _ = bus.setBool(BLUEZ, &st.adapter, ADAPTER, "Pairable", true);
        // エージェントを登録していないので、BlueZ は「入力も表示も無い」機器として名乗る(イヤホン・スピーカー・マウスは通る)
        if (!pairDev(bus, &d)) {
            const n = bus.errName();
            if (std.mem.indexOf(u8, n, "AlreadyExists") == null) {
                if (std.mem.indexOf(u8, n, "Authentication") == null) return btErr(bus, o, "pair");
                // 前のペアリングの情報が食い違っている: 消して探し直してからもう 1 回
                const m = Bus.call(BLUEZ, &st.adapter, ADAPTER, "RemoveDevice") orelse return;
                var p: [*c]const u8 = &d.path;
                _ = c.dbus_message_append_args(m, c.DBUS_TYPE_OBJECT_PATH, &p, c.DBUS_TYPE_INVALID);
                if (bus.send(m, 5000)) |r| c.dbus_message_unref(r);
                sleepMs(2000);
                discover(bus, st, 8);
                st.* = .{};
                if (!readBluez(bus, st)) return o.add("Failed: BlueZ が応答しません\n");
                d = (findDev(st, mac) orelse return o.add("Failed: 機器が見つかりません(ペアリングの待ち受けにしてください)\n")).*;
                if (!pairDev(bus, &d) and std.mem.indexOf(u8, bus.errName(), "AlreadyExists") == null) return btErr(bus, o, "pair");
            }
        }
        o.add("Pairing successful\n");
    }
    // 信頼済みにする(次から機器側からの自動接続も通る)
    _ = bus.setBool(BLUEZ, &d.path, DEVICE, "Trusted", true);
    // 接続(AirPods は 1 回目が失敗しやすいので、少し待ってもう 1 回。
    // 「音声の受け口が無い」(profile-unavailable)なら WirePlumber を再起動してから)
    if (!connectDev(bus, &d)) {
        if (std.mem.indexOf(u8, bus.errMsg(), "profile-unavailable") != null) {
            runScript(script, &.{"--restart-wireplumber"}, null);
            sleepMs(3000);
        } else sleepMs(2000);
        if (!connectDev(bus, &d)) return btErr(bus, o, "connect");
    }
    // イヤホン・スピーカーなら音の出力先にする(pactl。bt-connect.sh --audio)
    if (d.audio and script.len > 0) runScript(script, &.{ "--audio", mac }, o);
    o.add("Connection successful\n");
}

fn pairDev(bus: *Bus, d: *BtDev) bool {
    const r = bus.simple(BLUEZ, &d.path, DEVICE, "Pair", 40_000) orelse return false;
    c.dbus_message_unref(r);
    return true;
}

fn connectDev(bus: *Bus, d: *BtDev) bool {
    if (bus.simple(BLUEZ, &d.path, DEVICE, "Connect", 15_000)) |r| {
        c.dbus_message_unref(r);
        return true;
    }
    if (std.mem.indexOf(u8, bus.errName(), "AlreadyConnected") != null) return true;
    // 返事が遅れただけでつながっていることがある
    return bus.getBool(BLUEZ, &d.path, DEVICE, "Connected") orelse false;
}

fn discover(bus: *Bus, st: *BtState, secs: u32) void {
    if (bus.simple(BLUEZ, &st.adapter, ADAPTER, "StartDiscovery", 5000)) |r| c.dbus_message_unref(r);
    sleepMs(@as(u64, @min(secs, 60)) * 1000);
    if (bus.simple(BLUEZ, &st.adapter, ADAPTER, "StopDiscovery", 5000)) |r| c.dbus_message_unref(r);
}

/// sh <script> <args...> を実行し、出力を o に足す(o が null なら捨てる)。
/// ame-shell は SIGCHLD を無視している(子は自動で片付く)ので std.process.Child.wait は使えない
fn runScript(script: []const u8, args: []const []const u8, o: ?*Out) void {
    if (script.len == 0 or args.len > 4) return;
    var zb: [6][160:0]u8 = undefined;
    var av: [6]?[*:0]const u8 = .{null} ** 6;
    const all = [_][]const u8{ "sh", script } ++ [_][]const u8{""} ** 4;
    var n: usize = 0;
    for (0..2 + args.len) |i| {
        const s = if (i < 2) all[i] else args[i - 2];
        const l = @min(s.len, 159);
        @memcpy(zb[i][0..l], s[0..l]);
        zb[i][l] = 0;
        av[i] = &zb[i];
        n += 1;
    }
    var pid: c_int = 0;
    const fd = sys.spawnReaderAll(av[0..n], &pid) orelse return;
    defer _ = c.close(fd);
    // 読み口は非ブロックで返るので、ブロックに戻して最後まで読む
    _ = c.fcntl(fd, c.F_SETFL, @as(c_int, 0));
    var b: [2048]u8 = undefined;
    while (true) {
        const r = c.read(fd, &b, b.len);
        if (r <= 0) break;
        if (o) |out| out.add(b[0..@intCast(r)]);
    }
}
