// ame-keyring: 鍵束(org.freedesktop.secrets、freedesktop の Secret Service)。gnome-keyring の代わり。
//
//   ame-keyring            セッションの D-Bus で org.freedesktop.secrets を持ち、止めるまで動く
//                          (ほかのものが持っていれば何もせずに終わる)
//   ame-keyring list       しまってあるものの名前と属性(秘密そのものは出さない)
//
// Zed などのアプリが API キー・パスワードをここにしまう(libsecret / oo7 が使う D-Bus の口)。
// 中身は $XDG_DATA_HOME/ame-shell/keyring/login.keyring に XChaCha20-Poly1305 で暗号化して置く(src/lib/secretstore.zig)。
// 鍵は同じ場所の master.key(0600、初回に作る)。ファイルを持ち出されたり、ほかの人に読まれたりするのは防ぐが、
// このユーザーとして動くプログラムからは読める(ログインのパスワードで解錠する鍵束と違い、いつも開いている)。
// やりとりは "plain"(暗号化しない受け渡し。同じユーザーのセッションの D-Bus の中だけ)。鍵束は 1 つ(login、別名 default)。
const std = @import("std");
const store_mod = @import("ame_lib").secretstore;
const Store = store_mod.Store;
const Attr = store_mod.Attr;

const c = @cImport(@cInclude("dbus/dbus.h"));

/// libdbus の DBusError(ビットフィールドを含むため translate-c では不透明型になる)と同じ並び
const DBusError = extern struct { name: ?[*:0]const u8 = null, message: ?[*:0]const u8 = null, dummy: c_uint = 0, padding1: ?*anyopaque = null };

const NAME = "org.freedesktop.secrets";
const ROOT = "/org/freedesktop/secrets";
const COLL = ROOT ++ "/collection/login";
const ALIAS = ROOT ++ "/aliases/default";
const ITEM_PREFIX = COLL ++ "/";
const SESSION_PREFIX = ROOT ++ "/session/";
const I_SERVICE = "org.freedesktop.Secret.Service";
const I_COLL = "org.freedesktop.Secret.Collection";
const I_ITEM = "org.freedesktop.Secret.Item";
const I_SESSION = "org.freedesktop.Secret.Session";
const I_PROPS = "org.freedesktop.DBus.Properties";

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const A = gpa.allocator();
var store: Store = undefined;
var key: [store_mod.KEY_LEN]u8 = undefined;
var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var dir: []const u8 = "";
var next_session: u32 = 1;

fn now() u64 {
    return @intCast(@max(0, std.time.timestamp()));
}

// ---------------------------------------------------------------------------
// ファイル
// ---------------------------------------------------------------------------

fn keyringDir(buf: []u8) ![]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |d| if (d.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell/keyring", .{d});
    return std.fmt.bufPrint(buf, "{s}/.local/share/ame-shell/keyring", .{std.posix.getenv("HOME") orelse return error.NoHome});
}

/// 0600 で書く(一時ファイルに書いてから置き換える。途中で落ちても前のものが残る)
fn writeFile(name: []const u8, data: []const u8) !void {
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();
    var tb: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tb, "{s}.tmp", .{name});
    {
        const f = try d.createFile(tmp, .{ .mode = 0o600, .truncate = true });
        defer f.close();
        try f.writeAll(data);
        try f.sync();
    }
    try d.rename(tmp, name);
}

fn loadOrCreate() !void {
    dir = try keyringDir(&dir_buf);
    try std.fs.cwd().makePath(dir);
    // 鍵束の置き場は本人だけ
    std.posix.fchmodat(std.posix.AT.FDCWD, dir, 0o700, 0) catch {};
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();
    if (d.readFileAlloc(A, "master.key", 64)) |k| {
        defer A.free(k);
        if (k.len != key.len) return error.BadMasterKey;
        @memcpy(&key, k);
    } else |e| {
        if (e != error.FileNotFound) return e;
        // 鍵束が残っているのに鍵が無い: 作り直すと開けなくなるので止める
        if (d.access("login.keyring", .{})) |_| return error.MasterKeyMissing else |_| {}
        std.crypto.random.bytes(&key);
        try writeFile("master.key", &key);
    }
    store = Store.init(A);
    const data = d.readFileAlloc(A, "login.keyring", 64 << 20) catch |e| {
        if (e == error.FileNotFound) return;
        return e;
    };
    defer A.free(data);
    const plain = try store_mod.open(A, key, data);
    defer {
        std.crypto.utils.secureZero(u8, plain);
        A.free(plain);
    }
    store = try Store.fromJson(A, plain);
}

fn save() void {
    const json = store.toJson(A) catch |e| return std.log.err("保存できません: {}", .{e});
    defer {
        std.crypto.utils.secureZero(u8, json);
        A.free(json);
    }
    const sealed = store_mod.seal(A, key, json) catch |e| return std.log.err("暗号化できません: {}", .{e});
    defer A.free(sealed);
    writeFile("login.keyring", sealed) catch |e| std.log.err("保存できません: {}", .{e});
}

// ---------------------------------------------------------------------------
// D-Bus の値の読み書き
// ---------------------------------------------------------------------------

const Iter = c.DBusMessageIter;

fn argType(it: *Iter) c_int {
    return c.dbus_message_iter_get_arg_type(it);
}

fn getStr(it: *Iter) []const u8 {
    var s: [*c]const u8 = null;
    c.dbus_message_iter_get_basic(it, @ptrCast(&s));
    return if (s) |p| std.mem.sliceTo(p, 0) else "";
}

/// a{ss} を読む(文字列は D-Bus のメッセージを指す)
fn readAttrs(it: *Iter, out: *std.ArrayList(Attr)) bool {
    if (argType(it) != c.DBUS_TYPE_ARRAY) return false;
    var arr: Iter = undefined;
    c.dbus_message_iter_recurse(it, &arr);
    while (argType(&arr) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&arr)) {
        var e: Iter = undefined;
        c.dbus_message_iter_recurse(&arr, &e);
        if (argType(&e) != c.DBUS_TYPE_STRING) return false;
        const k = getStr(&e);
        _ = c.dbus_message_iter_next(&e);
        if (argType(&e) != c.DBUS_TYPE_STRING) return false;
        out.append(.{ .key = k, .value = getStr(&e) }) catch return false;
    }
    return true;
}

fn readBytes(it: *Iter) ?[]const u8 {
    if (argType(it) != c.DBUS_TYPE_ARRAY) return null;
    var arr: Iter = undefined;
    c.dbus_message_iter_recurse(it, &arr);
    var p: [*c]const u8 = null;
    var n: c_int = 0;
    if (argType(&arr) == c.DBUS_TYPE_BYTE) c.dbus_message_iter_get_fixed_array(&arr, @ptrCast(&p), &n);
    return if (p) |x| x[0..@intCast(n)] else &.{};
}

/// 秘密 (oayays): セッション・パラメータ・値・種類
const Secret = struct { value: []const u8, content_type: []const u8 };

fn readSecret(it: *Iter) ?Secret {
    if (argType(it) != c.DBUS_TYPE_STRUCT) return null;
    var s: Iter = undefined;
    c.dbus_message_iter_recurse(it, &s);
    if (argType(&s) != c.DBUS_TYPE_OBJECT_PATH) return null;
    _ = c.dbus_message_iter_next(&s);
    _ = readBytes(&s) orelse return null; // パラメータ(plain では空)
    _ = c.dbus_message_iter_next(&s);
    const v = readBytes(&s) orelse return null;
    _ = c.dbus_message_iter_next(&s);
    const ct = if (argType(&s) == c.DBUS_TYPE_STRING) getStr(&s) else "text/plain";
    return .{ .value = v, .content_type = ct };
}

fn appendStr(it: *Iter, s: []const u8) void {
    var buf: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{s}) catch "";
    var p: [*c]const u8 = z.ptr;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_STRING, @ptrCast(&p));
}

fn appendPath(it: *Iter, s: []const u8) void {
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{s}) catch "/";
    var p: [*c]const u8 = z.ptr;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_OBJECT_PATH, @ptrCast(&p));
}

fn appendBool(it: *Iter, b: bool) void {
    var v: c.dbus_bool_t = @intFromBool(b);
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_BOOLEAN, &v);
}

fn appendU64(it: *Iter, x: u64) void {
    var v = x;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_UINT64, &v);
}

fn appendBytes(it: *Iter, b: []const u8) void {
    var arr: Iter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_ARRAY, "y", &arr);
    var p: [*c]const u8 = b.ptr;
    _ = c.dbus_message_iter_append_fixed_array(&arr, c.DBUS_TYPE_BYTE, @ptrCast(&p), @intCast(b.len));
    _ = c.dbus_message_iter_close_container(it, &arr);
}

fn itemPath(id: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ ITEM_PREFIX, id }) catch "/";
}

fn appendItemPaths(it: *Iter, ids: []const u32) void {
    var arr: Iter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_ARRAY, "o", &arr);
    var b: [128]u8 = undefined;
    for (ids) |id| appendPath(&arr, itemPath(id, &b));
    _ = c.dbus_message_iter_close_container(it, &arr);
}

fn appendPaths(it: *Iter, paths: []const []const u8) void {
    var arr: Iter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_ARRAY, "o", &arr);
    for (paths) |p| appendPath(&arr, p);
    _ = c.dbus_message_iter_close_container(it, &arr);
}

fn appendSecret(it: *Iter, session: []const u8, item: *const store_mod.Item) void {
    var s: Iter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_STRUCT, null, &s);
    appendPath(&s, session);
    appendBytes(&s, "");
    appendBytes(&s, item.secret);
    appendStr(&s, item.content_type);
    _ = c.dbus_message_iter_close_container(it, &s);
}

fn appendAttrs(it: *Iter, attrs: []const Attr) void {
    var arr: Iter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_ARRAY, "{ss}", &arr);
    for (attrs) |at| {
        var e: Iter = undefined;
        _ = c.dbus_message_iter_open_container(&arr, c.DBUS_TYPE_DICT_ENTRY, null, &e);
        appendStr(&e, at.key);
        appendStr(&e, at.value);
        _ = c.dbus_message_iter_close_container(&arr, &e);
    }
    _ = c.dbus_message_iter_close_container(it, &arr);
}

/// プロパティの値(variant の中身)
const Prop = union(enum) { str: []const u8, b: bool, u: u64, paths: []const u32, attrs: []const Attr, coll_paths };

fn appendVariant(it: *Iter, v: Prop) void {
    var vi: Iter = undefined;
    const sig: [*c]const u8 = switch (v) {
        .str => "s",
        .b => "b",
        .u => "t",
        .paths, .coll_paths => "ao",
        .attrs => "a{ss}",
    };
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_VARIANT, sig, &vi);
    switch (v) {
        .str => |s| appendStr(&vi, s),
        .b => |b| appendBool(&vi, b),
        .u => |x| appendU64(&vi, x),
        .paths => |ids| appendItemPaths(&vi, ids),
        .coll_paths => appendPaths(&vi, &.{COLL}),
        .attrs => |at| appendAttrs(&vi, at),
    }
    _ = c.dbus_message_iter_close_container(it, &vi);
}

// ---------------------------------------------------------------------------
// プロパティ
// ---------------------------------------------------------------------------

const Obj = union(enum) { service, collection, item: u32, session: u32, none };

fn objectOf(path: []const u8) Obj {
    const eq = std.mem.eql;
    if (eq(u8, path, ROOT)) return .service;
    if (eq(u8, path, COLL) or eq(u8, path, ALIAS)) return .collection;
    if (std.mem.startsWith(u8, path, ITEM_PREFIX)) {
        const id = std.fmt.parseInt(u32, path[ITEM_PREFIX.len..], 10) catch return .none;
        return if (store.get(id) != null) .{ .item = id } else .none;
    }
    if (std.mem.startsWith(u8, path, SESSION_PREFIX)) return .{ .session = std.fmt.parseInt(u32, path[SESSION_PREFIX.len..], 10) catch return .none };
    return .none;
}

const PropEntry = struct { name: []const u8, value: Prop };

/// そのオブジェクトのプロパティの名前と値(l に書いて、使った分を返す)
fn props(o: Obj, ids_buf: *std.ArrayList(u32), l: *[6]PropEntry) []const PropEntry {
    switch (o) {
        .service => {
            l[0] = .{ .name = "Collections", .value = .coll_paths };
            return l[0..1];
        },
        .collection => {
            ids_buf.clearRetainingCapacity();
            store.search(&.{}, ids_buf) catch {};
            l[0] = .{ .name = "Items", .value = .{ .paths = ids_buf.items } };
            l[1] = .{ .name = "Label", .value = .{ .str = "Login" } };
            l[2] = .{ .name = "Locked", .value = .{ .b = false } };
            l[3] = .{ .name = "Created", .value = .{ .u = 0 } };
            l[4] = .{ .name = "Modified", .value = .{ .u = 0 } };
            return l[0..5];
        },
        .item => |id| {
            const it = store.get(id) orelse return &.{};
            l[0] = .{ .name = "Locked", .value = .{ .b = false } };
            l[1] = .{ .name = "Attributes", .value = .{ .attrs = it.attrs } };
            l[2] = .{ .name = "Label", .value = .{ .str = it.label } };
            l[3] = .{ .name = "Created", .value = .{ .u = it.created } };
            l[4] = .{ .name = "Modified", .value = .{ .u = it.modified } };
            l[5] = .{ .name = "Type", .value = .{ .str = "org.freedesktop.Secret.Generic" } };
            return l[0..6];
        },
        else => return &.{},
    }
}

// ---------------------------------------------------------------------------
// 呼び出し
// ---------------------------------------------------------------------------

/// 返事を組み立てる: begin で作り、iter に書き、finish で送る
const Reply = struct {
    conn: *c.DBusConnection,
    msg: *c.DBusMessage,
    it: Iter = undefined,

    fn begin(conn: *c.DBusConnection, call: *c.DBusMessage) ?Reply {
        const r = c.dbus_message_new_method_return(call) orelse return null;
        var rp = Reply{ .conn = conn, .msg = r };
        c.dbus_message_iter_init_append(r, &rp.it);
        return rp;
    }

    fn finish(self: *Reply) void {
        _ = c.dbus_connection_send(self.conn, self.msg, null);
        c.dbus_message_unref(self.msg);
    }
};

fn replyError(conn: *c.DBusConnection, msg: *c.DBusMessage, name: [*:0]const u8, text: [*:0]const u8) void {
    const r = c.dbus_message_new_error(msg, name, text) orelse return;
    defer c.dbus_message_unref(r);
    _ = c.dbus_connection_send(conn, r, null);
}

fn replyEmpty(conn: *c.DBusConnection, msg: *c.DBusMessage) void {
    var r = Reply.begin(conn, msg) orelse return;
    r.finish();
}

/// パスを 1 つ(または 2 つ)返す。"/" は「確認の画面は無し」
fn replyPaths(conn: *c.DBusConnection, msg: *c.DBusMessage, a: []const u8, b: ?[]const u8) void {
    var r = Reply.begin(conn, msg) orelse return;
    appendPath(&r.it, a);
    if (b) |x| appendPath(&r.it, x);
    r.finish();
}

/// セッションの引数(o。型の分からないクライアントは s で送ってくるので、それも受ける)
fn sessionArg(it: *Iter) []const u8 {
    const t = argType(it);
    return if (t == c.DBUS_TYPE_OBJECT_PATH or t == c.DBUS_TYPE_STRING) getStr(it) else "/";
}

fn badArgs(conn: *c.DBusConnection, msg: *c.DBusMessage) void {
    replyError(conn, msg, "org.freedesktop.DBus.Error.InvalidArgs", "invalid arguments");
}

fn emitItemSignal(conn: *c.DBusConnection, member: [*:0]const u8, id: u32) void {
    const sig = c.dbus_message_new_signal(COLL, I_COLL, member) orelse return;
    defer c.dbus_message_unref(sig);
    var it: Iter = undefined;
    c.dbus_message_iter_init_append(sig, &it);
    var b: [128]u8 = undefined;
    appendPath(&it, itemPath(id, &b));
    _ = c.dbus_connection_send(conn, sig, null);
}

/// 1 つの呼び出しで使うもの
const Call = struct {
    conn: *c.DBusConnection,
    msg: *c.DBusMessage,
    member: []const u8,
    args: Iter = undefined,
    has_args: bool,
    attrs: std.ArrayList(Attr),
    ids: std.ArrayList(u32),

    fn is(self: *const Call, m: []const u8) bool {
        return std.mem.eql(u8, self.member, m);
    }
    fn argType0(self: *Call) c_int {
        return if (self.has_args) argType(&self.args) else c.DBUS_TYPE_INVALID;
    }
};

fn handle(conn: *c.DBusConnection, msg: *c.DBusMessage) bool {
    const path = std.mem.sliceTo(c.dbus_message_get_path(msg) orelse return false, 0);
    if (!std.mem.startsWith(u8, path, ROOT)) return false;
    const iface = if (c.dbus_message_get_interface(msg)) |p| std.mem.sliceTo(p, 0) else "";
    var call = Call{
        .conn = conn,
        .msg = msg,
        .member = std.mem.sliceTo(c.dbus_message_get_member(msg) orelse return false, 0),
        .has_args = false,
        .attrs = std.ArrayList(Attr).init(A),
        .ids = std.ArrayList(u32).init(A),
    };
    defer call.attrs.deinit();
    defer call.ids.deinit();
    call.has_args = c.dbus_message_iter_init(msg, &call.args) != 0;
    const o = objectOf(path);
    if (o == .none) {
        replyError(conn, msg, "org.freedesktop.Secret.Error.NoSuchObject", "no such object");
        return true;
    }
    const done = if (std.mem.eql(u8, iface, I_PROPS)) properties(&call, o) else switch (o) {
        .service => serviceCall(&call),
        .collection => collectionCall(&call),
        .item => |id| itemCall(&call, id),
        .session => sessionCall(&call),
        .none => false,
    };
    if (!done) replyError(conn, msg, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
    return true;
}

fn sessionCall(call: *Call) bool {
    if (!call.is("Close")) return false;
    replyEmpty(call.conn, call.msg);
    return true;
}

fn properties(call: *Call, o: Obj) bool {
    const eq = std.mem.eql;
    var buf: [6]PropEntry = undefined;
    const list = props(o, &call.ids, &buf);
    if (call.is("GetAll")) {
        var r = Reply.begin(call.conn, call.msg) orelse return true;
        var arr: Iter = undefined;
        _ = c.dbus_message_iter_open_container(&r.it, c.DBUS_TYPE_ARRAY, "{sv}", &arr);
        for (list) |p| {
            var e: Iter = undefined;
            _ = c.dbus_message_iter_open_container(&arr, c.DBUS_TYPE_DICT_ENTRY, null, &e);
            appendStr(&e, p.name);
            appendVariant(&e, p.value);
            _ = c.dbus_message_iter_close_container(&arr, &e);
        }
        _ = c.dbus_message_iter_close_container(&r.it, &arr);
        r.finish();
        return true;
    }
    if (call.is("Get") and call.has_args) {
        _ = c.dbus_message_iter_next(&call.args);
        const name = if (argType(&call.args) == c.DBUS_TYPE_STRING) getStr(&call.args) else "";
        for (list) |p| if (eq(u8, p.name, name)) {
            var r = Reply.begin(call.conn, call.msg) orelse return true;
            appendVariant(&r.it, p.value);
            r.finish();
            return true;
        };
        replyError(call.conn, call.msg, "org.freedesktop.DBus.Error.UnknownProperty", "unknown property");
        return true;
    }
    if (call.is("Set") and call.has_args) {
        // 品物の Label・Attributes だけ変えられる
        const id = switch (o) {
            .item => |x| x,
            else => {
                replyError(call.conn, call.msg, "org.freedesktop.DBus.Error.PropertyReadOnly", "read only");
                return true;
            },
        };
        const it = store.get(id).?;
        _ = c.dbus_message_iter_next(&call.args);
        const name = getStr(&call.args);
        _ = c.dbus_message_iter_next(&call.args);
        var v: Iter = undefined;
        c.dbus_message_iter_recurse(&call.args, &v);
        if (eq(u8, name, "Label") and argType(&v) == c.DBUS_TYPE_STRING) {
            store.setLabel(it, getStr(&v), now()) catch {};
        } else if (eq(u8, name, "Attributes") and readAttrs(&v, &call.attrs)) {
            store.setAttrs(it, call.attrs.items, now()) catch {};
        } else {
            replyError(call.conn, call.msg, "org.freedesktop.DBus.Error.PropertyReadOnly", "read only");
            return true;
        }
        save();
        emitItemSignal(call.conn, "ItemChanged", id);
        replyEmpty(call.conn, call.msg);
        return true;
    }
    return false;
}

fn serviceCall(call: *Call) bool {
    const eq = std.mem.eql;
    if (call.is("OpenSession")) {
        const alg = if (call.argType0() == c.DBUS_TYPE_STRING) getStr(&call.args) else "";
        if (!eq(u8, alg, "plain")) {
            // 暗号化した受け渡し(dh-ietf1024-…)はまだ無い。libsecret / oo7 は plain でやり直す
            replyError(call.conn, call.msg, "org.freedesktop.DBus.Error.NotSupported", "only the plain algorithm is supported");
            return true;
        }
        var r = Reply.begin(call.conn, call.msg) orelse return true;
        appendVariant(&r.it, .{ .str = "" });
        var b: [96]u8 = undefined;
        appendPath(&r.it, std.fmt.bufPrint(&b, "{s}{d}", .{ SESSION_PREFIX, next_session }) catch "/");
        next_session += 1;
        r.finish();
        return true;
    }
    if (call.is("SearchItems")) {
        if (!call.has_args or !readAttrs(&call.args, &call.attrs)) {
            badArgs(call.conn, call.msg);
            return true;
        }
        store.search(call.attrs.items, &call.ids) catch {};
        var r = Reply.begin(call.conn, call.msg) orelse return true;
        appendItemPaths(&r.it, call.ids.items); // 開いているもの
        appendItemPaths(&r.it, &.{}); // 鍵がかかっているもの(無い)
        r.finish();
        return true;
    }
    if (call.is("Unlock") or call.is("Lock")) {
        // 鍵束はいつも開いている: Unlock は頼まれたものをそのまま「開いた」で返す。Lock は何もしない
        var r = Reply.begin(call.conn, call.msg) orelse return true;
        var arr: Iter = undefined;
        _ = c.dbus_message_iter_open_container(&r.it, c.DBUS_TYPE_ARRAY, "o", &arr);
        if (call.is("Unlock") and call.argType0() == c.DBUS_TYPE_ARRAY) {
            var src: Iter = undefined;
            c.dbus_message_iter_recurse(&call.args, &src);
            while (argType(&src) == c.DBUS_TYPE_OBJECT_PATH) : (_ = c.dbus_message_iter_next(&src)) appendPath(&arr, getStr(&src));
        }
        _ = c.dbus_message_iter_close_container(&r.it, &arr);
        appendPath(&r.it, "/");
        r.finish();
        return true;
    }
    if (call.is("GetSecrets")) {
        if (call.argType0() != c.DBUS_TYPE_ARRAY) {
            badArgs(call.conn, call.msg);
            return true;
        }
        var src: Iter = undefined;
        c.dbus_message_iter_recurse(&call.args, &src);
        while (argType(&src) == c.DBUS_TYPE_OBJECT_PATH) : (_ = c.dbus_message_iter_next(&src)) {
            switch (objectOf(getStr(&src))) {
                .item => |id| call.ids.append(id) catch {},
                else => {},
            }
        }
        _ = c.dbus_message_iter_next(&call.args);
        const session = sessionArg(&call.args);
        var r = Reply.begin(call.conn, call.msg) orelse return true;
        var d: Iter = undefined;
        _ = c.dbus_message_iter_open_container(&r.it, c.DBUS_TYPE_ARRAY, "{o(oayays)}", &d);
        var b: [128]u8 = undefined;
        for (call.ids.items) |id| {
            var e: Iter = undefined;
            _ = c.dbus_message_iter_open_container(&d, c.DBUS_TYPE_DICT_ENTRY, null, &e);
            appendPath(&e, itemPath(id, &b));
            appendSecret(&e, session, store.get(id).?);
            _ = c.dbus_message_iter_close_container(&d, &e);
        }
        _ = c.dbus_message_iter_close_container(&r.it, &d);
        r.finish();
        return true;
    }
    if (call.is("ReadAlias")) {
        const name = if (call.argType0() == c.DBUS_TYPE_STRING) getStr(&call.args) else "";
        replyPaths(call.conn, call.msg, if (eq(u8, name, "default") or eq(u8, name, "login")) COLL else "/", null);
        return true;
    }
    if (call.is("SetAlias") or call.is("LockService")) {
        replyEmpty(call.conn, call.msg); // 鍵束は 1 つなので、どの別名も login を指す
        return true;
    }
    if (call.is("CreateCollection")) {
        replyPaths(call.conn, call.msg, COLL, "/"); // 鍵束は 1 つ。作らずに login を返す
        return true;
    }
    return false;
}

fn collectionCall(call: *Call) bool {
    const eq = std.mem.eql;
    if (call.is("SearchItems")) {
        if (!call.has_args or !readAttrs(&call.args, &call.attrs)) {
            badArgs(call.conn, call.msg);
            return true;
        }
        store.search(call.attrs.items, &call.ids) catch {};
        var r = Reply.begin(call.conn, call.msg) orelse return true;
        appendItemPaths(&r.it, call.ids.items);
        r.finish();
        return true;
    }
    if (call.is("CreateItem")) {
        // properties a{sv}・secret (oayays)・replace b
        if (call.argType0() != c.DBUS_TYPE_ARRAY) {
            badArgs(call.conn, call.msg);
            return true;
        }
        var label: []const u8 = "";
        var arr: Iter = undefined;
        c.dbus_message_iter_recurse(&call.args, &arr);
        while (argType(&arr) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&arr)) {
            var e: Iter = undefined;
            c.dbus_message_iter_recurse(&arr, &e);
            const k = getStr(&e);
            _ = c.dbus_message_iter_next(&e);
            var v: Iter = undefined;
            c.dbus_message_iter_recurse(&e, &v);
            if (eq(u8, k, I_ITEM ++ ".Label") and argType(&v) == c.DBUS_TYPE_STRING) label = getStr(&v);
            if (eq(u8, k, I_ITEM ++ ".Attributes")) _ = readAttrs(&v, &call.attrs);
        }
        _ = c.dbus_message_iter_next(&call.args);
        const sec = readSecret(&call.args) orelse {
            badArgs(call.conn, call.msg);
            return true;
        };
        _ = c.dbus_message_iter_next(&call.args);
        var replace: c.dbus_bool_t = 0;
        if (argType(&call.args) == c.DBUS_TYPE_BOOLEAN) c.dbus_message_iter_get_basic(&call.args, &replace);
        const before = store.items.items.len;
        const id = store.create(label, call.attrs.items, sec.value, sec.content_type, replace != 0, now()) catch {
            replyError(call.conn, call.msg, "org.freedesktop.DBus.Error.NoMemory", "out of memory");
            return true;
        };
        save();
        emitItemSignal(call.conn, if (store.items.items.len > before) "ItemCreated" else "ItemChanged", id);
        var b: [128]u8 = undefined;
        replyPaths(call.conn, call.msg, itemPath(id, &b), "/");
        return true;
    }
    if (call.is("Delete")) {
        replyError(call.conn, call.msg, "org.freedesktop.DBus.Error.NotSupported", "the login collection cannot be deleted");
        return true;
    }
    return false;
}

fn itemCall(call: *Call, id: u32) bool {
    if (call.is("GetSecret")) {
        const session = if (call.has_args) sessionArg(&call.args) else "/";
        var r = Reply.begin(call.conn, call.msg) orelse return true;
        appendSecret(&r.it, session, store.get(id).?);
        r.finish();
        return true;
    }
    if (call.is("SetSecret")) {
        const sec = (if (call.has_args) readSecret(&call.args) else null) orelse {
            badArgs(call.conn, call.msg);
            return true;
        };
        store.setSecret(store.get(id).?, sec.value, sec.content_type, now()) catch {};
        save();
        emitItemSignal(call.conn, "ItemChanged", id);
        replyEmpty(call.conn, call.msg);
        return true;
    }
    if (call.is("Delete")) {
        _ = store.delete(id);
        save();
        emitItemSignal(call.conn, "ItemDeleted", id);
        replyPaths(call.conn, call.msg, "/", null);
        return true;
    }
    return false;
}

fn filter(conn: ?*c.DBusConnection, msg: ?*c.DBusMessage, _: ?*anyopaque) callconv(.C) c.DBusHandlerResult {
    const m = msg orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    if (c.dbus_message_get_type(m) != c.DBUS_MESSAGE_TYPE_METHOD_CALL) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    return if (handle(conn.?, m)) c.DBUS_HANDLER_RESULT_HANDLED else c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

// ---------------------------------------------------------------------------

fn printList() !void {
    const w = std.io.getStdOut().writer();
    for (store.items.items) |it| {
        try w.print("{d}\t{s}", .{ it.id, it.label });
        for (it.attrs) |at| try w.print("\t{s}={s}", .{ at.key, at.value });
        try w.writeByte('\n');
    }
}

pub fn main() !u8 {
    const args = try std.process.argsAlloc(A);
    if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "list"))) {
        std.io.getStdErr().writeAll("使い方: ame-keyring [list]\n") catch {};
        return 2;
    }
    loadOrCreate() catch |e| {
        std.log.err("鍵束を開けません({s}): {}", .{ dir, e });
        return 1;
    };
    if (args.len == 2) {
        try printList();
        return 0;
    }
    var err = DBusError{};
    const errp: *c.DBusError = @ptrCast(&err);
    c.dbus_error_init(errp);
    const conn = c.dbus_bus_get(c.DBUS_BUS_SESSION, errp) orelse {
        std.log.err("セッションの D-Bus につながりません", .{});
        return 1;
    };
    const r = c.dbus_bus_request_name(conn, NAME, c.DBUS_NAME_FLAG_DO_NOT_QUEUE, errp);
    if (r != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
        std.log.info("{s} はほかのものが持っています。何もせずに終わります", .{NAME});
        return 0;
    }
    _ = c.dbus_connection_add_filter(conn, filter, null, null);
    while (c.dbus_connection_read_write_dispatch(conn, -1) != 0) {}
    return 0;
}

test "object paths" {
    store = Store.init(std.testing.allocator);
    defer store.deinit();
    const id = try store.create("x", &.{}, "s", "text/plain", false, 0);
    var b: [128]u8 = undefined;
    try std.testing.expectEqual(Obj{ .item = id }, objectOf(itemPath(id, &b)));
    try std.testing.expectEqual(Obj.collection, objectOf(ALIAS));
    try std.testing.expectEqual(Obj.service, objectOf(ROOT));
    try std.testing.expectEqual(Obj.none, objectOf(ITEM_PREFIX ++ "999"));
    try std.testing.expectEqual(Obj{ .session = 3 }, objectOf(SESSION_PREFIX ++ "3"));
}
