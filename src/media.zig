// メディア(MPRIS): `playerctl --follow` を常駐させ、出力行が来たときだけ状態を更新する
// (ポーリングしない)。アルバムアートは file:// ならそのまま、http(s) なら curl で
// キャッシュへ取得(完了を pipe の EOF で検知)。読み込んだ画像から Odin で主色を抽出し、
// テーマのアクセント色をその色へ滑らかに遷移させる。
const std = @import("std");
const c = @import("c.zig");
const anim = @import("anim.zig");
const Color = anim.Color;
const gfx = @import("gfx.zig");
const theme = @import("theme.zig");
const App = @import("app.zig").App;
const sys = @import("platform/sys.zig");
const loop = @import("platform/loop.zig");
const Lyrics = @import("lyrics.zig").Lyrics;

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
    art_url: [512]u8 = undefined,
    art_len: usize = 0,
    length_s: f32 = 0,
    pos_s: f32 = 0,
    pos_at_ms: u64 = 0,
    art_tex: c.GLuint = 0,
    curl_fd: c_int = -1,
    curl_pid: c_int = 0,
    curl_path: [512]u8 = undefined,
    curl_path_len: usize = 0,
    restart_timer: loop.Timer,
    lyrics: *Lyrics = undefined,
    shuffle: bool = false,
    loop_mode: u8 = 0, // 0=なし 1=プレイリスト 2=1 曲
    last_resync_ms: u64 = 0,

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
        try app.loop.add(self.restart_timer.fd, c.EPOLLIN, self, onRestart);
        self.start();
        return self;
    }

    fn start(self: *Media) void {
        // \t 区切りで1行1イベント。position はイベント時点の値(以降は時間で外挿)
        const fmt = "{{status}}\t{{playerName}}\t{{artist}}\t{{title}}\t{{mpris:artUrl}}\t{{mpris:length}}\t{{position}}";
        const fd = sys.spawnReader(&.{ "playerctl", "--follow", "metadata", "--format", fmt }, &self.pid) orelse {
            std.log.info("media: playerctl が無いのでメディア表示は無効", .{});
            return;
        };
        self.fd = fd;
        self.app.loop.add(fd, c.EPOLLIN, self, onRead) catch {};
    }

    fn onRestart(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *Media = @ptrCast(@alignCast(ctx));
        self.restart_timer.ack();
        self.start();
    }

    fn onRead(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Media = @ptrCast(@alignCast(ctx));
        while (true) {
            const n = c.read(fd, self.linebuf[self.line_len..].ptr, self.linebuf.len - self.line_len);
            if (n == 0) {
                // playerctl が終了した → 少し待って再起動(落ち続けても 10 秒間隔なので負荷は無い)
                self.app.loop.remove(fd);
                _ = c.close(fd);
                self.fd = -1;
                self.restart_timer.arm(10_000, 0);
                return;
            }
            if (n < 0) break;
            self.line_len += @intCast(n);
            while (std.mem.indexOfScalar(u8, self.linebuf[0..self.line_len], '\n')) |nl| {
                self.parseLine(self.linebuf[0..nl]);
                const rest = self.line_len - nl - 1;
                std.mem.copyForwards(u8, self.linebuf[0..rest], self.linebuf[nl + 1 .. self.line_len]);
                self.line_len = rest;
            }
            if (self.line_len == self.linebuf.len) self.line_len = 0; // 異常に長い行は捨てる
        }
    }

    fn set(dst: []u8, len: *usize, src: []const u8) void {
        len.* = @min(src.len, dst.len);
        @memcpy(dst[0..len.*], src[0..len.*]);
        // UTF-8 の途中で切れないように
        while (len.* > 0 and len.* < src.len and (dst[len.* - 1] & 0xC0) == 0x80) len.* -= 1;
        if (len.* > 0 and len.* < src.len and dst[len.* - 1] >= 0xC0) len.* -= 1;
    }

    fn parseLine(self: *Media, line: []const u8) void {
        var f = std.mem.splitScalar(u8, line, '\t');
        const status = f.next() orelse "";
        const player = f.next() orelse "";
        const artist = f.next() orelse "";
        const title = f.next() orelse "";
        const art = f.next() orelse "";
        const len_us = f.next() orelse "";
        const pos_us = f.next() orelse "";
        const prev_status = self.status;
        self.status = if (std.mem.eql(u8, status, "Playing")) .playing else if (std.mem.eql(u8, status, "Paused")) .paused else .none;
        set(&self.player, &self.player_len, player);
        set(&self.artist, &self.artist_len, artist);
        set(&self.title, &self.title_len, title);
        self.length_s = (std.fmt.parseFloat(f32, len_us) catch 0) / 1e6;
        // ライブ配信などは長さが無意味な値(数日以上)になるので「不明」扱いにする
        if (self.length_s > 86400) self.length_s = 0;
        self.pos_s = (std.fmt.parseFloat(f32, pos_us) catch 0) / 1e6;
        self.pos_at_ms = loop.nowMs();
        if (!std.mem.eql(u8, art, self.art_url[0..self.art_len])) {
            set(&self.art_url, &self.art_len, art);
            self.loadArt();
        }
        // 曲が変わったら歌詞を取りに行く(同じ曲なら何もしない)
        if (self.status != .none) self.lyrics.request(self.artist[0..self.artist_len], self.title[0..self.title_len], self.length_s);
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
        if (self.app.cfg.media_accent) {
            // Odin で主色抽出。大きい画像は間引いて(stride)計算量を抑える。
            var work: [4096 * 4]u32 = undefined;
            const count = w * h;
            const stride = @max(1, @divTrunc(count, 40_000));
            const rgb = anim.ame_dominant_color(px, count, stride, &work);
            theme.setAccent(self.app, usable(Color.hex(rgb)));
        }
        self.app.dashboard.dataChanged();
        self.app.redrawBars();
    }

    // ---- 操作 ----
    pub fn toggle(self: *Media) void {
        _ = self;
        sys.spawnDetached("playerctl play-pause");
    }
    pub fn next(self: *Media) void {
        _ = self;
        sys.spawnDetached("playerctl next");
    }
    pub fn prev(self: *Media) void {
        _ = self;
        sys.spawnDetached("playerctl previous");
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

/// playerctl --follow は再生位置の変化(シーク)を通知しないので、歌詞を表示している間だけ
/// 3 秒おきに実際の位置を聞き直してずれを補正する。
pub fn resync(self: *Media) void {
    if (self.status != .playing) return;
    if (loop.nowMs() -| self.last_resync_ms < 3000) return;
    self.last_resync_ms = loop.nowMs();
    var out: [64]u8 = undefined;
    const s = sys.run(&.{ "playerctl", "position" }, &out) orelse return;
    const p = std.fmt.parseFloat(f32, s) catch return;
    self.pos_s = p;
    self.pos_at_ms = loop.nowMs();
}

/// シャッフル・リピートの状態を問い合わせる(メディア画面を開いたとき)
pub fn queryModes(self: *Media) void {
    var out: [64]u8 = undefined;
    if (sys.run(&.{ "playerctl", "shuffle" }, &out)) |s| self.shuffle = std.mem.eql(u8, s, "On");
    if (sys.run(&.{ "playerctl", "loop" }, &out)) |s| self.loop_mode = if (std.mem.eql(u8, s, "Playlist")) 1 else if (std.mem.eql(u8, s, "Track")) 2 else 0;
}

pub fn toggleShuffle(self: *Media) void {
    var out: [8]u8 = undefined;
    _ = sys.run(&.{ "playerctl", "shuffle", "toggle" }, &out);
    queryModes(self);
}

pub fn cycleLoop(self: *Media) void {
    const next: [*:0]const u8 = switch (self.loop_mode) {
        0 => "Playlist",
        1 => "Track",
        else => "None",
    };
    var out: [8]u8 = undefined;
    _ = sys.run(&.{ "playerctl", "loop", next }, &out);
    queryModes(self);
}

/// 試験用: 実際のプレイヤー無しで「再生中」の状態を作る(ipc の debug-media から。AME_DEBUG 時のみ)
pub fn debugFakeImpl(self: *Media, spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, '|');
    const artist = it.next() orelse return;
    const title = it.next() orelse return;
    const len = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
    const pos = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
    self.status = .playing;
    Media.set(&self.artist, &self.artist_len, artist);
    Media.set(&self.title, &self.title_len, title);
    Media.set(&self.player, &self.player_len, "debug");
    self.length_s = len;
    self.pos_s = pos;
    self.pos_at_ms = loop.nowMs();
    self.last_resync_ms = loop.nowMs() + 3_600_000; // 本物の playerctl で上書きしない
    self.lyrics.request(artist, title, len);
    self.app.dashboard.dataChanged();
}
