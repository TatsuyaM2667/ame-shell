// メディア(MPRIS): 音楽プレイヤーと D-Bus で直接やりとりする(src/media/mpris.zig)。信号が来たときだけ状態を更新する
// (ポーリングしない)。アルバムアートは file:// ならそのまま、http(s) なら curl で
// キャッシュへ取得(完了を pipe の EOF で検知)。読み込んだ画像から Odin で主色を抽出し、
// テーマのアクセント色をその色へ滑らかに遷移させる。
const std = @import("std");

const anim = @import("../gfx/anim.zig");
const Color = anim.Color;
const App = @import("../core/app.zig").App;
const c = @import("../c.zig");
const gfx = @import("../gfx/gfx.zig");
const Lyrics = @import("lyrics.zig").Lyrics;
const Mpris = @import("mpris.zig").Mpris;
const loop = @import("../platform/loop.zig");
const sys = @import("../platform/sys.zig");
const theme = @import("../gfx/theme.zig");

pub const Status = enum(u32) { none = 0, playing = 1, paused = 2 };

pub const Media = struct {
    app: *App,
    fd: c_int = -1,
    pid: c_int = 0,
    linebuf: [4096]u8 = undefined,
    line_len: usize = 0,
    status: Status = .none,
    player: [48]u8 = undefined,
    player_len: usize = 0,
    title: [160]u8 = undefined,
    title_len: usize = 0,
    artist: [160]u8 = undefined,
    artist_len: usize = 0,
    album: [160]u8 = undefined,
    album_len: usize = 0,
    art_url: [512]u8 = undefined,
    art_len: usize = 0,
    length_s: f32 = 0,
    pos_s: f32 = 0,
    pos_at_ms: u64 = 0,
    art_tex: c.GLuint = 0,
    /// ジャケットの一番鮮やかな色(ジャケットが無ければ null)
    art_color: ?Color = null,
    curl_fd: c_int = -1,
    curl_pid: c_int = 0,
    curl_path: [512]u8 = undefined,
    curl_path_len: usize = 0,
    restart_timer: loop.Timer,
    lyrics: *Lyrics = undefined,
    shuffle: bool = false,
    loop_mode: u8 = 0, // 0=なし 1=プレイリスト 2=1 曲
    last_resync_ms: u64 = 0,
    /// 音楽プレイヤーとのやりとり(D-Bus の MPRIS。playerctl は使わない)
    mpris: ?*Mpris = null,

    pub fn create(app: *App) !*Media {
        const self = try app.alloc.create(Media);
        self.* = .{ .app = app, .restart_timer = try loop.Timer.init() };
        self.lyrics = try Lyrics.create(app);
        self.lyrics.ctx = app;
        self.lyrics.on_change = struct {
            fn f(ctx: *anyopaque) void {
                const a: *App = @ptrCast(@alignCast(ctx));
                a.dashboard.dataChanged();
            }
        }.f;
        // 再生アプリ(music-tui)が歌詞ファイルを書くのは、歌詞を取得できた後(曲が変わった通知より遅い)。
        // 曲の情報は変わったときしか通知されないので、ファイルそのものを見張って拾う
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |rd| {
            var db: [512]u8 = undefined;
            if (std.fmt.bufPrintZ(&db, "{s}/lyrics", .{rd})) |d| {
                std.fs.cwd().makePath(d) catch {};
                app.addWatch(d, self, onLyricsFile);
            } else |_| {}
        }
        self.start();
        return self;
    }

    fn onLyricsFile(ctx: *anyopaque, name: []const u8) void {
        const self: *Media = @ptrCast(@alignCast(ctx));
        if (self.status == .none or !std.mem.endsWith(u8, name, ".lrc")) return;
        if (!std.mem.eql(u8, name[0 .. name.len - 4], self.player[0..self.player_len])) return;
        self.lyrics.trySidecar(self.player[0..self.player_len]);
    }

    fn start(self: *Media) void {
        // 曲の情報は D-Bus(MPRIS)の信号で受け取る(playerctl の常駐プロセスは使わない)
        if (self.mpris == null) self.mpris = Mpris.create(self.app, self);
    }

    fn set(dst: []u8, len: *usize, src: []const u8) void {
        len.* = @min(src.len, dst.len);
        @memcpy(dst[0..len.*], src[0..len.*]);
        // UTF-8 の途中で切れないように
        while (len.* > 0 and len.* < src.len and (dst[len.* - 1] & 0xC0) == 0x80) len.* -= 1;
        if (len.* > 0 and len.* < src.len and dst[len.* - 1] >= 0xC0) len.* -= 1;
    }

    /// MPRIS(src/media/mpris.zig)から: 今のプレイヤーの状態をまとめて反映する
    pub fn applyState(self: *Media, playing: ?bool, player: []const u8, artist: []const u8, title: []const u8, art: []const u8, length_s: f32, pos_s: f32, album: []const u8) void {
        const prev_status = self.status;
        self.status = if (playing) |p| (if (p) .playing else .paused) else .none;
        set(&self.player, &self.player_len, player);
        set(&self.artist, &self.artist_len, artist);
        set(&self.title, &self.title_len, title);
        set(&self.album, &self.album_len, album);
        self.length_s = if (length_s > 86400) 0 else length_s;
        self.pos_s = pos_s;
        self.pos_at_ms = loop.nowMs();
        if (!std.mem.eql(u8, art, self.art_url[0..self.art_len])) {
            set(&self.art_url, &self.art_len, art);
            self.loadArt();
        }
        if (self.status != .none) self.lyrics.request(self.artist[0..self.artist_len], self.title[0..self.title_len], self.length_s);
        if (self.status != .none) self.lyrics.trySidecar(self.player[0..self.player_len]);
        if (self.status == .none and prev_status != .none) {
            self.dropArt();
            if (self.app.cfg.media_accent) theme.setAccent(self.app, null);
        }
        self.app.dashboard.dataChanged();
    }

    pub fn position(self: *Media) f32 {
        if (self.status != .playing) return self.pos_s;
        const p = self.pos_s + @as(f32, @floatFromInt(loop.nowMs() - self.pos_at_ms)) / 1000.0;
        return if (self.length_s > 0) @min(p, self.length_s) else p;
    }

    fn dropArt(self: *Media) void {
        self.art_color = null;
        if (self.art_tex != 0) {
            c.glDeleteTextures(1, &self.art_tex);
            self.art_tex = 0;
        }
    }

    fn loadArt(self: *Media) void {
        const url = self.art_url[0..self.art_len];
        if (std.mem.startsWith(u8, url, "file://")) {
            var buf: [600]u8 = undefined;
            const p = std.fmt.bufPrintZ(&buf, "{s}", .{url[7..]}) catch return;
            self.loadArtFile(p);
        } else if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) {
            // キャッシュ: $XDG_CACHE_HOME/ame-shell/art-<hash>
            const home = std.posix.getenv("HOME") orelse return;
            var dir_buf: [512]u8 = undefined;
            const dir = if (std.posix.getenv("XDG_CACHE_HOME")) |x|
                std.fmt.bufPrint(&dir_buf, "{s}/ame-shell", .{x}) catch return
            else
                std.fmt.bufPrint(&dir_buf, "{s}/.cache/ame-shell", .{home}) catch return;
            std.fs.cwd().makePath(dir) catch {};
            const h = std.hash.Wyhash.hash(0, url);
            const p = std.fmt.bufPrintZ(&self.curl_path, "{s}/art-{x}", .{ dir, h }) catch return;
            self.curl_path_len = p.len;
            if (c.access(p.ptr, c.R_OK) == 0) {
                self.loadArtFile(p);
                return;
            }
            if (self.curl_fd >= 0) {
                self.app.loop.remove(self.curl_fd);
                _ = c.close(self.curl_fd);
            }
            var url_z: [520]u8 = undefined;
            const uz = std.fmt.bufPrintZ(&url_z, "{s}", .{url}) catch return;
            self.curl_fd = sys.spawnReader(&.{ "curl", "-sfL", "--max-time", "8", "--max-filesize", "8000000", "-o", p.ptr, uz.ptr }, &self.curl_pid) orelse return;
            self.app.loop.add(self.curl_fd, c.EPOLLIN | c.EPOLLHUP, self, onCurl) catch {};
        } else {
            self.dropArt();
        }
    }

    fn onCurl(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Media = @ptrCast(@alignCast(ctx));
        var b: [64]u8 = undefined;
        const n = c.read(fd, &b, b.len);
        if (n > 0) return; // curl は -o なので通常何も出さない
        self.app.loop.remove(fd);
        _ = c.close(fd);
        self.curl_fd = -1;
        self.loadArtFile(self.curl_path[0..self.curl_path_len :0]);
    }

    fn loadArtFile(self: *Media, path: [:0]const u8) void {
        var w: c_int = 0;
        var h: c_int = 0;
        var n: c_int = 0;
        const px = c.stbi_load(path.ptr, &w, &h, &n, 4) orelse return;
        defer c.stbi_image_free(px);
        self.dropArt();
        // 共有コンテキストなので、どのサーフェスにも紐づかない状態でアップロードしてよい
        _ = c.eglMakeCurrent(self.app.gpu.dpy, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, self.app.gpu.ctx);
        self.art_tex = gfx.uploadImage(px, w, h);
        // ジャケットの中で一番鮮やかな色(白地のジャケットでも白にならない)。大きい画像は間引いて計算する。
        // ダイナミックアイランドの色にも使う(アクセントにするかは設定次第)
        const count = w * h;
        const stride = @max(1, @divTrunc(count, 40_000));
        self.art_color = theme.accentFromPixels(px, count, stride);
        if (self.app.cfg.media_accent) theme.setAccent(self.app, self.art_color);
        self.app.dashboard.dataChanged();
        self.app.redrawBars();
    }

    // ---- 操作 ----
    pub fn toggle(self: *Media) void {
        if (self.mpris) |m| m.playPause();
    }
    pub fn next(self: *Media) void {
        if (self.mpris) |m| m.next();
    }
    pub fn prev(self: *Media) void {
        if (self.mpris) |m| m.previous();
    }
    pub const resyncPosition = resync;
    pub const debugFake = debugFakeImpl;
    pub const queryModesPub = queryModes;
    pub const toggleShufflePub = toggleShuffle;
    pub const cycleLoopPub = cycleLoop;
};

/// 暗すぎ・彩度が低すぎる色は UI のアクセントに使いにくいので明るさを持ち上げる
fn usable(col: Color) Color {
    const mx = @max(col.r, @max(col.g, col.b));
    var out = col;
    if (mx < 0.55) {
        const k = 0.55 / @max(mx, 0.05);
        out = .{ .r = @min(col.r * k, 1), .g = @min(col.g * k, 1), .b = @min(col.b * k, 1), .a = 1 };
    }
    return Color.mix(out, Color.hex(0xffffff), 0.12);
}

// ---- 歌詞表示のための補助(Media のメソッドとして使う) ----

/// 再生位置のずれの補正: 歌詞を表示している間だけ、3 秒おきにプレイヤーへ位置を聞く(MPRIS の Position)。
/// シーク(Seeked の信号)と再生状態の変化は信号で受け取っているので、これは念のための補正
pub fn resync(self: *Media) void {
    if (self.status != .playing) return;
    if (loop.nowMs() -| self.last_resync_ms < 3000) return;
    self.last_resync_ms = loop.nowMs();
    const m = self.mpris orelse return;
    // 返事は待たない(届いたら Mpris が pos_s を直す)
    m.requestPosition();
}

/// 再生位置を sec 秒へ(歌詞の行をクリックしたとき)。表示はすぐに新しい位置から進める
pub fn seekTo(self: *Media, sec: f32) void {
    if (self.mpris) |m| m.seek(sec);
    self.pos_s = @max(sec, 0);
    self.pos_at_ms = loop.nowMs();
    // 直後の位置問い合わせが古い位置を返すことがあるので、次の補正は少し後に
    self.last_resync_ms = loop.nowMs();
}

/// シャッフル・リピートの状態(MPRIS の信号で常に最新。ここでは何もしない)
pub fn queryModes(self: *Media) void {
    _ = self;
}

pub fn toggleShuffle(self: *Media) void {
    if (self.mpris) |m| m.toggleShuffle();
}

pub fn cycleLoop(self: *Media) void {
    if (self.mpris) |m| m.cycleLoop();
}

/// 試験用: 実際のプレイヤー無しで「再生中」の状態を作る(ipc の debug-media から。AME_DEBUG 時のみ)
pub fn debugFakeImpl(self: *Media, spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, '|');
    const artist = it.next() orelse return;
    const title = it.next() orelse return;
    const len = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
    const pos = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
    const album = it.next() orelse "";
    // 6 つ目: ジャケットの画像のパス(試験で背景の色付けなどを見るため)
    const art = it.next() orelse "";
    self.status = .playing;
    Media.set(&self.artist, &self.artist_len, artist);
    Media.set(&self.title, &self.title_len, title);
    Media.set(&self.player, &self.player_len, "demo");
    Media.set(&self.album, &self.album_len, album);
    self.length_s = len;
    self.pos_s = pos;
    self.pos_at_ms = loop.nowMs();
    self.last_resync_ms = loop.nowMs() + 3_600_000; // 本物のプレイヤーの位置で上書きしない
    self.lyrics.request(artist, title, len);
    if (art.len > 0) {
        var ub: [512]u8 = undefined;
        Media.set(&self.art_url, &self.art_len, std.fmt.bufPrint(&ub, "file://{s}", .{art}) catch "");
        self.loadArt();
    }
    self.lyrics.trySidecar("demo");
    self.app.dashboard.dataChanged();
}
