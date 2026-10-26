// vptr: 試験用の仮想ポインタ(zwlr_virtual_pointer_v1)。ヘッドレス River でホバー等を自動試験するため。
// 使い方: vptr <幅> <高さ> m X Y | s ミリ秒 | c(左クリック)| w 量(縦ホイール) ...
const std = @import("std");
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wlr-virtual-pointer-unstable-v1-client-protocol.h");
});

var mgr: ?*c.struct_zwlr_virtual_pointer_manager_v1 = null;
var seat: ?*c.struct_wl_seat = null;

fn onGlobal(_: ?*anyopaque, reg: ?*c.struct_wl_registry, name: u32, iface: [*c]const u8, _: u32) callconv(.C) void {
    const s = std.mem.sliceTo(iface, 0);
    if (std.mem.eql(u8, s, "zwlr_virtual_pointer_manager_v1")) mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.zwlr_virtual_pointer_manager_v1_interface, 1));
    if (std.mem.eql(u8, s, "wl_seat") and seat == null) seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, 1));
}
fn onRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.C) void {}
const listener = c.struct_wl_registry_listener{ .global = onGlobal, .global_remove = onRemove };

pub fn main() !u8 {
    var args = std.process.args();
    _ = args.next();
    const w = try std.fmt.parseInt(u32, args.next() orelse return 2, 10);
    const h = try std.fmt.parseInt(u32, args.next() orelse return 2, 10);
    const dpy = c.wl_display_connect(null) orelse return 1;
    const reg = c.wl_display_get_registry(dpy);
    _ = c.wl_registry_add_listener(reg, &listener, null);
    _ = c.wl_display_roundtrip(dpy);
    const ptr = c.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr orelse return 1, seat) orelse return 1;
    var t: u32 = 1;
    while (args.next()) |cmd| {
        t += 16;
        if (std.mem.eql(u8, cmd, "m")) {
            const x = try std.fmt.parseInt(u32, args.next() orelse break, 10);
            const y = try std.fmt.parseInt(u32, args.next() orelse break, 10);
            c.zwlr_virtual_pointer_v1_motion_absolute(ptr, t, x, y, w, h);
            c.zwlr_virtual_pointer_v1_frame(ptr);
        } else if (std.mem.eql(u8, cmd, "s")) {
            const ms = try std.fmt.parseInt(u64, args.next() orelse break, 10);
            _ = c.wl_display_roundtrip(dpy);
            std.time.sleep(ms * std.time.ns_per_ms);
            continue;
        } else if (std.mem.eql(u8, cmd, "c")) {
            c.zwlr_virtual_pointer_v1_button(ptr, t, 0x110, 1);
            c.zwlr_virtual_pointer_v1_frame(ptr);
            c.zwlr_virtual_pointer_v1_button(ptr, t + 5, 0x110, 0);
            c.zwlr_virtual_pointer_v1_frame(ptr);
        } else if (std.mem.eql(u8, cmd, "w")) {
            const v = try std.fmt.parseFloat(f64, args.next() orelse break);
            c.zwlr_virtual_pointer_v1_axis(ptr, t, 0, c.wl_fixed_from_double(v));
            c.zwlr_virtual_pointer_v1_frame(ptr);
        }
        _ = c.wl_display_roundtrip(dpy);
    }
    _ = c.wl_display_roundtrip(dpy);
    return 0;
}
