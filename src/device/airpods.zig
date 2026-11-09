// AirPods の頭の動きで操作する(AirPods Pro 2 など、空間オーディオ用に頭の向きを出すもの)。Linux のみ。
//
//   頭を右へ振って戻す … 右のワークスペースへ  / 左へ振って戻す … 左のワークスペースへ
//   上を向いて戻す     … ランチャー            / 下を向いて戻す … ダッシュボード
// 振ったまま・向いたままのとき(よそ見・キーボードを見る)は何もしない。戻したときにだけ動く。
// AirPods 本来の操作(軸を押す・つまむ)はそのまま使える(こちらは頭の向きを読むだけ)。
//
// 仕組み: Bluetooth で AirPods とつないで頭の向きを読み、動きを見つけるのは別のプロセスの ame-airpods head
// (src/cmd/ame-airpods.zig、読み方は src/lib/aap.zig)。ここはそれを動かして、出てくる 1 行 1 つの JSON
// (status / angles / gesture)を操作にするだけ。Bluetooth の処理で詰まっても ame-shell は止まらない。
// オン/オフ: ame-ctl airpods on|off|toggle|status、ユーティリティのボタン、
// 設定 airpods { enabled / invert-yaw / invert-pitch / yaw-angle / pitch-angle }。
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig");
const App = @import("../core/app.zig").App;
const sys = @import("../platform/sys.zig");

const log = std.log.scoped(.airpods);

pub const supported = builtin.os.tag == .linux;

const Status = enum { off, searching, connecting, running, no_device, failed, rejected };

var st: struct {
    app: ?*App = null,
    fd: c_int = -1,
    pid: c_int = 0,
    line: [512]u8 = undefined,
    line_len: usize = 0,
    on: bool = false,
    status: Status = .off,
    pitch: f32 = 0,
    yaw: f32 = 0,
    name: [64]u8 = undefined,
    name_len: usize = 0,
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
    st.debug = std.posix.getenv("AME_DEBUG") != null;
    var yb: [16]u8 = undefined;
    var pb: [16]u8 = undefined;
    var argv: [8]?[*:0]const u8 = undefined;
    var n: usize = 0;
    for ([_][*:0]const u8{ "ame-airpods", "head", "--yaw", (std.fmt.bufPrintZ(&yb, "{d}", .{app.cfg.airpods_yaw}) catch "25").ptr, "--pitch", (std.fmt.bufPrintZ(&pb, "{d}", .{app.cfg.airpods_pitch}) catch "18").ptr }) |a| {
        argv[n] = a;
        n += 1;
    }
    if (app.cfg.airpods_invert_yaw) {
        argv[n] = "--invert-yaw";
        n += 1;
    }
    if (app.cfg.airpods_invert_pitch) {
        argv[n] = "--invert-pitch";
        n += 1;
    }
    const fd = sys.spawnReader(argv[0..n], &st.pid) orelse {
        app.osd.info("ame-airpods を起動できませんでした");
        return;
    };
    _ = c.fcntl(fd, c.F_SETFL, c.fcntl(fd, c.F_GETFL, @as(c_int, 0)) | c.O_NONBLOCK);
    app.loop.add(fd, c.EPOLLIN | c.EPOLLHUP, app, onRead) catch {
        _ = c.kill(st.pid, c.SIGTERM);
        _ = c.close(fd);
        return;
    };
    st.fd = fd;
    st.line_len = 0;
    st.on = true;
    st.status = .searching;
    app.osd.info("AirPods の頭の動きで操作します(左右に振る: ワークスペース / 上: ランチャー / 下: ダッシュボード)");
    app.redrawBars();
}

pub fn disable() void {
    if (!st.on) return;
    // ame-airpods は SIGTERM で頭の向きの送信を止めてから終わる
    if (st.pid > 0) _ = c.kill(st.pid, c.SIGTERM);
    closeFd();
    st.on = false;
    st.status = .off;
    if (st.app) |app| app.redrawBars();
}

fn closeFd() void {
    if (st.fd < 0) return;
    if (st.app) |app| app.loop.remove(st.fd);
    _ = c.close(st.fd);
    st.fd = -1;
    st.pid = 0;
}

/// ame-ctl airpods status
pub fn status(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} pitch={d:.1} yaw={d:.1} {s}", .{
        if (st.on) "on" else "off", @tagName(st.status), st.pitch, st.yaw, st.name[0..st.name_len],
    }) catch "?";
}

fn onRead(ctx: *anyopaque, fd: c_int, _: u32) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    while (true) {
        if (st.line_len == st.line.len) st.line_len = 0; // 長すぎる行は捨てる
        const n = c.read(fd, st.line[st.line_len..].ptr, st.line.len - st.line_len);
        if (n > 0) {
            st.line_len += @intCast(n);
            while (std.mem.indexOfScalar(u8, st.line[0..st.line_len], '\n')) |nl| {
                handleLine(app, st.line[0..nl]);
                std.mem.copyForwards(u8, st.line[0..], st.line[nl + 1 .. st.line_len]);
                st.line_len -= nl + 1;
            }
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) return;
        break;
    }
    // ame-airpods が終わった(入っていない・落ちた)
    closeFd();
    if (st.on) {
        st.on = false;
        st.status = .off;
        app.osd.info("AirPods の操作が止まりました(ame-airpods が終わりました)");
        app.redrawBars();
    }
}

const Ev = struct { event: []const u8, status: []const u8 = "", name: []const u8 = "", gesture: []const u8 = "", pitch: f32 = 0, yaw: f32 = 0 };

fn handleLine(app: *App, line: []const u8) void {
    const p = std.json.parseFromSlice(Ev, std.heap.c_allocator, line, .{ .ignore_unknown_fields = true }) catch return;
    defer p.deinit();
    const e = p.value;
    const eq = std.mem.eql;
    if (eq(u8, e.event, "angles")) {
        st.pitch = e.pitch;
        st.yaw = e.yaw;
    } else if (eq(u8, e.event, "gesture")) {
        if (std.meta.stringToEnum(Gesture, e.gesture)) |g| act(app, g);
    } else if (eq(u8, e.event, "status")) {
        const s = std.meta.stringToEnum(Status, e.status) orelse return;
        if (e.name.len > 0) {
            st.name_len = @min(e.name.len, st.name.len);
            @memcpy(st.name[0..st.name_len], e.name[0..st.name_len]);
        }
        if (s == st.status) return;
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
    }
}

const Gesture = enum { right, left, up, down };

fn act(app: *App, g: Gesture) void {
    if (app.lock.locked) return;
    if (st.debug) log.info("頭の動き: {s}", .{@tagName(g)});
    switch (g) {
        .right, .left => {
            if (@import("../hand/hand.zig").stepWorkspace(app, if (g == .right) 1 else -1)) |n| {
                var b: [32]u8 = undefined;
                app.osd.info(std.fmt.bufPrint(&b, "ワークスペース {d}", .{n}) catch "");
            }
        },
        .up => app.launcher.toggle(),
        .down => @import("../core/ipc.zig").runCommand(app, "dashboard toggle"),
    }
    _ = c.wl_display_flush(app.display);
}

/// 接続中の AirPods のアドレスと名前(ame-ctl airpods popup)
pub fn connectedAirPods(addr: *[17]u8, name_buf: []u8) ?[]const u8 {
    var out: [2048]u8 = undefined;
    const s = @import("../platform/netdbus.zig").run(&.{ "bluetoothctl", "devices", "AirPods" }, &out) orelse return null;
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
