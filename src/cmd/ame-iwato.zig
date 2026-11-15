// ame-iwato: 画面をロックする小さな道具(swaylock の代わり)。
// 名前は天照大神がこもって世界を閉ざした天岩戸(あまのいわと)から。
//
//   ame-iwato        ロックし、正しいパスワードが入るまで戻らない
//   ame-iwato -f     ロックできたら裏に回り、すぐ戻る(放置で自動ロックする道具から呼ぶとき)
//
// ame-shell の中のロック画面(顔認証・曲のカードつき)とは別の、どのコンポジタでも動く単体のもの。
// ame-shell が落ちてロックが残ったときに外す道具にもなる(別の端末から WAYLAND_DISPLAY を合わせて実行)。
// 画面: 雨の夜の色の上に、入力の輪(打った数だけ点・確かめ中は橙・違ったら赤)。文字は使わない。
// 照合: PAM(サービス ame-shell、無ければ swaylock)を子プロセスで。FreeBSD は root の setuid の ame-auth に頼む。
// 終了コード: 0 外した / 1 ロックできない(コンポジタが対応していない・ほかのロックが動いている・照合の準備ができない)
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("ext-session-lock-v1-client-protocol.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;

fn die(comptime msg: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("ame-iwato: " ++ msg ++ "\n", args) catch {};
    std.process.exit(1);
}

// ---------------- 照合(PAM / FreeBSD の ame-auth。ame-shell の中のロック画面と共有: pam.zig) ----------------

const pam = @import("pam.zig");

// 打っているパスワード
var pw: [256]u8 = undefined;
var pw_len: usize = 0;

// ---------------- 画面 ----------------

const State = enum { idle, typing, checking, wrong };
var state: State = .idle;

const View = struct {
    out: *c.struct_wl_output,
    surf: ?*c.struct_wl_surface = null,
    lsurf: ?*c.struct_ext_session_lock_surface_v1 = null,
    w: u32 = 0,
    h: u32 = 0,
};
var views: [8]View = undefined;
var n_views: usize = 0;
var compositor: ?*c.struct_wl_compositor = null;
var shm: ?*c.struct_wl_shm = null;
var seat: ?*c.struct_wl_seat = null;
var lock_mgr: ?*c.struct_ext_session_lock_manager_v1 = null;
var lock: ?*c.struct_ext_session_lock_v1 = null;
var locked = false;
var finished = false;

/// 1 画素(XRGB8888)
fn rgb(r: f32, g: f32, b: f32) u32 {
    const R: u32 = @intFromFloat(std.math.clamp(r, 0, 1) * 255);
    const G: u32 = @intFromFloat(std.math.clamp(g, 0, 1) * 255);
    const B: u32 = @intFromFloat(std.math.clamp(b, 0, 1) * 255);
    return 0xff000000 | (R << 16) | (G << 8) | B;
}

/// 輪の色(状態で変える。色だけに頼らないよう、確かめ中は輪を切り、違ったときは点を消す)
fn ringColor() [3]f32 {
    return switch (state) {
        .idle, .typing => .{ 0.48, 0.72, 1.0 },
        .checking => .{ 1.0, 0.70, 0.36 },
        .wrong => .{ 1.0, 0.36, 0.40 },
    };
}

/// 背景(雨の夜: 上は深い藍、下は少し明るい)と、真ん中の入力の輪・打った数の点
fn paint(px: []u32, w: u32, h: u32) void {
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const cx = fw / 2;
    const cy = fh / 2;
    const r: f32 = @min(fw, fh) * 0.09;
    const thick: f32 = @max(3, r * 0.08);
    const col = ringColor();
    const n_dots: usize = @min(pw_len, 24);
    for (0..h) |y| {
        const fy: f32 = @floatFromInt(y);
        const t = fy / fh;
        const bg = [3]f32{ 0.03 + 0.03 * t, 0.06 + 0.05 * t, 0.12 + 0.08 * t };
        const row = px[y * w ..][0..w];
        const dy = fy + 0.5 - cy;
        // 輪の辺りの行だけ、輪と点を計算する
        if (@abs(dy) > r + thick * 2) {
            @memset(row, rgb(bg[0], bg[1], bg[2]));
            continue;
        }
        for (0..w) |x| {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const d = @sqrt(dx * dx + dy * dy);
            var a: f32 = 0;
            // 輪(確かめ中は 12 か所を切って回っているように見せる)
            const ring = std.math.clamp(thick / 2 + 0.5 - @abs(d - r), 0, 1);
            if (state == .checking) {
                const ang = std.math.atan2(dy, dx);
                if (@mod(ang * 6 / std.math.pi, 1) < 0.25) a = 0 else a = ring;
            } else a = ring;
            // 打った数だけ、輪の内側に点を並べる(違ったときは点を消す)
            if (state != .wrong and n_dots > 0) {
                const dot_r = r * 0.08;
                for (0..n_dots) |i| {
                    const ang = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * (2 * std.math.pi / 24.0);
                    const ddx = dx - @cos(ang) * r * 0.72;
                    const ddy = dy - @sin(ang) * r * 0.72;
                    a = @max(a, std.math.clamp(dot_r + 0.5 - @sqrt(ddx * ddx + ddy * ddy), 0, 1));
                }
            }
            row[x] = rgb(bg[0] + (col[0] - bg[0]) * a, bg[1] + (col[1] - bg[1]) * a, bg[2] + (col[2] - bg[2]) * a);
        }
    }
}

fn bufRelease(_: ?*anyopaque, b: ?*c.struct_wl_buffer) callconv(.C) void {
    c.wl_buffer_destroy(b);
}
const buffer_listener = c.struct_wl_buffer_listener{ .release = bufRelease };

fn draw(v: *View) void {
    if (v.w == 0 or v.h == 0) return;
    const size: usize = @as(usize, v.w) * v.h * 4;
    const fd = memfd_create("ame-iwato", 1);
    if (fd < 0) return;
    defer std.posix.close(fd);
    std.posix.ftruncate(fd, size) catch return;
    const map = std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0) catch return;
    defer std.posix.munmap(map);
    paint(@as([*]u32, @ptrCast(map.ptr))[0 .. size / 4], v.w, v.h);
    const pool = c.wl_shm_create_pool(shm, fd, @intCast(size));
    const buf = c.wl_shm_pool_create_buffer(pool, 0, @intCast(v.w), @intCast(v.h), @intCast(v.w * 4), c.WL_SHM_FORMAT_XRGB8888);
    c.wl_shm_pool_destroy(pool);
    _ = c.wl_buffer_add_listener(buf, &buffer_listener, null);
    c.wl_surface_attach(v.surf, buf, 0, 0);
    c.wl_surface_damage_buffer(v.surf, 0, 0, @intCast(v.w), @intCast(v.h));
    c.wl_surface_commit(v.surf);
}

fn redrawAll() void {
    for (views[0..n_views]) |*v| draw(v);
}

fn lsConfigure(data: ?*anyopaque, ls: ?*c.struct_ext_session_lock_surface_v1, serial: u32, w: u32, h: u32) callconv(.C) void {
    const v: *View = @ptrCast(@alignCast(data.?));
    c.ext_session_lock_surface_v1_ack_configure(ls, serial);
    v.w = w;
    v.h = h;
    draw(v);
}
const lsurf_listener = c.struct_ext_session_lock_surface_v1_listener{ .configure = lsConfigure };

fn onLocked(_: ?*anyopaque, _: ?*c.struct_ext_session_lock_v1) callconv(.C) void {
    locked = true;
}
fn onFinished(_: ?*anyopaque, _: ?*c.struct_ext_session_lock_v1) callconv(.C) void {
    finished = true;
}
const lock_listener = c.struct_ext_session_lock_v1_listener{ .locked = onLocked, .finished = onFinished };

// ---------------- キーボード ----------------

var xkb_ctx: ?*c.struct_xkb_context = null;
var xkb_state: ?*c.struct_xkb_state = null;
var submit = false;

fn kbKeymap(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, fmt: u32, fd: i32, size: u32) callconv(.C) void {
    defer std.posix.close(fd);
    if (fmt != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
    const map = std.posix.mmap(null, size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
    defer std.posix.munmap(map);
    const km = c.xkb_keymap_new_from_string(xkb_ctx, @ptrCast(map.ptr), c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
    defer c.xkb_keymap_unref(km);
    if (xkb_state) |s| c.xkb_state_unref(s);
    xkb_state = c.xkb_state_new(km);
}
fn kbEnter(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface, _: ?*c.struct_wl_array) callconv(.C) void {}
fn kbLeave(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface) callconv(.C) void {}
fn kbModifiers(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, dep: u32, lat: u32, lk: u32, group: u32) callconv(.C) void {
    if (xkb_state) |s| _ = c.xkb_state_update_mask(s, dep, lat, lk, 0, 0, group);
}
fn kbRepeat(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: i32, _: i32) callconv(.C) void {}

/// UTF-8 の最後の 1 文字の長さ
fn lastCharLen(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len) {
        n += 1;
        if (s[s.len - n] & 0xC0 != 0x80) break;
    }
    return n;
}

fn kbKey(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: u32, key: u32, st: u32) callconv(.C) void {
    if (st != c.WL_KEYBOARD_KEY_STATE_PRESSED or state == .checking) return;
    const s = xkb_state orelse return;
    const code = key + 8;
    const sym = c.xkb_state_key_get_one_sym(s, code);
    const ctrl = c.xkb_state_mod_name_is_active(s, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) > 0;
    switch (sym) {
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
            if (pw_len > 0) submit = true;
            return;
        },
        c.XKB_KEY_BackSpace => pw_len -= lastCharLen(pw[0..pw_len]),
        c.XKB_KEY_Escape => pw_len = 0,
        else => {
            if (ctrl and (sym == c.XKB_KEY_u or sym == c.XKB_KEY_U)) {
                pw_len = 0;
            } else {
                var b: [16]u8 = undefined;
                const n: usize = @intCast(@max(0, c.xkb_state_key_get_utf8(s, code, &b, b.len)));
                if (n == 0 or b[0] < 0x20 or pw_len + n >= pw.len) return;
                @memcpy(pw[pw_len..][0..n], b[0..n]);
                pw_len += n;
            }
        },
    }
    state = if (pw_len > 0) .typing else .idle;
    redrawAll();
}
const kb_listener = c.struct_wl_keyboard_listener{ .keymap = kbKeymap, .enter = kbEnter, .leave = kbLeave, .key = kbKey, .modifiers = kbModifiers, .repeat_info = kbRepeat };

fn seatCaps(_: ?*anyopaque, s: ?*c.struct_wl_seat, caps: u32) callconv(.C) void {
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0) {
        const kb = c.wl_seat_get_keyboard(s);
        _ = c.wl_keyboard_add_listener(kb, &kb_listener, null);
    }
}
fn seatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.C) void {}
const seat_listener = c.struct_wl_seat_listener{ .capabilities = seatCaps, .name = seatName };

fn onGlobal(_: ?*anyopaque, reg: ?*c.struct_wl_registry, id: u32, iface: [*c]const u8, ver: u32) callconv(.C) void {
    const s = std.mem.sliceTo(iface, 0);
    const eq = std.mem.eql;
    if (eq(u8, s, "wl_compositor")) compositor = @ptrCast(c.wl_registry_bind(reg, id, &c.wl_compositor_interface, @min(ver, 4)));
    if (eq(u8, s, "wl_shm")) shm = @ptrCast(c.wl_registry_bind(reg, id, &c.wl_shm_interface, 1));
    if (eq(u8, s, "ext_session_lock_manager_v1")) lock_mgr = @ptrCast(c.wl_registry_bind(reg, id, &c.ext_session_lock_manager_v1_interface, 1));
    if (eq(u8, s, "wl_seat") and seat == null) {
        seat = @ptrCast(c.wl_registry_bind(reg, id, &c.wl_seat_interface, @min(ver, 5)));
        _ = c.wl_seat_add_listener(seat, &seat_listener, null);
    }
    if (eq(u8, s, "wl_output") and n_views < views.len) {
        views[n_views] = .{ .out = @ptrCast(c.wl_registry_bind(reg, id, &c.wl_output_interface, 1)) };
        n_views += 1;
    }
}
fn onRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.C) void {}
const reg_listener = c.struct_wl_registry_listener{ .global = onGlobal, .global_remove = onRemove };

pub fn main() u8 {
    var daemonize = false;
    var it = std.process.args();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "-f")) daemonize = true else {
            std.io.getStdErr().writeAll("使い方: ame-iwato [-f]\n") catch {};
            return 2;
        }
    }
    // 照合できない構成ならロックしない(閉じ込め防止)
    const auth = switch (pam.prepare()) {
        .ok => |a| a,
        .err => |why| die("{s}", .{why}),
    };
    xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse die("xkbcommon を使えません", .{});
    const dpy = c.wl_display_connect(null) orelse die("画面(Wayland)につながりません", .{});
    const reg = c.wl_display_get_registry(dpy);
    _ = c.wl_registry_add_listener(reg, &reg_listener, null);
    _ = c.wl_display_roundtrip(dpy);
    if (compositor == null or shm == null or lock_mgr == null) die("このコンポジタは画面のロック(ext-session-lock-v1)に対応していません", .{});
    if (n_views == 0) die("画面がありません", .{});

    lock = c.ext_session_lock_manager_v1_lock(lock_mgr);
    _ = c.ext_session_lock_v1_add_listener(lock, &lock_listener, null);
    for (views[0..n_views]) |*v| {
        v.surf = c.wl_compositor_create_surface(compositor);
        v.lsurf = c.ext_session_lock_v1_get_lock_surface(lock, v.surf, v.out);
        _ = c.ext_session_lock_surface_v1_add_listener(v.lsurf, &lsurf_listener, v);
    }
    while (!locked and !finished) if (c.wl_display_dispatch(dpy) < 0) die("画面とのつながりが切れました", .{});
    if (finished) die("ロックできません(ほかのロックが動いているか、コンポジタが断りました)", .{});
    if (daemonize) {
        // 呼んだ側にはロックできたことだけ伝えて戻る
        const pid = std.posix.fork() catch die("裏に回れません", .{});
        if (pid != 0) std.process.exit(0);
        _ = c.setsid();
        // 呼んだ側の標準入出力を手放す(持ったままだと、出力を待つ呼び出し元が戻らない)
        const nul = std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch -1;
        if (nul >= 0) for ([_]i32{ 0, 1, 2 }) |t| std.posix.dup2(nul, t) catch {};
    }

    const fd = c.wl_display_get_fd(dpy);
    var auth_fd: c_int = -1;
    while (!finished) {
        _ = c.wl_display_flush(dpy);
        var pfd = [_]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = auth_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(pfd[0..if (auth_fd >= 0) 2 else 1], -1) catch continue;
        if (pfd[0].revents != 0 and c.wl_display_dispatch(dpy) < 0) die("画面とのつながりが切れました(ロックは残ります。もう一度 ame-iwato を)", .{});
        if (submit and auth_fd < 0) {
            submit = false;
            var p: [2]c_int = undefined;
            if (c.pipe(&p) != 0) continue;
            const pid = c.fork();
            if (pid == 0) {
                _ = c.close(p[0]);
                const b: u8 = if (pam.check(auth, pw[0..pw_len])) 1 else 0;
                _ = c.write(p[1], &b, 1);
                c._exit(0);
            }
            _ = c.close(p[1]);
            std.crypto.utils.secureZero(u8, &pw); // 親の写しは消す(子は自分のメモリで使い終わる)
            pw_len = 0;
            auth_fd = p[0];
            state = .checking;
            redrawAll();
            continue;
        }
        if (auth_fd >= 0 and pfd[1].revents != 0) {
            var b: u8 = 0;
            const n = c.read(auth_fd, &b, 1);
            _ = c.close(auth_fd);
            auth_fd = -1;
            _ = c.waitpid(-1, null, c.WNOHANG);
            if (n == 1 and b == 1) {
                c.ext_session_lock_v1_unlock_and_destroy(lock);
                _ = c.wl_display_roundtrip(dpy);
                return 0;
            }
            state = .wrong;
            redrawAll();
        }
    }
    die("コンポジタがロックを終えました", .{});
}

test "最後の 1 文字" {
    try std.testing.expectEqual(@as(usize, 1), lastCharLen("ab"));
    try std.testing.expectEqual(@as(usize, 3), lastCharLen("aあ"));
    try std.testing.expectEqual(@as(usize, 0), lastCharLen(""));
}
