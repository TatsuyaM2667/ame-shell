// イベントループ抽象(epoll + timerfd)。
//
// 方針: 全てのデータ源(Wayland, タイマー, IPCソケット, inotify, 子プロセスのパイプ)を
// fd として1つの epoll に登録し、カーネルに待たせる。アニメーション中以外は
// epoll_wait で完全にブロックするので、待機時の CPU 使用率はほぼ 0 になる。
const std = @import("std");
const c = @import("../c.zig");

pub const Callback = *const fn (ctx: *anyopaque, fd: c_int, events: u32) void;

const Entry = struct { ctx: *anyopaque, cb: Callback };

pub const Loop = struct {
    epfd: c_int,
    entries: std.AutoHashMap(c_int, Entry),

    pub fn init(alloc: std.mem.Allocator) !Loop {
        const fd = c.epoll_create1(c.EPOLL_CLOEXEC);
        if (fd < 0) return error.EpollCreate;
        return .{ .epfd = fd, .entries = std.AutoHashMap(c_int, Entry).init(alloc) };
    }

    pub fn add(self: *Loop, fd: c_int, events: u32, ctx: *anyopaque, cb: Callback) !void {
        var ev = std.mem.zeroes(c.struct_epoll_event);
        ev.events = events;
        ev.data.fd = fd;
        if (c.epoll_ctl(self.epfd, c.EPOLL_CTL_ADD, fd, &ev) != 0) return error.EpollAdd;
        try self.entries.put(fd, .{ .ctx = ctx, .cb = cb });
    }

    pub fn remove(self: *Loop, fd: c_int) void {
        _ = c.epoll_ctl(self.epfd, c.EPOLL_CTL_DEL, fd, null);
        _ = self.entries.remove(fd);
    }

    /// 1回待って、準備できた fd のコールバックを呼ぶ。timeout_ms=-1 で無期限。
    pub fn dispatch(self: *Loop, timeout_ms: c_int) void {
        var evs: [32]c.struct_epoll_event = undefined;
        const n = c.epoll_wait(self.epfd, &evs, evs.len, timeout_ms);
        if (n <= 0) return;
        for (evs[0..@intCast(n)]) |ev| {
            // コールバック内で他の fd が remove されることがあるので毎回引き直す。
            const e = self.entries.get(ev.data.fd) orelse continue;
            e.cb(e.ctx, ev.data.fd, ev.events);
        }
    }
};

/// timerfd の薄いラッパ。CLOCK_MONOTONIC。ポーリングではなく「次に何かが変わる時刻」
/// (時計の分の変わり目、OSD の自動非表示など)にだけ起こすために使う。
pub const Timer = struct {
    fd: c_int,

    pub fn init() !Timer {
        const fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
        if (fd < 0) return error.TimerCreate;
        return .{ .fd = fd };
    }

    /// first_ms 後に1回、interval_ms>0 ならその後周期的に発火。first_ms=0 で停止。
    pub fn arm(self: Timer, first_ms: u64, interval_ms: u64) void {
        if (@import("builtin").os.tag != .linux) {
            // FreeBSD 14 以降は timerfd が libc にある(std.os.linux の直接のシステムコールは番号が違い SIGSYS で落ちる)
            var spec = std.mem.zeroes(c.struct_itimerspec);
            spec.it_value.tv_sec = @intCast(first_ms / 1000);
            spec.it_value.tv_nsec = @intCast((first_ms % 1000) * 1_000_000);
            spec.it_interval.tv_sec = @intCast(interval_ms / 1000);
            spec.it_interval.tv_nsec = @intCast((interval_ms % 1000) * 1_000_000);
            if (c.timerfd_settime(self.fd, 0, &spec, null) != 0) std.log.warn("timerfd_settime failed (fd={d})", .{self.fd});
            return;
        }
        // musl の struct timespec は translate-c で不透明型になるため、std の定義でシステムコールを直接呼ぶ(Linux 専用)
        const linux = std.os.linux;
        const spec = linux.itimerspec{
            .it_value = .{ .tv_sec = @intCast(first_ms / 1000), .tv_nsec = @intCast((first_ms % 1000) * 1_000_000) },
            .it_interval = .{ .tv_sec = @intCast(interval_ms / 1000), .tv_nsec = @intCast((interval_ms % 1000) * 1_000_000) },
        };
        _ = linux.timerfd_settime(self.fd, .{}, &spec, null);
    }

    pub fn disarm(self: Timer) void {
        self.arm(0, 0);
    }

    /// 発火回数を読み捨てる(読まないと epoll がずっと readable を返す)。
    pub fn ack(self: Timer) void {
        var buf: u64 = 0;
        _ = c.read(self.fd, &buf, 8);
    }
};

pub fn nowMs() u64 {
    var ts: std.posix.timespec = undefined;
    std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) catch return 0;
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
}
