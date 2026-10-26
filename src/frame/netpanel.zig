// ネットワーク設定パネル(枠の左辺、バーの横から生えるドロワー)。
//   Wi-Fi     … オン/オフ、スキャン、一覧(電波の強さ・鍵・保存済み・接続中)、パスワード入力、接続/切断
//   Bluetooth … 電源、スキャン、一覧(ペア済み・接続中を上に)、ペアリング+接続 / 切断
//
// 裏では nmcli / bluetoothctl を「1 つずつ順番に」非同期で実行し(キュー)、完了は pipe の EOF で知る。
// 引数はシェルを通さず渡すので、SSID やパスワードにどんな文字が入っていても安全。
const std = @import("std");
const c = @import("../c.zig");
const anim = @import("../anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("../gfx.zig");
const theme = @import("../theme.zig");
const surface = @import("../surface.zig");
const sys = @import("../platform/sys.zig");
const loop = @import("../platform/loop.zig");
const Frame = @import("frame.zig").Frame;

const MAX_ITEMS = 40;
const ROW_H: f32 = 50;
const EDIT_H: f32 = 100;
const LIST_Y: f32 = 112;
pub const W: f32 = 430;

const WifiNet = struct {
    ssid: [64]u8 = undefined,
    ssid_len: usize = 0,
    signal: u8 = 0,
    secure: bool = false,
    active: bool = false,
    saved: bool = false,
    fn name(self: *const WifiNet) []const u8 {
        return self.ssid[0..self.ssid_len];
    }
};

const BtDev = struct {
    mac: [17]u8 = undefined,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    paired: bool = false,
    connected: bool = false,
    fn name(self: *const BtDev) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const JobKind = enum { wifi_list, wifi_saved, wifi_connect, wifi_down, wifi_radio, bt_show, bt_all, bt_paired, bt_connected, bt_scan, bt_action, bt_power };

const Job = struct {
    kind: JobKind,
    args: [10][128]u8 = undefined,
    argc: usize = 0,
    /// 完了時に出すメッセージ(成功時)
    ok_msg: [96]u8 = undefined,
    ok_len: usize = 0,
};

pub const State = struct {
    tab: u8 = 0, // 0=Wi-Fi 1=Bluetooth
    tab_s: Spring = Spring.init(0, 0.25, 0.8),
    wifi_on: bool = true,
    bt_on: bool = false,
    sw: [2]Spring = .{ Spring.init(1, 0.25, 0.7), Spring.init(0, 0.25, 0.7) },
    nets: [MAX_ITEMS]WifiNet = undefined,
    n_nets: usize = 0,
    devs: [MAX_ITEMS]BtDev = undefined,
    n_devs: usize = 0,
    saved: [32][64]u8 = undefined,
    saved_len: [32]usize = undefined,
    n_saved: usize = 0,
    // 非同期ジョブ
    queue: [8]Job = undefined,
    n_queue: usize = 0,
    running: ?Job = null,
    fd: c_int = -1,
    pid: c_int = 0,
    out: [16384]u8 = undefined,
    out_len: usize = 0,
    busy_scan: bool = false,
    // 表示
    status: [128]u8 = undefined,
    status_len: usize = 0,
    status_err: bool = false,
    hover: i32 = -1,
    editing: ?usize = null,
    pw: [128]u8 = undefined,
    pw_len: usize = 0,
    scroll: f32 = 0,
    appear: [MAX_ITEMS]Spring = [_]Spring{Spring.init(0, 0.3, 0.75)} ** MAX_ITEMS,
    edit_h: Spring = Spring.init(0, 0.3, 0.85),
    frame: ?*Frame = null,
};

// ---------------------------------------------------------------------------
// ジョブ(nmcli / bluetoothctl)
// ---------------------------------------------------------------------------

fn makeJob(kind: JobKind, args: []const []const u8, ok: []const u8) Job {
    var j = Job{ .kind = kind };
    for (args, 0..) |a, i| {
        const n = @min(a.len, 127);
        @memcpy(j.args[i][0..n], a[0..n]);
        j.args[i][n] = 0;
        j.argc = i + 1;
    }
    j.ok_len = @min(ok.len, j.ok_msg.len);
    @memcpy(j.ok_msg[0..j.ok_len], ok[0..j.ok_len]);
    return j;
}

fn push(st: *State, j: Job) void {
    if (st.n_queue >= st.queue.len) return;
    st.queue[st.n_queue] = j;
    st.n_queue += 1;
    pump(st);
}

fn pump(st: *State) void {
    if (st.running != null or st.n_queue == 0) return;
    const j = st.queue[0];
    std.mem.copyForwards(Job, st.queue[0 .. st.n_queue - 1], st.queue[1..st.n_queue]);
    st.n_queue -= 1;
    st.running = j;
    // 引数は running の中のバッファを指す(ジョブが終わるまで有効)
    var av: [11]?[*:0]const u8 = .{null} ** 11;
    const r = &st.running.?;
    for (0..r.argc) |i| av[i] = @ptrCast(&r.args[i]);
    st.out_len = 0;
    st.fd = sys.spawnReaderAll(av[0..r.argc], &st.pid) orelse {
        st.running = null;
        setStatus(st, "コマンドを実行できません", true);
        return;
    };
    const f = st.frame orelse {
        std.log.warn("netpanel: frame 未設定", .{});
        return;
    };
    f.app.loop.add(st.fd, c.EPOLLIN | c.EPOLLHUP, st, onRead) catch {};
}

fn onRead(ctx: *anyopaque, fd: c_int, _: u32) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    const n = c.read(fd, st.out[st.out_len..].ptr, st.out.len - st.out_len);
    if (n > 0) {
        st.out_len += @intCast(n);
        if (st.out_len < st.out.len) return;
    }
    const f = st.frame orelse return;
    f.app.loop.remove(fd);
    _ = c.close(fd);
    st.fd = -1;
    const j = st.running.?;
    st.running = null;
    finish(st, j, st.out[0..st.out_len]);
    pump(st);
    f.schedule();
}

fn setStatus(st: *State, msg: []const u8, err: bool) void {
    st.status_len = @min(msg.len, st.status.len);
    @memcpy(st.status[0..st.status_len], msg[0..st.status_len]);
    // UTF-8 の途中で切らない
    while (st.status_len > 0 and st.status_len < msg.len and (st.status[st.status_len - 1] & 0xC0) == 0x80) st.status_len -= 1;
    st.status_err = err;
}

/// nmcli -t の 1 行を ':' で分ける("\:" は値の中のコロン)
fn splitNm(line: []const u8, out: [][]const u8, buf: []u8) usize {
    var n: usize = 0;
    var o: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= line.len and n < out.len) : (i += 1) {
        if (i == line.len or line[i] == ':') {
            out[n] = buf[start..o];
            n += 1;
            start = o;
            continue;
        }
        if (line[i] == '\\' and i + 1 < line.len) i += 1;
        if (o < buf.len) {
            buf[o] = line[i];
            o += 1;
        }
    }
    return n;
}

fn isSaved(st: *const State, ssid: []const u8) bool {
    for (0..st.n_saved) |i| if (std.mem.eql(u8, st.saved[i][0..st.saved_len[i]], ssid)) return true;
    return false;
}

fn finish(st: *State, j: Job, out: []const u8) void {
    const trimmed = std.mem.trim(u8, out, " \n");
    switch (j.kind) {
        .wifi_list => {
            st.busy_scan = false;
            st.n_nets = 0;
            var lines = std.mem.splitScalar(u8, out, '\n');
            while (lines.next()) |l| {
                var buf: [256]u8 = undefined;
                var f: [4][]const u8 = undefined;
                if (splitNm(l, &f, &buf) < 4) continue;
                const ssid = f[1];
                if (ssid.len == 0) continue; // 隠しネットワーク
                const sig = std.fmt.parseInt(u8, f[2], 10) catch 0;
                const active = std.mem.eql(u8, f[0], "*");
                // 同じ SSID は電波の強い方 / 接続中の方だけ残す
                var dup: ?usize = null;
                for (st.nets[0..st.n_nets], 0..) |*e, k| if (std.mem.eql(u8, e.name(), ssid)) {
                    dup = k;
                };
                if (dup) |k| {
                    if (active) st.nets[k].active = true;
                    if (sig > st.nets[k].signal) st.nets[k].signal = sig;
                    continue;
                }
                if (st.n_nets >= MAX_ITEMS) break;
                var e = WifiNet{ .signal = sig, .secure = f[3].len > 0 and !std.mem.eql(u8, f[3], "--"), .active = active };
                e.ssid_len = @min(ssid.len, e.ssid.len);
                @memcpy(e.ssid[0..e.ssid_len], ssid[0..e.ssid_len]);
                e.saved = isSaved(st, e.name());
                st.nets[st.n_nets] = e;
                st.n_nets += 1;
            }
            // 接続中 → 保存済み → 電波の強い順
            std.mem.sort(WifiNet, st.nets[0..st.n_nets], {}, struct {
                fn lt(_: void, a: WifiNet, b: WifiNet) bool {
                    if (a.active != b.active) return a.active;
                    if (a.saved != b.saved) return a.saved;
                    return a.signal > b.signal;
                }
            }.lt);
            restartAppear(st);
        },
        .wifi_saved => {
            st.n_saved = 0;
            var lines = std.mem.splitScalar(u8, out, '\n');
            while (lines.next()) |l| {
                var buf: [256]u8 = undefined;
                var f: [2][]const u8 = undefined;
                if (splitNm(l, &f, &buf) < 2) continue;
                if (!std.mem.eql(u8, f[1], "802-11-wireless") or st.n_saved >= st.saved.len) continue;
                const n = @min(f[0].len, 64);
                @memcpy(st.saved[st.n_saved][0..n], f[0][0..n]);
                st.saved_len[st.n_saved] = n;
                st.n_saved += 1;
            }
        },
        .wifi_radio => {
            st.wifi_on = std.mem.startsWith(u8, trimmed, "enabled") or (trimmed.len == 0 and st.wifi_on);
        },
        .wifi_connect, .wifi_down, .bt_action, .bt_power => {
            // 成功/失敗の判定: nmcli はエラー時 "Error:"、bluetoothctl は "Failed" を出す
            const failed = std.mem.indexOf(u8, out, "Error") != null or std.mem.indexOf(u8, out, "Failed") != null or std.mem.indexOf(u8, out, "not available") != null;
            if (failed) {
                var msg: [160]u8 = undefined;
                const line = firstLine(trimmed);
                const pretty = if (std.mem.indexOf(u8, out, "Secrets were required") != null or std.mem.indexOf(u8, out, "802-11-wireless-security.psk") != null)
                    "パスワードが違うか、必要です"
                else
                    line;
                setStatus(st, std.fmt.bufPrint(&msg, "失敗: {s}", .{pretty}) catch "失敗", true);
            } else {
                setStatus(st, j.ok_msg[0..j.ok_len], false);
                st.editing = null;
            }
            // 状態を取り直す
            if (j.kind == .wifi_connect or j.kind == .wifi_down) refreshWifi(st, false) else refreshBt(st);
        },
        .bt_show => {
            st.bt_on = std.mem.indexOf(u8, out, "Powered: yes") != null;
        },
        .bt_all => {
            st.n_devs = 0;
            var lines = std.mem.splitScalar(u8, out, '\n');
            while (lines.next()) |l| {
                // "Device AA:BB:CC:DD:EE:FF 名前"
                if (!std.mem.startsWith(u8, l, "Device ") or l.len < 25) continue;
                const mac = l[7..24];
                var dup = false;
                for (st.devs[0..st.n_devs]) |*d| if (std.mem.eql(u8, &d.mac, mac)) {
                    dup = true;
                };
                if (dup or st.n_devs >= MAX_ITEMS) continue;
                var d = BtDev{};
                @memcpy(&d.mac, mac);
                const nm = std.mem.trim(u8, l[24..], " ");
                d.name_len = @min(nm.len, d.name_buf.len);
                @memcpy(d.name_buf[0..d.name_len], nm[0..d.name_len]);
                st.devs[st.n_devs] = d;
                st.n_devs += 1;
            }
            restartAppear(st);
        },
        .bt_paired, .bt_connected => {
            var lines = std.mem.splitScalar(u8, out, '\n');
            while (lines.next()) |l| {
                if (!std.mem.startsWith(u8, l, "Device ") or l.len < 24) continue;
                const mac = l[7..24];
                for (st.devs[0..st.n_devs]) |*d| if (std.mem.eql(u8, &d.mac, mac)) {
                    if (j.kind == .bt_paired) d.paired = true else d.connected = true;
                };
            }
            if (j.kind == .bt_connected) {
                std.mem.sort(BtDev, st.devs[0..st.n_devs], {}, struct {
                    fn lt(_: void, a: BtDev, b: BtDev) bool {
                        if (a.connected != b.connected) return a.connected;
                        return a.paired and !b.paired;
                    }
                }.lt);
            }
        },
        .bt_scan => {
            st.busy_scan = false;
            refreshBt(st);
        },
    }
}

fn firstLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    return s[0..nl];
}

fn restartAppear(st: *State) void {
    for (&st.appear) |*a| a.snap(0);
}

pub fn refreshWifi(st: *State, rescan: bool) void {
    push(st, makeJob(.wifi_radio, &.{ "nmcli", "radio", "wifi" }, ""));
    push(st, makeJob(.wifi_saved, &.{ "nmcli", "-t", "-f", "NAME,TYPE", "connection", "show" }, ""));
    push(st, makeJob(.wifi_list, &.{ "nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", if (rescan) "yes" else "auto" }, ""));
    if (rescan) st.busy_scan = true;
}

pub fn refreshBt(st: *State) void {
    push(st, makeJob(.bt_show, &.{ "bluetoothctl", "show" }, ""));
    push(st, makeJob(.bt_all, &.{ "bluetoothctl", "devices" }, ""));
    push(st, makeJob(.bt_paired, &.{ "bluetoothctl", "devices", "Paired" }, ""));
    push(st, makeJob(.bt_connected, &.{ "bluetoothctl", "devices", "Connected" }, ""));
}

pub fn onOpen(f: *Frame) void {
    const st = &f.netv;
    st.frame = f;
    st.status_len = 0;
    st.editing = null;
    if (st.tab == 0) refreshWifi(st, false) else refreshBt(st);
}

fn connectWifi(st: *State, i: usize, with_pw: bool) void {
    const n = &st.nets[i];
    var msg: [96]u8 = undefined;
    const ok = std.fmt.bufPrint(&msg, "{s} に接続しました", .{n.name()}) catch "接続しました";
    setStatus(st, "接続しています…", false);
    if (with_pw) {
        push(st, makeJob(.wifi_connect, &.{ "nmcli", "dev", "wifi", "connect", n.name(), "password", st.pw[0..st.pw_len] }, ok));
        @memset(&st.pw, 0); // パスワードはメモリに残さない
        st.pw_len = 0;
    } else if (n.saved) {
        push(st, makeJob(.wifi_connect, &.{ "nmcli", "connection", "up", "id", n.name() }, ok));
    } else {
        push(st, makeJob(.wifi_connect, &.{ "nmcli", "dev", "wifi", "connect", n.name() }, ok));
    }
}

// ---------------------------------------------------------------------------
// 描画
// ---------------------------------------------------------------------------

pub fn size(f: *Frame) [2]f32 {
    const st = &f.netv;
    const n: usize = if (st.tab == 0) st.n_nets else st.n_devs;
    const rows: f32 = @floatFromInt(@min(@max(n, 1), 8));
    const want = LIST_Y + rows * ROW_H + st.edit_h.x * (EDIT_H - ROW_H) + 52;
    // 画面に収まる高さまで(はみ出す分はスクロール)
    return .{ W, @min(want, f.H - f.T() * 2 - 24) };
}

fn signalIcon(sig: u8) []const u8 {
    return if (sig >= 75) "\u{F0928}" else if (sig >= 50) "\u{F0925}" else if (sig >= 25) "\u{F0922}" else "\u{F091F}";
}

pub fn draw(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, dt: f32) bool {
    const st = &f.netv;
    st.frame = f;
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    var animating = false;
    st.tab_s.set(@floatFromInt(st.tab));
    st.sw[0].set(if (st.wifi_on) 1 else 0);
    st.sw[1].set(if (st.bt_on) 1 else 0);
    st.edit_h.set(if (st.editing != null) 1 else 0);
    var sp = [_]*Spring{ &st.tab_s, &st.sw[0], &st.sw[1], &st.edit_h };
    if (anim.stepAll(&sp, dt)) animating = true;

    // ---- タブ ----
    const tw = (w - 36) / 2;
    cv.rect(18, 14, w - 36, 36, 18, Color.hex(0xffffff).alpha(0.06));
    cv.rectGrad(18 + st.tab_s.x * tw + 3, 17, tw - 6, 30, 15, acc.lighten(0.3), acc);
    const labels = [2][]const u8{ "\u{F05A9}  Wi-Fi", "\u{F00AF}  Bluetooth" };
    for (labels, 0..) |l, i| {
        const on = std.math.clamp(1 - @abs(@as(f32, @floatFromInt(i)) - st.tab_s.x), 0, 1);
        _ = cv.text(18 + tw * @as(f32, @floatFromInt(i)) + tw / 2, 38, 13.5, Color.mix(txt, Color.hex(0x08101e), on), l, .{ .bold = true, .alignment = .center });
    }

    // ---- 電源スイッチとスキャン ----
    const is_wifi = st.tab == 0;
    const swv = st.sw[st.tab].x;
    _ = cv.text(22, 86, 14, txt, if (is_wifi) "Wi-Fi" else "Bluetooth", .{ .bold = true });
    const sx: f32 = 120;
    cv.rect(sx, 70, 46, 24, 12, Color.mix(Color.hex(0xffffff).alpha(0.15), acc, swv));
    cv.rect(sx + 3 + swv * 22, 73, 18, 18, 9, Color.hex(0xffffff));
    const hv_scan: f32 = if (st.hover == 201) 1 else 0;
    cv.rect(w - 118, 68, 100, 28, 14, acc.alpha(0.15 + 0.2 * hv_scan));
    _ = cv.text(w - 68, 87, 12.5, txt, if (st.busy_scan) "スキャン中…" else "\u{F0450} スキャン", .{ .alignment = .center });

    // ---- 一覧 ----
    const list_h = h - LIST_Y - 44;
    cv.setClip(0, LIST_Y - 4, w, list_h + 4);
    var y: f32 = LIST_Y - st.scroll;
    const n: usize = if (is_wifi) st.n_nets else st.n_devs;
    if (n == 0) {
        _ = cv.text(w / 2, LIST_Y + 30, 13, sub, if (st.running != null) "読み込み中…" else if (is_wifi and !st.wifi_on) "Wi-Fi はオフです" else if (!is_wifi and !st.bt_on) "Bluetooth はオフです" else "見つかりません", .{ .alignment = .center });
    }
    for (0..n) |i| {
        if (i == 0 or st.appear[i - 1].x > 0.3) st.appear[i].set(1);
        if (st.appear[i].step(dt)) animating = true;
        const a = st.appear[i].x;
        const editing = is_wifi and st.editing != null and st.editing.? == i;
        const rh = if (editing) ROW_H + st.edit_h.x * (EDIT_H - ROW_H) else ROW_H;
        const hv: f32 = if (st.hover == @as(i32, @intCast(i))) 1 else 0;
        cv.save();
        cv.translate((1 - a) * -24, 0);
        cv.opacity(a);
        cv.rect(12, y + 3, w - 24, rh - 6, 14, Color.hex(0xffffff).alpha(0.04 + 0.06 * hv + (if (editing) @as(f32, 0.05) else 0)));
        if (is_wifi) {
            const e = &st.nets[i];
            const col = if (e.active) acc.lighten(0.3) else txt;
            _ = cv.text(36, y + 32, 18, col, signalIcon(e.signal), .{ .alignment = .center });
            _ = cv.text(58, y + 23, 14, col, e.name(), .{ .bold = e.active, .max_w = w - 190 });
            var sb: [64]u8 = undefined;
            const s2 = std.fmt.bufPrint(&sb, "{s}{s}{d}%", .{ if (e.active) "接続中 ・ " else if (e.saved) "保存済み ・ " else "", if (e.secure) "\u{F033E} " else "", e.signal }) catch "";
            _ = cv.text(58, y + 41, 11.5, if (e.active) acc else sub, s2, .{});
            const btn = if (e.active) "切断" else "接続";
            cv.rect(w - 86, y + 12, 62, 26, 13, (if (e.active) Color.hex(0xff7a90) else acc).alpha(0.18 + 0.2 * hv));
            _ = cv.text(w - 55, y + 30, 12.5, txt, btn, .{ .alignment = .center });
            if (editing) {
                // パスワード入力欄(文字は伏せ字)
                const fy = y + 54;
                cv.rect(24, fy, w - 140, 32, 10, Color.hex(0x000000).alpha(0.3));
                cv.rectBorder(24, fy, w - 140, 32, 10, .{ .a = 0 }, acc.alpha(0.6), 1);
                var dots: [128]u8 = undefined;
                var nd: usize = 0;
                var k: usize = 0;
                while (k < st.pw_len and nd + 3 < dots.len) : (k += 1) {
                    if ((st.pw[k] & 0xC0) == 0x80) continue;
                    @memcpy(dots[nd .. nd + 3], "●");
                    nd += 3;
                }
                if (nd == 0) {
                    _ = cv.text(36, fy + 21, 12.5, sub.alpha(0.7), "パスワード(Enter で接続 / Esc で取消)", .{ .max_w = w - 170 });
                } else _ = cv.text(36, fy + 22, 11, txt, dots[0..nd], .{ .max_w = w - 170 });
                cv.rectGrad(w - 106, fy, 82, 32, 12, acc.lighten(0.3), acc);
                _ = cv.text(w - 65, fy + 21, 13, Color.hex(0x08101e), "接続", .{ .bold = true, .alignment = .center });
            }
        } else {
            const d = &st.devs[i];
            const col = if (d.connected) acc.lighten(0.3) else txt;
            _ = cv.text(36, y + 32, 18, col, if (d.connected) "\u{F00B1}" else "\u{F00AF}", .{ .alignment = .center });
            _ = cv.text(58, y + 23, 14, col, d.name(), .{ .bold = d.connected, .max_w = w - 190 });
            _ = cv.text(58, y + 41, 11.5, if (d.connected) acc else sub, if (d.connected) "接続中" else if (d.paired) "ペア済み" else "未ペア", .{});
            const btn = if (d.connected) "切断" else if (d.paired) "接続" else "ペア";
            cv.rect(w - 86, y + 12, 62, 26, 13, (if (d.connected) Color.hex(0xff7a90) else acc).alpha(0.18 + 0.2 * hv));
            _ = cv.text(w - 55, y + 30, 12.5, txt, btn, .{ .alignment = .center });
        }
        cv.restore();
        y += rh;
    }
    cv.setClip(0, 0, 0, 0);

    // ---- 状態表示 ----
    if (st.status_len > 0) {
        _ = cv.text(22, h - 18, 12, if (st.status_err) Color.hex(0xff8a9b) else acc.lighten(0.2), st.status[0..st.status_len], .{ .max_w = w - 44 });
    } else if (st.running != null) {
        _ = cv.text(22, h - 18, 12, sub, "更新中…", .{});
    }
    return animating or st.running != null;
}

// ---------------------------------------------------------------------------
// 入力
// ---------------------------------------------------------------------------

fn rowAt(st: *State, ly: f32) ?usize {
    var y: f32 = LIST_Y - st.scroll;
    const n: usize = if (st.tab == 0) st.n_nets else st.n_devs;
    for (0..n) |i| {
        const editing = st.tab == 0 and st.editing != null and st.editing.? == i;
        const rh = if (editing) EDIT_H else ROW_H;
        if (ly >= y and ly < y + rh) return i;
        y += rh;
    }
    return null;
}

pub fn pointer(f: *Frame, ev: surface.PointerEvent, lx: f32, ly: f32) bool {
    const st = &f.netv;
    st.frame = f;
    const w = W;
    var hov: i32 = -1;
    if (ev.kind != .leave) {
        if (ly >= 68 and ly < 96 and lx >= w - 118 and lx < w - 18) hov = 201 else if (ly >= LIST_Y) {
            if (rowAt(st, ly)) |i| hov = @intCast(i);
        }
    }
    const redraw = hov != st.hover;
    st.hover = hov;
    if (ev.kind == .scroll) {
        const n: usize = if (st.tab == 0) st.n_nets else st.n_devs;
        const visible = f.net.h.x - LIST_Y - 44;
        const max = @max(0, @as(f32, @floatFromInt(n)) * ROW_H + st.edit_h.x * (EDIT_H - ROW_H) - visible);
        st.scroll = std.math.clamp(st.scroll + ev.scroll * 3, 0, max);
        return true;
    }
    if (ev.kind != .press) return redraw;
    // タブ
    if (ly >= 14 and ly < 50) {
        const t: u8 = if (lx < w / 2) 0 else 1;
        if (t != st.tab) {
            st.tab = t;
            st.editing = null;
            st.scroll = 0;
            st.status_len = 0;
            if (t == 0) refreshWifi(st, false) else refreshBt(st);
        }
        return true;
    }
    // 電源スイッチ
    if (ly >= 66 and ly < 98 and lx >= 110 and lx < 176) {
        if (st.tab == 0) {
            st.wifi_on = !st.wifi_on;
            push(st, makeJob(.wifi_down, &.{ "nmcli", "radio", "wifi", if (st.wifi_on) "on" else "off" }, if (st.wifi_on) "Wi-Fi をオンにしました" else "Wi-Fi をオフにしました"));
        } else {
            st.bt_on = !st.bt_on;
            push(st, makeJob(.bt_power, &.{ "bluetoothctl", "power", if (st.bt_on) "on" else "off" }, if (st.bt_on) "Bluetooth をオンにしました" else "Bluetooth をオフにしました"));
        }
        return true;
    }
    if (hov == 201) {
        if (st.tab == 0) refreshWifi(st, true) else if (!st.busy_scan) {
            st.busy_scan = true;
            setStatus(st, "周囲のデバイスを探しています(10 秒)…", false);
            push(st, makeJob(.bt_scan, &.{ "bluetoothctl", "--timeout", "10", "scan", "on" }, ""));
        }
        return true;
    }
    const i = rowAt(st, ly) orelse return redraw;
    var msg: [96]u8 = undefined;
    if (st.tab == 0) {
        const e = &st.nets[i];
        const editing = st.editing != null and st.editing.? == i;
        if (editing and ly > LIST_Y - st.scroll) {
            // 編集中の行: 右下の「接続」ボタン
            if (lx >= w - 106) connectWifi(st, i, true);
            return true;
        }
        if (e.active) {
            setStatus(st, "切断しています…", false);
            push(st, makeJob(.wifi_down, &.{ "nmcli", "connection", "down", "id", e.name() }, std.fmt.bufPrint(&msg, "{s} から切断しました", .{e.name()}) catch "切断しました"));
        } else if (e.secure and !e.saved) {
            st.editing = i; // パスワード入力へ
            st.pw_len = 0;
            f.updateKeyboardPub();
        } else connectWifi(st, i, false);
    } else {
        const d = &st.devs[i];
        const mac: []const u8 = &d.mac;
        if (d.connected) {
            setStatus(st, "切断しています…", false);
            push(st, makeJob(.bt_action, &.{ "bluetoothctl", "disconnect", mac }, std.fmt.bufPrint(&msg, "{s} を切断しました", .{d.name()}) catch "切断しました"));
        } else if (d.paired) {
            setStatus(st, "接続しています…", false);
            push(st, makeJob(.bt_action, &.{ "bluetoothctl", "connect", mac }, std.fmt.bufPrint(&msg, "{s} に接続しました", .{d.name()}) catch "接続しました"));
        } else {
            // 未ペア: ペアリング → 信頼 → 接続 を順に(引数はシェル展開されない位置引数で渡す)
            setStatus(st, "ペアリングしています…", false);
            push(st, makeJob(.bt_action, &.{ "sh", "-c", "bluetoothctl pair \"$1\" && bluetoothctl trust \"$1\" && bluetoothctl connect \"$1\"", "ame-bt", mac }, std.fmt.bufPrint(&msg, "{s} とペアリングしました", .{d.name()}) catch "ペアリングしました"));
        }
    }
    return true;
}

/// キー入力(パネルを開いている間)。true を返したら処理済み
pub fn key(f: *Frame, ev: surface.KeyEvent) bool {
    const st = &f.netv;
    const i = st.editing orelse return false;
    switch (ev.sym) {
        c.XKB_KEY_Escape => {
            st.editing = null;
            @memset(&st.pw, 0);
            st.pw_len = 0;
        },
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => connectWifi(st, i, true),
        c.XKB_KEY_BackSpace => {
            if (ev.ctrl) st.pw_len = 0 else if (st.pw_len > 0) {
                var k = st.pw_len - 1;
                while (k > 0 and (st.pw[k] & 0xC0) == 0x80) k -= 1;
                st.pw_len = k;
            }
        },
        else => if (ev.utf8.len > 0 and ev.utf8[0] >= 0x20 and st.pw_len + ev.utf8.len < st.pw.len) {
            @memcpy(st.pw[st.pw_len .. st.pw_len + ev.utf8.len], ev.utf8);
            st.pw_len += ev.utf8.len;
        },
    }
    return true;
}
