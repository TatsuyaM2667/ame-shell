// ame-airpods: AirPods と Apple のアクセサリの通信(AAP、Bluetooth の L2CAP)で話す。Linux のみ。
//
//   ame-airpods find                      接続中の AirPods の「番地 名前」(無ければ終了コード 1)
//   ame-airpods battery [-a 番地]          左・右・ケースの電池 {"left":{"level","charging"},"right":…,"case":…}
//   ame-airpods head [-a 番地] [--yaw 度] [--pitch 度] [--invert-yaw] [--invert-pitch]
//                                         頭の動きを 1 行 1 つの JSON で流し続ける(止めるまで):
//     {"event":"status","status":"searching|connecting|running|no_device|failed|rejected","name":"…"}
//     {"event":"angles","pitch":度,"yaw":度}   (10 回/秒まで)
//     {"event":"gesture","gesture":"right|left|up|down"}   頭を振って戻した・向いて戻した
//
// 番地を省くと、接続中の Bluetooth の機器から AAP の UUID(74ec2172-…)を持つものを探す(bluetoothctl)。
// head は AirPods が外れても探し直してつなぎ直す。SIGTERM / SIGINT で頭の向きの送信を止めてから終わる。
// パケットの読み方と動きの見つけ方は src/lib/aap.zig。ame-shell の AirPods 操作と接続のカードもこれを使う。
const std = @import("std");
const builtin = @import("builtin");
const aap = @import("ame_lib").aap;

const AAP_UUID = "74ec2172-0bad-4d01-8f77-997b2be0722a";
const AF_BLUETOOTH = 31;
const BTPROTO_L2CAP = 0;

var out: std.io.BufferedWriter(4096, std.fs.File.Writer) = undefined;
var quit = std.atomic.Value(bool).init(false);

fn emit(v: anytype) void {
    const w = out.writer();
    std.json.stringify(v, .{}, w) catch return;
    w.writeByte('\n') catch return;
    out.flush() catch quit.store(true, .release); // 読む側がいなくなった
}

fn usage() noreturn {
    std.io.getStdErr().writeAll(
        \\使い方: ame-airpods find
        \\        ame-airpods battery [-a 番地]
        \\        ame-airpods head [-a 番地] [--yaw 度] [--pitch 度] [--invert-yaw] [--invert-pitch]
        \\
    ) catch {};
    std.process.exit(2);
}

/// quit が立つまで ms だけ待つ。立ったら true
fn sleepQuit(ms: u32) bool {
    var left = ms;
    while (left > 0) {
        if (quit.load(.acquire)) return true;
        const d = @min(left, 200);
        std.time.sleep(@as(u64, d) * std.time.ns_per_ms);
        left -= d;
    }
    return quit.load(.acquire);
}

// ---- 探す(bluetoothctl)----

const Found = struct { addr: [17]u8, name: [64]u8 = undefined, name_len: usize = 0 };

fn run(a: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const r = std.process.Child.run(.{ .allocator = a, .argv = argv, .max_output_bytes = 64 << 10 }) catch return null;
    if (r.term != .Exited or r.term.Exited != 0) return null;
    return r.stdout;
}

/// 「Device AA:BB:CC:DD:EE:FF 名前」の行から番地と名前
fn parseDeviceLine(line: []const u8) ?Found {
    if (!std.mem.startsWith(u8, line, "Device ") or line.len < 7 + 17) return null;
    var f = Found{ .addr = undefined };
    @memcpy(&f.addr, line[7..24]);
    const name = std.mem.trim(u8, line[24..], " \r");
    f.name_len = @min(name.len, f.name.len);
    @memcpy(f.name[0..f.name_len], name[0..f.name_len]);
    return f;
}

/// 接続中で AAP の UUID を持つ機器
fn find(a: std.mem.Allocator) ?Found {
    const list = run(a, &.{ "bluetoothctl", "devices", "Connected" }) orelse return null;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |line| {
        const f = parseDeviceLine(line) orelse continue;
        const info = run(a, &.{ "bluetoothctl", "info", &f.addr }) orelse continue;
        if (std.ascii.indexOfIgnoreCase(info, AAP_UUID) != null) return f;
    }
    return null;
}

// ---- つなぐ(L2CAP)----

const SockaddrL2 = extern struct { family: u16, psm: u16, bdaddr: [6]u8, cid: u16, bdaddr_type: u8 };

/// "AA:BB:CC:DD:EE:FF" → 逆順の 6 バイト(BlueZ の bdaddr_t)
fn parseAddr(s: []const u8) ?[6]u8 {
    if (s.len != 17) return null;
    var b: [6]u8 = undefined;
    for (0..6) |i| {
        if (i > 0 and s[i * 3 - 1] != ':') return null;
        b[5 - i] = std.fmt.parseInt(u8, s[i * 3 .. i * 3 + 2], 16) catch return null;
    }
    return b;
}

/// AAP(L2CAP の PSM 0x1001)につなぐ。最長 8 秒(quit を見ながら)
fn connect(addr: []const u8) ?std.posix.fd_t {
    const bd = parseAddr(addr) orelse return null;
    const fd = std.posix.socket(AF_BLUETOOTH, std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, BTPROTO_L2CAP) catch return null;
    var sa = std.mem.zeroes(SockaddrL2);
    sa.family = AF_BLUETOOTH;
    sa.psm = std.mem.nativeToLittle(u16, aap.AAP_PSM);
    sa.bdaddr = bd;
    std.posix.connect(fd, @ptrCast(&sa), @sizeOf(SockaddrL2)) catch |e| if (e != error.WouldBlock) {
        std.posix.close(fd);
        return null;
    };
    var waited: u32 = 0;
    while (waited < 8000 and !quit.load(.acquire)) : (waited += 200) {
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        const n = std.posix.poll(&pfd, 200) catch break;
        if (n == 0) continue;
        std.posix.getsockoptError(fd) catch break;
        return fd;
    }
    std.posix.close(fd);
    return null;
}

fn sendPkt(fd: std.posix.fd_t, p: []const u8) bool {
    const n = std.posix.send(fd, p, std.posix.MSG.NOSIGNAL) catch return false;
    return n == p.len;
}

/// 届いたパケット 1 つ(timeout_ms 待っても無ければ 0 バイト。切れたら null)
fn recvPkt(fd: std.posix.fd_t, buf: []u8, timeout_ms: i32) ?[]const u8 {
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&pfd, timeout_ms) catch return null;
    if (n == 0) return buf[0..0];
    if (pfd[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return null;
    const r = std.posix.recv(fd, buf, 0) catch return null;
    if (r == 0) return null;
    return buf[0..r];
}

// ---- battery ----

fn battery(a: std.mem.Allocator, addr_opt: ?[]const u8) u8 {
    const f = if (addr_opt == null) find(a) else null;
    const addr: []const u8 = addr_opt orelse if (f) |ff| &ff.addr else {
        std.io.getStdErr().writeAll("ame-airpods: 接続中の AirPods がありません\n") catch {};
        return 1;
    };
    // つないだ直後は AAP がまだ開かないことがあるので、何度か試す
    var tries: u32 = 0;
    while (tries < 4 and !quit.load(.acquire)) : (tries += 1) {
        if (tries > 0) _ = sleepQuit(800);
        const fd = connect(addr) orelse continue;
        defer std.posix.close(fd);
        if (!sendPkt(fd, &aap.HANDSHAKE)) continue;
        _ = sleepQuit(200);
        _ = sendPkt(fd, &aap.REQUEST_NOTIFICATIONS);
        var buf: [512]u8 = undefined;
        const t0 = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - t0 < 3000 and !quit.load(.acquire)) {
            const p = recvPkt(fd, &buf, 200) orelse break;
            var b: aap.Batteries = undefined;
            if (p.len == 0 or !aap.parseBattery(p, &b)) continue;
            emit(.{ .left = b[0], .right = b[1], .case = b[2] });
            return 0;
        }
    }
    std.io.getStdErr().writeAll("ame-airpods: 電池の残りを読めませんでした\n") catch {};
    return 1;
}

// ---- head ----

const Status = enum { searching, connecting, running, no_device, failed, rejected };

const HeadOpts = struct { addr: ?[]const u8 = null, yaw: f32 = 25, pitch: f32 = 18, inv_yaw: bool = false, inv_pitch: bool = false };

fn head(a: std.mem.Allocator, o: HeadOpts) void {
    // 状態は変わったときだけ出す(つながらない間、5 秒おきに同じものを出さない)
    var last: ?Status = null;
    var name: []const u8 = "";
    const report = struct {
        fn f(l: *?Status, s: Status, nm: []const u8) void {
            if (l.* == s) return;
            l.* = s;
            emit(.{ .event = "status", .status = @tagName(s), .name = nm });
        }
    }.f;
    report(&last, .searching, "");
    var found: Found = undefined;
    while (!quit.load(.acquire)) {
        var addr: []const u8 = undefined;
        if (o.addr) |x| addr = x else if (find(a)) |f| {
            found = f;
            addr = &found.addr;
            name = found.name[0..found.name_len];
        } else {
            report(&last, .no_device, "");
            if (sleepQuit(5000)) break;
            continue;
        }
        report(&last, .connecting, name);
        const fd = connect(addr) orelse {
            report(&last, .failed, name);
            if (sleepQuit(5000)) break;
            continue;
        };
        const r = session(fd, o, &last, name);
        std.posix.close(fd);
        // 断られた(Apple の機器でないため): 設定を直してつなぎ直すまで、ゆっくり試し直す
        if (sleepQuit(if (r == .rejected) 30_000 else 2000)) break;
    }
}

fn session(fd: std.posix.fd_t, o: HeadOpts, last: *?Status, name: []const u8) Status {
    if (!sendPkt(fd, &aap.HANDSHAKE)) return .failed;
    _ = sleepQuit(300);
    _ = sendPkt(fd, &aap.REQUEST_NOTIFICATIONS);
    if (!sendPkt(fd, &aap.HEAD_TRACKING_START)) return .failed;
    defer _ = sendPkt(fd, &aap.HEAD_TRACKING_STOP);
    var calib = aap.Calib{};
    var det = aap.Detector{ .yaw_t = o.yaw, .pitch_t = o.pitch };
    var buf: [512]u8 = undefined;
    const t_start = std.time.milliTimestamp();
    var last_data = t_start;
    var last_angles: i64 = 0;
    var got_head = false;
    var rejected = false;
    while (!quit.load(.acquire)) {
        const pkt = recvPkt(fd, &buf, 250) orelse return .failed;
        const now = std.time.milliTimestamp();
        // 断られたまま 3 秒、頭の向きが来ない: Apple の機器でないと送らない(DeviceID の設定が要る)
        if (rejected and !got_head and now - t_start > 3000) {
            if (last.* != .rejected) emit(.{ .event = "status", .status = "rejected", .name = name });
            last.* = .rejected;
            return .rejected;
        }
        // 頭の向きが届かなくなった(耳から外した・ほかの機器が止めた): 頼み直す
        if (got_head and now - last_data > 4000) {
            if (!sendPkt(fd, &aap.HEAD_TRACKING_START)) return .failed;
            last_data = now;
        }
        if (pkt.len == 0) continue;
        if (aap.isRejected(pkt)) rejected = true;
        const raw = aap.parseHead(pkt) orelse continue;
        if (!got_head) {
            got_head = true;
            if (last.* != .running) emit(.{ .event = "status", .status = "running", .name = name });
            last.* = .running;
        }
        last_data = now;
        const ang = calib.angles(raw) orelse continue;
        const pitch = if (o.inv_pitch) -ang[0] else ang[0];
        const yaw = if (o.inv_yaw) -ang[1] else ang[1];
        if (now - last_angles > 100) {
            last_angles = now;
            emit(.{ .event = "angles", .pitch = pitch, .yaw = yaw });
        }
        if (det.step(pitch, yaw, now)) |g| emit(.{ .event = "gesture", .gesture = @tagName(g) });
    }
    return .failed;
}

fn onSignal(_: c_int) callconv(.C) void {
    quit.store(true, .release);
}

pub fn main() !u8 {
    if (builtin.os.tag != .linux) {
        std.io.getStdErr().writeAll("ame-airpods: Linux だけで使えます\n") catch {};
        return 2;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    out = std.io.bufferedWriter(std.io.getStdOut().writer());
    if (args.len < 2) usage();
    const act = std.posix.Sigaction{ .handler = .{ .handler = onSignal }, .mask = std.posix.empty_sigset, .flags = 0 };
    try std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    try std.posix.sigaction(std.posix.SIG.INT, &act, null);

    var o = HeadOpts{};
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        const eq = std.mem.eql;
        if (eq(u8, x, "--invert-yaw")) {
            o.inv_yaw = true;
        } else if (eq(u8, x, "--invert-pitch")) {
            o.inv_pitch = true;
        } else if (i + 1 < args.len and (eq(u8, x, "-a") or eq(u8, x, "--yaw") or eq(u8, x, "--pitch"))) {
            i += 1;
            const v = args[i];
            if (eq(u8, x, "-a")) {
                if (parseAddr(v) == null) usage();
                o.addr = v;
            } else {
                const n = std.fmt.parseFloat(f32, v) catch usage();
                if (!(n > 1 and n < 90)) usage();
                if (eq(u8, x, "--yaw")) o.yaw = n else o.pitch = n;
            }
        } else usage();
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "find")) {
        const f = find(a) orelse return 1;
        try out.writer().print("{s} {s}\n", .{ f.addr, f.name[0..f.name_len] });
        try out.flush();
        return 0;
    }
    if (std.mem.eql(u8, cmd, "battery")) return battery(a, o.addr);
    if (std.mem.eql(u8, cmd, "head")) {
        head(a, o);
        return 0;
    }
    usage();
}

test "address and device line" {
    const b = parseAddr("AA:BB:CC:DD:EE:0F").?;
    try std.testing.expectEqualSlices(u8, &.{ 0x0F, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA }, &b);
    try std.testing.expect(parseAddr("AA:BB:CC:DD:EE") == null);
    try std.testing.expect(parseAddr("AA-BB-CC-DD-EE-FF") == null);
    const f = parseDeviceLine("Device 11:22:33:44:55:66 Tatsuya の AirPods Pro").?;
    try std.testing.expectEqualStrings("11:22:33:44:55:66", &f.addr);
    try std.testing.expectEqualStrings("Tatsuya の AirPods Pro", f.name[0..f.name_len]);
    try std.testing.expect(parseDeviceLine("Controller 00:11 x") == null);
}
