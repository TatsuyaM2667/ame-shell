// 窓の app_id と、通知のアプリ名(app_name / desktop-entry)が同じアプリかを見る。
// 例: "com.discordapp.Discord" と "discord"、"org.mozilla.firefox" と "Firefox"、"vesktop.desktop" と "Vesktop"
const std = @import("std");

/// 比べる形に: 小文字・".desktop" を除く・逆ドメイン名なら最後の部分
fn key(s: []const u8, buf: []u8) []const u8 {
    var t = std.mem.trim(u8, s, " ");
    if (std.ascii.endsWithIgnoreCase(t, ".desktop")) t = t[0 .. t.len - 8];
    if (std.mem.lastIndexOfScalar(u8, t, '.')) |i| t = t[i + 1 ..];
    const n = @min(t.len, buf.len);
    return std.ascii.lowerString(buf[0..n], t[0..n]);
}

/// 同じアプリか(どちらかが空なら false)
pub fn matches(app_id: []const u8, name: []const u8) bool {
    var ab: [96]u8 = undefined;
    var nb: [96]u8 = undefined;
    const a = key(app_id, &ab);
    const n = key(name, &nb);
    if (a.len == 0 or n.len == 0) return false;
    if (std.mem.eql(u8, a, n)) return true;
    // "google-chrome" と "chrome"、"code-oss" と "code" のような片方を含むもの(短すぎる名前は誤りやすいので 4 文字以上)
    return @min(a.len, n.len) >= 4 and (std.mem.indexOf(u8, a, n) != null or std.mem.indexOf(u8, n, a) != null);
}

test "app id matching" {
    try std.testing.expect(matches("com.discordapp.Discord", "discord"));
    try std.testing.expect(matches("discord", "Discord"));
    try std.testing.expect(matches("org.mozilla.firefox", "Firefox"));
    try std.testing.expect(matches("vesktop", "vesktop.desktop"));
    try std.testing.expect(matches("google-chrome", "Chrome"));
    try std.testing.expect(!matches("vim", "nvim"));
    try std.testing.expect(!matches("kitty", ""));
    try std.testing.expect(!matches("org.gnome.Nautilus", "Thunderbird"));
}
