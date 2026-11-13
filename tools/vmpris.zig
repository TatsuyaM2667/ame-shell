// vmpris: 試験用の偽の音楽プレイヤー(MPRIS)。ヘッドレス River で「再生中」の画面(波形・曲のカード)を試すため。
// 使い方: vmpris [曲名]   セッションの D-Bus に org.mpris.MediaPlayer2.vmpris として現れ、ずっと「再生中」と答える。
// 音は出さない(波形を試すときは pw-play などで別に鳴らす)。止めるのは kill。
const std = @import("std");
const c = @cImport(@cInclude("dbus/dbus.h"));

const DBusError = extern struct { name: ?[*:0]const u8 = null, message: ?[*:0]const u8 = null, dummy: c_uint = 0, padding1: ?*anyopaque = null };

var title: [*:0]const u8 = "vmpris test tone";

fn str(it: *c.DBusMessageIter, s: [*:0]const u8) void {
    var p: [*c]const u8 = s;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_STRING, @ptrCast(&p));
}

/// a{sv} に 1 つ(値は文字列 / オブジェクトパス / 文字列の配列)
fn entry(dict: *c.DBusMessageIter, key: [*:0]const u8, sig: [*:0]const u8, val: [*:0]const u8) void {
    var e: c.DBusMessageIter = undefined;
    var v: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(dict, c.DBUS_TYPE_DICT_ENTRY, null, &e);
    str(&e, key);
    _ = c.dbus_message_iter_open_container(&e, c.DBUS_TYPE_VARIANT, sig, &v);
    if (sig[0] == 'a') {
        var a: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&v, c.DBUS_TYPE_ARRAY, "s", &a);
        str(&a, val);
        _ = c.dbus_message_iter_close_container(&v, &a);
    } else if (sig[0] == 'o') {
        var p: [*c]const u8 = val;
        _ = c.dbus_message_iter_append_basic(&v, c.DBUS_TYPE_OBJECT_PATH, @ptrCast(&p));
    } else str(&v, val);
    _ = c.dbus_message_iter_close_container(&e, &v);
    _ = c.dbus_message_iter_close_container(dict, &e);
}

/// Player の全プロパティ(a{sv})
fn playerProps(it: *c.DBusMessageIter) void {
    var dict: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_ARRAY, "{sv}", &dict);
    entry(&dict, "PlaybackStatus", "s", "Playing");
    // Metadata は a{sv} の入れ子
    var e: c.DBusMessageIter = undefined;
    var v: c.DBusMessageIter = undefined;
    var md: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(&dict, c.DBUS_TYPE_DICT_ENTRY, null, &e);
    str(&e, "Metadata");
    _ = c.dbus_message_iter_open_container(&e, c.DBUS_TYPE_VARIANT, "a{sv}", &v);
    _ = c.dbus_message_iter_open_container(&v, c.DBUS_TYPE_ARRAY, "{sv}", &md);
    entry(&md, "mpris:trackid", "o", "/vmpris/track/1");
    entry(&md, "xesam:title", "s", title);
    entry(&md, "xesam:artist", "as", "vmpris");
    _ = c.dbus_message_iter_close_container(&v, &md);
    _ = c.dbus_message_iter_close_container(&e, &v);
    _ = c.dbus_message_iter_close_container(&dict, &e);
    _ = c.dbus_message_iter_close_container(it, &dict);
}

pub fn main() u8 {
    var args = std.process.args();
    _ = args.next();
    if (args.next()) |t| title = t;
    var err = DBusError{};
    const errp: *c.DBusError = @ptrCast(&err);
    c.dbus_error_init(errp);
    const conn = c.dbus_bus_get(c.DBUS_BUS_SESSION, errp) orelse {
        std.debug.print("vmpris: セッションの D-Bus に接続できません\n", .{});
        return 1;
    };
    if (c.dbus_bus_request_name(conn, "org.mpris.MediaPlayer2.vmpris", 0, errp) != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
        std.debug.print("vmpris: 名前を取れません\n", .{});
        return 1;
    }
    while (c.dbus_connection_read_write(conn, -1) != 0) {
        while (c.dbus_connection_pop_message(conn)) |m| {
            defer c.dbus_message_unref(m);
            if (c.dbus_message_get_type(m) != c.DBUS_MESSAGE_TYPE_METHOD_CALL) continue;
            const r = c.dbus_message_new_method_return(m) orelse continue;
            defer c.dbus_message_unref(r);
            var it: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(r, &it);
            if (c.dbus_message_is_method_call(m, "org.freedesktop.DBus.Properties", "GetAll") != 0) {
                playerProps(&it);
            } else if (c.dbus_message_is_method_call(m, "org.freedesktop.DBus.Properties", "Get") != 0) {
                // 位置などは 0 と答える(使う側は無ければ無いで動く)
                var v: c.DBusMessageIter = undefined;
                _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_VARIANT, "x", &v);
                var zero: i64 = 0;
                _ = c.dbus_message_iter_append_basic(&v, c.DBUS_TYPE_INT64, @ptrCast(&zero));
                _ = c.dbus_message_iter_close_container(&it, &v);
            }
            // 操作(再生/一時停止など)は空の返事だけ
            _ = c.dbus_connection_send(conn, r, null);
        }
    }
    return 0;
}
