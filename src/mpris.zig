// 再生中の曲(MPRIS)。playerctl を使わず、D-Bus で音楽プレイヤーと直接やりとりする。
//
//  * 起動時に org.mpris.MediaPlayer2.* の一覧を取り、各プレイヤーの状態(GetAll)を読む
//  * 以後は信号だけで追う: PropertiesChanged(曲・再生状態・シャッフルなど)、Seeked(再生位置)、
//    NameOwnerChanged(プレイヤーが増えた・消えた)。ポーリングしない
//  * どのプレイヤーを表示するか: 再生中のものを優先し、無ければ最後に変化のあったもの
//  * 操作(再生/一時停止・前・次・位置・シャッフル・リピート)はメソッド呼び出し
// 結果は Media.applyState で反映する(アートの読み込み・歌詞・アクセント色は media.zig のまま)。
const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig").App;
const Media = @import("media.zig").Media;
const loop = @import("platform/loop.zig");

const IFACE_PLAYER = "org.mpris.MediaPlayer2.Player";
const PATH = "/org/mpris/MediaPlayer2";
const PREFIX = "org.mpris.MediaPlayer2.";
const MAX = 8;

const DBusError = extern struct { name: ?[*:0]const u8 = null, message: ?[*:0]const u8 = null, dummy: c_uint = 0, padding1: ?*anyopaque = null };

fn Buf(comptime n: usize) type {
    return struct {
        b: [n]u8 = undefined,
        len: usize = 0,
        fn set(self: *@This(), s: []const u8) void {
            self.len = @min(s.len, n);
            @memcpy(self.b[0..self.len], s[0..self.len]);
            // UTF-8 の途中で切らない
            while (self.len > 0 and self.len < s.len and (self.b[self.len - 1] & 0xC0) == 0x80) self.len -= 1;
            if (self.len > 0 and self.len < s.len and self.b[self.len - 1] >= 0xC0) self.len -= 1;
        }
        fn get(self: *const @This()) []const u8 {
            return self.b[0..self.len];
        }
    };
}

const Player = struct {
    name: Buf(96) = .{}, // org.mpris.MediaPlayer2.firefox.instance_1_23
    owner: Buf(48) = .{}, // :1.42(信号の送り主はこちら)
    status: enum { stopped, playing, paused } = .stopped,
    title: Buf(160) = .{},
    artist: Buf(160) = .{},
    album: Buf(160) = .{},
    art: Buf(512) = .{},
    trackid: Buf(160) = .{},
    length_s: f32 = 0,
    pos_s: f32 = 0,
    /// pos_s を知った時刻(再生中はここから経過時間ぶん進める。古い位置を「今」として渡さないため)
    pos_at_ms: u64 = 0,
    shuffle: bool = false,
    loop_mode: u8 = 0, // 0=なし 1=プレイリスト 2=1 曲
    changed_ms: u64 = 0,
    used: bool = false,

    /// playerctl の playerName と同じ短い名前(firefox.instance_… → firefox)
    fn shortName(self: *const Player) []const u8 {
        const n = self.name.get();
        if (n.len <= PREFIX.len) return n;
        const rest = n[PREFIX.len..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, '.') orelse rest.len];
    }
};

pub const Mpris = struct {
    app: *App,
    media: *Media,
    conn: ?*c.DBusConnection = null,
    fd: c_int = -1,
    players: [MAX]Player = [_]Player{.{}} ** MAX,
    cur: ?usize = null,
    /// 返事を待っている位置の問い合わせ(queryPosition)
    pos_serial: u32 = 0,
    pos_player: ?*Player = null,

    pub fn create(app: *App, media: *Media) ?*Mpris {
        const self = app.alloc.create(Mpris) catch return null;
        self.* = .{ .app = app, .media = media };
        var err = DBusError{};
        const errp: *c.DBusError = @ptrCast(&err);
        c.dbus_error_init(errp);
        const conn = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, errp) orelse {
            std.log.info("mpris: セッションバスに接続できないため、曲の表示は無効", .{});
            c.dbus_error_free(errp);
            return self;
        };
        c.dbus_connection_set_exit_on_disconnect(conn, 0);
        self.conn = conn;
        const rules = [_][*:0]const u8{
            "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/mpris/MediaPlayer2',arg0='org.mpris.MediaPlayer2.Player'",
            "type='signal',interface='org.mpris.MediaPlayer2.Player',member='Seeked',path='/org/mpris/MediaPlayer2'",
            "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0namespace='org.mpris.MediaPlayer2'",
        };
        for (rules) |r| c.dbus_bus_add_match(conn, r, null);
        c.dbus_connection_flush(conn);
        var fd: c_int = -1;
        if (c.dbus_connection_get_unix_fd(conn, &fd) != 0 and fd >= 0) {
            self.fd = fd;
            app.loop.add(fd, c.EPOLLIN, self, onDbus) catch {};
        }
        self.scan();
        return self;
    }

    // ---------------------------------------------------------------------------
    // 一覧と状態の読み込み
    // ---------------------------------------------------------------------------

    fn scan(self: *Mpris) void {
        const conn = self.conn orelse return;
        const msg = c.dbus_message_new_method_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames") orelse return;
        defer c.dbus_message_unref(msg);
        const reply = c.dbus_connection_send_with_reply_and_block(conn, msg, 1000, null) orelse return;
        defer c.dbus_message_unref(reply);
        var it: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &it) == 0) return;
        var arr: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&it, &arr);
        while (c.dbus_message_iter_get_arg_type(&arr) == c.DBUS_TYPE_STRING) : (_ = c.dbus_message_iter_next(&arr)) {
            var s: [*c]const u8 = null;
            c.dbus_message_iter_get_basic(&arr, @ptrCast(&s));
            const name = std.mem.sliceTo(s, 0);
            if (std.mem.startsWith(u8, name, PREFIX)) _ = self.addPlayer(name);
        }
        self.choose();
    }

    fn addPlayer(self: *Mpris, name: []const u8) ?usize {
        for (&self.players, 0..) |*p, i| if (p.used and std.mem.eql(u8, p.name.get(), name)) return i;
        for (&self.players, 0..) |*p, i| if (!p.used) {
            p.* = .{ .used = true, .changed_ms = loop.nowMs() };
            p.name.set(name);
            self.refreshOwner(p);
            self.getAll(p);
            return i;
        };
        return null;
    }

    fn refreshOwner(self: *Mpris, p: *Player) void {
        const conn = self.conn orelse return;
        const msg = c.dbus_message_new_method_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner") orelse return;
        defer c.dbus_message_unref(msg);
        var nz: [97]u8 = undefined;
        const name = std.fmt.bufPrintZ(&nz, "{s}", .{p.name.get()}) catch return;
        var np: [*c]const u8 = name.ptr;
        _ = c.dbus_message_append_args(msg, c.DBUS_TYPE_STRING, &np, c.DBUS_TYPE_INVALID);
        const reply = c.dbus_connection_send_with_reply_and_block(conn, msg, 500, null) orelse return;
        defer c.dbus_message_unref(reply);
        var s: [*c]const u8 = null;
        if (c.dbus_message_get_args(reply, null, c.DBUS_TYPE_STRING, &s, c.DBUS_TYPE_INVALID) != 0 and s != null) p.owner.set(std.mem.sliceTo(s, 0));
    }

    /// プレイヤーの全プロパティを読む(GetAll)
    fn getAll(self: *Mpris, p: *Player) void {
        const conn = self.conn orelse return;
        var nz: [97]u8 = undefined;
        const dest = std.fmt.bufPrintZ(&nz, "{s}", .{p.name.get()}) catch return;
        const msg = c.dbus_message_new_method_call(dest.ptr, PATH, "org.freedesktop.DBus.Properties", "GetAll") orelse return;
        defer c.dbus_message_unref(msg);
        var ip: [*c]const u8 = IFACE_PLAYER;
        _ = c.dbus_message_append_args(msg, c.DBUS_TYPE_STRING, &ip, c.DBUS_TYPE_INVALID);
        const reply = c.dbus_connection_send_with_reply_and_block(conn, msg, 800, null) orelse return;
        defer c.dbus_message_unref(reply);
        var it: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &it) == 0) return;
        applyProps(p, &it);
    }

    /// a{sv} のプロパティを Player に反映する(GetAll の返事・PropertiesChanged の 2 番目の引数)
    fn applyProps(p: *Player, dict_it: *c.DBusMessageIter) void {
        if (c.dbus_message_iter_get_arg_type(dict_it) != c.DBUS_TYPE_ARRAY) return;
        var d: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(dict_it, &d);
        while (c.dbus_message_iter_get_arg_type(&d) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&d)) {
            var e: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&d, &e);
            const key = getString(&e) orelse continue;
            _ = c.dbus_message_iter_next(&e);
            var v: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&e, &v);
            if (std.mem.eql(u8, key, "PlaybackStatus")) {
                const s = getString(&v) orelse continue;
                p.status = if (std.mem.eql(u8, s, "Playing")) .playing else if (std.mem.eql(u8, s, "Paused")) .paused else .stopped;
            } else if (std.mem.eql(u8, key, "Metadata")) {
                applyMetadata(p, &v);
            } else if (std.mem.eql(u8, key, "Position")) {
                p.pos_s = @as(f32, @floatFromInt(getInt(&v) orelse 0)) / 1e6;
                p.pos_at_ms = loop.nowMs();
            } else if (std.mem.eql(u8, key, "Shuffle")) {
                if (c.dbus_message_iter_get_arg_type(&v) == c.DBUS_TYPE_BOOLEAN) {
                    var b: c.dbus_bool_t = 0;
                    c.dbus_message_iter_get_basic(&v, &b);
                    p.shuffle = b != 0;
                }
            } else if (std.mem.eql(u8, key, "LoopStatus")) {
                const s = getString(&v) orelse continue;
                p.loop_mode = if (std.mem.eql(u8, s, "Playlist")) 1 else if (std.mem.eql(u8, s, "Track")) 2 else 0;
            }
        }
        p.changed_ms = loop.nowMs();
    }

    fn applyMetadata(p: *Player, v: *c.DBusMessageIter) void {
        if (c.dbus_message_iter_get_arg_type(v) != c.DBUS_TYPE_ARRAY) return;
        // 曲が変わったら古い値を残さない
        p.title.len = 0;
        p.artist.len = 0;
        p.album.len = 0;
        p.art.len = 0;
        p.length_s = 0;
        var d: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(v, &d);
        while (c.dbus_message_iter_get_arg_type(&d) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&d)) {
            var e: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&d, &e);
            const key = getString(&e) orelse continue;
            _ = c.dbus_message_iter_next(&e);
            var val: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&e, &val);
            if (std.mem.eql(u8, key, "xesam:title")) {
                if (getString(&val)) |s| p.title.set(s);
            } else if (std.mem.eql(u8, key, "xesam:album")) {
                if (getString(&val)) |s| p.album.set(s);
            } else if (std.mem.eql(u8, key, "mpris:artUrl")) {
                if (getString(&val)) |s| p.art.set(s);
            } else if (std.mem.eql(u8, key, "mpris:trackid")) {
                if (getString(&val)) |s| p.trackid.set(s);
            } else if (std.mem.eql(u8, key, "mpris:length")) {
                p.length_s = @as(f32, @floatFromInt(getInt(&val) orelse 0)) / 1e6;
            } else if (std.mem.eql(u8, key, "xesam:artist")) {
                // 文字列の配列(複数のアーティストは「, 」でつなぐ)
                if (c.dbus_message_iter_get_arg_type(&val) == c.DBUS_TYPE_ARRAY) {
                    var a: c.DBusMessageIter = undefined;
                    c.dbus_message_iter_recurse(&val, &a);
                    var tmp: [160]u8 = undefined;
                    var w = std.io.fixedBufferStream(&tmp);
                    var first = true;
                    while (getString(&a)) |s| : (_ = c.dbus_message_iter_next(&a)) {
                        if (!first) w.writer().writeAll(", ") catch break;
                        w.writer().writeAll(s) catch break;
                        first = false;
                    }
                    p.artist.set(tmp[0..w.pos]);
                } else if (getString(&val)) |s| p.artist.set(s);
            }
        }
    }

    // ---------------------------------------------------------------------------
    // 信号
    // ---------------------------------------------------------------------------

    fn onDbus(ctx: *anyopaque, fd: c_int, events: u32) void {
        const self: *Mpris = @ptrCast(@alignCast(ctx));
        const conn = self.conn orelse return;
        if (events & (c.EPOLLHUP | c.EPOLLERR) != 0) {
            self.app.loop.remove(fd);
            self.fd = -1;
            return;
        }
        _ = c.dbus_connection_read_write(conn, 0);
        var changed = false;
        while (c.dbus_connection_pop_message(conn)) |msg| {
            defer c.dbus_message_unref(msg);
            const t = c.dbus_message_get_type(msg);
            if ((t == c.DBUS_MESSAGE_TYPE_METHOD_RETURN or t == c.DBUS_MESSAGE_TYPE_ERROR) and self.pos_serial != 0 and c.dbus_message_get_reply_serial(msg) == self.pos_serial) {
                self.onPositionReply(msg);
                continue;
            }
            if (t != c.DBUS_MESSAGE_TYPE_SIGNAL) continue;
            if (self.handleSignal(msg)) changed = true;
        }
        if (changed) self.choose();
    }

    fn findByOwner(self: *Mpris, owner: []const u8) ?*Player {
        for (&self.players) |*p| if (p.used and std.mem.eql(u8, p.owner.get(), owner)) return p;
        return null;
    }

    fn handleSignal(self: *Mpris, msg: *c.DBusMessage) bool {
        if (c.dbus_message_is_signal(msg, "org.freedesktop.DBus", "NameOwnerChanged") != 0) {
            var name: [*c]const u8 = null;
            var old: [*c]const u8 = null;
            var new: [*c]const u8 = null;
            if (c.dbus_message_get_args(msg, null, c.DBUS_TYPE_STRING, &name, c.DBUS_TYPE_STRING, &old, c.DBUS_TYPE_STRING, &new, c.DBUS_TYPE_INVALID) == 0) return false;
            const n = std.mem.sliceTo(name, 0);
            if (!std.mem.startsWith(u8, n, PREFIX)) return false;
            if (std.mem.sliceTo(new, 0).len == 0) {
                // プレイヤーが終わった
                for (&self.players, 0..) |*p, i| if (p.used and std.mem.eql(u8, p.name.get(), n)) {
                    p.used = false;
                    if (self.cur == i) self.cur = null;
                };
            } else _ = self.addPlayer(n);
            return true;
        }
        const sender = std.mem.sliceTo(c.dbus_message_get_sender(msg) orelse return false, 0);
        const p = self.findByOwner(sender) orelse return false;
        if (c.dbus_message_is_signal(msg, "org.mpris.MediaPlayer2.Player", "Seeked") != 0) {
            var it: c.DBusMessageIter = undefined;
            if (c.dbus_message_iter_init(msg, &it) == 0) return false;
            p.pos_s = @as(f32, @floatFromInt(getInt(&it) orelse 0)) / 1e6;
            p.pos_at_ms = loop.nowMs();
            p.changed_ms = loop.nowMs();
            return true;
        }
        if (c.dbus_message_is_signal(msg, "org.freedesktop.DBus.Properties", "PropertiesChanged") != 0) {
            var it: c.DBusMessageIter = undefined;
            if (c.dbus_message_iter_init(msg, &it) == 0) return false;
            _ = c.dbus_message_iter_next(&it); // インターフェイス名
            const before = p.status;
            const before_track = std.hash.Wyhash.hash(0, p.title.get()) ^ std.hash.Wyhash.hash(1, p.trackid.get());
            applyProps(p, &it);
            // 再生状態が変わったときは、位置をプレイヤーに聞き直す(一時停止中に進んだ分を外挿しないように)
            // 曲が変わったときも(前の曲の位置から外挿しないように)
            const track_changed = before_track != (std.hash.Wyhash.hash(0, p.title.get()) ^ std.hash.Wyhash.hash(1, p.trackid.get()));
            if (track_changed) {
                // 位置を答えないプレイヤーもあるので、まず曲の頭にしておく
                p.pos_s = 0;
                p.pos_at_ms = loop.nowMs();
            }
            if (before != p.status or track_changed) self.queryPosition(p);
            return true;
        }
        return false;
    }

    /// 表示するプレイヤーを選んで Media に反映する
    fn choose(self: *Mpris) void {
        var best: ?usize = null;
        for (&self.players, 0..) |*p, i| {
            if (!p.used) continue;
            const b = best orelse {
                best = i;
                continue;
            };
            const q = &self.players[b];
            const p_play = p.status == .playing;
            const q_play = q.status == .playing;
            if (p_play != q_play) {
                if (p_play) best = i;
            } else if (p.changed_ms > q.changed_ms) best = i;
        }
        self.cur = best;
        const i = best orelse {
            self.media.applyState(null, "", "", "", "", 0, 0, "");
            return;
        };
        const p = &self.players[i];
        if (p.status == .stopped and p.title.len == 0) {
            self.media.applyState(null, "", "", "", "", 0, 0, "");
            return;
        }
        self.media.shuffle = p.shuffle;
        self.media.loop_mode = p.loop_mode;
        // 再生中は、位置を知った時刻からの経過時間ぶん進めて渡す(音量・アートなど別の値が変わったときに、
        // 古い位置へ巻き戻って歌詞が前の行を指すのを防ぐ)
        var pos = p.pos_s;
        if (p.status == .playing and p.pos_at_ms != 0) pos += @as(f32, @floatFromInt(loop.nowMs() -| p.pos_at_ms)) / 1000.0;
        if (p.length_s > 0) pos = @min(pos, p.length_s);
        self.media.applyState(p.status == .playing, p.shortName(), p.artist.get(), p.title.get(), p.art.get(), p.length_s, pos, p.album.get());
    }

    fn current(self: *Mpris) ?*Player {
        const i = self.cur orelse return null;
        return &self.players[i];
    }

    // ---------------------------------------------------------------------------
    // 操作
    // ---------------------------------------------------------------------------

    fn call(self: *Mpris, member: [*:0]const u8) void {
        const conn = self.conn orelse return;
        const p = self.current() orelse return;
        var nz: [97]u8 = undefined;
        const dest = std.fmt.bufPrintZ(&nz, "{s}", .{p.name.get()}) catch return;
        const msg = c.dbus_message_new_method_call(dest.ptr, PATH, IFACE_PLAYER, member) orelse return;
        defer c.dbus_message_unref(msg);
        c.dbus_message_set_no_reply(msg, 1);
        _ = c.dbus_connection_send(conn, msg, null);
        c.dbus_connection_flush(conn);
    }

    pub fn playPause(self: *Mpris) void {
        self.call("PlayPause");
    }
    pub fn next(self: *Mpris) void {
        self.call("Next");
    }
    pub fn previous(self: *Mpris) void {
        self.call("Previous");
    }

    /// 再生位置を sec 秒へ(SetPosition。曲の ID が要る)
    pub fn seek(self: *Mpris, sec: f32) void {
        const conn = self.conn orelse return;
        const p = self.current() orelse return;
        if (p.trackid.len == 0) return;
        var nz: [97]u8 = undefined;
        const dest = std.fmt.bufPrintZ(&nz, "{s}", .{p.name.get()}) catch return;
        const msg = c.dbus_message_new_method_call(dest.ptr, PATH, IFACE_PLAYER, "SetPosition") orelse return;
        defer c.dbus_message_unref(msg);
        var tz: [161]u8 = undefined;
        const tid = std.fmt.bufPrintZ(&tz, "{s}", .{p.trackid.get()}) catch return;
        var tp: [*c]const u8 = tid.ptr;
        var us: i64 = @intFromFloat(@max(sec, 0) * 1e6);
        _ = c.dbus_message_append_args(msg, c.DBUS_TYPE_OBJECT_PATH, &tp, c.DBUS_TYPE_INT64, &us, c.DBUS_TYPE_INVALID);
        c.dbus_message_set_no_reply(msg, 1);
        _ = c.dbus_connection_send(conn, msg, null);
        c.dbus_connection_flush(conn);
    }

    /// 今の再生位置を聞く(歌詞のずれの補正・再生状態や曲が変わったとき)。返事は待たない:
    /// 返事は onDbus の中で受け取り(reply_serial で見分ける)、その時点の位置として使う。
    /// (待つと、プレイヤーが忙しいときに描画が最大で数百 ms 止まる。ロック画面の描画からも呼ぶため)
    pub fn queryPosition(self: *Mpris, p_opt: ?*Player) void {
        const conn = self.conn orelse return;
        const p = p_opt orelse (self.current() orelse return);
        var nz: [97]u8 = undefined;
        const dest = std.fmt.bufPrintZ(&nz, "{s}", .{p.name.get()}) catch return;
        const msg = c.dbus_message_new_method_call(dest.ptr, PATH, "org.freedesktop.DBus.Properties", "Get") orelse return;
        defer c.dbus_message_unref(msg);
        var ip: [*c]const u8 = IFACE_PLAYER;
        var pp: [*c]const u8 = "Position";
        _ = c.dbus_message_append_args(msg, c.DBUS_TYPE_STRING, &ip, c.DBUS_TYPE_STRING, &pp, c.DBUS_TYPE_INVALID);
        var serial: u32 = 0;
        if (c.dbus_connection_send(conn, msg, &serial) == 0) return;
        c.dbus_connection_flush(conn);
        self.pos_serial = serial;
        self.pos_player = p;
    }

    /// queryPosition の返事(onDbus から)
    fn onPositionReply(self: *Mpris, reply: *c.DBusMessage) void {
        const p = self.pos_player orelse return;
        self.pos_serial = 0;
        self.pos_player = null;
        if (c.dbus_message_get_type(reply) != c.DBUS_MESSAGE_TYPE_METHOD_RETURN) return;
        var it: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &it) == 0 or c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_VARIANT) return;
        var v: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&it, &v);
        p.pos_s = @as(f32, @floatFromInt(getInt(&v) orelse return)) / 1e6;
        p.pos_at_ms = loop.nowMs();
        // 表示中のプレイヤーなら、その場で位置を直す(曲の情報などは変わらないので applyState まではしない)
        if (self.current() == p) {
            self.media.pos_s = p.pos_s;
            self.media.pos_at_ms = p.pos_at_ms;
        }
    }

    /// 歌詞のずれの補正(Media.resync から): 表示中のプレイヤーに位置を聞く
    pub fn requestPosition(self: *Mpris) void {
        if (self.pos_serial != 0) return; // 前の問い合わせの返事を待っている
        self.queryPosition(null);
    }

    fn setProp(self: *Mpris, prop: [*:0]const u8, sig: [*:0]const u8, value: *const anyopaque, dtype: c_int) void {
        const conn = self.conn orelse return;
        const p = self.current() orelse return;
        var nz: [97]u8 = undefined;
        const dest = std.fmt.bufPrintZ(&nz, "{s}", .{p.name.get()}) catch return;
        const msg = c.dbus_message_new_method_call(dest.ptr, PATH, "org.freedesktop.DBus.Properties", "Set") orelse return;
        defer c.dbus_message_unref(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(msg, &it);
        var ip: [*c]const u8 = IFACE_PLAYER;
        var pp: [*c]const u8 = prop;
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&ip));
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&pp));
        var v: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_VARIANT, sig, &v);
        _ = c.dbus_message_iter_append_basic(&v, dtype, value);
        _ = c.dbus_message_iter_close_container(&it, &v);
        c.dbus_message_set_no_reply(msg, 1);
        _ = c.dbus_connection_send(conn, msg, null);
        c.dbus_connection_flush(conn);
    }

    pub fn toggleShuffle(self: *Mpris) void {
        const p = self.current() orelse return;
        var b: c.dbus_bool_t = if (p.shuffle) 0 else 1;
        self.setProp("Shuffle", "b", &b, c.DBUS_TYPE_BOOLEAN);
    }

    pub fn cycleLoop(self: *Mpris) void {
        const p = self.current() orelse return;
        var s: [*c]const u8 = switch (p.loop_mode) {
            0 => "Playlist",
            1 => "Track",
            else => "None",
        };
        self.setProp("LoopStatus", "s", @ptrCast(&s), c.DBUS_TYPE_STRING);
    }
};

// ---- D-Bus の値の取り出し ----

fn getString(it: *c.DBusMessageIter) ?[]const u8 {
    const t = c.dbus_message_iter_get_arg_type(it);
    if (t != c.DBUS_TYPE_STRING and t != c.DBUS_TYPE_OBJECT_PATH) return null;
    var s: [*c]const u8 = null;
    c.dbus_message_iter_get_basic(it, @ptrCast(&s));
    if (s == null) return null;
    return std.mem.sliceTo(s, 0);
}

/// 整数(プレイヤーによって int64 / uint64 / int32 / double と型がまちまち)
fn getInt(it: *c.DBusMessageIter) ?i64 {
    switch (c.dbus_message_iter_get_arg_type(it)) {
        c.DBUS_TYPE_INT64 => {
            var v: i64 = 0;
            c.dbus_message_iter_get_basic(it, &v);
            return v;
        },
        c.DBUS_TYPE_UINT64 => {
            var v: u64 = 0;
            c.dbus_message_iter_get_basic(it, &v);
            return @intCast(@min(v, std.math.maxInt(i64)));
        },
        c.DBUS_TYPE_INT32 => {
            var v: i32 = 0;
            c.dbus_message_iter_get_basic(it, &v);
            return v;
        },
        c.DBUS_TYPE_UINT32 => {
            var v: u32 = 0;
            c.dbus_message_iter_get_basic(it, &v);
            return v;
        },
        c.DBUS_TYPE_DOUBLE => {
            var v: f64 = 0;
            c.dbus_message_iter_get_basic(it, &v);
            return @intFromFloat(v);
        },
        else => return null,
    }
}
