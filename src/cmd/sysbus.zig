// システムの D-Bus を呼ぶ小さな道具の共通部分(ame-light・ame-power)。libdbus の薄い包み。
const std = @import("std");
pub const c = @cImport(@cInclude("dbus/dbus.h"));

const DBusError = extern struct { name: ?[*:0]const u8 = null, message: ?[*:0]const u8 = null, dummy: c_uint = 0, padding1: ?*anyopaque = null };

pub const Bus = struct {
    conn: *c.DBusConnection,
    /// 最後の失敗の理由(D-Bus のエラー名と文)
    why: [256]u8 = undefined,
    why_len: usize = 0,

    pub fn open() ?Bus {
        var e0 = DBusError{};
        const errp: *c.DBusError = @ptrCast(&e0);
        c.dbus_error_init(errp);
        const conn = c.dbus_bus_get_private(c.DBUS_BUS_SYSTEM, errp) orelse {
            c.dbus_error_free(errp);
            return null;
        };
        c.dbus_connection_set_exit_on_disconnect(conn, 0);
        return .{ .conn = conn };
    }

    pub fn close(self: *Bus) void {
        c.dbus_connection_close(self.conn);
        c.dbus_connection_unref(self.conn);
    }

    pub fn err(self: *const Bus) []const u8 {
        return self.why[0..self.why_len];
    }

    /// m を送って返事を待つ(m は手放す)。失敗なら null で、理由は err()
    pub fn send(self: *Bus, m: *c.DBusMessage) ?*c.DBusMessage {
        defer c.dbus_message_unref(m);
        var e = DBusError{};
        const errp: *c.DBusError = @ptrCast(&e);
        c.dbus_error_init(errp);
        const r = c.dbus_connection_send_with_reply_and_block(self.conn, m, 5000, errp) orelse {
            const s = std.fmt.bufPrint(&self.why, "{s}: {s}", .{
                if (e.name) |p| std.mem.sliceTo(p, 0) else "Error",
                if (e.message) |p| std.mem.sliceTo(p, 0) else "",
            }) catch self.why[0..0];
            self.why_len = s.len;
            c.dbus_error_free(errp);
            return null;
        };
        return r;
    }

    /// 文字列の値のプロパティを buf に写す
    pub fn getStr(self: *Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8, buf: []u8) ?[]const u8 {
        const m = c.dbus_message_new_method_call(dest, path, "org.freedesktop.DBus.Properties", "Get") orelse return null;
        var i: [*c]const u8 = iface;
        var p: [*c]const u8 = prop;
        _ = c.dbus_message_append_args(m, c.DBUS_TYPE_STRING, &i, c.DBUS_TYPE_STRING, &p, c.DBUS_TYPE_INVALID);
        const r = self.send(m) orelse return null;
        defer c.dbus_message_unref(r);
        var top: c.DBusMessageIter = undefined;
        var v: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(r, &top) == 0 or c.dbus_message_iter_get_arg_type(&top) != c.DBUS_TYPE_VARIANT) return null;
        c.dbus_message_iter_recurse(&top, &v);
        return copyStr(&v, buf);
    }

    pub fn setStr(self: *Bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, prop: [*:0]const u8, val: [*:0]const u8) bool {
        const m = c.dbus_message_new_method_call(dest, path, "org.freedesktop.DBus.Properties", "Set") orelse return false;
        var w: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(m, &w);
        var i: [*c]const u8 = iface;
        var p: [*c]const u8 = prop;
        var s: [*c]const u8 = val;
        _ = c.dbus_message_iter_append_basic(&w, c.DBUS_TYPE_STRING, @ptrCast(&i));
        _ = c.dbus_message_iter_append_basic(&w, c.DBUS_TYPE_STRING, @ptrCast(&p));
        var vi: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&w, c.DBUS_TYPE_VARIANT, "s", &vi);
        _ = c.dbus_message_iter_append_basic(&vi, c.DBUS_TYPE_STRING, @ptrCast(&s));
        _ = c.dbus_message_iter_close_container(&w, &vi);
        const r = self.send(m) orelse return false;
        c.dbus_message_unref(r);
        return true;
    }
};

/// 文字列 / オブジェクトパスの値を buf に写す
pub fn copyStr(it: *c.DBusMessageIter, buf: []u8) ?[]const u8 {
    const t = c.dbus_message_iter_get_arg_type(it);
    if (t != c.DBUS_TYPE_STRING and t != c.DBUS_TYPE_OBJECT_PATH) return null;
    var p: [*c]const u8 = null;
    c.dbus_message_iter_get_basic(it, @ptrCast(&p));
    const s = std.mem.sliceTo(p orelse return null, 0);
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}
