// LRC(同期歌詞)の部品: 解析・再生位置での今の行・曲名の整え方。画面にもネットにも依存しない
// (ame-shell の歌詞の表示と、歌詞を探すコマンド ame-lyrics の両方が使う)
const std = @import("std");

pub const Line = struct { t: f32, text: []const u8 };

pub const Kind = enum { synced, plain, none };

/// LRC を解析して lines に入れる。"[mm:ss.xx]歌詞"(1 行に複数のタイムスタンプも可)。
/// タイムスタンプが無ければ plain(t = -1)。text は data を指すので、data は lines を使う間とっておく
pub fn parse(data: []const u8, lines: *std.ArrayList(Line)) Kind {
    lines.clearRetainingCapacity();
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
            for (times[0..nt]) |t| lines.append(.{ .t = t, .text = text }) catch {};
        } else if (!synced and text.len > 0) {
            lines.append(.{ .t = -1, .text = text }) catch {};
        }
    }
    if (!synced) return if (lines.items.len > 0) .plain else .none;
    // タイムスタンプの無い行(plain の残り)を除き、時刻順に並べる
    var i: usize = 0;
    while (i < lines.items.len) {
        if (lines.items[i].t < 0) _ = lines.orderedRemove(i) else i += 1;
    }
    std.mem.sort(Line, lines.items, {}, struct {
        fn lt(_: void, x: Line, y: Line) bool {
            return x.t < y.t;
        }
    }.lt);
    return .synced;
}

/// 再生位置 pos(秒)での今の行と、その行の進み具合(0..1、次の行までの割合)
pub fn current(lines: []const Line, pos: f32) struct { idx: ?usize, frac: f32 } {
    var idx: ?usize = null;
    for (lines, 0..) |l, i| {
        if (l.t <= pos) idx = i else break;
    }
    const i = idx orelse return .{ .idx = null, .frac = 0 };
    const next_t = if (i + 1 < lines.len) lines[i + 1].t else lines[i].t + 5;
    const span = @max(next_t - lines[i].t, 0.1);
    return .{ .idx = i, .frac = std.math.clamp((pos - lines[i].t) / span, 0, 1) };
}

/// 動画サイトのタイトルにありがちな飾り("【MV】"、"(Official Video)" など)を除いて検索精度を上げる
pub fn cleanTitle(t: []const u8) []const u8 {
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

pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

/// "[mm:ss.xx]" のタイムスタンプがある(同期歌詞)か
pub fn hasTimestamps(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimLeft(u8, raw, " \t");
        if (l.len >= 4 and l[0] == '[' and std.ascii.isDigit(l[1])) return true;
    }
    return false;
}

/// 歌詞の頭に付くクレジットの行(「作词 : …」「作曲 : …」)
pub fn isCredit(text: []const u8) bool {
    const heads = [_][]const u8{ "作词", "作詞", "作曲", "词", "曲", "词曲", "编曲", "編曲", "制作", "混音", "母带", "和声", "吉他", "贝斯", "鼓", "录音", "监制", "出品", "OP", "SP" };
    const colon = std.mem.indexOf(u8, text, ":") orelse std.mem.indexOf(u8, text, "：") orelse return false;
    const head = std.mem.trim(u8, text[0..colon], " ");
    if (head.len == 0 or head.len > 24) return false;
    for (heads) |h| if (std.mem.startsWith(u8, head, h)) return true;
    return false;
}

test "parse and current" {
    var lines = std.ArrayList(Line).init(std.testing.allocator);
    defer lines.deinit();
    try std.testing.expectEqual(Kind.synced, parse("[ar:x]\n[00:02.00]b\n[00:01.00][00:03.00]a\n[00:00.50]作词 : 誰か\n", &lines));
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("a", lines.items[0].text);
    const c = current(lines.items, 2.5);
    try std.testing.expectEqual(@as(?usize, 1), c.idx);
    try std.testing.expectEqual(Kind.plain, parse("just\ntext\n", &lines));
    try std.testing.expectEqual(Kind.none, parse("\n", &lines));
}
