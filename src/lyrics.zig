// 歌詞: 再生位置に同期した LRC を、いくつかの取り寄せ先から順に探す。
//
//   0. 再生アプリ自身が置いた歌詞ファイル(music-tui。trySidecar、最優先)
//   1. キャッシュ(~/.cache/ame-shell/lyrics/<曲のハッシュ>)
//   2. music-tui の歌詞サーバ(music-tui と同じ WORKERS_URL。曲の一覧から曲名で探し、その曲の LRC を取る)
//   3. LRCLIB(https://lrclib.net、無料・登録不要)の /api/get(アーティスト + 曲名 + 長さ)→ /api/search
//   4. NetEase Cloud Music(非公式の公開 API。日本語の曲の同期歌詞が多い)の検索 → 歌詞
//   5. 酷狗(Kugou、歌詞ツールで広く使われる公開 API)の検索 → 歌詞(base64 の LRC)。長さの近い候補を選ぶ(ライブ版を避ける)
//   6. 最後に、曲名だけで LRCLIB を検索(長さが 3 秒以内で合うものだけ)
// 検索の前に、動画サイトの書き方(「チャンネル名 - Topic」「アーティスト - 曲名」「【MV】アーティスト「曲名」」など)を
// アーティストと曲名に分けて整える(normalize)。
// 同期歌詞が見つかった時点で終わり。同期の無い歌詞しか無ければ、残りの取り寄せ先で同期歌詞を探してから使う。
// curl を非同期に動かし、完了を pipe の EOF で知る(シェルを通さず引数で渡すので曲名に何が入っていても安全)。
// どこにも無かったことは「無し」としてキャッシュするが、タイムアウトや 5xx(混雑)のときは覚えない(次に再生したときに探し直す)。
const std = @import("std");

const App = @import("app.zig").App;
const c = @import("c.zig");
const sys = @import("platform/sys.zig");

pub const Line = struct { t: f32, text: []const u8 };

pub const State = enum { idle, fetching, synced, plain, none };

/// 取り寄せ先の順番
const Stage = enum { mt_index, mt_lrc, lrclib_get, lrclib_search, ne_search, ne_lyric, kg_search, kg_lyric, lrclib_title, done };

/// 「どこにも無かった」の印。取り寄せ先を増やす前の "#none" は無効(探し直す)
const NONE_MARK = "#none3";

/// music-tui の曲の一覧(タイトル → 歌詞ファイルのパス)。1 回読めば、曲が変わっても使い回す
const MtTrack = struct { title: []const u8, artist: []const u8, lrc: []const u8 };

pub const Lyrics = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    lines: std.ArrayList(Line),
    state: State = .idle,
    key: u64 = 0,
    fd: c_int = -1,
    pid: c_int = 0,
    buf: std.ArrayList(u8),
    stage: Stage = .lrclib_get,
    artist: [160]u8 = undefined,
    artist_len: usize = 0,
    title: [160]u8 = undefined,
    title_len: usize = 0,
    duration: f32 = 0,
    /// 同期の無い歌詞(ほかで同期歌詞が見つからなければ使う)
    plain_fallback: ?[]const u8 = null,
    /// 一時的な失敗(タイムアウト・混雑)があった。最後まで見つからなくても「無し」と覚えない
    transient: bool = false,
    /// NetEase の検索で選んだ曲の id / music-tui の歌詞ファイルのパス
    ne_id: u64 = 0,
    /// 酷狗の候補(id と accesskey)
    kg_id: [40]u8 = undefined,
    kg_id_len: usize = 0,
    kg_key: [64]u8 = undefined,
    kg_key_len: usize = 0,
    /// 検索に使う、整えたアーティストと曲名(normalize)
    qa: [160]u8 = undefined,
    qa_len: usize = 0,
    qt: [160]u8 = undefined,
    qt_len: usize = 0,
    mt_path: []const u8 = "",
    mt_tracks: std.ArrayList(MtTrack),
    mt_arena: std.heap.ArenaAllocator,
    mt_loaded_ms: i64 = 0,
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
            .mt_tracks = std.ArrayList(MtTrack).init(app.alloc),
            .mt_arena = std.heap.ArenaAllocator.init(app.alloc),
        };
        return self;
    }

    fn cacheDir(buf: []u8) ?[]const u8 {
        if (std.posix.getenv("XDG_CACHE_HOME")) |x| return std.fmt.bufPrint(buf, "{s}/ame-shell", .{x}) catch null;
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/.cache/ame-shell", .{home}) catch null;
    }

    fn cachePath(self: *Lyrics, buf: []u8) ?[]const u8 {
        var db: [400]u8 = undefined;
        const d = cacheDir(&db) orelse return null;
        return std.fmt.bufPrint(buf, "{s}/lyrics/{x}", .{ d, self.key }) catch null;
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
        const nq = normalize(artist, title, &self.qa, &self.qt);
        self.qa_len = nq[0];
        self.qt_len = nq[1];
        self.plain_fallback = null;
        self.transient = false;
        // キャッシュ
        var pb: [512]u8 = undefined;
        if (self.cachePath(&pb)) |p| {
            if (std.fs.cwd().readFileAlloc(self.arena.allocator(), p, 1 << 20)) |data| {
                if (std.mem.eql(u8, data, NONE_MARK)) {
                    self.reset(.none);
                    self.changed();
                    return;
                }
                if (!std.mem.startsWith(u8, data, "#none")) {
                    self.parse(data);
                    self.changed();
                    return;
                }
            } else |_| {}
        }
        self.stage = if (self.musicTuiUrl().len > 0) .mt_index else .lrclib_get;
        self.run();
    }

    fn reset(self: *Lyrics, st: State) void {
        self.lines.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.state = st;
        self.plain_fallback = null;
        self.mt_path = "";
    }

    fn cancel(self: *Lyrics) void {
        if (self.fd >= 0) {
            _ = c.kill(self.pid, c.SIGTERM);
            self.app.loop.remove(self.fd);
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    /// music-tui の歌詞サーバ(設定の lyrics { music-tui … }。無ければ music-tui の .env の WORKERS_URL)
    fn musicTuiUrl(self: *Lyrics) []const u8 {
        const cfg = &self.app.cfg;
        if (!cfg.lyrics_music_tui_on) return "";
        const s = std.mem.trimRight(u8, cfg.lyrics_music_tui.get(), "/");
        if (s.len > 0) return s;
        return envUrl();
    }

    var env_url_buf: [512]u8 = undefined;
    var env_url_len: usize = 0;
    var env_url_read = false;

    fn envUrl() []const u8 {
        if (env_url_read) return env_url_buf[0..env_url_len];
        env_url_read = true;
        const home = std.posix.getenv("HOME") orelse return "";
        for ([_][]const u8{ "music-tui-bsd", "music-tui" }) |dir| {
            var pb: [512]u8 = undefined;
            const p = std.fmt.bufPrint(&pb, "{s}/{s}/.env", .{ home, dir }) catch continue;
            var fb: [4096]u8 = undefined;
            const f = std.fs.cwd().openFile(p, .{}) catch continue;
            const n = f.readAll(&fb) catch 0;
            f.close();
            var it = std.mem.splitScalar(u8, fb[0..n], '\n');
            while (it.next()) |raw| {
                const l = std.mem.trim(u8, raw, " \r\t");
                if (!std.mem.startsWith(u8, l, "WORKERS_URL=")) continue;
                const v = std.mem.trimRight(u8, std.mem.trim(u8, l["WORKERS_URL=".len..], " \"'"), "/");
                if (v.len == 0 or v.len > env_url_buf.len) continue;
                @memcpy(env_url_buf[0..v.len], v);
                env_url_len = v.len;
                return env_url_buf[0..env_url_len];
            }
        }
        return "";
    }

    /// 今の段階の問い合わせを始める(要らない段階は飛ばす)
    fn run(self: *Lyrics) void {
        while (self.stage != .done) {
            const ok = switch (self.stage) {
                .mt_index => blk: {
                    // 一覧は 6 時間使い回す(曲の追加に追いつく程度)
                    if (self.mt_tracks.items.len > 0 and std.time.milliTimestamp() - self.mt_loaded_ms < 6 * 3600 * 1000) {
                        self.stage = .mt_lrc;
                        continue;
                    }
                    if (self.loadMtIndexFile(6 * 3600)) {
                        self.stage = .mt_lrc;
                        continue;
                    }
                    var ub: [600]u8 = undefined;
                    var ob: [512]u8 = undefined;
                    const url = std.fmt.bufPrintZ(&ub, "{s}/tracks", .{self.musicTuiUrl()}) catch break :blk false;
                    const out = mtIndexPath(&ob) orelse break :blk false;
                    if (std.fs.path.dirname(out)) |d| std.fs.cwd().makePath(d) catch {};
                    break :blk self.curl(&.{ "curl", "-s", "--max-time", "20", "-o", out.ptr, "-w", "%{http_code}", url.ptr });
                },
                .mt_lrc => blk: {
                    const path = self.findMt() orelse {
                        self.stage = .lrclib_get;
                        continue;
                    };
                    var eb: [800]u8 = undefined;
                    var ub: [1400]u8 = undefined;
                    const enc = encodePath(&eb, path) orelse break :blk false;
                    const url = std.fmt.bufPrintZ(&ub, "{s}/lyrics/{s}", .{ self.musicTuiUrl(), enc }) catch break :blk false;
                    break :blk self.curl(&.{ "curl", "-s", "--max-time", "8", "-w", "\n%{http_code}", url.ptr });
                },
                .lrclib_get, .lrclib_search => blk: {
                    if (!self.app.cfg.lyrics_lrclib) {
                        self.stage = .ne_search;
                        continue;
                    }
                    var a1: [400]u8 = undefined;
                    var a2: [400]u8 = undefined;
                    var a3: [64]u8 = undefined;
                    const artist = self.qArtist();
                    const title = self.qTitle();
                    const ua = "ame-shell (https://github.com/TatsuyaM2667/ame-shell)";
                    if (self.stage == .lrclib_get) {
                        const an = std.fmt.bufPrintZ(&a1, "artist_name={s}", .{artist}) catch break :blk false;
                        const tn = std.fmt.bufPrintZ(&a2, "track_name={s}", .{title}) catch break :blk false;
                        if (self.duration > 0) {
                            const dn = std.fmt.bufPrintZ(&a3, "duration={d}", .{@as(u32, @intFromFloat(self.duration))}) catch break :blk false;
                            break :blk self.curl(&.{ "curl", "-s", "--max-time", "8", "-w", "\n%{http_code}", "-A", ua, "-G", "https://lrclib.net/api/get", "--data-urlencode", an.ptr, "--data-urlencode", tn.ptr, "--data-urlencode", dn.ptr });
                        }
                        break :blk self.curl(&.{ "curl", "-s", "--max-time", "8", "-w", "\n%{http_code}", "-A", ua, "-G", "https://lrclib.net/api/get", "--data-urlencode", an.ptr, "--data-urlencode", tn.ptr });
                    }
                    const q = std.fmt.bufPrintZ(&a1, "q={s} {s}", .{ artist, title }) catch break :blk false;
                    break :blk self.curl(&.{ "curl", "-s", "--max-time", "8", "-w", "\n%{http_code}", "-A", ua, "-G", "https://lrclib.net/api/search", "--data-urlencode", q.ptr });
                },
                .ne_search => blk: {
                    if (!self.app.cfg.lyrics_netease) {
                        self.stage = .kg_search;
                        continue;
                    }
                    var a1: [400]u8 = undefined;
                    const q = std.fmt.bufPrintZ(&a1, "s={s} {s}", .{ self.qArtist(), self.qTitle() }) catch break :blk false;
                    break :blk self.curl(&.{ "curl", "-s", "--max-time", "8", "-w", "\n%{http_code}", "-G", "https://music.163.com/api/cloudsearch/pc", "--data-urlencode", q.ptr, "--data-urlencode", "type=1", "--data-urlencode", "limit=10" });
                },
                .ne_lyric => blk: {
                    var ub: [160]u8 = undefined;
                    const url = std.fmt.bufPrintZ(&ub, "https://music.163.com/api/song/lyric?id={d}&lv=1&tv=-1", .{self.ne_id}) catch break :blk false;
                    break :blk self.curl(&.{ "curl", "-s", "--max-time", "8", "-w", "\n%{http_code}", url.ptr });
                },
                .kg_search => blk: {
                    if (!self.app.cfg.lyrics_kugou) {
                        self.stage = .lrclib_title;
                        continue;
                    }
                    var a1: [400]u8 = undefined;
                    var a2: [48]u8 = undefined;
                    const kw = (if (self.qa_len > 0) std.fmt.bufPrintZ(&a1, "keyword={s} - {s}", .{ self.qArtist(), self.qTitle() }) else std.fmt.bufPrintZ(&a1, "keyword={s}", .{self.qTitle()})) catch break :blk false;
                    const du = std.fmt.bufPrintZ(&a2, "duration={d}", .{@as(u64, @intFromFloat(@max(self.duration, 0) * 1000))}) catch break :blk false;
                    break :blk self.curl(&.{ "curl", "-s", "--max-time", "8", "-w", "\n%{http_code}", "-G", "https://lyrics.kugou.com/search", "--data-urlencode", "ver=1", "--data-urlencode", "man=yes", "--data-urlencode", "client=pc", "--data-urlencode", kw.ptr, "--data-urlencode", du.ptr });
                },
                .kg_lyric => blk: {
                    var a1: [80]u8 = undefined;
                    var a2: [96]u8 = undefined;
                    const id = std.fmt.bufPrintZ(&a1, "id={s}", .{self.kg_id[0..self.kg_id_len]}) catch break :blk false;
                    const key = std.fmt.bufPrintZ(&a2, "accesskey={s}", .{self.kg_key[0..self.kg_key_len]}) catch break :blk false;
                    break :blk self.curl(&.{ "curl", "-s", "--max-time", "8", "-w", "\n%{http_code}", "-G", "https://lyrics.kugou.com/download", "--data-urlencode", "ver=1", "--data-urlencode", "client=pc", "--data-urlencode", id.ptr, "--data-urlencode", key.ptr, "--data-urlencode", "fmt=lrc", "--data-urlencode", "charset=utf8" });
                },
                .lrclib_title => blk: {
                    // 最後の手段: 曲名だけで探す(長さが合うものだけ使う。長さが分からなければ使わない)
                    if (!self.app.cfg.lyrics_lrclib or self.duration <= 0) {
                        self.stage = .done;
                        continue;
                    }
                    var a1: [400]u8 = undefined;
                    const q = std.fmt.bufPrintZ(&a1, "track_name={s}", .{self.qTitle()}) catch break :blk false;
                    break :blk self.curl(&.{ "curl", "-s", "--max-time", "8", "-w", "\n%{http_code}", "-A", "ame-shell (https://github.com/TatsuyaM2667/ame-shell)", "-G", "https://lrclib.net/api/search", "--data-urlencode", q.ptr });
                },
                .done => unreachable,
            };
            if (ok) return; // 応答待ち(onRead → handleResponse)
            self.next();
        }
        self.finish();
    }

    fn curl(self: *Lyrics, argv: []const ?[*:0]const u8) bool {
        self.buf.clearRetainingCapacity();
        self.fd = sys.spawnReader(argv, &self.pid) orelse return false;
        self.app.loop.add(self.fd, c.EPOLLIN | c.EPOLLHUP, self, onRead) catch {};
        return true;
    }

    /// 次の取り寄せ先へ(同じ取り寄せ先の 2 段目は、1 段目で必要なときだけ呼び出し側が進める)
    fn next(self: *Lyrics) void {
        self.stage = switch (self.stage) {
            .mt_index => .mt_lrc,
            .mt_lrc => .lrclib_get,
            .lrclib_get => .lrclib_search,
            .lrclib_search => .ne_search,
            .ne_search, .ne_lyric => .kg_search,
            .kg_search, .kg_lyric => .lrclib_title,
            .lrclib_title => .done,
            .done => .done,
        };
    }

    fn onRead(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Lyrics = @ptrCast(@alignCast(ctx));
        var tmp: [8192]u8 = undefined;
        const n = c.read(fd, &tmp, tmp.len);
        if (n > 0) {
            self.buf.appendSlice(tmp[0..@intCast(n)]) catch {};
            if (self.buf.items.len < 4 << 20) return;
        }
        self.app.loop.remove(fd);
        _ = c.close(fd);
        self.fd = -1;
        self.handleResponse();
    }

    const Rec = struct { syncedLyrics: ?[]const u8 = null, plainLyrics: ?[]const u8 = null, instrumental: bool = false, duration: ?f32 = null };
    const KgCand = struct { id: []const u8 = "", accesskey: []const u8 = "", song: []const u8 = "", singer: []const u8 = "", duration: u64 = 0 };
    const KgSearch = struct { candidates: ?[]KgCand = null };
    const KgDownload = struct { content: ?[]const u8 = null };
    const NeArtist = struct { name: []const u8 = "" };
    const NeSong = struct { id: u64 = 0, name: []const u8 = "", ar: []NeArtist = &.{}, dt: u64 = 0 };
    const NeSearch = struct { result: ?struct { songs: ?[]NeSong = null } = null };
    const NeLyric = struct { lrc: ?struct { lyric: ?[]const u8 = null } = null };

    /// curl の -w で末尾に付けた HTTP の状態コードを切り離す
    fn splitStatus(body: []const u8) struct { body: []const u8, code: u32 } {
        const nl = std.mem.lastIndexOfScalar(u8, body, '\n') orelse return .{ .body = "", .code = std.fmt.parseInt(u32, std.mem.trim(u8, body, " \n"), 10) catch 0 };
        return .{ .body = body[0..nl], .code = std.fmt.parseInt(u32, std.mem.trim(u8, body[nl + 1 ..], " \r\n"), 10) catch 0 };
    }

    fn handleResponse(self: *Lyrics) void {
        const a = self.arena.allocator();
        const r = splitStatus(self.buf.items);
        // 0 = 通信できない・タイムアウト、429・5xx = 混雑。「無い」とは限らない
        if (r.code == 0 or r.code == 429 or r.code >= 500) self.transient = true;
        var found: ?[]const u8 = null; // 見つかった LRC(同期とは限らない)
        switch (self.stage) {
            .mt_index => {
                if (r.code == 200 and self.loadMtIndexFile(null)) {
                    self.stage = .mt_lrc;
                } else self.stage = .lrclib_get;
                self.run();
                return;
            },
            .mt_lrc => if (r.code == 200 and r.body.len > 0) {
                found = r.body;
            },
            .lrclib_get => {
                if (r.code == 200) if (std.json.parseFromSliceLeaky(Rec, a, r.body, .{ .ignore_unknown_fields = true })) |rec| {
                    found = rec.syncedLyrics orelse rec.plainLyrics;
                } else |_| {};
            },
            .lrclib_search => {
                if (r.code == 200) if (std.json.parseFromSliceLeaky([]Rec, a, r.body, .{ .ignore_unknown_fields = true })) |list| {
                    for (list) |rec| if (rec.syncedLyrics) |s| {
                        found = s;
                        break;
                    };
                    if (found == null) for (list) |rec| if (rec.plainLyrics) |p| {
                        found = p;
                        break;
                    };
                } else |_| {};
            },
            .ne_search => {
                if (r.code == 200) if (std.json.parseFromSliceLeaky(NeSearch, a, r.body, .{ .ignore_unknown_fields = true })) |res| {
                    if (res.result) |rs| if (rs.songs) |songs| if (self.pickNetease(songs)) |id| {
                        self.ne_id = id;
                        self.stage = .ne_lyric;
                        self.run();
                        return;
                    };
                } else |_| {};
            },
            .ne_lyric => {
                if (r.code == 200) if (std.json.parseFromSliceLeaky(NeLyric, a, r.body, .{ .ignore_unknown_fields = true })) |res| {
                    if (res.lrc) |l| if (l.lyric) |text| {
                        if (std.mem.trim(u8, text, " \n").len > 0) found = text;
                    };
                } else |_| {};
            },
            .kg_search => {
                if (r.code == 200) if (std.json.parseFromSliceLeaky(KgSearch, a, r.body, .{ .ignore_unknown_fields = true })) |res| {
                    if (res.candidates) |cands| if (self.pickKugou(cands)) |cd| {
                        self.kg_id_len = @min(cd.id.len, self.kg_id.len);
                        @memcpy(self.kg_id[0..self.kg_id_len], cd.id[0..self.kg_id_len]);
                        self.kg_key_len = @min(cd.accesskey.len, self.kg_key.len);
                        @memcpy(self.kg_key[0..self.kg_key_len], cd.accesskey[0..self.kg_key_len]);
                        self.stage = .kg_lyric;
                        self.run();
                        return;
                    };
                } else |_| {};
            },
            .kg_lyric => {
                if (r.code == 200) if (std.json.parseFromSliceLeaky(KgDownload, a, r.body, .{ .ignore_unknown_fields = true })) |res| {
                    if (res.content) |b64| {
                        const dec = std.base64.standard.Decoder;
                        if (dec.calcSizeForSlice(b64)) |n| {
                            const out = a.alloc(u8, n) catch null;
                            if (out) |o| if (dec.decode(o, b64)) {
                                if (std.mem.trim(u8, o, " \r\n").len > 0) found = o;
                            } else |_| {};
                        } else |_| {}
                    }
                } else |_| {};
            },
            .lrclib_title => {
                if (r.code == 200) if (std.json.parseFromSliceLeaky([]Rec, a, r.body, .{ .ignore_unknown_fields = true })) |list| {
                    for (list) |rec| {
                        const d = rec.duration orelse continue;
                        if (@abs(d - self.duration) > 3) continue;
                        if (rec.syncedLyrics) |s| {
                            found = s;
                            break;
                        }
                    }
                } else |_| {};
            },
            .done => {},
        }
        if (found) |text| {
            if (hasTimestamps(text)) {
                self.store(text);
                return;
            }
            // 同期の無い歌詞は取っておき、残りの取り寄せ先で同期歌詞を探す
            if (self.plain_fallback == null) self.plain_fallback = a.dupe(u8, text) catch null;
        }
        // LRCLIB の完全一致で見つからなければ、同じ LRCLIB のあいまい検索へ。それ以外は次の取り寄せ先へ
        self.next();
        if (self.stage == .lrclib_search and found != null) self.next(); // get で(同期の無い)歌詞はあった
        self.run();
    }

    /// 検索に使う(整えた)アーティストと曲名
    pub fn qArtist(self: *const Lyrics) []const u8 {
        return self.qa[0..self.qa_len];
    }
    pub fn qTitle(self: *const Lyrics) []const u8 {
        return self.qt[0..self.qt_len];
    }

    /// 酷狗の候補から、曲名・アーティスト・長さが合うものを選ぶ(1 件目がライブ版のことも多い)
    fn pickKugou(self: *Lyrics, cands: []const KgCand) ?KgCand {
        const title = self.qTitle();
        const artist = self.qArtist();
        var best: ?KgCand = null;
        var best_score: i32 = -100;
        for (cands) |cd| {
            if (cd.id.len == 0 or cd.accesskey.len == 0) continue;
            var score: i32 = 0;
            if (containsIgnoreCase(cd.song, title) or containsIgnoreCase(title, cd.song)) score += 3;
            if (artist.len > 0 and (containsIgnoreCase(cd.singer, artist) or containsIgnoreCase(artist, cd.singer))) score += 3;
            if (self.duration > 0 and cd.duration > 0) {
                const d = @abs(@as(f32, @floatFromInt(cd.duration)) / 1000 - self.duration);
                if (d < 3) score += 4 else if (d < 8) score += 1 else if (d > 20) score -= 4;
            }
            // ライブ・別バージョンは避ける
            for ([_][]const u8{ "现场", "Live", "live", "LIVE", "伴奏", "Instrumental", "钢琴", "翻自" }) |w| if (std.mem.indexOf(u8, cd.song, w) != null) {
                score -= 3;
            };
            if (score > best_score) {
                best = cd;
                best_score = score;
            }
        }
        // 長さもアーティストも合わないものは別の曲とみなす
        return if (best_score >= 4) best else null;
    }

    /// NetEase の検索結果から、曲名・アーティスト・長さが合うものを選ぶ(1 件目が別の曲のことも多い)
    fn pickNetease(self: *Lyrics, songs: []const NeSong) ?u64 {
        const title = self.qTitle();
        const artist = self.qArtist();
        var best: ?u64 = null;
        var best_score: i32 = 0;
        for (songs) |s| {
            var score: i32 = 0;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, s.name, " "), title)) score += 4 else if (containsIgnoreCase(s.name, title) or containsIgnoreCase(title, s.name)) score += 2 else continue;
            for (s.ar) |ar| if (artist.len > 0 and (containsIgnoreCase(artist, ar.name) or containsIgnoreCase(ar.name, artist))) {
                score += 3;
                break;
            };
            if (self.duration > 0 and s.dt > 0) {
                const d = @abs(@as(f32, @floatFromInt(s.dt)) / 1000 - self.duration);
                if (d < 3) score += 2 else if (d > 20) score -= 3;
            }
            // 曲名だけ合って、アーティストも長さも合わないものは別の曲とみなす
            if (score >= 5 and score > best_score) {
                best = s.id;
                best_score = score;
            }
        }
        return best;
    }

    /// 見つかった LRC を使い、キャッシュに書く
    fn store(self: *Lyrics, text: []const u8) void {
        std.log.info("lyrics: {s} から取得 / found via {s}", .{ @tagName(self.stage), @tagName(self.stage) });
        const owned = self.arena.allocator().dupe(u8, text) catch return;
        var pb: [512]u8 = undefined;
        if (self.cachePath(&pb)) |p| {
            if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
            if (std.fs.cwd().createFile(p, .{})) |f| {
                f.writeAll(owned) catch {};
                f.close();
            } else |_| {}
        }
        self.parse(owned);
        self.stage = .done;
        self.changed();
    }

    /// 全部の取り寄せ先を見終わった
    fn finish(self: *Lyrics) void {
        if (self.plain_fallback) |p| {
            self.store(p);
            return;
        }
        // 一時的な失敗があったときは「無し」と覚えない(次に再生したときに探し直す)
        if (!self.transient) {
            var pb: [512]u8 = undefined;
            if (self.cachePath(&pb)) |p| {
                if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
                if (std.fs.cwd().createFile(p, .{})) |f| {
                    f.writeAll(NONE_MARK) catch {};
                    f.close();
                } else |_| {}
            }
        }
        std.log.info("lyrics: 見つかりません: {s} / {s}(検索: {s} / {s})", .{ self.artist[0..self.artist_len], self.title[0..self.title_len], self.qArtist(), self.qTitle() });
        self.state = .none;
        self.changed();
    }

    fn mtIndexPath(buf: []u8) ?[:0]const u8 {
        var db: [400]u8 = undefined;
        const d = cacheDir(&db) orelse return null;
        return std.fmt.bufPrintZ(buf, "{s}/music-tui-tracks.ndjson", .{d}) catch null;
    }

    /// 取ってきた music-tui の曲の一覧(1 行 1 曲の JSON)を読む。max_age_s を超えて古ければ読まない
    fn loadMtIndexFile(self: *Lyrics, max_age_s: ?i64) bool {
        var ob: [512]u8 = undefined;
        const p = mtIndexPath(&ob) orelse return false;
        const st = std.fs.cwd().statFile(p) catch return false;
        if (max_age_s) |age| if (std.time.timestamp() - @as(i64, @intCast(@divTrunc(st.mtime, std.time.ns_per_s))) > age) return false;
        _ = self.mt_arena.reset(.retain_capacity);
        self.mt_tracks.clearRetainingCapacity();
        const a = self.mt_arena.allocator();
        const data = std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch return false;
        const T = struct { title: []const u8 = "", artist: []const u8 = "", lrc: ?[]const u8 = null };
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len < 2) continue;
            const t = std.json.parseFromSliceLeaky(T, a, line, .{ .ignore_unknown_fields = true }) catch continue;
            const lrc = t.lrc orelse continue;
            if (lrc.len == 0 or t.title.len == 0) continue;
            self.mt_tracks.append(.{ .title = t.title, .artist = t.artist, .lrc = lrc }) catch {};
        }
        self.mt_loaded_ms = std.time.milliTimestamp();
        return self.mt_tracks.items.len > 0;
    }

    /// 今の曲の歌詞ファイルを music-tui の一覧から探す(曲名が一致、アーティストは分かれば一致)
    fn findMt(self: *Lyrics) ?[]const u8 {
        const title = std.mem.trim(u8, self.title[0..self.title_len], " ");
        const ctitle = cleanTitle(title);
        const artist = self.qArtist();
        const eqi = std.ascii.eqlIgnoreCase;
        for (self.mt_tracks.items) |t| {
            const tt = std.mem.trim(u8, t.title, " ");
            if (!(eqi(tt, title) or eqi(tt, ctitle))) continue;
            if (artist.len > 0 and t.artist.len > 0 and !(containsIgnoreCase(artist, t.artist) or containsIgnoreCase(t.artist, artist))) continue;
            return t.lrc;
        }
        return null;
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
        const artist = self.qArtist();
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
                if (isCredit(text)) continue; // 「作词 : …」などのクレジットの行(NetEase の歌詞の頭に付く)
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


/// 動画サイトなどの書き方をアーティストと曲名に分けて整える。返り値は (アーティストの長さ, 曲名の長さ)
///   「YOASOBI - Topic」/「YOASOBI Official」→ YOASOBI
///   「YOASOBI - アイドル (Official Music Video)」→ YOASOBI / アイドル
///   「【MV】YOASOBI「アイドル」」→ YOASOBI / アイドル
///   「アイドル / YOASOBI」→ アイドル(アーティストと一致する側を外す)
pub fn normalize(artist_in: []const u8, title_in: []const u8, abuf: *[160]u8, tbuf: *[160]u8) [2]usize {
    var a = std.mem.trim(u8, artist_in, " ");
    var t = std.mem.trim(u8, title_in, " ");
    // チャンネル名の飾り
    var changed = true;
    while (changed) {
        changed = false;
        for ([_][]const u8{ " - Topic", "VEVO", " Official YouTube Channel", " Official Channel", " official channel", " Official", " official", " OFFICIAL", "公式チャンネル", "オフィシャルチャンネル", "公式", " Channel", " channel", "チャンネル", "【公式】" }) |suf| {
            if (a.len > suf.len and std.mem.endsWith(u8, a, suf)) {
                a = std.mem.trim(u8, a[0 .. a.len - suf.len], " ");
                changed = true;
            }
        }
    }
    // 先頭の【MV】[MV] などのタグ
    while (true) {
        if (std.mem.startsWith(u8, t, "【")) {
            const e = std.mem.indexOf(u8, t, "】") orelse break;
            t = std.mem.trim(u8, t[e + "】".len ..], " ");
        } else if (t.len > 0 and t[0] == '[') {
            const e = std.mem.indexOfScalar(u8, t, ']') orelse break;
            t = std.mem.trim(u8, t[e + 1 ..], " ");
        } else break;
    }
    // 「曲名」『曲名』: かぎかっこの中が曲名、前がアーティストのことが多い
    for ([_][2][]const u8{ .{ "「", "」" }, .{ "『", "』" } }) |q| {
        if (std.mem.indexOf(u8, t, q[0])) |o| if (std.mem.indexOf(u8, t[o..], q[1])) |cl| {
            const before = std.mem.trim(u8, t[0..o], " -/");
            const inner = std.mem.trim(u8, t[o + q[0].len .. o + cl], " ");
            if (inner.len > 0) {
                if (before.len > 0 and (a.len == 0 or containsIgnoreCase(before, a) or containsIgnoreCase(a, before))) a = before;
                t = inner;
                break;
            }
        };
    }
    // 「アーティスト - 曲名」「曲名 / アーティスト」
    for ([_][]const u8{ " - ", " – ", " — ", " / ", "／" }) |sep| {
        const i = std.mem.indexOf(u8, t, sep) orelse continue;
        const l = std.mem.trim(u8, t[0..i], " ");
        const r = std.mem.trim(u8, t[i + sep.len ..], " ");
        if (l.len == 0 or r.len == 0) continue;
        const slash = std.mem.eql(u8, sep, " / ") or std.mem.eql(u8, sep, "／");
        if (slash) {
            // 日本の MV に多い「曲名 / アーティスト」
            if (a.len == 0 or containsIgnoreCase(r, a) or containsIgnoreCase(a, r)) {
                if (a.len == 0) a = r;
                t = l;
            }
        } else if (a.len == 0 or containsIgnoreCase(l, a) or containsIgnoreCase(a, l)) {
            a = l;
            t = r;
        } else if (containsIgnoreCase(r, a)) {
            t = l;
        }
        break;
    }
    t = cleanTitle(t);
    // 末尾の飾り(かっこ無し)
    for ([_][]const u8{ " Official Music Video", " Official Video", " Music Video", " Official Audio", " Lyric Video", " Lyrics", " MV", " PV", " (Audio)" }) |suf| {
        if (t.len > suf.len and std.ascii.endsWithIgnoreCase(t, suf)) t = std.mem.trim(u8, t[0 .. t.len - suf.len], " ");
    }
    // feat. 以降は外す(検索でぶれる)
    for ([_][]const u8{ " feat.", " ft.", " Feat.", " FEAT." }) |f| if (std.mem.indexOf(u8, t, f)) |i| {
        t = std.mem.trim(u8, t[0..i], " ");
    };
    const al = @min(a.len, abuf.len);
    @memcpy(abuf[0..al], a[0..al]);
    const tl = @min(t.len, tbuf.len);
    @memcpy(tbuf[0..tl], t[0..tl]);
    return .{ al, tl };
}

test "normalize: 動画サイトの書き方" {
    var ab: [160]u8 = undefined;
    var tb: [160]u8 = undefined;
    var r = normalize("YOASOBI - Topic", "アイドル", &ab, &tb);
    try std.testing.expectEqualStrings("YOASOBI", ab[0..r[0]]);
    try std.testing.expectEqualStrings("アイドル", tb[0..r[1]]);
    r = normalize("YOASOBI Official", "YOASOBI - アイドル (Official Music Video)", &ab, &tb);
    try std.testing.expectEqualStrings("YOASOBI", ab[0..r[0]]);
    try std.testing.expectEqualStrings("アイドル", tb[0..r[1]]);
    r = normalize("Ayase / YOASOBI", "【MV】YOASOBI「アイドル」", &ab, &tb);
    try std.testing.expectEqualStrings("アイドル", tb[0..r[1]]);
    r = normalize("Ado", "うっせぇわ / Ado", &ab, &tb);
    try std.testing.expectEqualStrings("うっせぇわ", tb[0..r[1]]);
    r = normalize("", "Mrs. GREEN APPLE - ケセラセラ", &ab, &tb);
    try std.testing.expectEqualStrings("Mrs. GREEN APPLE", ab[0..r[0]]);
    try std.testing.expectEqualStrings("ケセラセラ", tb[0..r[1]]);
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

/// "[mm:ss.xx]" のタイムスタンプがある(同期歌詞)か
fn hasTimestamps(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimLeft(u8, raw, " \t");
        if (l.len >= 4 and l[0] == '[' and std.ascii.isDigit(l[1])) return true;
    }
    return false;
}

/// URL のパス(各部分をパーセントエンコードし、/ はそのまま)
fn encodePath(buf: []u8, path: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (std.mem.trimLeft(u8, path, "/")) |ch| {
        const keep = std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (keep) {
            if (n + 1 > buf.len) return null;
            buf[n] = ch;
            n += 1;
        } else {
            if (n + 3 > buf.len) return null;
            _ = std.fmt.bufPrint(buf[n .. n + 3], "%{X:0>2}", .{ch}) catch return null;
            n += 3;
        }
    }
    return buf[0..n];
}

/// 歌詞の頭に付くクレジットの行(「作词 : …」「作曲 : …」)
fn isCredit(text: []const u8) bool {
    const heads = [_][]const u8{ "作词", "作詞", "作曲", "词", "曲", "词曲", "编曲", "編曲", "制作", "混音", "母带", "和声", "吉他", "贝斯", "鼓", "录音", "监制", "出品", "OP", "SP" };
    const colon = std.mem.indexOf(u8, text, ":") orelse std.mem.indexOf(u8, text, "：") orelse return false;
    const head = std.mem.trim(u8, text[0..colon], " ");
    if (head.len == 0 or head.len > 24) return false;
    for (heads) |h| if (std.mem.startsWith(u8, head, h)) return true;
    return false;
}
