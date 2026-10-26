// ソケットパスの決定(ame-shell と ame-ctl で共有。libc 以外に依存しない)。
const std = @import("std");

/// $XDG_RUNTIME_DIR/ame-shell-<WAYLAND_DISPLAY の basename>.sock
pub fn socketPath(buf: []u8) ?[:0]const u8 {
    const rt = std.posix.getenv("XDG_RUNTIME_DIR") orelse return null;
    const wd = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";
    return std.fmt.bufPrintZ(buf, "{s}/ame-shell-{s}.sock", .{ rt, std.fs.path.basename(wd) }) catch null;
}
