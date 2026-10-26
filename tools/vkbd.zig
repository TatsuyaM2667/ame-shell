// vkbd: 試験用の仮想キーボード(zwp_virtual_keyboard_v1)。ヘッドレス River 0.5 で WM のキー操作を自動試験するため。
// 使い方: vkbd Super+Return | Super+Shift+2 | s ミリ秒 ...   (配列は XKB_DEFAULT_LAYOUT、無ければ us)
const std = @import("std");
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("virtual-keyboard-unstable-v1-client-protocol.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

var mgr: ?*c.struct_zwp_virtual_keyboard_manager_v1 = null;
var seat: ?*c.struct_wl_seat = null;

fn onGlobal(_: ?*anyopaque, reg: ?*c.struct_wl_registry, name: u32, iface: [*c]const u8, _: u32) callconv(.C) void {
    const s = std.mem.sliceTo(iface, 0);
    if (std.mem.eql(u8, s, "zwp_virtual_keyboard_manager_v1")) mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.zwp_virtual_keyboard_manager_v1_interface, 1));
    if (std.mem.eql(u8, s, "wl_seat") and seat == null) seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, 1));
}
fn onRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.C) void {}
const listener = c.struct_wl_registry_listener{ .global = onGlobal, .global_remove = onRemove };

/// keysym を出す keycode(レベル 0)を探す
fn findKey(km: *c.struct_xkb_keymap, sym: u32) ?u32 {
    var kc = c.xkb_keymap_min_keycode(km);
    while (kc <= c.xkb_keymap_max_keycode(km)) : (kc += 1) {
        var syms: [*c]const c.xkb_keysym_t = undefined;
        const n = c.xkb_keymap_key_get_syms_by_level(km, kc, 0, 0, &syms);
        var i: c_int = 0;
        while (i < n) : (i += 1) if (syms[@intCast(i)] == sym) return kc;
    }
    return null;
}

const Kb = struct {
    kb: *c.struct_zwp_virtual_keyboard_v1,
    km: *c.struct_xkb_keymap,
    st: *c.struct_xkb_state,
    t: u32 = 1,

    fn key(self: *Kb, kc: u32, down: bool) void {
        self.t += 10;
        c.zwp_virtual_keyboard_v1_key(self.kb, self.t, kc - 8, if (down) 1 else 0);
        _ = c.xkb_state_update_key(self.st, kc, if (down) c.XKB_KEY_DOWN else c.XKB_KEY_UP);
        c.zwp_virtual_keyboard_v1_modifiers(
            self.kb,
            c.xkb_state_serialize_mods(self.st, c.XKB_STATE_MODS_DEPRESSED),
            c.xkb_state_serialize_mods(self.st, c.XKB_STATE_MODS_LATCHED),
            c.xkb_state_serialize_mods(self.st, c.XKB_STATE_MODS_LOCKED),
            c.xkb_state_serialize_layout(self.st, c.XKB_STATE_LAYOUT_EFFECTIVE),
        );
    }
};

pub fn main() !u8 {
    const dpy = c.wl_display_connect(null) orelse return 1;
    const reg = c.wl_display_get_registry(dpy);
    _ = c.wl_registry_add_listener(reg, &listener, null);
    _ = c.wl_display_roundtrip(dpy);

    const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return 1;
    const km = c.xkb_keymap_new_from_names(ctx, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return 1;
    const str = c.xkb_keymap_get_as_string(km, c.XKB_KEYMAP_FORMAT_TEXT_V1) orelse return 1;
    const len = std.mem.len(str) + 1;
    const fd: c_int = @intCast(std.posix.memfd_create("vkbd-keymap", 0) catch return 1);
    _ = c.write(fd, str, len);
    const kb = c.zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(mgr orelse return 1, seat) orelse return 1;
    c.zwp_virtual_keyboard_v1_keymap(kb, c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, @intCast(len));
    _ = c.wl_display_roundtrip(dpy);
    var k = Kb{ .kb = kb, .km = km, .st = c.xkb_state_new(km) orelse return 1 };

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "s")) {
            const ms = try std.fmt.parseInt(u64, args.next() orelse break, 10);
            _ = c.wl_display_roundtrip(dpy);
            std.time.sleep(ms * std.time.ns_per_ms);
            continue;
        }
        // "Super+Shift+2" → 修飾キーを押す → 最後のキーを押して離す → 修飾キーを離す
        var held: [6]u32 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, arg, '+');
        var parts: [8][]const u8 = undefined;
        var np: usize = 0;
        while (it.next()) |p| : (np += 1) parts[np] = p;
        for (parts[0..np], 0..) |p, i| {
            const name: []const u8 = if (i + 1 < np) (if (std.mem.eql(u8, p, "Super")) "Super_L" else if (std.mem.eql(u8, p, "Shift")) "Shift_L" else if (std.mem.eql(u8, p, "Ctrl")) "Control_L" else if (std.mem.eql(u8, p, "Alt")) "Alt_L" else p) else p;
            var buf: [64]u8 = undefined;
            const z = try std.fmt.bufPrintZ(&buf, "{s}", .{name});
            const sym = c.xkb_keysym_from_name(z.ptr, c.XKB_KEYSYM_NO_FLAGS);
            const kc = findKey(km, sym) orelse {
                std.debug.print("vkbd: キーが見つかりません: {s}\n", .{name});
                return 1;
            };
            if (i + 1 < np) {
                k.key(kc, true);
                held[n] = kc;
                n += 1;
            } else {
                k.key(kc, true);
                _ = c.wl_display_roundtrip(dpy);
                k.key(kc, false);
            }
        }
        while (n > 0) {
            n -= 1;
            k.key(held[n], false);
        }
        _ = c.wl_display_roundtrip(dpy);
    }
    _ = c.wl_display_roundtrip(dpy);
    c.zwp_virtual_keyboard_v1_destroy(kb);
    _ = c.wl_display_roundtrip(dpy);
    return 0;
}
