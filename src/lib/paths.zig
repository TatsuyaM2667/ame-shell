// ame-shell の置き場所(設定と状態)。ame-shell・小さな道具・部品が同じものを使う(場所の決め方を 1 か所に)。
//   設定: $XDG_CONFIG_HOME/ame-shell(無い・空なら ~/.config/ame-shell)
//   状態: $XDG_STATE_HOME/ame-shell(無い・空なら ~/.local/state/ame-shell)。壁紙・明るさ・音量など、覚えておく値
const std = @import("std");

pub fn configDir(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell", .{x}) catch null;
    const h = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/ame-shell", .{h}) catch null;
}

pub fn stateDir(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |x| if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell", .{x}) catch null;
    const h = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/ame-shell", .{h}) catch null;
}

/// 状態のフォルダの中のファイル(例: stateFile(&buf, "wallpaper"))
pub fn stateFile(buf: []u8, name: []const u8) ?[]const u8 {
    var d: [400]u8 = undefined;
    const dir = stateDir(&d) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch null;
}

test "状態のファイル" {
    var b: [512]u8 = undefined;
    const p = stateFile(&b, "light") orelse return;
    try std.testing.expect(std.mem.endsWith(u8, p, "/ame-shell/light"));
}
