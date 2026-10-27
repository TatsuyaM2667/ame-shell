// Super キー単体の「タップ」でランチャーを開く。
//
// River 0.3 のキーマップは、修飾キー単体の押下と組み合わせ(Super+1 など)を区別できない
// (-release マッピングは組み合わせの後でも発火する)。そこで evdev(/dev/input/event*)から
// キー入力を「読むだけ」で監視し、
//     Super を押す → 他のキー・マウスボタンを一切押さずに → 600ms 以内に離す
// ときだけ発火させる。デバイスを grab しないので River や他のアプリの入力には影響しない。
// 読むのは押下/解放のキーコードだけで、どこにも保存しない。
//
// 必要: ユーザーが input グループに属していること(Chimera では /dev/input/event* が root:input 0660)。
// 読めない環境ではこの機能だけ無効になる(Super+D 等のキーバインドは引き続き使える)。
const std = @import("std");
const c = @import("../c.zig");
const loop_mod = @import("loop.zig");

const EV_KEY: u16 = 1;
const KEY_A: u16 = 30;
const KEY_LEFTMETA: u16 = 125;
const KEY_RIGHTMETA: u16 = 126;
const BTN_LEFT: u16 = 0x110;
const TAP_MS: u64 = 600;
const MAX_DEV = 16;

/// struct input_event(64bit: timeval 16 バイト + type + code + value)
const InputEvent = extern struct { sec: i64, usec: i64, type: u16, code: u16, value: i32 };

/// EVIOCGBIT(EV_KEY, len) = _IOC(_IOC_READ, 'E', 0x20 + EV_KEY, len)
fn eviocgbitKey(len: u32) u32 {
    // EVIOCGBIT(EV_KEY, len)。ioctl 番号の作り方は OS で違う(Linux の _IOC_READ は 2<<30、FreeBSD の IOC_OUT は 1<<30)
    const dir: u32 = if (@import("builtin").os.tag == .freebsd) 1 << 30 else 2 << 30;
    return dir | ((len & 0x1fff) << 16) | ('E' << 8) | (0x20 + 1);
}

pub const SuperTap = struct {
    loop: *loop_mod.Loop,
    ctx: *anyopaque,
    on_tap: *const fn (ctx: *anyopaque) void,
    fds: [MAX_DEV]c_int = [_]c_int{-1} ** MAX_DEV,
    inotify: c_int = -1,
    rescan_timer: ?loop_mod.Timer = null,
    armed: bool = false,
    spoiled: bool = false,
    t0: u64 = 0,
    enabled: bool = true,

    pub fn start(self: *SuperTap) void {
        self.scan();
        // キーボードの抜き差しに追従(新しい event* ができたら少し待って読み直す。権限の設定が後から来るため)
        self.inotify = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
        if (self.inotify >= 0) {
            _ = c.inotify_add_watch(self.inotify, "/dev/input", c.IN_CREATE | c.IN_ATTRIB);
            self.loop.add(self.inotify, c.EPOLLIN, self, onInotify) catch {};
        }
        self.rescan_timer = loop_mod.Timer.init() catch null;
        if (self.rescan_timer) |t| self.loop.add(t.fd, c.EPOLLIN, self, onRescan) catch {};
    }

    fn hasBit(bits: []const u8, code: u16) bool {
        return (bits[code / 8] >> @intCast(code % 8)) & 1 == 1;
    }

    fn scan(self: *SuperTap) void {
        for (&self.fds) |*fd| if (fd.* >= 0) {
            self.loop.remove(fd.*);
            _ = c.close(fd.*);
            fd.* = -1;
        };
        var n: usize = 0;
        var opened: usize = 0;
        var i: usize = 0;
        while (i < 64 and n < MAX_DEV) : (i += 1) {
            var p: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&p, "/dev/input/event{d}", .{i}) catch break;
            const fd = c.open(path.ptr, c.O_RDONLY | c.O_NONBLOCK | c.O_CLOEXEC);
            if (fd < 0) continue;
            opened += 1;
            var bits: [96]u8 = [_]u8{0} ** 96;
            // ioctl の request の型は libc で違う(musl は int、FreeBSD は unsigned long)ので、その型へビット列のまま変換する
            const Req = @typeInfo(@TypeOf(c.ioctl)).Fn.params[1].type.?;
            const req: Req = if (@typeInfo(Req).Int.signedness == .signed) @bitCast(eviocgbitKey(bits.len)) else eviocgbitKey(bits.len);
            const ok = c.ioctl(fd, req, &bits) >= 0;
            // キーボード(A と Super を持つ)とマウス(左ボタンを持つ)だけを見る
            const keyboard = ok and hasBit(&bits, KEY_A) and hasBit(&bits, KEY_LEFTMETA);
            const mouse = ok and hasBit(&bits, BTN_LEFT);
            if (!keyboard and !mouse) {
                _ = c.close(fd);
                continue;
            }
            self.loop.add(fd, c.EPOLLIN, self, onRead) catch {
                _ = c.close(fd);
                continue;
            };
            self.fds[n] = fd;
            n += 1;
        }
        if (n == 0) std.log.info("supertap: 入力デバイスを読めません(input グループ外?)。Super 単体でのランチャーは無効", .{});
    }

    fn onInotify(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *SuperTap = @ptrCast(@alignCast(ctx));
        var buf: [1024]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
        while (c.read(fd, &buf, buf.len) > 0) {}
        if (self.rescan_timer) |t| t.arm(800, 0);
    }

    fn onRescan(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *SuperTap = @ptrCast(@alignCast(ctx));
        if (self.rescan_timer) |t| t.ack();
        self.scan();
    }

    fn onRead(ctx: *anyopaque, fd: c_int, events: u32) void {
        const self: *SuperTap = @ptrCast(@alignCast(ctx));
        var evs: [32]InputEvent = undefined;
        while (true) {
            const n = c.read(fd, &evs, @sizeOf(@TypeOf(evs)));
            if (n <= 0) {
                if (events & (c.EPOLLHUP | c.EPOLLERR) != 0) {
                    // デバイスが外れた
                    self.loop.remove(fd);
                    _ = c.close(fd);
                    for (&self.fds) |*f| if (f.* == fd) {
                        f.* = -1;
                    };
                }
                return;
            }
            const cnt = @as(usize, @intCast(n)) / @sizeOf(InputEvent);
            for (evs[0..cnt]) |e| self.handle(e);
        }
    }

    fn handle(self: *SuperTap, e: InputEvent) void {
        if (e.type != EV_KEY) return;
        const meta = e.code == KEY_LEFTMETA or e.code == KEY_RIGHTMETA;
        if (meta) {
            if (e.value == 1) {
                self.armed = true;
                self.spoiled = false;
                self.t0 = loop_mod.nowMs();
            } else if (e.value == 0) {
                const quick = loop_mod.nowMs() - self.t0 < TAP_MS;
                if (self.armed and !self.spoiled and quick and self.enabled) self.on_tap(self.ctx);
                self.armed = false;
            }
            return;
        }
        // Super を押している間に他のキーやボタンが押されたら、それは組み合わせ(Super+1 等)
        if (e.value == 1 and self.armed) self.spoiled = true;
    }
};
