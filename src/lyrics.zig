// 歌詞(画面の側): 曲が変わったら歌詞を探すコマンド ame-lyrics(src/cmd/ame-lyrics.zig)を動かし、出てきた LRC を
// 解析して持つ。探し方・キャッシュは ame-lyrics の仕事。ここは起動・読み取り・解析(lib/lrc.zig)と、
// 再生アプリ自身が置いた歌詞ファイル(trySidecar)だけ。
const std = @import("std");

const App = @import("app.zig").App;
const c = @import("c.zig");
const sys = @import("platform/sys.zig");
const lrc = @import("ame_lib").lrc;

pub const Line = lrc.Line;

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
    artist: [160]u8 = undefined,
    artist_len: usize = 0,
    title: [160]u8 = undefined,
    title_len: usize = 0,
    /// 表示・照合に使う、整えたアーティストと曲名(lrc.normalize)
    qa: [160]u8 = undefined,
    qa_len: usize = 0,
    qt: [160]u8 = undefined,
    qt_len: usize = 0,
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
        const nq = lrc.normalize(artist, title, &self.qa, &self.qt);
        self.qa_len = nq[0];
        self.qt_len = nq[1];
        self.spawn(artist, title, duration);
    }

    /// ame-lyrics を動かす(設定の lyrics { … } を引数で渡す)
    fn spawn(self: *Lyrics, artist: []const u8, title: []const u8, duration: f32) void {
        const cfg = &self.app.cfg;
        var ab: [200]u8 = undefined;
        var tb: [200]u8 = undefined;
        var db: [32]u8 = undefined;
        var mb: [300]u8 = undefined;
        var argv: [16]?[*:0]const u8 = undefined;
        var n: usize = 0;
        argv[n] = "ame-lyrics";
        n += 1;
        if (duration > 0) {
            argv[n] = "-d";
            argv[n + 1] = (std.fmt.bufPrintZ(&db, "{d}", .{@as(u32, @intFromFloat(duration))}) catch return).ptr;
            n += 2;
        }
        argv[n] = "--music-tui";
        argv[n + 1] = if (!cfg.lyrics_music_tui_on) "off" else if (cfg.lyrics_music_tui.get().len > 0) (std.fmt.bufPrintZ(&mb, "{s}", .{cfg.lyrics_music_tui.get()}) catch return).ptr else "on";
        n += 2;
        if (!cfg.lyrics_lrclib) {
            argv[n] = "--no-lrclib";
            n += 1;
        }
        if (!cfg.lyrics_netease) {
            argv[n] = "--no-netease";
            n += 1;
        }
        if (!cfg.lyrics_kugou) {
            argv[n] = "--no-kugou";
            n += 1;
        }
        argv[n] = (std.fmt.bufPrintZ(&ab, "{s}", .{artist[0..@min(artist.len, ab.len - 1)]}) catch return).ptr;
        argv[n + 1] = (std.fmt.bufPrintZ(&tb, "{s}", .{title[0..@min(title.len, tb.len - 1)]}) catch return).ptr;
        n += 2;
        self.buf.clearRetainingCapacity();
        self.fd = sys.spawnReader(argv[0..n], &self.pid) orelse {
            self.state = .none;
            return;
        };
        self.app.loop.add(self.fd, c.EPOLLIN | c.EPOLLHUP, self, onRead) catch {};
    }

    fn onRead(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Lyrics = @ptrCast(@alignCast(ctx));
        var tmp: [8192]u8 = undefined;
        const n = c.read(fd, &tmp, tmp.len);
        if (n > 0) {
            if (self.buf.items.len < 4 << 20) self.buf.appendSlice(tmp[0..@intCast(n)]) catch {};
            return;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) return;
        self.app.loop.remove(fd);
        _ = c.close(fd);
        self.fd = -1;
        const data = self.arena.allocator().dupe(u8, self.buf.items) catch "";
        self.parse(data);
        self.changed();
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

    /// 表示に使う(整えた)アーティストと曲名
    pub fn qArtist(self: *const Lyrics) []const u8 {
        return self.qa[0..self.qa_len];
    }
    pub fn qTitle(self: *const Lyrics) []const u8 {
        return self.qt[0..self.qt_len];
    }

    /// 再生アプリ自身が置いた、この曲の同期歌詞($XDG_RUNTIME_DIR/lyrics/<MPRIS のプレイヤー名>.lrc)を使う。
    /// LRC の [ti:](曲名)と [ar:](アーティスト)が今の曲と一致したときだけ、ネットで探した結果より優先する。
    /// music-tui が書く。曲の情報が届くたびに呼ばれ、ファイルの更新時刻が変わっていなければ何もしない
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
        var ti: []const u8 = "";
        var ar: []const u8 = "";
        var it = std.mem.splitScalar(u8, head[0..n], '\n');
        while (it.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \r\t");
            if (std.mem.startsWith(u8, l, "[ti:") and std.mem.endsWith(u8, l, "]")) ti = std.mem.trim(u8, l[4 .. l.len - 1], " ");
            if (std.mem.startsWith(u8, l, "[ar:") and std.mem.endsWith(u8, l, "]")) ar = std.mem.trim(u8, l[4 .. l.len - 1], " ");
        }
        const eqi = std.ascii.eqlIgnoreCase;
        if (!eqi(ti, std.mem.trim(u8, self.title[0..self.title_len], " "))) return;
        if (ar.len > 0 and self.qa_len > 0 and !eqi(ar, self.qArtist())) return;
        // 一致: ネットで探すのをやめて、こちらを使う
        self.cancel();
        self.reset(.idle);
        const data = std.fs.cwd().readFileAlloc(self.arena.allocator(), p, 1 << 20) catch return;
        self.parse(data);
        self.sidecar_mtime = st.mtime;
        std.log.info("lyrics: {s} の歌詞ファイルを使用 / using lyrics from {s}", .{ player, p });
        self.changed();
    }

    fn changed(self: *Lyrics) void {
        if (self.on_change) |cb| cb(self.ctx);
    }

    fn parse(self: *Lyrics, data: []const u8) void {
        self.state = switch (lrc.parse(data, &self.lines)) {
            .synced => .synced,
            .plain => .plain,
            .none => .none,
        };
    }

    /// 再生位置 pos(秒)での今の行と、その行の進み具合(0..1、次の行までの割合)
    pub fn current(self: *const Lyrics, pos: f32) struct { idx: ?usize, frac: f32 } {
        if (self.state != .synced) return .{ .idx = null, .frac = 0 };
        const r = lrc.current(self.lines.items, pos);
        return .{ .idx = r.idx, .frac = r.frac };
    }
};
