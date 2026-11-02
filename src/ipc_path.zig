// ソケットパスの決定(ame-shell と ame-ctl で共有。libc 以外に依存しない)。
const std = @import("std");

/// $XDG_RUNTIME_DIR/ame-shell-<WAYLAND_DISPLAY の basename>.sock
pub fn socketPath(buf: []u8) ?[:0]const u8 {
    const rt = std.posix.getenv("XDG_RUNTIME_DIR") orelse return null;
    const wd = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";
    return std.fmt.bufPrintZ(buf, "{s}/ame-shell-{s}.sock", .{ rt, std.fs.path.basename(wd) }) catch null;
}

/// UNIX ドメインソケットのアドレス(std.posix の型で作る)。
/// glibc は _GNU_SOURCE のとき bind / connect の sockaddr 引数を transparent union で宣言するので、
/// C の bind / connect に @ptrCast で渡せない。std.posix.bind / connect を使えば glibc・musl・FreeBSD で同じに書ける。
/// パスが長すぎれば null
pub fn unixAddr(path: []const u8) ?std.posix.sockaddr.un {
    var addr: std.posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}
