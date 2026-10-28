// 歌詞: LRCLIB(https://lrclib.net、無料・登録不要の歌詞 DB)から、再生位置に同期した LRC を取る。
//
//   1. キャッシュ(~/.cache/ame-shell/lyrics/<曲のハッシュ>)があればそれを使う
//   2. 無ければ curl で /api/get(アーティスト名 + 曲名 + 長さ)→ 見つからなければ /api/search
//      を非同期に叩き、完了を pipe の EOF で知る(シェルを通さず引数で渡すので曲名に何が入っていても安全)
//   3. JSON(std.json)から syncedLyrics(無ければ plainLyrics)を取り出して LRC を解析
// 曲が変わるたびに 1 回だけ問い合わせ、見つからなかったことも「無し」としてキャッシュする。
const std = @import("std");
const c = @import("c.zig");
const sys = @import("platform/sys.zig");
const App = @import("app.zig").App;

pub const Line = struct { t: f32, text: []const u8 };

pub const State = enum { idle, fetching, synced, plain, none };

pub const Lyrics = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    lines: std.ArrayList(Line),
    state: State = .idle,
    key: u64 = 0,
    fd: c_int = -1,
    pid: c_int = 0,
    buf: std.ArrayList(u8),
    stage: u8 = 0, // 0=get 1=search
    artist: [160]u8 = undefined,
    artist_len: usize = 0,
    title: [160]u8 = undefined,
    title_len: usize = 0,
    duration: f32 = 0,
    /// 再生アプリが置いた歌詞ファイルの更新時刻(同じなら読み直さない。曲が変わったら 0 に戻す)
    sidecar_mtime: i128 = 0,
    on_change: ?*const fn (ctx: *anyopaque) void = null,
    ctx: *anyopaque = undefined,

    pub fn create(app: *App) !*Lyrics {
        const self = try app.alloc.create(Lyrics);
        self.* = .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(app.alloc),
            .lines = std.ArrayList(Line).init(app.alloc),
            .buf = std.ArrayList(u8).init(app.alloc),
        };
        return self;
    }

    fn cachePath(self: *Lyrics, buf: []u8) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        if (std.posix.getenv("XDG_CACHE_HOME")) |x| return std.fmt.bufPrint(buf, "{s}/ame-shell/lyrics/{x}", .{ x, self.key }) catch null;
        return std.fmt.bufPrint(buf, "{s}/.cache/ame-shell/lyrics/{x}", .{ home, self.key }) catch null;
    }

    /// 曲が変わったら呼ぶ(同じ曲なら何もしない)
    pub fn request(self: *Lyrics, artist: []const u8, title: []const u8, duration: f32) void {
        if (title.len == 0) {
            self.reset(.idle);
            return;
        }
        var h = std.hash.Wyhash.init(0);
        h.update(artist);
        h.update("\x00");
        h.update(title);
        const key = h.final();
        if (key == self.key) return;
        self.key = key;
        self.sidecar_mtime = 0;
        self.cancel();
        self.reset(.fetching);
        self.artist_len = @min(artist.len, self.artist.len);
        @memcpy(self.artist[0..self.artist_len], artist[0..self.artist_len]);
        self.title_len = @min(title.len, self.title.len);
        @memcpy(self.title[0..self.title_len], title[0..self.title_len]);
        self.duration = duration;
        // キャッシュ
        var pb: [512]u8 = undefined;
        if (self.cachePath(&pb)) |p| {
            if (std.fs.cwd().readFileAlloc(self.arena.allocator(), p, 1 << 20)) |data| {
                if (std.mem.eql(u8, data, "#none")) self.reset(.none) else self.parse(data);
                self.changed();
                return;
            } else |_| {}
        }
        self.stage = 0;
        self.spawn();
    }

    fn reset(self: *Lyrics, st: State) void {
        self.lines.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.state = st;
    }

    fn cancel(self: *Lyrics) void {
        if (self.fd >= 0) {
            _ = c.kill(self.pid, c.SIGTERM);
            self.app.loop.remove(self.fd);
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    fn spawn(self: *Lyrics) void {
        var a1: [400]u8 = undefined;
        var a2: [400]u8 = undefined;
        var a3: [64]u8 = undefined;
        const artist = self.artist[0..self.artist_len];
        const title = cleanTitle(self.title[0..self.title_len]);
        self.buf.clearRetainingCapacity();
        var fd: ?c_int = null;
        if (self.stage == 0) {
            const an = std.fmt.bufPrintZ(&a1, "artist_name={s}", .{artist}) catch return;
            const tn = std.fmt.bufPrintZ(&a2, "track_name={s}", .{title}) catch return;
            if (self.duration > 0) {
                const dn = std.fmt.bufPrintZ(&a3, "duration={d}", .{@as(u32, @intFromFloat(self.duration))}) catch return;
                fd = sys.spawnReader(&.{ "curl", "-s", "--max-time", "8", "-A", "ame-shell (https://github.com)", "-G", "https://lrclib.net/api/get", "--data-urlencode", an.ptr, "--data-urlencode", tn.ptr, "--data-urlencode", dn.ptr }, &self.pid);
            } else {
                fd = sys.spawnReader(&.{ "curl", "-s", "--max-time", "8", "-A", "ame-shell (https://github.com)", "-G", "https://lrclib.net/api/get", "--data-urlencode", an.ptr, "--data-urlencode", tn.ptr }, &self.pid);
            }
        } else {
            const q = std.fmt.bufPrintZ(&a1, "q={s} {s}", .{ artist, title }) catch return;
            fd = sys.spawnReader(&.{ "curl", "-s", "--max-time", "8", "-A", "ame-shell (https://github.com)", "-G", "https://lrclib.net/api/search", "--data-urlencode", q.ptr }, &self.pid);
        }
        self.fd = fd orelse {
            self.finish(null);
            return;
        };
        self.app.loop.add(self.fd, c.EPOLLIN | c.EPOLLHUP, self, onRead) catch {};
    }

    fn onRead(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Lyrics = @ptrCast(@alignCast(ctx));
        var tmp: [8192]u8 = undefined;
        const n = c.read(fd, &tmp, tmp.len);
        if (n > 0) {
            self.buf.appendSlice(tmp[0..@intCast(n)]) catch {};
            if (self.buf.items.len < 2 << 20) return;
        }
        self.app.loop.remove(fd);
        _ = c.close(fd);
        self.fd = -1;
        self.handleResponse();
    }

    const Rec = struct { syncedLyrics: ?[]const u8 = null, plainLyrics: ?[]const u8 = null, instrumental: bool = false };

    fn handleResponse(self: *Lyrics) void {
        const a = self.arena.allocator();
        const body = self.buf.items;
        var lrc: ?[]const u8 = null;
        if (self.stage == 0) {
            if (std.json.parseFromSliceLeaky(Rec, a, body, .{ .ignore_unknown_fields = true })) |r| {
                lrc = r.syncedLyrics orelse r.plainLyrics;
            } else |_| {}
            if (lrc == null) {
                // 完全一致で見つからない → あいまい検索
                self.stage = 1;
                self.spawn();
                return;
            }
        } else {
            if (std.json.parseFromSliceLeaky([]Rec, a, body, .{ .ignore_unknown_fields = true })) |list| {
                // 同期歌詞のあるものを優先
                for (list) |r| if (r.syncedLyrics) |s| {
                    lrc = s;
                    break;
                };
                if (lrc == null) for (list) |r| if (r.plainLyrics) |p| {
                    lrc = p;
                    break;
                };
            } else |_| {}
        }
        self.finish(lrc);
    }

    fn finish(self: *Lyrics, lrc: ?[]const u8) void {
        var pb: [512]u8 = undefined;
        const path = self.cachePath(&pb);
        if (path) |p| if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
        if (lrc) |text| {
            const owned = self.arena.allocator().dupe(u8, text) catch return;
            if (path) |p| if (std.fs.cwd().createFile(p, .{})) |f| {
                f.writeAll(owned) catch {};
                f.close();
            } else |_| {};
            self.parse(owned);
        } else {
            if (path) |p| if (std.fs.cwd().createFile(p, .{})) |f| {
                f.writeAll("#none") catch {};
                f.close();
            } else |_| {};
            self.state = .none;
        }
        self.changed();
    }

    /// 再生アプリ自身が置いた、この曲の同期歌詞($XDG_RUNTIME_DIR/lyrics/<MPRIS のプレイヤー名>.lrc)を使う。
    /// LRC の [ti:](曲名)と [ar:](アーティスト)が今の曲と一致したときだけ、LRCLIB の結果より優先する。
    /// music-tui が書く。ネットで探すより確実(その曲そのものの歌詞)。曲の情報が届くたびに呼ばれ、
    /// ファイルの更新時刻が変わっていなければ何もしない
    pub fn trySidecar(self: *Lyrics, player: []const u8) void {
        if (player.len == 0 or self.title_len == 0) return;
        for (player) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return;
        const rd = std.posix.getenv("XDG_RUNTIME_DIR") orelse return;
        var pb: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/lyrics/{s}.lrc", .{ rd, player }) catch return;
        const st = std.fs.cwd().statFile(p) catch return;
        if (st.mtime == self.sidecar_mtime) return;
        var head: [1024]u8 = undefined;
        const f = std.fs.cwd().openFile(p, .{}) catch return;
        const n = f.readAll(&head) catch 0;
        f.close();
        // [ti:] / [ar:] のタグが今の曲か
        var ti: []const u8 = "";
        var ar: []const u8 = "";
        var it = std.mem.splitScalar(u8, head[0..n], '\n');
        while (it.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \r\t");
            if (std.mem.startsWith(u8, l, "[ti:") and std.mem.endsWith(u8, l, "]")) ti = std.mem.trim(u8, l[4 .. l.len - 1], " ");
            if (std.mem.startsWith(u8, l, "[ar:") and std.mem.endsWith(u8, l, "]")) ar = std.mem.trim(u8, l[4 .. l.len - 1], " ");
        }
        const eqi = std.ascii.eqlIgnoreCase;
        const title = std.mem.trim(u8, self.title[0..self.title_len], " ");
        const artist = std.mem.trim(u8, self.artist[0..self.artist_len], " ");
        if (!eqi(ti, title)) return;
        if (ar.len > 0 and artist.len > 0 and !eqi(ar, artist)) return;
        // 一致: LRCLIB の問い合わせをやめて、こちらを使う
        self.cancel();
        self.reset(.idle);
        const data = std.fs.cwd().readFileAlloc(self.arena.allocator(), p, 1 << 20) catch return;
        self.parse(data);
        self.sidecar_mtime = st.mtime;
        std.log.info("lyrics: {s} の歌詞ファイルを使用 / using lyrics from {s}", .{ player, p });
        self.changed();
    }

    fn changed(self: *Lyrics) void {
        if (self.on_change) |f| f(self.ctx);
    }

    /// LRC を解析。"[mm:ss.xx]歌詞"(1 行に複数のタイムスタンプも可)。タイムスタンプが無ければ plain。
    fn parse(self: *Lyrics, data: []const u8) void {
        self.lines.clearRetainingCapacity();
        var synced = false;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \r\t");
            var times: [8]f32 = undefined;
            var nt: usize = 0;
            while (line.len > 0 and line[0] == '[') {
                const close = std.mem.indexOfScalar(u8, line, ']') orelse break;
                const tag = line[1..close];
                line = line[close + 1 ..];
                const colon = std.mem.indexOfScalar(u8, tag, ':') orelse continue;
                const mm = std.fmt.parseFloat(f32, tag[0..colon]) catch continue; // [ar:..] 等のタグは数値にならない
                const ss = std.fmt.parseFloat(f32, tag[colon + 1 ..]) catch continue;
                if (nt < times.len) {
                    times[nt] = mm * 60 + ss;
                    nt += 1;
                }
            }
            const text = std.mem.trim(u8, line, " ");
            if (nt > 0) {
                synced = true;
                for (times[0..nt]) |t| self.lines.append(.{ .t = t, .text = text }) catch {};
            } else if (!synced and text.len > 0) {
                self.lines.append(.{ .t = -1, .text = text }) catch {};
            }
        }
        if (synced) {
            // タイムスタンプの無い行(plain の残り)を除き、時刻順に並べる
            var i: usize = 0;
            while (i < self.lines.items.len) {
                if (self.lines.items[i].t < 0) _ = self.lines.orderedRemove(i) else i += 1;
            }
            std.mem.sort(Line, self.lines.items, {}, struct {
                fn lt(_: void, x: Line, y: Line) bool {
                    return x.t < y.t;
                }
            }.lt);
            self.state = .synced;
        } else {
            self.state = if (self.lines.items.len > 0) .plain else .none;
        }
    }

    /// 再生位置 pos(秒)での現在行と、その行の進み具合(0..1、次の行までの割合)
    pub fn current(self: *const Lyrics, pos: f32) struct { idx: ?usize, frac: f32 } {
        if (self.state != .synced or self.lines.items.len == 0) return .{ .idx = null, .frac = 0 };
        const ls = self.lines.items;
        var idx: ?usize = null;
        for (ls, 0..) |l, i| {
            if (l.t <= pos) idx = i else break;
        }
        const i = idx orelse return .{ .idx = null, .frac = 0 };
        const next_t = if (i + 1 < ls.len) ls[i + 1].t else ls[i].t + 5;
        const span = @max(next_t - ls[i].t, 0.1);
        return .{ .idx = i, .frac = std.math.clamp((pos - ls[i].t) / span, 0, 1) };
    }
};

/// 動画サイトのタイトルにありがちな飾り("【MV】"、"(Official Video)" など)を除いて検索精度を上げる
fn cleanTitle(t: []const u8) []const u8 {
    var s = t;
    // 末尾の (...) / [...] / 【...】 を落とす
    while (s.len > 0) {
        const trimmed = std.mem.trimRight(u8, s, " ");
        if (trimmed.len == 0) break;
        const last = trimmed[trimmed.len - 1];
        const open: ?usize = if (last == ')') std.mem.lastIndexOfScalar(u8, trimmed, '(') else if (last == ']') std.mem.lastIndexOfScalar(u8, trimmed, '[') else if (std.mem.endsWith(u8, trimmed, "】")) std.mem.lastIndexOf(u8, trimmed, "【") else null;
        if (open) |o| {
            if (o == 0) break;
            s = trimmed[0..o];
        } else break;
    }
    return std.mem.trim(u8, s, " ");
}
