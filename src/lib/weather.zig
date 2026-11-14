// 天気(wttr.in)の問い合わせ先の組み立てと、返事の読み方。ame-weather コマンドとダッシュボードが使う。
// 返事の形は format=%t|%C|%x|%l(気温|天気|天気記号|場所)の 1 行。
const std = @import("std");

pub const Report = struct {
    /// "12°C"(先頭の + は取る)
    temp: []const u8,
    /// "晴れ" など(lang の言葉)
    condition: []const u8,
    /// wttr.in の天気記号(o 晴れ・m 晴れ時々曇り・mm 曇り・/ 雨・* 雪・! 雷・= 霧 など)
    symbol: []const u8,
    place: []const u8,
};

/// 問い合わせの URL。場所の URL に入れられない文字は落とし、空白は +(wttr.in の書式)。空なら IP アドレスから推定
pub fn url(location: []const u8, lang: []const u8, buf: []u8) ?[:0]const u8 {
    var lb: [96]u8 = undefined;
    var ln: usize = 0;
    for (location) |ch| {
        if (ln >= lb.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == ',' or ch >= 0x80) {
            lb[ln] = ch;
            ln += 1;
        } else if (ch == ' ') {
            lb[ln] = '+';
            ln += 1;
        }
    }
    var gb: [8]u8 = undefined;
    var gn: usize = 0;
    for (lang) |ch| if (std.ascii.isAlphabetic(ch) and gn < gb.len) {
        gb[gn] = ch;
        gn += 1;
    };
    return std.fmt.bufPrintZ(buf, "https://wttr.in/{s}?format=%t|%C|%x|%l&lang={s}", .{ lb[0..ln], gb[0..gn] }) catch null;
}

/// 返事を読む。場所が分からない・形が違うときは null(文字列は body を指す)
pub fn parse(body: []const u8) ?Report {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, body, " \r\n"), '|');
    const t = it.next() orelse return null;
    const cond = it.next() orelse return null;
    const r = Report{
        .temp = std.mem.trimLeft(u8, std.mem.trim(u8, t, " "), "+"),
        .condition = std.mem.trim(u8, cond, " "),
        .symbol = std.mem.trim(u8, it.next() orelse "", " "),
        .place = std.mem.trim(u8, it.next() orelse "", " "),
    };
    if (r.temp.len == 0 or std.mem.indexOf(u8, body, "Unknown") != null) return null;
    return r;
}

/// 天気記号 → Nerd Font のアイコン(夜は月のもの)
pub fn icon(symbol: []const u8, night: bool) []const u8 {
    const s = symbol;
    const eq = std.mem.eql;
    const has = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.indexOf(u8, x, y) != null;
        }
    }.f;
    if (eq(u8, s, "o")) return if (night) "\u{F0594}" else "\u{F0599}"; // 晴れ
    if (eq(u8, s, "m")) return if (night) "\u{F0F31}" else "\u{F0595}"; // 晴れ時々曇り
    if (eq(u8, s, "mm") or eq(u8, s, "mmm")) return "\u{F0590}"; // 曇り
    if (eq(u8, s, "=")) return "\u{F0591}"; // 霧
    if (has(s, "!")) return "\u{F0593}"; // 雷
    if (has(s, "*")) return "\u{F0598}"; // 雪
    if (has(s, "/") or has(s, ".")) return "\u{F0597}"; // 雨
    return "\u{F0590}";
}

test "weather url and parse" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://wttr.in/New+York?format=%t|%C|%x|%l&lang=ja", url("New York;&", "ja", &b).?);
    try std.testing.expectEqualStrings("https://wttr.in/?format=%t|%C|%x|%l&lang=en", url("", "en", &b).?);
    const r = parse("+12°C|晴れ|o|Sapporo, Japan\n").?;
    try std.testing.expectEqualStrings("12°C", r.temp);
    try std.testing.expectEqualStrings("晴れ", r.condition);
    try std.testing.expectEqualStrings("o", r.symbol);
    try std.testing.expectEqualStrings("Sapporo, Japan", r.place);
    try std.testing.expect(parse("Unknown location; please try ~45.7,12.3") == null);
    try std.testing.expect(parse("") == null);
    try std.testing.expectEqualStrings("\u{F0597}", icon("/", false));
    try std.testing.expectEqualStrings("\u{F0594}", icon("o", true));
}
