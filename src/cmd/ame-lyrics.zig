// ame-lyrics: 曲の同期歌詞(LRC)を探して標準出力へ出す。
//
//   ame-lyrics [-d 秒] [--music-tui URL|on|off] [--no-lrclib] [--no-netease] [--no-kugou] [--no-cache] アーティスト 曲名
//
// 終了コード: 0 = 見つかった(LRC を出した) / 1 = どこにも無かった / 2 = 通信できない・混雑(あとで探し直せる)
// どこで見つかったかは標準エラーへ 1 行で出す。
//
// 取り寄せ先(上から順に、同期歌詞が見つかった時点で終わり。同期の無い歌詞しか無ければ、残りで同期歌詞を探してから使う):
//   1. キャッシュ(~/.cache/ame-shell/lyrics/<曲のハッシュ>)
//   2. music-tui の歌詞サーバ(--music-tui。on なら ~/music-tui(-bsd)/.env の WORKERS_URL)
//   3. LRCLIB の /api/get(アーティスト + 曲名 + 長さ)→ /api/search
//   4. NetEase Cloud Music の検索 → 歌詞
//   5. 酷狗(Kugou)の検索 → 歌詞(base64 の LRC)。長さの近い候補を選ぶ(ライブ版を避ける)
//   6. 曲名だけで LRCLIB を検索(長さが 3 秒以内で合うものだけ)
// 検索の前に、動画サイトの書き方(「チャンネル名 - Topic」「【MV】アーティスト「曲名」」など)を整える(lrc.normalize)。
// どこにも無かったことは「無し」としてキャッシュするが、通信できない・混雑のときは覚えない。
// 通信は curl(シェルを通さず引数で渡すので、曲名に何が入っていても安全)。
const std = @import("std");
const lrc = @import("ame_lib").lrc;

const NONE_MARK = "#none3";
const UA = "ame-shell (https://github.com/TatsuyaM2667/ame-shell)";

const Opts = struct {
    artist: []const u8 = "",
    title: []const u8 = "",
    duration: f32 = 0,
    music_tui: []const u8 = "on",
    lrclib: bool = true,
    netease: bool = true,
    kugou: bool = true,
    cache: bool = true,
};

const Found = struct { text: []const u8, via: []const u8 };

const Search = struct {
    a: std.mem.Allocator,
    o: Opts,
    qa: []const u8,
    qt: []const u8,
    /// 通信できない・混雑があった(見つからなくても「無し」と覚えない)
    transient: bool = false,
    /// 同期の無い歌詞(ほかで同期歌詞が見つからなければ使う)
    plain: ?Found = null,

    const Resp = struct { body: []const u8, code: u32 };

    /// curl で取ってくる。-w で末尾に付けた HTTP の状態コードを切り離す。0 = 通信できない
    fn get(self: *Search, args: []const []const u8) Resp {
        var argv = std.ArrayList([]const u8).init(self.a);
        argv.appendSlice(&.{ "curl", "-s", "--max-time", "8", "-A", UA, "-w", "\n%{http_code}" }) catch return .{ .body = "", .code = 0 };
        argv.appendSlice(args) catch return .{ .body = "", .code = 0 };
        const r = std.process.Child.run(.{ .allocator = self.a, .argv = argv.items, .max_output_bytes = 8 << 20 }) catch return self.fail(0);
        const out = r.stdout;
        const nl = std.mem.lastIndexOfScalar(u8, out, '\n') orelse return self.fail(0);
        const code = std.fmt.parseInt(u32, std.mem.trim(u8, out[nl + 1 ..], " \r\n"), 10) catch 0;
        if (code == 0 or code == 429 or code >= 500) self.transient = true;
        return .{ .body = out[0..nl], .code = code };
    }

    fn fail(self: *Search, code: u32) Resp {
        self.transient = true;
        return .{ .body = "", .code = code };
    }

    fn arg(self: *Search, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.a, f, args) catch "";
    }

    /// 見つかった歌詞: 同期していれば終わり、していなければ取っておいて続ける
    fn take(self: *Search, text: ?[]const u8, via: []const u8) ?Found {
        const t = text orelse return null;
        if (std.mem.trim(u8, t, " \r\n").len == 0) return null;
        if (lrc.hasTimestamps(t)) return .{ .text = t, .via = via };
        if (self.plain == null) self.plain = .{ .text = t, .via = via };
        return null;
    }

    fn run(self: *Search) ?Found {
        if (self.musicTui()) |f| return f;
        if (self.o.lrclib) if (self.lrclib()) |f| return f;
        if (self.o.netease) if (self.netease()) |f| return f;
        if (self.o.kugou) if (self.kugou()) |f| return f;
        if (self.o.lrclib) if (self.lrclibTitle()) |f| return f;
        return self.plain;
    }

    // ---- music-tui ----

    fn musicTui(self: *Search) ?Found {
        const base = musicTuiUrl(self.a, self.o.music_tui) orelse return null;
        const index = self.mtIndex(base) orelse return null;
        const title = std.mem.trim(u8, self.o.title, " ");
        const ctitle = lrc.cleanTitle(title);
        const eqi = std.ascii.eqlIgnoreCase;
        const T = struct { title: []const u8 = "", artist: []const u8 = "", lrc: ?[]const u8 = null };
        var it = std.mem.splitScalar(u8, index, '\n');
        while (it.next()) |line| {
            if (line.len < 2) continue;
            const t = std.json.parseFromSliceLeaky(T, self.a, line, .{ .ignore_unknown_fields = true }) catch continue;
            const path = t.lrc orelse continue;
            const tt = std.mem.trim(u8, t.title, " ");
            if (path.len == 0 or !(eqi(tt, title) or eqi(tt, ctitle))) continue;
            if (self.qa.len > 0 and t.artist.len > 0 and !(lrc.containsIgnoreCase(self.qa, t.artist) or lrc.containsIgnoreCase(t.artist, self.qa))) continue;
            const r = self.get(&.{self.arg("{s}/lyrics/{s}", .{ base, encodePath(self.a, path) })});
            if (r.code == 200) return self.take(r.body, "music-tui");
            return null;
        }
        return null;
    }

    /// music-tui の曲の一覧(1 行 1 曲の JSON)。6 時間はキャッシュを使う
    fn mtIndex(self: *Search, base: []const u8) ?[]const u8 {
        const path = cachePath(self.a, "music-tui-tracks.ndjson") orelse return null;
        if (std.fs.cwd().statFile(path)) |s| {
            if (std.time.timestamp() - @as(i64, @intCast(@divTrunc(s.mtime, std.time.ns_per_s))) < 6 * 3600)
                return std.fs.cwd().readFileAlloc(self.a, path, 64 << 20) catch null;
        } else |_| {}
        if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
        const r = std.process.Child.run(.{ .allocator = self.a, .argv = &.{ "curl", "-s", "--max-time", "20", "-o", path, "-w", "%{http_code}", self.arg("{s}/tracks", .{base}) } }) catch return null;
        if (!std.mem.eql(u8, std.mem.trim(u8, r.stdout, " \n"), "200")) return null;
        return std.fs.cwd().readFileAlloc(self.a, path, 64 << 20) catch null;
    }

    // ---- LRCLIB ----

    const Rec = struct { syncedLyrics: ?[]const u8 = null, plainLyrics: ?[]const u8 = null, duration: ?f32 = null };

    fn lrclib(self: *Search) ?Found {
        var args = std.ArrayList([]const u8).init(self.a);
        args.appendSlice(&.{ "-G", "https://lrclib.net/api/get", "--data-urlencode", self.arg("artist_name={s}", .{self.qa}), "--data-urlencode", self.arg("track_name={s}", .{self.qt}) }) catch return null;
        if (self.o.duration > 0) args.appendSlice(&.{ "--data-urlencode", self.arg("duration={d}", .{@as(u32, @intFromFloat(self.o.duration))}) }) catch {};
        var got_plain = false;
        const r = self.get(args.items);
        if (r.code == 200) if (std.json.parseFromSliceLeaky(Rec, self.a, r.body, .{ .ignore_unknown_fields = true })) |rec| {
            if (self.take(rec.syncedLyrics orelse rec.plainLyrics, "LRCLIB")) |f| return f;
            got_plain = rec.plainLyrics != null;
        } else |_| {};
        if (got_plain) return null; // 完全一致で(同期の無い)歌詞はあった: あいまい検索はしない
        const s = self.get(&.{ "-G", "https://lrclib.net/api/search", "--data-urlencode", self.arg("q={s} {s}", .{ self.qa, self.qt }) });
        if (s.code != 200) return null;
        const list = std.json.parseFromSliceLeaky([]Rec, self.a, s.body, .{ .ignore_unknown_fields = true }) catch return null;
        for (list) |rec| if (rec.syncedLyrics) |t| return self.take(t, "LRCLIB(検索)");
        for (list) |rec| if (rec.plainLyrics) |t| return self.take(t, "LRCLIB(検索)");
        return null;
    }

    /// 最後の手段: 曲名だけで探す(長さが 3 秒以内で合う同期歌詞だけ)
    fn lrclibTitle(self: *Search) ?Found {
        if (self.o.duration <= 0) return null;
        const s = self.get(&.{ "-G", "https://lrclib.net/api/search", "--data-urlencode", self.arg("track_name={s}", .{self.qt}) });
        if (s.code != 200) return null;
        const list = std.json.parseFromSliceLeaky([]Rec, self.a, s.body, .{ .ignore_unknown_fields = true }) catch return null;
        for (list) |rec| {
            const d = rec.duration orelse continue;
            if (@abs(d - self.o.duration) > 3) continue;
            if (rec.syncedLyrics) |t| return self.take(t, "LRCLIB(曲名)");
        }
        return null;
    }

    // ---- NetEase ----

    const NeArtist = struct { name: []const u8 = "" };
    const NeSong = struct { id: u64 = 0, name: []const u8 = "", ar: []NeArtist = &.{}, dt: u64 = 0 };

    fn netease(self: *Search) ?Found {
        const NeSearch = struct { result: ?struct { songs: ?[]NeSong = null } = null };
        const NeLyric = struct { lrc: ?struct { lyric: ?[]const u8 = null } = null };
        const s = self.get(&.{ "-G", "https://music.163.com/api/cloudsearch/pc", "--data-urlencode", self.arg("s={s} {s}", .{ self.qa, self.qt }), "--data-urlencode", "type=1", "--data-urlencode", "limit=10" });
        if (s.code != 200) return null;
        const res = std.json.parseFromSliceLeaky(NeSearch, self.a, s.body, .{ .ignore_unknown_fields = true }) catch return null;
        const songs = (res.result orelse return null).songs orelse return null;
        const id = self.pickNetease(songs) orelse return null;
        const l = self.get(&.{self.arg("https://music.163.com/api/song/lyric?id={d}&lv=1&tv=-1", .{id})});
        if (l.code != 200) return null;
        const ly = std.json.parseFromSliceLeaky(NeLyric, self.a, l.body, .{ .ignore_unknown_fields = true }) catch return null;
        return self.take((ly.lrc orelse return null).lyric, "NetEase");
    }

    /// 検索結果から、曲名・アーティスト・長さが合うものを選ぶ(1 件目が別の曲のことも多い)
    fn pickNetease(self: *Search, songs: []const NeSong) ?u64 {
        var best: ?u64 = null;
        var best_score: i32 = 0;
        for (songs) |s| {
            var score: i32 = 0;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, s.name, " "), self.qt)) score += 4 else if (lrc.containsIgnoreCase(s.name, self.qt) or lrc.containsIgnoreCase(self.qt, s.name)) score += 2 else continue;
            for (s.ar) |ar| if (self.qa.len > 0 and (lrc.containsIgnoreCase(self.qa, ar.name) or lrc.containsIgnoreCase(ar.name, self.qa))) {
                score += 3;
                break;
            };
            if (self.o.duration > 0 and s.dt > 0) {
                const d = @abs(@as(f32, @floatFromInt(s.dt)) / 1000 - self.o.duration);
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

    // ---- 酷狗 ----

    const KgCand = struct { id: []const u8 = "", accesskey: []const u8 = "", song: []const u8 = "", singer: []const u8 = "", duration: u64 = 0 };

    fn kugou(self: *Search) ?Found {
        const KgSearch = struct { candidates: ?[]KgCand = null };
        const KgDownload = struct { content: ?[]const u8 = null };
        var args = std.ArrayList([]const u8).init(self.a);
        args.appendSlice(&.{ "-G", "https://lyrics.kugou.com/search", "--data-urlencode", "ver=1", "--data-urlencode", "man=yes", "--data-urlencode", "client=pc", "--data-urlencode", if (self.qa.len > 0) self.arg("keyword={s} - {s}", .{ self.qa, self.qt }) else self.arg("keyword={s}", .{self.qt}), "--data-urlencode", self.arg("duration={d}", .{@as(u64, @intFromFloat(@max(self.o.duration, 0) * 1000))}) }) catch return null;
        const s = self.get(args.items);
        if (s.code != 200) return null;
        const res = std.json.parseFromSliceLeaky(KgSearch, self.a, s.body, .{ .ignore_unknown_fields = true }) catch return null;
        const cd = self.pickKugou(res.candidates orelse return null) orelse return null;
        const d = self.get(&.{ "-G", "https://lyrics.kugou.com/download", "--data-urlencode", "ver=1", "--data-urlencode", "client=pc", "--data-urlencode", self.arg("id={s}", .{cd.id}), "--data-urlencode", self.arg("accesskey={s}", .{cd.accesskey}), "--data-urlencode", "fmt=lrc", "--data-urlencode", "charset=utf8" });
        if (d.code != 200) return null;
        const dl = std.json.parseFromSliceLeaky(KgDownload, self.a, d.body, .{ .ignore_unknown_fields = true }) catch return null;
        const b64 = dl.content orelse return null;
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(b64) catch return null;
        const out = self.a.alloc(u8, n) catch return null;
        dec.decode(out, b64) catch return null;
        return self.take(out, "酷狗");
    }

    /// 候補から、曲名・アーティスト・長さが合うものを選ぶ(1 件目がライブ版のことも多い)
    fn pickKugou(self: *Search, cands: []const KgCand) ?KgCand {
        var best: ?KgCand = null;
        var best_score: i32 = -100;
        for (cands) |cd| {
            if (cd.id.len == 0 or cd.accesskey.len == 0) continue;
            var score: i32 = 0;
            if (lrc.containsIgnoreCase(cd.song, self.qt) or lrc.containsIgnoreCase(self.qt, cd.song)) score += 3;
            if (self.qa.len > 0 and (lrc.containsIgnoreCase(cd.singer, self.qa) or lrc.containsIgnoreCase(self.qa, cd.singer))) score += 3;
            if (self.o.duration > 0 and cd.duration > 0) {
                const d = @abs(@as(f32, @floatFromInt(cd.duration)) / 1000 - self.o.duration);
                if (d < 3) score += 4 else if (d < 8) score += 1 else if (d > 20) score -= 4;
            }
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
};

// ---------------------------------------------------------------------------

fn cachePath(a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CACHE_HOME")) |x| if (x.len > 0) return std.fmt.allocPrint(a, "{s}/ame-shell/{s}", .{ x, name }) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.cache/ame-shell/{s}", .{ home, name }) catch null;
}

/// 曲ごとのキャッシュの名前(ame-shell の前の版と同じ。キャッシュをそのまま使える)
fn songKey(artist: []const u8, title: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(artist);
    h.update("\x00");
    h.update(title);
    return h.final();
}

/// music-tui の歌詞サーバの URL。"on" なら ~/music-tui(-bsd)/.env の WORKERS_URL、"off" や空なら使わない
fn musicTuiUrl(a: std.mem.Allocator, opt: []const u8) ?[]const u8 {
    if (opt.len == 0 or std.mem.eql(u8, opt, "off")) return null;
    if (!std.mem.eql(u8, opt, "on")) return std.mem.trimRight(u8, opt, "/");
    const home = std.posix.getenv("HOME") orelse return null;
    for ([_][]const u8{ "music-tui-bsd", "music-tui" }) |dir| {
        const p = std.fmt.allocPrint(a, "{s}/{s}/.env", .{ home, dir }) catch continue;
        const txt = std.fs.cwd().readFileAlloc(a, p, 1 << 16) catch continue;
        var it = std.mem.splitScalar(u8, txt, '\n');
        while (it.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \r\t");
            if (!std.mem.startsWith(u8, l, "WORKERS_URL=")) continue;
            const v = std.mem.trimRight(u8, std.mem.trim(u8, l["WORKERS_URL=".len..], " \"'"), "/");
            if (v.len > 0) return v;
        }
    }
    return null;
}

/// URL のパス(各部分をパーセントエンコードし、/ はそのまま)
fn encodePath(a: std.mem.Allocator, path: []const u8) []const u8 {
    var out = std.ArrayList(u8).init(a);
    for (std.mem.trimLeft(u8, path, "/")) |ch| {
        const keep = std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (keep) out.append(ch) catch {} else out.writer().print("%{X:0>2}", .{ch}) catch {};
    }
    return out.items;
}

fn usage() noreturn {
    std.io.getStdErr().writeAll("使い方: ame-lyrics [-d 秒] [--music-tui URL|on|off] [--no-lrclib] [--no-netease] [--no-kugou] [--no-cache] アーティスト 曲名\n") catch {};
    std.process.exit(64);
}

pub fn parseArgs(args: []const []const u8) ?Opts {
    var o = Opts{};
    var pos: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        const eq = std.mem.eql;
        if (eq(u8, s, "-d")) {
            i += 1;
            if (i >= args.len) return null;
            o.duration = std.fmt.parseFloat(f32, args[i]) catch return null;
            if (!(o.duration >= 0 and o.duration <= 86400)) return null; // nan や巨大値は整数にできない
        } else if (eq(u8, s, "--music-tui")) {
            i += 1;
            if (i >= args.len) return null;
            o.music_tui = args[i];
        } else if (eq(u8, s, "--no-lrclib")) {
            o.lrclib = false;
        } else if (eq(u8, s, "--no-netease")) {
            o.netease = false;
        } else if (eq(u8, s, "--no-kugou")) {
            o.kugou = false;
        } else if (eq(u8, s, "--no-cache")) {
            o.cache = false;
        } else {
            if (pos == 0) o.artist = s else if (pos == 1) o.title = s else return null;
            pos += 1;
        }
    }
    if (pos != 2 or o.title.len == 0) return null;
    return o;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    const o = parseArgs(argv[1..]) orelse usage();
    const out = std.io.getStdOut().writer();
    const err = std.io.getStdErr().writer();

    const cache = if (o.cache) cachePath(a, std.fmt.allocPrint(a, "lyrics/{x}", .{songKey(o.artist, o.title)}) catch "") else null;
    if (cache) |p| if (std.fs.cwd().readFileAlloc(a, p, 1 << 20)) |data| {
        if (std.mem.eql(u8, data, NONE_MARK)) std.process.exit(1);
        if (!std.mem.startsWith(u8, data, "#none")) {
            try out.writeAll(data);
            try err.writeAll("ame-lyrics: キャッシュ\n");
            return;
        }
    } else |_| {};

    var ab: [160]u8 = undefined;
    var tb: [160]u8 = undefined;
    const nq = lrc.normalize(o.artist, o.title, &ab, &tb);
    var s = Search{ .a = a, .o = o, .qa = ab[0..nq[0]], .qt = tb[0..nq[1]] };
    const found = s.run();
    if (found) |f| {
        if (cache) |p| writeCache(p, f.text);
        try out.writeAll(f.text);
        try err.print("ame-lyrics: {s}\n", .{f.via});
        return;
    }
    // 一時的な失敗があったときは「無し」と覚えない(次に探し直す)
    if (s.transient) std.process.exit(2);
    if (cache) |p| writeCache(p, NONE_MARK);
    try err.print("ame-lyrics: 見つかりません(検索: {s} / {s})\n", .{ s.qa, s.qt });
    std.process.exit(1);
}

fn writeCache(path: []const u8, data: []const u8) void {
    if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
    const f = std.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    f.writeAll(data) catch {};
}

test "args" {
    const o = parseArgs(&.{ "-d", "213", "--no-kugou", "YOASOBI", "アイドル" }).?;
    try std.testing.expectEqualStrings("アイドル", o.title);
    try std.testing.expect(!o.kugou and o.duration == 213);
    try std.testing.expect(parseArgs(&.{"only-one"}) == null);
    try std.testing.expect(parseArgs(&.{ "-d", "nan", "a", "b" }) == null);
    try std.testing.expect(parseArgs(&.{ "-d", "1e30", "a", "b" }) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a%20b/c", encodePath(arena.allocator(), "/a b/c"));
}
