// xdg-desktop-portal の「ファイルを開く」画面(FileChooser.OpenFile)で画像を 1 枚選んでもらう。
// ダッシュボードのユーザーの写真から使う。ファイル選択の画面そのものはポータルのバックエンド
// (xdg-desktop-portal-gtk など。river-portals.conf で選ぶ)が出す。
//
// 流れ: OpenFile を呼ぶ → ポータルが画面を出す → 選ばれると Request.Response シグナルで URI が届く。
// 返事は通知サーバと同じセッションバスの接続(notify.zig)に届き、そこから handle() に回ってくる。
// 待つあいだ何も止めない(ブロックしない)。
const std = @import("std");
const c = @import("../c.zig");
const App = @import("../core/app.zig").App;
const loop = @import("../platform/loop.zig");
const deps = @import("../core/deps.zig");

pub const Callback = *const fn (app: *App, path: []const u8) void;

const State = struct {
    /// 送った OpenFile の serial(エラーの返事を見分ける)
    serial: u32 = 0,
    /// 返事のシグナルが届くオブジェクトのパス
    req_path: [256]u8 = undefined,
    req_len: usize = 0,
    rule: [384]u8 = undefined,
    rule_len: usize = 0,
    cb: ?Callback = null,
    since_ms: u64 = 0,
    token_n: u32 = 0,
};
var st = State{};

/// 画像を選ぶ画面を開く。選ばれたら cb(app, 絶対パス) を呼ぶ
pub fn openImage(app: *App, title: [:0]const u8, cb: Callback) void {
    // 前の画面がまだ開いている(1 分以内)なら重ねて開かない
    if (st.cb != null and loop.nowMs() -| st.since_ms < 60_000) return;
    const conn = app.notifs.connection() orelse {
        fail(app, "セッションの D-Bus に接続できません");
        return;
    };
    // 返事のパス: /org/freedesktop/portal/desktop/request/<自分のバス名の : を除き . を _ に>/<token>
    const uniq = std.mem.sliceTo(c.dbus_bus_get_unique_name(conn) orelse {
        fail(app, "D-Bus の名前が分かりません");
        return;
    }, 0);
    var sender: [64]u8 = undefined;
    var sn: usize = 0;
    for (uniq) |ch| {
        if (ch == ':') continue;
        if (sn >= sender.len) break;
        sender[sn] = if (ch == '.') '_' else ch;
        sn += 1;
    }
    st.token_n += 1;
    var tok_buf: [32]u8 = undefined;
    const token = std.fmt.bufPrintZ(&tok_buf, "ame_pick_{d}", .{st.token_n}) catch return;
    const rp = std.fmt.bufPrint(&st.req_path, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ sender[0..sn], token }) catch return;
    st.req_len = rp.len;
    const rule = std.fmt.bufPrintZ(&st.rule, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{rp}) catch return;
    st.rule_len = rule.len;
    c.dbus_bus_add_match(conn, rule.ptr, null);

    const msg = c.dbus_message_new_method_call("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.FileChooser", "OpenFile") orelse return;
    defer c.dbus_message_unref(msg);
    var it: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(msg, &it);
    appendStr(&it, "");
    appendStr(&it, title.ptr);
    // オプション a{sv}
    var opts: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "{sv}", &opts);
    {
        var e: c.DBusMessageIter = undefined;
        var v: c.DBusMessageIter = undefined;
        openEntry(&opts, &e, &v, "handle_token", "s");
        appendStr(&v, token.ptr);
        closeEntry(&opts, &e, &v);

        openEntry(&opts, &e, &v, "modal", "b");
        var yes: c.dbus_bool_t = 1;
        _ = c.dbus_message_iter_append_basic(&v, c.DBUS_TYPE_BOOLEAN, &yes);
        closeEntry(&opts, &e, &v);

        // 絞り込み: [("画像", [(1, "image/png"), (1, "image/jpeg"), …])](1 = MIME の種類)
        openEntry(&opts, &e, &v, "filters", "a(sa(us))");
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&v, c.DBUS_TYPE_ARRAY, "(sa(us))", &arr);
        var stc: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&arr, c.DBUS_TYPE_STRUCT, null, &stc);
        appendStr(&stc, "画像");
        var pats: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&stc, c.DBUS_TYPE_ARRAY, "(us)", &pats);
        for ([_][*:0]const u8{ "image/png", "image/jpeg", "image/gif", "image/bmp", "image/svg+xml" }) |mime| {
            var p: c.DBusMessageIter = undefined;
            _ = c.dbus_message_iter_open_container(&pats, c.DBUS_TYPE_STRUCT, null, &p);
            var kind: u32 = 1;
            _ = c.dbus_message_iter_append_basic(&p, c.DBUS_TYPE_UINT32, &kind);
            appendStr(&p, mime);
            _ = c.dbus_message_iter_close_container(&pats, &p);
        }
        _ = c.dbus_message_iter_close_container(&stc, &pats);
        _ = c.dbus_message_iter_close_container(&arr, &stc);
        _ = c.dbus_message_iter_close_container(&v, &arr);
        closeEntry(&opts, &e, &v);

        // 最初に開く場所: ~/Pictures(無ければホーム)。バイト列(末尾の 0 を含む)で渡す
        var fb: [512]u8 = undefined;
        const home = std.posix.getenv("HOME") orelse "/";
        const pics = std.fmt.bufPrintZ(&fb, "{s}/Pictures", .{home}) catch null;
        if (pics) |p| {
            const folder: [:0]const u8 = if (c.access(p.ptr, c.R_OK) == 0) p else std.fmt.bufPrintZ(&fb, "{s}", .{home}) catch p;
            openEntry(&opts, &e, &v, "current_folder", "ay");
            var bytes: c.DBusMessageIter = undefined;
            _ = c.dbus_message_iter_open_container(&v, c.DBUS_TYPE_ARRAY, "y", &bytes);
            var ptr: [*]const u8 = folder.ptr;
            _ = c.dbus_message_iter_append_fixed_array(&bytes, c.DBUS_TYPE_BYTE, @ptrCast(&ptr), @intCast(folder.len + 1));
            _ = c.dbus_message_iter_close_container(&v, &bytes);
            closeEntry(&opts, &e, &v);
        }
    }
    _ = c.dbus_message_iter_close_container(&it, &opts);

    var serial: u32 = 0;
    if (c.dbus_connection_send(conn, msg, &serial) == 0) {
        fail(app, "ポータルを呼べませんでした");
        return;
    }
    c.dbus_connection_flush(conn);
    st.serial = serial;
    st.cb = cb;
    st.since_ms = loop.nowMs();
    std.log.info("portal: ファイル選択を開きます ({s})", .{rp});
}

/// セッションバスに届いたメッセージのうち、ここ宛てのものを処理する(処理したら true)
pub fn handle(app: *App, msg: *c.DBusMessage) bool {
    if (st.cb == null) return false;
    const t = c.dbus_message_get_type(msg);
    if (t == c.DBUS_MESSAGE_TYPE_ERROR and c.dbus_message_get_reply_serial(msg) == st.serial) {
        const ename = c.dbus_message_get_error_name(msg);
        const name: []const u8 = if (ename != null) std.mem.sliceTo(ename, 0) else "?";
        var detail: [*c]const u8 = null;
        _ = c.dbus_message_get_args(msg, null, c.DBUS_TYPE_STRING, &detail, c.DBUS_TYPE_INVALID);
        const detail_s: []const u8 = if (detail != null) std.mem.sliceTo(detail, 0) else "";
        std.log.warn("portal: OpenFile に失敗: {s} {s}", .{ name, detail_s });
        finish(app);
        fail(app, if (std.mem.indexOf(u8, name, "ServiceUnknown") != null or std.mem.indexOf(u8, name, "UnknownMethod") != null)
            "ファイル選択の画面(xdg-desktop-portal と -gtk)がありません"
        else
            "ファイル選択の画面を開けませんでした");
        return true;
    }
    if (t != c.DBUS_MESSAGE_TYPE_SIGNAL) return false;
    if (c.dbus_message_is_signal(msg, "org.freedesktop.portal.Request", "Response") == 0) return false;
    const path = std.mem.sliceTo(c.dbus_message_get_path(msg) orelse return false, 0);
    if (!std.mem.eql(u8, path, st.req_path[0..st.req_len])) return false;

    const cb = st.cb.?;
    finish(app);
    // 引数: u response(0 = 選ばれた / 1 = 取り消し / 2 = その他), a{sv} results(uris: as)
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(msg, &it) == 0) return true;
    var response: u32 = 2;
    if (c.dbus_message_iter_get_arg_type(&it) == c.DBUS_TYPE_UINT32) c.dbus_message_iter_get_basic(&it, &response);
    if (response != 0) return true; // 取り消し
    if (c.dbus_message_iter_next(&it) == 0) return true;
    var dict: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&it, &dict);
    while (c.dbus_message_iter_get_arg_type(&dict) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&dict)) {
        var e: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&dict, &e);
        var key: [*c]const u8 = null;
        c.dbus_message_iter_get_basic(&e, @ptrCast(&key));
        if (key == null or !std.mem.eql(u8, std.mem.sliceTo(key, 0), "uris")) continue;
        _ = c.dbus_message_iter_next(&e);
        var v: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&e, &v);
        if (c.dbus_message_iter_get_arg_type(&v) != c.DBUS_TYPE_ARRAY) continue;
        var arr: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&v, &arr);
        if (c.dbus_message_iter_get_arg_type(&arr) != c.DBUS_TYPE_STRING) continue;
        var uri: [*c]const u8 = null;
        c.dbus_message_iter_get_basic(&arr, @ptrCast(&uri));
        if (uri == null) continue;
        var pb: [1024]u8 = undefined;
        const p = uriToPath(std.mem.sliceTo(uri, 0), &pb) orelse {
            fail(app, "ローカルのファイルを選んでください");
            return true;
        };
        std.log.info("portal: 選ばれたファイル {s}", .{p});
        cb(app, p);
        return true;
    }
    return true;
}

fn finish(app: *App) void {
    if (app.notifs.connection()) |conn| {
        if (st.rule_len > 0) c.dbus_bus_remove_match(conn, @ptrCast(&st.rule), null);
    }
    st.cb = null;
    st.serial = 0;
    st.rule_len = 0;
}

fn fail(app: *App, why: []const u8) void {
    var b: [384]u8 = undefined;
    const body = std.fmt.bufPrint(&b, "{s}。入れてください: {s} xdg-desktop-portal xdg-desktop-portal-gtk", .{ why, deps.installCmd() }) catch why;
    std.log.warn("portal: {s}", .{body});
    app.notifs.post("ame-shell", "ファイル選択の画面を開けません", body, 0);
}

/// "file:///a/b%20c.png" → "/a/b c.png"(file: 以外は null)
pub fn uriToPath(uri: []const u8, out: []u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];
    // file://localhost/… の形
    if (std.mem.startsWith(u8, rest, "localhost/")) rest = rest["localhost".len..];
    if (rest.len == 0 or rest[0] != '/') return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (n >= out.len) return null;
        if (rest[i] == '%' and i + 2 < rest.len) {
            const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch {
                out[n] = rest[i];
                n += 1;
                continue;
            };
            out[n] = v;
            n += 1;
            i += 2;
        } else {
            out[n] = rest[i];
            n += 1;
        }
    }
    return out[0..n];
}

fn appendStr(it: *c.DBusMessageIter, s: [*:0]const u8) void {
    var p: [*c]const u8 = s;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_STRING, @ptrCast(&p));
}

fn openEntry(dict: *c.DBusMessageIter, e: *c.DBusMessageIter, v: *c.DBusMessageIter, key: [*:0]const u8, sig: [*:0]const u8) void {
    _ = c.dbus_message_iter_open_container(dict, c.DBUS_TYPE_DICT_ENTRY, null, e);
    appendStr(e, key);
    _ = c.dbus_message_iter_open_container(e, c.DBUS_TYPE_VARIANT, sig, v);
}

fn closeEntry(dict: *c.DBusMessageIter, e: *c.DBusMessageIter, v: *c.DBusMessageIter) void {
    _ = c.dbus_message_iter_close_container(e, v);
    _ = c.dbus_message_iter_close_container(dict, e);
}

test "uriToPath" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/home/a/b c.png", uriToPath("file:///home/a/b%20c.png", &b).?);
    try std.testing.expectEqualStrings("/x/写真.jpg", uriToPath("file:///x/%E5%86%99%E7%9C%9F.jpg", &b).?);
    try std.testing.expectEqualStrings("/x.png", uriToPath("file://localhost/x.png", &b).?);
    try std.testing.expect(uriToPath("https://example.com/a.png", &b) == null);
}
