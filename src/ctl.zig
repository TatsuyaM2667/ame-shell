// ame-ctl: ame-shell デーモンを操作する小さな CLI(libc だけに依存)。
// 使い方: ame-ctl launcher toggle / ame-ctl volume up / ame-ctl help
// River のキーバインドから `riverctl map normal Super D spawn "ame-ctl launcher toggle"` のように呼ぶ。
const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});
const ipc_path = @import("ipc_path.zig");

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
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return 2;
    defer _ = c.close(fd);
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..path.len], path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
        std.debug.print("ame-ctl: ame-shell に接続できません ({s})\n", .{path});
        return 1;
    }
    _ = c.write(fd, &line_buf, len);
    _ = c.shutdown(fd, c.SHUT_WR);
    var out: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < out.len) {
        const n = c.read(fd, out[total..].ptr, out.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    const reply = out[0..total];
    _ = std.io.getStdOut().write(reply) catch {};
    return if (std.mem.startsWith(u8, reply, "error")) 1 else 0;
}
