// スリープから戻ったら、スリープの前につながっていた AirPods などのイヤホン・スピーカーをつなぎ直す。
//
// スリープ中は PC の Bluetooth も止まるので、接続そのものは切れる(つないだままにはできない)。そこで:
//   スリープの直前(logind / ConsoleKit の PrepareForSleep(true))… 接続中のイヤホン・スピーカーを覚える
//   戻った直後(PrepareForSleep(false))… 2 秒待って(Bluetooth が立ち上がるのを待つ)、覚えた機器を
//       ame-bt connect でつなぎ直す(信頼済みにして、音の出力先にもする)。つながるまで 4 秒おきに最大 5 回
// AirPods はケースに戻さずに耳に着けたままでも、iPhone などより先にこの PC へつなぎ直す。
// 設定: airpods { reconnect-after-sleep off } で止める。Linux のみ(BlueZ)。
const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig").App;
const loop = @import("platform/loop.zig");
const netdbus = @import("platform/netdbus.zig");

const log = std.log.scoped(.btresume);

const MAX_DEV = 4;

var st: struct {
    app: ?*App = null,
    macs: [MAX_DEV][17]u8 = undefined,
    n: usize = 0,
    timer: ?loop.Timer = null,
    thread: ?std.Thread = null,
    busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    script: [512]u8 = undefined,
    script_len: usize = 0,
} = .{};

/// スリープを少し待ってもらう(logind / ConsoleKit の delay inhibitor)。PrepareForSleep(true) を受けて機器を覚え終わるまで。
/// これが無いと、合図を受け取る前に眠ってしまい、戻ってから見ると機器はもう切れている
var inhibit_fd: c_int = -1;

/// システムの D-Bus につながった(syswatch.zig から)
pub fn init(app: *App, conn: *c.DBusConnection) void {
    if (@import("builtin").os.tag != .linux or !app.cfg.bt_reconnect) return;
    st.app = app;
    takeInhibitor(conn);
}

fn takeInhibitor(conn: *c.DBusConnection) void {
    if (inhibit_fd >= 0) return;
    const targets = [_][3][*:0]const u8{
        .{ "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager" },
        .{ "org.freedesktop.ConsoleKit", "/org/freedesktop/ConsoleKit/Manager", "org.freedesktop.ConsoleKit.Manager" },
    };
    for (targets) |t| {
        const m = c.dbus_message_new_method_call(t[0], t[1], t[2], "Inhibit") orelse continue;
        defer c.dbus_message_unref(m);
        var what: [*c]const u8 = "sleep";
        var who: [*c]const u8 = "ame-shell";
        var why: [*c]const u8 = "Bluetooth のイヤホンを覚えて、戻ったらつなぎ直す";
        var mode: [*c]const u8 = "delay";
        _ = c.dbus_message_append_args(m, c.DBUS_TYPE_STRING, &what, c.DBUS_TYPE_STRING, &who, c.DBUS_TYPE_STRING, &why, c.DBUS_TYPE_STRING, &mode, c.DBUS_TYPE_INVALID);
        const r = c.dbus_connection_send_with_reply_and_block(conn, m, 2000, null) orelse continue;
        defer c.dbus_message_unref(r);
        var fd: c_int = -1;
        if (c.dbus_message_get_args(r, null, c.DBUS_TYPE_UNIX_FD, &fd, c.DBUS_TYPE_INVALID) != 0 and fd >= 0) {
            inhibit_fd = fd;
            return;
        }
    }
}

fn releaseInhibitor() void {
    if (inhibit_fd >= 0) _ = c.close(inhibit_fd);
    inhibit_fd = -1;
}

/// logind / ConsoleKit の PrepareForSleep(syswatch.zig から)。sleeping = true でスリープへ、false で戻った
pub fn prepareForSleep(app: *App, conn: *c.DBusConnection, sleeping: bool) void {
    if (@import("builtin").os.tag != .linux or !app.cfg.bt_reconnect) return;
    st.app = app;
    if (sleeping) {
        remember();
        // 覚えたので眠ってよい
        releaseInhibitor();
        return;
    }
    // 次のスリープのために、また待ってもらう
    takeInhibitor(conn);
    if (st.n == 0) return;
    if (st.timer == null) {
        const t = loop.Timer.init() catch return;
        app.loop.add(t.fd, c.EPOLLIN, app, onTimer) catch return;
        st.timer = t;
    }
    st.timer.?.arm(2000, 0);
}

/// 接続中のイヤホン・スピーカーを覚える(スリープの直前。すぐ返る D-Bus の問い合わせ)
fn remember() void {
    if (st.busy.load(.acquire)) return; // まだつなぎ直している途中(覚えた機器をそのまま使う)
    st.n = 0;
    var out: [2048]u8 = undefined;
    const s = netdbus.run(&.{ "bluetoothctl", "devices", "Audio" }, &out) orelse return;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (st.n >= MAX_DEV) break;
        if (!std.mem.startsWith(u8, line, "Device ") or line.len < 7 + 17) continue;
        @memcpy(&st.macs[st.n], line[7..24]);
        st.n += 1;
    }
    if (st.n > 0) log.info("スリープの前に接続していた音の機器: {d} 台(戻ったらつなぎ直します)", .{st.n});
}

fn onTimer(ctx: *anyopaque, _: c_int, _: u32) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (st.timer) |t| t.ack();
    if (st.busy.load(.acquire)) return;
    const s = std.fmt.bufPrint(&st.script, "{s}/bt-connect.sh", .{app.shareDir()}) catch return;
    st.script_len = s.len;
    if (st.thread) |t| t.join();
    st.busy.store(true, .release);
    st.thread = std.Thread.spawn(.{ .stack_size = 256 << 10 }, worker, .{}) catch {
        st.busy.store(false, .release);
        return;
    };
}

fn connected(mac: []const u8) bool {
    var out: [2048]u8 = undefined;
    const s = netdbus.run(&.{ "bluetoothctl", "devices", "Connected" }, &out) orelse return false;
    return std.mem.indexOf(u8, s, mac) != null;
}

fn worker() void {
    defer st.busy.store(false, .release);
    const script = st.script[0..st.script_len];
    var tries: u32 = 0;
    while (tries < 5) : (tries += 1) {
        if (tries > 0) std.time.sleep(4 * std.time.ns_per_s);
        var left: usize = 0;
        for (st.macs[0..st.n]) |*mac| {
            if (connected(mac)) continue;
            var out: [1024]u8 = undefined;
            const r = netdbus.run(&.{ "ame-bt", "connect", mac, script }, &out) orelse "";
            if (std.mem.indexOf(u8, r, "successful") == null) left += 1;
        }
        if (left == 0) {
            log.info("スリープから戻ったので、イヤホン・スピーカーをつなぎ直しました", .{});
            return;
        }
    }
    log.warn("スリープから戻ったあと、イヤホン・スピーカーをつなぎ直せませんでした", .{});
}

/// 覚えている機器(試験・ame-ctl debug-sleep 用)
pub fn status(buf: []u8) []const u8 {
    var w = std.io.fixedBufferStream(buf);
    w.writer().print("inhibitor={s} devices={d}", .{ if (inhibit_fd >= 0) "held" else "none", st.n }) catch {};
    for (st.macs[0..st.n]) |*m| w.writer().print(" {s}", .{m}) catch {};
    return w.getWritten();
}
