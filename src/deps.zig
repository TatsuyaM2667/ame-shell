// 外部コマンドが足りないときの案内(スクショの grim / slurp / wl-copy、波形の cava など)。
// 使う直前に PATH を調べ、無ければ「何を入れればよいか」を通知とログで知らせる。
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("platform/sys.zig");
const App = @import("app.zig").App;

/// このシステムでパッケージを入れるコマンド(案内用)
pub fn installCmd() []const u8 {
    if (builtin.os.tag == .freebsd) return "doas pkg install";
    if (sys.hasCommand("apk")) return "doas apk add";
    if (sys.hasCommand("pacman")) return "sudo pacman -S";
    return "パッケージマネージャで";
}

/// コマンドに対応するパッケージ名(ディストリで違うものだけ。ほかはコマンド名と同じ)
pub fn packageFor(cmd: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, cmd, "wl-copy")) return "wl-clipboard";
    if (eq(u8, cmd, "pactl")) {
        if (builtin.os.tag == .freebsd) return "pulseaudio";
        return if (sys.hasCommand("pacman")) "libpulse" else "libpulse-progs";
    }
    if (eq(u8, cmd, "bluetoothctl")) return if (sys.hasCommand("pacman")) "bluez-utils" else "bluez";
    return cmd;
}

/// cmds のうち PATH に無いものを空白区切りで out に書く。全部あれば空
pub fn missing(cmds: []const []const u8, out: []u8) []const u8 {
    var w = std.io.fixedBufferStream(out);
    for (cmds) |cmd| {
        if (sys.hasCommand(cmd)) continue;
        if (w.pos > 0) w.writer().writeByte(' ') catch {};
        w.writer().writeAll(cmd) catch {};
    }
    return out[0..w.pos];
}

/// 足りないコマンドを通知で知らせる(summary: 何ができなかったか)。全部あれば true
pub fn require(app: *App, summary: []const u8, cmds: []const []const u8) bool {
    var mb: [128]u8 = undefined;
    const miss = missing(cmds, &mb);
    if (miss.len == 0) return true;
    var pb: [160]u8 = undefined;
    var pw = std.io.fixedBufferStream(&pb);
    var it = std.mem.tokenizeScalar(u8, miss, ' ');
    while (it.next()) |cmd| {
        const p = packageFor(cmd);
        // 同じパッケージは 1 回だけ
        if (std.mem.indexOf(u8, pb[0..pw.pos], p) != null) continue;
        pw.writer().print(" {s}", .{p}) catch {};
    }
    var body: [384]u8 = undefined;
    const b = std.fmt.bufPrint(&body, "{s} が見つかりません。入れてください: {s}{s}", .{ miss, installCmd(), pb[0..pw.pos] }) catch "必要なコマンドが見つかりません";
    std.log.warn("{s}: {s}", .{ summary, b });
    app.notifs.post("ame-shell", summary, b, 0);
    return false;
}
