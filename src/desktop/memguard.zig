// メモリの見張り(Linux)。スワップの無い機械はメモリが尽きると、OOM キラーが動く前にページの追い出しと
// 読み直しを繰り返して何分も固まる(実機: 空き 93MB で River と ame-shell が D 状態のまま止まり、電源で切るしか
// なかった)。カーネルのメモリ圧力(PSI)の知らせを待ち(定期的には調べない)、来たら空きを見て:
//   空きが 10% を切った → 通知(いちばん使っているアプリと量)
//   空きが 3% を切った  → カーネルの OOM キラーが選ぶのと同じプロセス(oom_score が最大)を止めて通知
// 止めるのは自分のユーザーのプロセスだけ。River・Xwayland・ame-*・音やバスの常駐は選ばない。
// shell { memory-guard false } で止めるのをやめる(通知だけになる)。
const std = @import("std");
const c = @import("../c.zig");
const App = @import("../core/app.zig").App;
const loop = @import("../platform/loop.zig");

const log = std.log.scoped(.memguard);

pub const Level = enum { ok, low, critical };

/// 空き(MemAvailable)と全体から段階を決める
pub fn level(avail_kb: u64, total_kb: u64) Level {
    if (total_kb == 0) return .ok;
    if (avail_kb * 100 < total_kb * 3) return .critical;
    if (avail_kb * 100 < total_kb * 10) return .low;
    return .ok;
}

/// 止めてはいけない(止めるとセッションごと落ちる・音やバスが消える)もの
fn protected(comm: []const u8) bool {
    const names = [_][]const u8{ "river", "Xwayland", "dbus-daemon", "dbus-broker", "pipewire", "wireplumber", "pipewire-pulse", "dinit", "turnstiled", "greetd", "sddm", "sh", "zsh", "bash", "login", "elogind", "fcitx5" };
    for (names) |n| if (std.mem.eql(u8, comm, n)) return true;
    return std.mem.startsWith(u8, comm, "ame-") or std.mem.startsWith(u8, comm, "ame_");
}

pub const Guard = struct {
    app: *App,
    fd: c_int = -1,
    warned_ms: u64 = 0,
    killed_ms: u64 = 0,

    /// /proc/pressure/memory に「2 秒のうち 0.3 秒以上メモリ待ちで止まったら知らせて」と頼む
    /// (一般ユーザーの PSI の見張りは窓が 2 秒の倍数でないといけない)
    pub fn start(self: *Guard) void {
        if (@import("builtin").os.tag != .linux) return;
        const fd = c.open("/proc/pressure/memory", c.O_RDWR | c.O_NONBLOCK | c.O_CLOEXEC);
        if (fd < 0) return log.info("PSI が無いのでメモリの見張りは無し", .{});
        const trig = "some 300000 2000000";
        if (c.write(fd, trig, trig.len + 1) < 0) {
            _ = c.close(fd);
            return log.info("PSI の見張りを頼めないのでメモリの見張りは無し", .{});
        }
        self.app.loop.add(fd, c.EPOLLPRI, self, onPsi) catch {
            _ = c.close(fd);
            return;
        };
        self.fd = fd;
    }

    fn onPsi(ctx: *anyopaque, fd: c_int, ev: u32) void {
        const self: *Guard = @ptrCast(@alignCast(ctx));
        if (ev & c.EPOLLERR != 0) {
            self.app.loop.remove(fd);
            _ = c.close(fd);
            self.fd = -1;
            return;
        }
        self.check();
    }

    fn check(self: *Guard) void {
        const mi = memInfo() orelse return;
        const now = loop.nowMs();
        switch (level(mi.avail_kb, mi.total_kb)) {
            .ok => {},
            .low => {
                if (self.warned_ms != 0 and now -| self.warned_ms < 120_000) return;
                self.warned_ms = now;
                var top: Proc = .{};
                _ = pick(&top, .largest);
                var sb: [96]u8 = undefined;
                var bb: [160]u8 = undefined;
                const summary = std.fmt.bufPrint(&sb, "メモリが残りわずかです(残り {d} MB)", .{mi.avail_kb / 1024}) catch "メモリが残りわずかです";
                const body = if (top.pid > 0) std.fmt.bufPrint(&bb, "いちばん使っているのは {s}({d} MB)", .{ top.name(), top.rss_kb / 1024 }) catch "" else "";
                self.app.notifs.post("ame-shell", summary, body, 0);
            },
            .critical => {
                if (!self.app.cfg.memory_guard) return;
                if (self.killed_ms != 0 and now -| self.killed_ms < 5_000) return;
                var v: Proc = .{};
                if (!pick(&v, .oom)) return;
                if (c.kill(v.pid, c.SIGKILL) != 0) return;
                self.killed_ms = now;
                log.warn("空き {d} MB: {s}(pid {d}, {d} MB)を止めました", .{ mi.avail_kb / 1024, v.name(), v.pid, v.rss_kb / 1024 });
                var sb: [128]u8 = undefined;
                const summary = std.fmt.bufPrint(&sb, "メモリが尽きそうだったので {s} を止めました", .{v.name()}) catch "メモリが尽きそうだったのでアプリを止めました";
                self.app.notifs.post("ame-shell", summary, "固まるのを防ぐため、カーネルが選ぶのと同じものを止めました(shell { memory-guard false } で止めなくなります)", 0);
            },
        }
    }
};

const MemInfo = struct { total_kb: u64, avail_kb: u64 };

fn memInfo() ?MemInfo {
    var buf: [2048]u8 = undefined;
    const s = rd("/proc/meminfo", &buf) orelse return null;
    var r = MemInfo{ .total_kb = 0, .avail_kb = 0 };
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| {
        const v = std.mem.trim(u8, l[(std.mem.indexOfScalar(u8, l, ':') orelse continue) + 1 ..], " kB");
        if (std.mem.startsWith(u8, l, "MemTotal:")) r.total_kb = std.fmt.parseInt(u64, v, 10) catch 0;
        if (std.mem.startsWith(u8, l, "MemAvailable:")) r.avail_kb = std.fmt.parseInt(u64, v, 10) catch 0;
    }
    return if (r.total_kb > 0) r else null;
}

const Proc = struct {
    pid: c_int = 0,
    rss_kb: u64 = 0,
    score: i64 = -1,
    comm: [32]u8 = undefined,
    comm_len: usize = 0,
    fn name(self: *const Proc) []const u8 {
        return self.comm[0..self.comm_len];
    }
};

/// 自分のユーザーのプロセスから、largest = 常駐が最大 / oom = oom_score が最大(守るものは除く)
fn pick(out: *Proc, by: enum { largest, oom }) bool {
    var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return false;
    defer dir.close();
    const me = std.os.linux.getpid();
    const uid = std.os.linux.getuid();
    var it = dir.iterate();
    var found = false;
    while (it.next() catch null) |e| {
        const pid = std.fmt.parseInt(c_int, e.name, 10) catch continue;
        if (pid <= 1 or pid == me) continue;
        var pb: [64]u8 = undefined;
        var buf: [512]u8 = undefined;
        // 持ち主(status の Uid の 1 つ目)
        const st = rd(std.fmt.bufPrint(&pb, "/proc/{d}/status", .{pid}) catch continue, &buf) orelse continue;
        const ui = std.mem.indexOf(u8, st, "\nUid:\t") orelse continue;
        var uit = std.mem.tokenizeAny(u8, st[ui + 6 ..], "\t\n");
        if ((std.fmt.parseInt(std.os.linux.uid_t, uit.next() orelse continue, 10) catch continue) != uid) continue;
        const comm = std.mem.trim(u8, rd(std.fmt.bufPrint(&pb, "/proc/{d}/comm", .{pid}) catch continue, &buf) orelse continue, " \n");
        if (protected(comm)) continue;
        var p = Proc{ .pid = pid };
        p.comm_len = @min(comm.len, p.comm.len);
        @memcpy(p.comm[0..p.comm_len], comm[0..p.comm_len]);
        // 常駐(statm の 2 つ目、ページ数)
        const sm = rd(std.fmt.bufPrint(&pb, "/proc/{d}/statm", .{pid}) catch continue, &buf) orelse continue;
        var smi = std.mem.tokenizeScalar(u8, sm, ' ');
        _ = smi.next();
        p.rss_kb = (std.fmt.parseInt(u64, smi.next() orelse continue, 10) catch continue) * 4;
        if (by == .oom) {
            const sc = rd(std.fmt.bufPrint(&pb, "/proc/{d}/oom_score", .{pid}) catch continue, &buf) orelse continue;
            p.score = std.fmt.parseInt(i64, std.mem.trim(u8, sc, " \n"), 10) catch continue;
            if (p.score <= 0) continue; // oom_score_adj -1000 など、カーネルも止めないもの
            if (p.score <= out.score) continue;
        } else if (p.rss_kb <= out.rss_kb) continue;
        out.* = p;
        found = true;
    }
    return found;
}

test "level: 10% / 3% で段階が変わる" {
    try std.testing.expectEqual(Level.ok, level(2000, 10000));
    try std.testing.expectEqual(Level.low, level(900, 10000));
    try std.testing.expectEqual(Level.critical, level(200, 10000));
    try std.testing.expectEqual(Level.ok, level(0, 0));
    try std.testing.expect(protected("river") and protected("ame-keyring") and !protected("Discord"));
}

test "pick: 守るもの・自分は選ばない(実際の /proc を読むだけで、止めはしない)" {
    var v: Proc = .{};
    if (pick(&v, .oom)) {
        try std.testing.expect(!protected(v.name()));
        try std.testing.expect(v.pid != std.os.linux.getpid() and v.score > 0);
    }
    var l: Proc = .{};
    if (pick(&l, .largest)) try std.testing.expect(l.rss_kb > 0);
}

/// /proc の小さなファイルを読む(c.zig を使わない: 試験のビルドには Wayland のヘッダが無い)
fn rd(path: []const u8, buf: []u8) ?[]const u8 {
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const n = f.read(buf) catch return null;
    if (n == 0) return null;
    return std.mem.trim(u8, buf[0..n], " \n\t");
}
