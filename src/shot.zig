// スクリーンショット(grim / slurp / wl-copy)。キー(WM の Print)・サイドバーのボタン・ame-ctl screenshot から。
// 撮る前にコマンドがあるかを確かめ、無ければ通知で何を入れればよいかを知らせる。
// 保存先は ~/Pictures/Screenshots(無ければ作る)。保存したものはクリップボードにも入れる。
const std = @import("std");
const sys = @import("platform/sys.zig");
const deps = @import("deps.zig");
const App = @import("app.zig").App;

pub const Kind = enum {
    /// 範囲を選んで保存 + コピー
    region,
    /// 画面全体を保存 + コピー
    full,
    /// 画面全体をコピーだけ
    clip,

    pub fn parse(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }
};

/// delay_ms: パネルを閉じるアニメーションが写らないよう少し待つ(0 なら待たない)
pub fn take(app: *App, kind: Kind, delay_ms: u32) void {
    const need: []const []const u8 = switch (kind) {
        .region => &.{ "grim", "slurp", "wl-copy" },
        .full, .clip => &.{ "grim", "wl-copy" },
    };
    if (!deps.require(app, "スクリーンショットを撮れません", need)) return;

    var dir_buf: [512]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse return;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/Pictures/Screenshots", .{home}) catch return;
    if (kind != .clip) std.fs.cwd().makePath(dir) catch |e| {
        var b: [640]u8 = undefined;
        const msg = std.fmt.bufPrint(&b, "{s} を作れません({s})", .{ dir, @errorName(e) }) catch "保存先を作れません";
        std.log.warn("screenshot: {s}", .{msg});
        app.notifs.post("ame-shell", "スクリーンショットを撮れません", msg, 0);
        return;
    };

    // 時刻のファイル名はシェルの date で(撮った瞬間の時刻にするため)。パスはシェルの引用符で囲む
    var cmd_buf: [1024]u8 = undefined;
    var delay_buf: [32]u8 = undefined;
    const delay = if (delay_ms > 0) std.fmt.bufPrint(&delay_buf, "sleep {d}.{d:0>3}; ", .{ delay_ms / 1000, delay_ms % 1000 }) catch "" else "";
    const file = "\"$D/shot_$(date +%Y%m%d_%H%M%S).png\"";
    const cmd = switch (kind) {
        .region => std.fmt.bufPrintZ(&cmd_buf, "{s}D='{s}'; G=$(slurp) || exit 0; F={s}; grim -g \"$G\" \"$F\" && wl-copy < \"$F\"", .{ delay, dir, file }),
        .full => std.fmt.bufPrintZ(&cmd_buf, "{s}D='{s}'; F={s}; grim \"$F\" && wl-copy < \"$F\"", .{ delay, dir, file }),
        .clip => std.fmt.bufPrintZ(&cmd_buf, "{s}grim - | wl-copy", .{delay}),
    } catch return;
    sys.spawnDetached(cmd.ptr);
}
