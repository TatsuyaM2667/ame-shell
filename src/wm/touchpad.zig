// タッチパッドの設定(River 0.5 の river_libinput_config_v1)。
// libinput の既定では「タップでクリック」が無効なので、対応する機器ではタップを有効にする(設定 tap-to-click)。
// 機器のイベントは種類が多く、使うのは tap_support と removed だけなので、リスナーではなく
// wl_proxy_add_dispatcher で受けてイベント名で振り分ける(未使用のイベントは無視)。
const std = @import("std");
const c = @import("../c.zig");

const Touchpad = @This();

cfg: *c.struct_river_libinput_config_v1,
tap: bool,

pub fn create(alloc: std.mem.Allocator, cfg: *c.struct_river_libinput_config_v1, tap: bool) !*Touchpad {
    const self = try alloc.create(Touchpad);
    self.* = .{ .cfg = cfg, .tap = tap };
    _ = c.wl_proxy_add_dispatcher(@ptrCast(cfg), dispatchConfig, null, self);
    return self;
}

fn msgName(msg: [*c]const c.struct_wl_message) []const u8 {
    return std.mem.span(msg.*.name);
}

fn dispatchConfig(_: ?*const anyopaque, proxy: ?*anyopaque, _: u32, msg: [*c]const c.struct_wl_message, args: [*c]c.union_wl_argument) callconv(.C) c_int {
    const self: *Touchpad = @ptrCast(@alignCast(c.wl_proxy_get_user_data(@ptrCast(proxy))));
    if (std.mem.eql(u8, msgName(msg), "libinput_device")) {
        const dev: ?*c.struct_wl_proxy = @ptrCast(args[0].o);
        if (dev) |d| _ = c.wl_proxy_add_dispatcher(d, dispatchDevice, null, self);
    }
    return 0;
}

fn dispatchDevice(_: ?*const anyopaque, proxy: ?*anyopaque, _: u32, msg: [*c]const c.struct_wl_message, args: [*c]c.union_wl_argument) callconv(.C) c_int {
    const self: *Touchpad = @ptrCast(@alignCast(c.wl_proxy_get_user_data(@ptrCast(proxy))));
    const dev: *c.struct_river_libinput_device_v1 = @ptrCast(proxy);
    const name = msgName(msg);
    if (std.mem.eql(u8, name, "tap_support")) {
        // 指の数が 0 = タップ非対応(マウスなど)
        if (args[0].i > 0) {
            const state: u32 = if (self.tap) c.RIVER_LIBINPUT_DEVICE_V1_TAP_STATE_ENABLED else c.RIVER_LIBINPUT_DEVICE_V1_TAP_STATE_DISABLED;
            if (c.river_libinput_device_v1_set_tap(dev, state)) |res| {
                _ = c.wl_proxy_add_dispatcher(@ptrCast(res), dispatchResult, null, null);
            }
            std.log.info("wm: タッチパッドのタップでクリック: {s} / tap-to-click {s}", .{ if (self.tap) "有効" else "無効", if (self.tap) "on" else "off" });
        }
    } else if (std.mem.eql(u8, name, "removed")) {
        c.river_libinput_device_v1_destroy(dev);
    }
    return 0;
}

// 結果(success / unsupported / invalid)はどれもデストラクタのイベント。受けたら片付けるだけ
fn dispatchResult(_: ?*const anyopaque, proxy: ?*anyopaque, _: u32, _: [*c]const c.struct_wl_message, _: [*c]c.union_wl_argument) callconv(.C) c_int {
    c.wl_proxy_destroy(@ptrCast(proxy));
    return 0;
}
