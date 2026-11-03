// AirPods の頭の動きで操作する(AirPods Pro 2 など、空間オーディオ用に頭の向きを出すもの)。Linux のみ。
//
//   頭を右へ振って戻す … 右のワークスペースへ  / 左へ振って戻す … 左のワークスペースへ
//   上を向いて戻す     … ランチャー            / 下を向いて戻す … ダッシュボード
// 振ったまま・向いたままのとき(よそ見・キーボードを見る)は何もしない。戻したときにだけ動く。
// 軸に入れる量の基準は、ふだんの姿勢へゆっくり合わせ直す(姿勢が変わっても誤って動かない)。
// AirPods 本来の操作(軸を押す・つまむ)はそのまま使える(こちらは頭の向きを読むだけ)。
//
// 仕組み: BlueZ で接続中の AirPods(AAP の UUID 74ec2172-… を持つ機器)に L2CAP(PSM 0x1001)でつなぎ、
// Apple のアクセサリの通信(AAP)の「頭の向きを送る」を頼む。通信の形は LibrePods(kavishdevar/librepods)の
// 解析による: 頭の向きのパケットは 04 00 04 00 17 00 00 00 10 00 で始まり、43・45・47 バイト目に向きの値
// (符号つき 16 ビット、リトルエンディアン)。最初の 10 個の平均を「正面」にして、
//   上下(pitch) = ((o2 - 正面) + (o3 - 正面)) / 2 / 32000 × 180 度
//   左右(yaw)   = ((o2 - 正面) - (o3 - 正面)) / 2 / 32000 × 180 度
// ハンド操作と同じくオン/オフできる(ame-ctl airpods on|off|toggle|status、ユーティリティのボタン、
// 設定 airpods { enabled / invert-yaw / invert-pitch / yaw-angle / pitch-angle })。
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const App = @import("app.zig").App;
const loop = @import("platform/loop.zig");

const log = std.log.scoped(.airpods);

pub const supported = builtin.os.tag == .linux;

// ---- AAP のパケット(LibrePods より)----
pub const HANDSHAKE = [_]u8{ 0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
pub const REQUEST_NOTIFICATIONS = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x0F, 0x00, 0xFF, 0xFF, 0xFF, 0xFF };
const HEAD_TRACKING_START = [_]u8{
    0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x08, 0xA1, 0x02, 0x42,
    0x0B, 0x08, 0x0E, 0x10, 0x02, 0x1A, 0x05, 0x01, 0x40, 0x9C, 0x00, 0x00,
};
const HEAD_TRACKING_STOP = [_]u8{
    0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x11, 0x00, 0x08, 0x7E, 0x10, 0x02,
    0x42, 0x0B, 0x08, 0x4E, 0x10, 0x02, 0x1A, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00,
};
const AAP_PSM: u16 = 0x1001;

pub const Gesture = enum(u8) { right, left, up, down };

const Status = enum(u8) { off, searching, connecting, running, no_device, failed, rejected };

const Msg = extern struct {
    kind: u8, // 0 = 状態 / 1 = 動き / 2 = 今の角度(状態の表示用)
    code: u8 = 0,
    _r: [2]u8 = .{ 0, 0 },
    pitch: f32 = 0,
    yaw: f32 = 0,
};

var st: struct {
    app: ?*App = null,
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rfd: c_int = -1,
    wfd: c_int = -1,
    on: bool = false,
    status: Status = .off,
    pitch: f32 = 0,
    yaw: f32 = 0,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    // 設定(始めるときに写す)
    yaw_t: f32 = 25,
    pitch_t: f32 = 18,
    inv_yaw: bool = false,
    inv_pitch: bool = false,
    debug: bool = false,
} = .{};

pub fn enabled() bool {
    return st.on;
}

pub fn toggle(app: *App) void {
    if (st.on) disable() else enable(app);
}

pub fn enable(app: *App) void {
    if (st.on) return;
    if (!supported) {
        app.osd.info("AirPods の頭の動きでの操作は Linux だけで使えます");
        return;
    }
    st.app = app;
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return;
    st.rfd = fds[0];
    st.wfd = fds[1];
    app.loop.add(st.rfd, c.EPOLLIN, app, onMsg) catch {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return;
    };
    st.yaw_t = app.cfg.airpods_yaw;
    st.pitch_t = app.cfg.airpods_pitch;
    st.inv_yaw = app.cfg.airpods_invert_yaw;
    st.inv_pitch = app.cfg.airpods_invert_pitch;
    st.debug = std.posix.getenv("AME_DEBUG") != null;
    st.quit.store(false, .release);
    st.thread = std.Thread.spawn(.{ .stack_size = 256 << 10 }, worker, .{}) catch {
        app.loop.remove(st.rfd);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return;
    };
    st.on = true;
    st.status = .searching;
    app.osd.info("AirPods の頭の動きで操作します(左右に振る: ワークスペース / 上: ランチャー / 下: ダッシュボード)");
    app.redrawBars();
}

pub fn disable() void {
    if (!st.on) return;
    st.quit.store(true, .release);
    if (st.thread) |t| t.join();
    st.thread = null;
    if (st.app) |app| {
        app.loop.remove(st.rfd);
        app.redrawBars();
    }
    _ = c.close(st.rfd);
    _ = c.close(st.wfd);
    st.rfd = -1;
    st.wfd = -1;
    st.on = false;
    st.status = .off;
}

/// ame-ctl airpods status
pub fn status(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} pitch={d:.1} yaw={d:.1} {s}", .{
        if (st.on) "on" else "off", @tagName(st.status), st.pitch, st.yaw, st.name[0..st.name_len],
    }) catch "?";
}

fn onMsg(ctx: *anyopaque, fd: c_int, _: u32) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    var m: Msg = undefined;
    while (c.read(fd, &m, @sizeOf(Msg)) == @sizeOf(Msg)) {
        switch (m.kind) {
            0 => {
                const s: Status = @enumFromInt(m.code);
                if (s == st.status) continue;
                st.status = s;
                switch (s) {
                    .running => {
                        var b: [128]u8 = undefined;
                        app.osd.info(std.fmt.bufPrint(&b, "{s} の頭の動きを読んでいます", .{st.name[0..st.name_len]}) catch "AirPods の頭の動きを読んでいます");
                    },
                    .no_device => app.osd.info("AirPods が接続されていません(つなぐと自動で始めます)"),
                    .failed => app.osd.info("AirPods に接続できませんでした(しばらくしてもう一度試します)"),
                    .rejected => app.notifs.post("AirPods 操作", "AirPods が頭の向きを送ってくれません", "頭の向きを頼むと、AirPods が「使えない」と返しました。/etc/bluetooth/main.conf の [General] に DeviceID = bluetooth:004C:0000:0000 を書いて Bluetooth を再起動し、AirPods をいったん削除してペアリングし直すと送るようになることがあります", 0),
                    else => {},
                }
                app.redrawBars();
            },
            1 => act(app, @enumFromInt(m.code)),
            else => {
                st.pitch = m.pitch;
                st.yaw = m.yaw;
            },
        }
    }
}

fn act(app: *App, g: Gesture) void {
    if (app.lock.locked) return;
    if (st.debug) log.info("頭の動き: {s}", .{@tagName(g)});
    switch (g) {
        .right, .left => {
            if (@import("hand/hand.zig").stepWorkspace(app, if (g == .right) 1 else -1)) |n| {
                var b: [32]u8 = undefined;
                app.osd.info(std.fmt.bufPrint(&b, "ワークスペース {d}", .{n}) catch "");
            }
        },
        .up => app.launcher.toggle(),
        .down => @import("ipc.zig").runCommand(app, "dashboard toggle"),
    }
    _ = c.wl_display_flush(app.display);
}

// ---------------------------------------------------------------------------
// スレッド: AirPods を探す → つなぐ → 頭の向きを読む → 動きを見つける
// ---------------------------------------------------------------------------

fn send(m: Msg) void {
    _ = c.write(st.wfd, &m, @sizeOf(Msg));
}

fn sendStatus(s: Status) void {
    send(.{ .kind = 0, .code = @intFromEnum(s) });
}

/// quit が立つまで ms だけ待つ。立ったら true
fn sleepQuit(ms: u32) bool {
    var left = ms;
    while (left > 0) {
        if (st.quit.load(.acquire)) return true;
        const d = @min(left, 200);
        std.time.sleep(@as(u64, d) * std.time.ns_per_ms);
        left -= d;
    }
    return st.quit.load(.acquire);
}

fn worker() void {
    // 状態は変わったときだけ知らせる(つながらない間、5 秒おきに同じ案内を出さない)
    var last: Status = .off;
    const Report = struct {
        fn f(l: *Status, s: Status) void {
            if (l.* != s) sendStatus(s);
            l.* = s;
        }
    }.f;
    Report(&last, .searching);
    while (!st.quit.load(.acquire)) {
        var addr: [17]u8 = undefined;
        if (!findAirPods(&addr)) {
            Report(&last, .no_device);
            if (sleepQuit(5000)) break;
            continue;
        }
        const fd = connectL2cap(&addr, &st.quit) orelse {
            Report(&last, .failed);
            if (sleepQuit(5000)) break;
            continue;
        };
        const r = session(fd, &last);
        _ = c.close(fd);
        // 断られた(Apple の機器でないため): 設定を直してつなぎ直すまで、ゆっくり試し直す
        if (sleepQuit(if (r == .rejected) 30_000 else 2000)) break;
    }
}

/// 接続中の AirPods のアドレスと名前(ame-ctl airpods popup)
pub fn connectedAirPods(addr: *[17]u8, name_buf: []u8) ?[]const u8 {
    var out: [2048]u8 = undefined;
    const s = @import("platform/netdbus.zig").run(&.{ "bluetoothctl", "devices", "AirPods" }, &out) orelse return null;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Device ") or line.len < 7 + 17) continue;
        @memcpy(addr, line[7..24]);
        const name = std.mem.trim(u8, line[24..], " ");
        const n = @min(name.len, name_buf.len);
        @memcpy(name_buf[0..n], name[0..n]);
        return name_buf[0..n];
    }
    return null;
}

/// 接続中の AirPods のアドレスと名前(BlueZ を D-Bus で読む。netdbus.zig)
fn findAirPods(addr: *[17]u8) bool {
    var out: [2048]u8 = undefined;
    const s = @import("platform/netdbus.zig").run(&.{ "bluetoothctl", "devices", "AirPods" }, &out) orelse return false;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Device ") or line.len < 7 + 17) continue;
        @memcpy(addr, line[7..24]);
        const name = std.mem.trim(u8, line[24..], " ");
        st.name_len = @min(name.len, st.name.len);
        @memcpy(st.name[0..st.name_len], name[0..st.name_len]);
        return true;
    }
    return false;
}

const SockaddrL2 = extern struct {
    family: u16,
    psm: u16,
    bdaddr: [6]u8,
    cid: u16,
    bdaddr_type: u8,
};

/// AirPods の AAP(L2CAP PSM 0x1001)につなぐ。quit が立ったらやめる(ポップアップの電池の読み取りでも使う)
pub fn connectL2cap(addr: *const [17]u8, quit: *const std.atomic.Value(bool)) ?c_int {
    const AF_BLUETOOTH = 31;
    const BTPROTO_L2CAP = 0;
    const fd = c.socket(AF_BLUETOOTH, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, BTPROTO_L2CAP);
    if (fd < 0) {
        log.warn("Bluetooth の L2CAP のソケットを作れません", .{});
        return null;
    }
    var sa = std.mem.zeroes(SockaddrL2);
    sa.family = AF_BLUETOOTH;
    sa.psm = std.mem.nativeToLittle(u16, AAP_PSM);
    // "AA:BB:CC:DD:EE:FF" → 逆順の 6 バイト
    for (0..6) |i| {
        sa.bdaddr[5 - i] = std.fmt.parseInt(u8, addr[i * 3 .. i * 3 + 2], 16) catch {
            _ = c.close(fd);
            return null;
        };
    }
    if (c.connect(fd, @ptrCast(&sa), @sizeOf(SockaddrL2)) != 0 and std.c._errno().* != @intFromEnum(std.posix.E.INPROGRESS)) {
        _ = c.close(fd);
        return null;
    }
    // つながるまで最長 8 秒(quit を見ながら)
    var waited: u32 = 0;
    while (waited < 8000) : (waited += 200) {
        if (quit.load(.acquire)) break;
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        const n = std.posix.poll(&pfd, 200) catch break;
        if (n == 0) continue;
        var err: c_int = 0;
        var len: c.socklen_t = @sizeOf(c_int);
        _ = c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &err, &len);
        if (err != 0) break;
        return fd;
    }
    _ = c.close(fd);
    return null;
}

pub fn sendPkt(fd: c_int, p: []const u8) bool {
    return c.send(fd, p.ptr, p.len, c.MSG_NOSIGNAL) == @as(isize, @intCast(p.len));
}

/// 頭の向きを頼んだ返事(04 00 04 00 17 00 00 00 10 00 …、短いもの)で、断られた(状態 3)か
pub fn isRejected(p: []const u8) bool {
    if (p.len < 16 or p.len > 40) return false;
    const prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00 };
    if (!std.mem.eql(u8, p[0..10], &prefix)) return false;
    // 中身は protobuf: 08 <番号> 10 <状態> …。状態 3 = 使えない
    return p[12] == 0x08 and p[14] == 0x10 and p[15] == 0x03;
}

fn session(fd: c_int, last: *Status) Status {
    if (!sendPkt(fd, &HANDSHAKE)) return .failed;
    _ = sleepQuit(300);
    _ = sendPkt(fd, &REQUEST_NOTIFICATIONS);
    if (!sendPkt(fd, &HEAD_TRACKING_START)) return .failed;
    var calib = Calib{};
    var det = Detector{ .yaw_t = st.yaw_t, .pitch_t = st.pitch_t };
    var buf: [512]u8 = undefined;
    const t_start = std.time.milliTimestamp();
    var last_data = t_start;
    var last_angles: i64 = 0;
    var got_head = false;
    var rejected = false;
    var result: Status = .failed;
    while (!st.quit.load(.acquire)) {
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&pfd, 250) catch break;
        const now = std.time.milliTimestamp();
        // 断られたまま 3 秒、頭の向きが来ない: Apple の機器でないと送らない(DeviceID の設定が要る)
        if (rejected and !got_head and now - t_start > 3000) {
            if (last.* != .rejected) sendStatus(.rejected);
            last.* = .rejected;
            result = .rejected;
            break;
        }
        // 頭の向きが届かなくなった(耳から外した・ほかの機器が止めた): 頼み直す
        if (got_head and now - last_data > 4000) {
            if (!sendPkt(fd, &HEAD_TRACKING_START)) break;
            last_data = now;
        }
        if (n == 0) continue;
        if (pfd[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
        const r = c.recv(fd, &buf, buf.len, 0);
        if (r <= 0) break;
        const pkt = buf[0..@intCast(r)];
        if (isRejected(pkt)) rejected = true;
        const o = parseHead(pkt) orelse continue;
        if (!got_head) {
            got_head = true;
            if (last.* != .running) sendStatus(.running);
            last.* = .running;
        }
        last_data = now;
        const ang = calib.angles(o) orelse continue;
        const pitch = if (st.inv_pitch) -ang[0] else ang[0];
        const yaw = if (st.inv_yaw) -ang[1] else ang[1];
        if (now - last_angles > 100) {
            last_angles = now;
            send(.{ .kind = 2, .pitch = pitch, .yaw = yaw });
        }
        if (det.step(pitch, yaw, now)) |g| send(.{ .kind = 1, .code = @intFromEnum(g) });
    }
    _ = sendPkt(fd, &HEAD_TRACKING_STOP);
    return result;
}

/// 頭の向きのパケットなら o1・o2・o3
pub fn parseHead(p: []const u8) ?[3]i16 {
    if (p.len <= 60) return null;
    const prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00 };
    if (!std.mem.eql(u8, p[0..10], &prefix)) return null;
    if (p[10] != 0x44 and p[10] != 0x45) return null;
    if (p[11] != 0x00) return null;
    return .{
        std.mem.readInt(i16, p[43..45], .little),
        std.mem.readInt(i16, p[45..47], .little),
        std.mem.readInt(i16, p[47..49], .little),
    };
}

/// 最初の 10 個の平均を正面にして、上下・左右の角度(度)にする
pub const Calib = struct {
    n: u32 = 0,
    sum: [3]f64 = .{ 0, 0, 0 },
    zero: [3]f32 = .{ 0, 0, 0 },

    pub fn angles(self: *Calib, o: [3]i16) ?[2]f32 {
        if (self.n < 10) {
            for (0..3) |i| self.sum[i] += @floatFromInt(o[i]);
            self.n += 1;
            if (self.n == 10) for (0..3) |i| {
                self.zero[i] = @floatCast(self.sum[i] / 10);
            };
            return null;
        }
        const a2 = @as(f32, @floatFromInt(o[1])) - self.zero[1];
        const a3 = @as(f32, @floatFromInt(o[2])) - self.zero[2];
        return .{ (a2 + a3) / 2 / 32000 * 180, (a2 - a3) / 2 / 32000 * 180 };
    }
};

/// 頭を振って戻す・向いて戻すを見つける
pub const Detector = struct {
    yaw_t: f32 = 25,
    pitch_t: f32 = 18,
    base_p: f32 = 0,
    base_y: f32 = 0,
    has_base: bool = false,
    state: enum { idle, out, held, cool } = .idle,
    yaw_axis: bool = false,
    sign: f32 = 1,
    t0: i64 = 0,
    last: i64 = 0,

    /// 戻ったとみなす近さ(度)
    const BACK: f32 = 8;
    /// 振ってからこの時間のうちに戻れば動き。過ぎたら「よそ見」として何もしない
    const WINDOW_MS: i64 = 1200;
    const COOL_MS: i64 = 700;

    pub fn step(self: *Detector, p: f32, y: f32, now: i64) ?Gesture {
        if (!self.has_base) {
            self.base_p = p;
            self.base_y = y;
            self.has_base = true;
            self.last = now;
            return null;
        }
        const dt: f32 = @as(f32, @floatFromInt(@max(now - self.last, 0))) / 1000;
        self.last = now;
        const dp = p - self.base_p;
        const dy = y - self.base_y;
        switch (self.state) {
            .idle => {
                // ふだんの姿勢へゆっくり合わせ直す(2.5 秒くらい)
                if (@abs(dp) < 6 and @abs(dy) < 6) {
                    const k = @min(1, dt / 2.5);
                    self.base_p += dp * k;
                    self.base_y += dy * k;
                }
                const ry = @abs(dy) / self.yaw_t;
                const rp = @abs(dp) / self.pitch_t;
                if (ry >= 1 or rp >= 1) {
                    self.state = .out;
                    self.yaw_axis = ry >= rp;
                    self.sign = if (self.yaw_axis) std.math.sign(dy) else std.math.sign(dp);
                    self.t0 = now;
                }
            },
            .out => {
                const d = if (self.yaw_axis) dy else dp;
                if (now - self.t0 > WINDOW_MS) {
                    self.state = .held;
                } else if (@abs(d) < BACK) {
                    self.state = .cool;
                    self.t0 = now;
                    return if (self.yaw_axis)
                        (if (self.sign > 0) .right else .left)
                    else
                        (if (self.sign > 0) .up else .down);
                }
            },
            .held => {
                // よそ見から戻ったら、その姿勢を基準にし直す
                if (@abs(dp) < BACK and @abs(dy) < BACK) self.state = .idle;
                if (now - self.t0 > 6000) {
                    // 長く向いたまま: そこを新しい基準に
                    self.base_p = p;
                    self.base_y = y;
                    self.state = .idle;
                }
            },
            .cool => if (now - self.t0 > COOL_MS) {
                self.state = .idle;
            },
        }
        return null;
    }
};

test "頭の向きのパケットを読む" {
    var p = [_]u8{0} ** 70;
    const prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x44, 0x00 };
    @memcpy(p[0..12], &prefix);
    std.mem.writeInt(i16, p[43..45], -100, .little);
    std.mem.writeInt(i16, p[45..47], 1234, .little);
    std.mem.writeInt(i16, p[47..49], -5678, .little);
    const o = parseHead(&p).?;
    try std.testing.expectEqual(@as(i16, -100), o[0]);
    try std.testing.expectEqual(@as(i16, 1234), o[1]);
    try std.testing.expectEqual(@as(i16, -5678), o[2]);
    p[10] = 0x33;
    try std.testing.expect(parseHead(&p) == null);
    try std.testing.expect(parseHead(p[0..40]) == null);
}

test "振って戻すと動き・向いたままは何もしない" {
    var d = Detector{};
    var t: i64 = 0;
    // 正面で落ち着く
    while (t < 1000) : (t += 50) try std.testing.expect(d.step(0, 0, t) == null);
    // 右へ 35 度振って 0.4 秒で戻す → right
    var got: ?Gesture = null;
    const t1 = t;
    while (t < t1 + 400) : (t += 50) {
        if (d.step(0, 35, t)) |g| got = g;
    }
    if (d.step(0, 2, t)) |g| got = g;
    try std.testing.expectEqual(Gesture.right, got.?);
    t += 1000;
    _ = d.step(0, 0, t);
    // 下を向いたまま 3 秒(キーボードを見る)→ 戻しても何もしない
    got = null;
    const t2 = t;
    while (t < t2 + 3000) : (t += 50) {
        if (d.step(-30, 0, t)) |g| got = g;
    }
    while (t < t2 + 3500) : (t += 50) {
        if (d.step(0, 0, t)) |g| got = g;
    }
    try std.testing.expect(got == null);
    // 上を向いてすぐ戻す → up
    t += 1000;
    const t3 = t;
    while (t < t3 + 300) : (t += 50) {
        if (d.step(25, 1, t)) |g| got = g;
    }
    while (t < t3 + 600) : (t += 50) {
        if (d.step(0, 0, t)) |g| got = g;
    }
    try std.testing.expectEqual(Gesture.up, got.?);
}

test "頭の向きを断られた返事" {
    // AirPods Pro 2 が返した実際のもの(DeviceID が Apple でないとき)
    const r = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x08, 0x00, 0x08, 0x21, 0x10, 0x03, 0x4a, 0x02, 0x08, 0x0e };
    try std.testing.expect(isRejected(&r));
    var ok = r;
    ok[15] = 0x02;
    try std.testing.expect(!isRejected(&ok));
}

test "最初の 10 個で正面を決める" {
    var cb = Calib{};
    for (0..10) |_| try std.testing.expect(cb.angles(.{ 0, 1000, 1000 }) == null);
    const a = cb.angles(.{ 0, 1000 + 3200, 1000 + 3200 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 18), a[0], 0.01); // 上下だけ
    try std.testing.expectApproxEqAbs(@as(f32, 0), a[1], 0.01);
}

// ---- 電池(AAP のパケット 04 00 04 00 04 00 [数] ([部品] 01 [残り%] [状態] 01) × 数)----

pub const Battery = struct {
    /// 残り %(null = 分からない・つながっていない)
    level: ?u8 = null,
    charging: bool = false,
};

/// 左・右・ケースの順
pub const Batteries = [3]Battery;

pub fn parseBattery(p: []const u8, out: *Batteries) bool {
    if (p.len < 7) return false;
    const prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x04, 0x00 };
    if (!std.mem.eql(u8, p[0..6], &prefix)) return false;
    const n: usize = p[6];
    if (n == 0 or n > 3 or p.len < 7 + n * 5) return false;
    out.* = .{ .{}, .{}, .{} };
    for (0..n) |i| {
        const e = p[7 + i * 5 ..][0..5];
        if (e[1] != 0x01) return false;
        const idx: usize = switch (e[0]) {
            0x04 => 0, // 左
            0x02 => 1, // 右
            0x08 => 2, // ケース
            else => continue,
        };
        // 状態: 01 充電中 / 02 使用中 / 04 つながっていない / 05 最適化充電
        if (e[3] == 0x04) continue;
        out[idx] = .{ .level = @min(e[2], 100), .charging = e[3] == 0x01 or e[3] == 0x05 };
    }
    return true;
}

test "電池のパケットを読む" {
    // AirPods Pro 2 が返した実際のもの: 左 60% 使用中・右 47% 使用中・ケースはつながっていない
    const p = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x03, 0x04, 0x01, 0x3c, 0x02, 0x01, 0x02, 0x01, 0x2f, 0x02, 0x01, 0x08, 0x01, 0x00, 0x04, 0x01 };
    var b: Batteries = undefined;
    try std.testing.expect(parseBattery(&p, &b));
    try std.testing.expectEqual(@as(u8, 60), b[0].level.?);
    try std.testing.expectEqual(@as(u8, 47), b[1].level.?);
    try std.testing.expect(b[2].level == null);
    try std.testing.expect(!b[0].charging);
}
