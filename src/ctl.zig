// ame-ctl: ame-shell デーモンを操作する小さな CLI(libc だけに依存)。
// 使い方: ame-ctl launcher toggle / ame-ctl volume up / ame-ctl help
//       ame-ctl watch … 出来事(ワークスペース・フォーカス・窓・通知・曲・ロック)を 1 行 1 つの JSON で流し続ける(src/core/events.zig)
// River のキーバインドから `riverctl map normal Super D spawn "ame-ctl launcher toggle"` のように呼ぶ。
const std = @import("std");

const ipc_path = @import("core/ipc_path.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});
pub fn main() !u8 {
    var args = std.process.args();
    _ = args.next();
    var line_buf: [512]u8 = undefined;
    var len: usize = 0;
    while (args.next()) |a| {
        if (len > 0 and len < line_buf.len) {
            line_buf[len] = ' ';
            len += 1;
        }
        const n = @min(a.len, line_buf.len - len);
        @memcpy(line_buf[len .. len + n], a[0..n]);
        len += n;
    }
    if (len == 0) {
        @memcpy(line_buf[0..4], "help");
        len = 4;
    }

    var pbuf: [256]u8 = undefined;
    const path = ipc_path.socketPath(&pbuf) orelse {
        std.debug.print("ame-ctl: XDG_RUNTIME_DIR が未設定です\n", .{});
        return 2;
    };
    const addr = ipc_path.unixAddr(path) orelse {
        std.debug.print("ame-ctl: ソケットのパスが長すぎます ({s})\n", .{path});
        return 2;
    };
    // socket / connect は std.posix で(glibc の transparent union の sockaddr を避ける。ipc_path.zig)
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return 2;
    defer _ = c.close(fd);
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
        std.debug.print("ame-ctl: ame-shell に接続できません ({s})\n", .{path});
        return 1;
    };
    _ = c.write(fd, &line_buf, len);
    _ = c.shutdown(fd, c.SHUT_WR);
    // 届いた分からすぐ出す(ame-ctl watch は切れるまで出来事が流れ続ける)
    var out: [4096]u8 = undefined;
    var total: usize = 0;
    var is_err = false;
    const stdout = std.io.getStdOut();
    while (true) {
        const n = c.read(fd, &out, out.len);
        if (n <= 0) break;
        const chunk = out[0..@intCast(n)];
        if (total == 0) is_err = std.mem.startsWith(u8, chunk, "error");
        total += chunk.len;
        stdout.writeAll(chunk) catch break; // 読む側が閉じた(| head など)
    }
    return if (is_err) 1 else 0;
}
