// org.freedesktop.FileManager1: ブラウザなどの「フォルダを開く」「ダウンロードしたファイルをフォルダで表示」を
// ame-filemanager で開く。
//
// Firefox・Chromium などは xdg-open ではなくこの D-Bus の窓口を呼ぶ。名前を持つ人がいなければ D-Bus が
// Thunar を起動していた(Thunar の org.xfce.Thunar.FileManager1.service)。ame-shell が起動時にこの名前を持てば、
// D-Bus は Thunar を起動せず、こちらに届く。通知(notify.zig)と同じ接続を使う。
const std = @import("std");
const c = @import("../c.zig");
const sys = @import("../platform/sys.zig");

const NAME = "org.freedesktop.FileManager1";

/// 名前を持つ(既に別のファイルマネージャが持っていれば何もしない)
pub fn claim(conn: *c.DBusConnection) void {
    const r = c.dbus_bus_request_name(conn, NAME, c.DBUS_NAME_FLAG_DO_NOT_QUEUE, null);
    if (r != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) std.log.info("fm1: {s} は別のアプリが持っています(フォルダを開くのはそのアプリ)", .{NAME});
}

/// FileManager1 の呼び出しなら処理して true
pub fn handle(conn: *c.DBusConnection, msg: *c.DBusMessage) bool {
    const show_items = c.dbus_message_is_method_call(msg, NAME, "ShowItems") != 0 or
        c.dbus_message_is_method_call(msg, NAME, "ShowItemProperties") != 0;
    const show_folders = c.dbus_message_is_method_call(msg, NAME, "ShowFolders") != 0;
    if (!show_items and !show_folders) return false;
    // 1 つ目の引数 as(URI の並び)
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(msg, &it) != 0 and c.dbus_message_iter_get_arg_type(&it) == c.DBUS_TYPE_ARRAY) {
        var arr: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&it, &arr);
        var n: usize = 0;
        while (c.dbus_message_iter_get_arg_type(&arr) == c.DBUS_TYPE_STRING and n < 4) : (n += 1) {
            var s: [*c]const u8 = null;
            c.dbus_message_iter_get_basic(&arr, @ptrCast(&s));
            if (s != null) open(std.mem.sliceTo(s, 0), show_items);
            _ = c.dbus_message_iter_next(&arr);
        }
    }
    if (c.dbus_message_new_method_return(msg)) |reply| {
        _ = c.dbus_connection_send(conn, reply, null);
        c.dbus_message_unref(reply);
    }
    return true;
}

/// フォルダ(ファイルなら、それの入っているフォルダ)を開く。ame-filemanager → thunar → xdg-open
fn open(uri: []const u8, parent: bool) void {
    var pb: [4096]u8 = undefined;
    const path = pathOf(uri, &pb) orelse return;
    const dir = if (parent) std.fs.path.dirname(path) orelse path else path;
    var zb: [4097]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{dir}) catch return;
    // パスは文に埋め込まず "$1" で渡す
    sys.spawnDetachedArgs("PATH=\"$HOME/.local/bin:$PATH\"; command -v ame-filemanager >/dev/null 2>&1 && exec ame-filemanager \"$1\"; command -v thunar >/dev/null 2>&1 && exec thunar \"$1\"; exec xdg-open \"$1\"", &.{z.ptr});
}

/// file:// の URI をパスに(%XX を戻す)。パスならそのまま。file 以外の URI は扱わない
fn pathOf(uri: []const u8, buf: []u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else if (uri.len > 0 and uri[0] == '/') uri else return null;
    // file://ホスト名/パス のホスト名は捨てる
    const p = if (rest.len > 0 and rest[0] != '/') rest[(std.mem.indexOfScalar(u8, rest, '/') orelse return null)..] else rest;
    var n: usize = 0;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (n >= buf.len) return null;
        if (p[i] == '%' and i + 2 < p.len) {
            if (std.fmt.parseInt(u8, p[i + 1 .. i + 3], 16)) |v| {
                buf[n] = v;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        buf[n] = p[i];
        n += 1;
    }
    // 途中に NUL があるパスは扱わない(シェルに渡せない)
    if (std.mem.indexOfScalar(u8, buf[0..n], 0) != null) return null;
    return buf[0..n];
}

test "fm1: URI をパスに" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/home/a/My Files/x.txt", pathOf("file:///home/a/My%20Files/x.txt", &b).?);
    try std.testing.expectEqualStrings("/tmp/日本", pathOf("file://localhost/tmp/%E6%97%A5%E6%9C%AC", &b).?);
    try std.testing.expectEqualStrings("/plain/path", pathOf("/plain/path", &b).?);
    try std.testing.expect(pathOf("https://example.com/", &b) == null);
    try std.testing.expect(pathOf("file:///a%00b", &b) == null);
}
