// AirPods をつないだときのカード(iPhone / iPad で AirPods をつなぐと下から出る、あれ)。
//
//   画面の下の真ん中から、ガラスのカードがポンと上がる。名前・「接続しました」・AirPods の絵(左右のイヤホンとケース)、
//   その下に左・右・ケースの電池の残り(リングと %、充電中は稲妻)。約 6 秒で下へ沈んで消える。押すとすぐ消える。
//
// 電池の残りは AirPods の AAP(airpods.zig と同じ L2CAP の接続)で読む: つないで handshake と通知の依頼を送ると、
// 電池のパケットが届く。読めるまでは「…」。BlueZ の Device1 の Connected が true になったときに syswatch.zig から呼ぶ。
// 設定: airpods { popup off } で出さない(そのときは今までどおり「ヘッドホンを接続しました」の通知)。Linux のみ。
const std = @import("std");
const anim = @import("../gfx/anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const appmod = @import("../core/app.zig");
const App = appmod.App;
const Output = appmod.Output;
const c = @import("../c.zig");
const gfx = @import("../gfx/gfx.zig");
const theme = @import("../gfx/theme.zig");
const loop = @import("../platform/loop.zig");
const surface = @import("../core/surface.zig");
const Surface = surface.Surface;
const ap = @import("airpods.zig");

const W: u32 = 520;
const H: u32 = 330;
const CARD_W: f32 = 440;
const CARD_H: f32 = 268;
const SHOW_MS = 6000;

const white = Color.hex(0xffffff);
const black = Color.hex(0x000000);
const I_BOLT = "\u{F140B}";

pub const Popup = struct {
    app: *App,
    surf: ?*Surface = null,
    out: ?*Output = null,
    show_s: Spring = Spring.init(0, 0.42, 0.72),
    visible: bool = false,
    hide_timer: loop.Timer,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    batt: ap.Batteries = .{ .{}, .{}, .{} },
    have_batt: bool = false,
    /// 電池を読むスレッド
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rfd: c_int = -1,
    wfd: c_int = -1,
    addr: [17]u8 = undefined,
    /// 電池のリングが満ちていく
    fill: Spring = Spring.init(0, 0.6, 0.9),

    pub fn create(app: *App) !*Popup {
        const self = try app.alloc.create(Popup);
        self.* = .{ .app = app, .hide_timer = try loop.Timer.init() };
        try app.loop.add(self.hide_timer.fd, c.EPOLLIN, self, onHide);
        return self;
    }

    /// AirPods がつながった。addr は "AA:BB:…"
    pub fn show(self: *Popup, addr: []const u8, name: []const u8) void {
        const app = self.app;
        if (!ap.supported or app.lock.locked or addr.len != 17) return;
        self.stopWorker();
        @memcpy(&self.addr, addr[0..17]);
        self.name_len = @min(name.len, self.name.len);
        @memcpy(self.name[0..self.name_len], name[0..self.name_len]);
        self.batt = .{ .{}, .{}, .{} };
        self.have_batt = false;
        self.fill.snap(0);
        if (self.surf == null) {
            const out = app.activeOutput() orelse return;
            self.surf = Surface.createLayer(app, .{ .ctx = self, .draw = draw, .pointer = pointer, .configured = configured }, .{
                .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
                .anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM,
                .width = W,
                .height = H,
                .margin = .{ 0, 0, 10, 0 },
                .namespace = "ame-airpods",
                .output = out.wl,
            }) catch return;
            self.out = out;
            self.surf.?.output = out;
            self.show_s.snap(0);
        }
        // クリックはカードの上だけ
        const cx: i32 = @intFromFloat((@as(f32, W) - CARD_W) / 2);
        const cy: i32 = @intFromFloat(@as(f32, H) - CARD_H - 30);
        self.surf.?.setInputRect(cx, cy, @intFromFloat(CARD_W), @intFromFloat(CARD_H));
        self.visible = true;
        self.show_s.set(1);
        self.hide_timer.arm(SHOW_MS, 0);
        self.startWorker();
        self.surf.?.schedule();
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        const self: *Popup = @ptrCast(@alignCast(ctx));
        const o = self.out orelse return;
        const sz = o.logicalSize();
        s.origin = .{ (@as(f32, @floatFromInt(sz[0])) - W) / 2, @as(f32, @floatFromInt(sz[1])) - 10 - H };
    }

    fn hide(self: *Popup) void {
        self.visible = false;
        self.show_s.set(0);
        self.hide_timer.disarm();
        self.stopWorker();
        if (self.surf) |s| {
            s.setInputRect(0, 0, 0, 0);
            s.schedule();
        }
    }

    fn onHide(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *Popup = @ptrCast(@alignCast(ctx));
        self.hide_timer.ack();
        self.hide();
    }

    pub fn reap(self: *Popup) void {
        if (self.surf == null or self.visible or self.show_s.x > 0.01 or self.show_s.moving()) return;
        self.surf.?.destroy();
        self.surf = null;
        self.out = null;
    }

    pub fn outputRemoved(self: *Popup, o: *Output) void {
        if (self.out != o) return;
        self.stopWorker();
        if (self.surf) |s| s.destroy();
        self.surf = null;
        self.out = null;
        self.visible = false;
    }

    pub fn backdropChanged(self: *Popup) void {
        if (self.surf) |s| s.schedule();
    }

    // ---- 電池を読むスレッド ----

    const Msg = extern struct { lv: [3]u8, chg: [3]u8 };

    fn startWorker(self: *Popup) void {
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return;
        self.rfd = fds[0];
        self.wfd = fds[1];
        self.app.loop.add(self.rfd, c.EPOLLIN, self, onMsg) catch {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            self.rfd = -1;
            self.wfd = -1;
            return;
        };
        self.quit.store(false, .release);
        self.thread = std.Thread.spawn(.{ .stack_size = 128 << 10 }, worker, .{self}) catch null;
    }

    fn stopWorker(self: *Popup) void {
        if (self.thread) |t| {
            self.quit.store(true, .release);
            t.join();
            self.thread = null;
        }
        if (self.rfd >= 0) {
            self.app.loop.remove(self.rfd);
            _ = c.close(self.rfd);
            _ = c.close(self.wfd);
        }
        self.rfd = -1;
        self.wfd = -1;
    }

    fn onMsg(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Popup = @ptrCast(@alignCast(ctx));
        var m: Msg = undefined;
        while (c.read(fd, &m, @sizeOf(Msg)) == @sizeOf(Msg)) {
            for (0..3) |i| self.batt[i] = .{ .level = if (m.lv[i] == 255) null else m.lv[i], .charging = m.chg[i] != 0 };
            self.have_batt = true;
            self.fill.snap(0);
            self.fill.set(1);
        }
        if (self.surf) |s| s.schedule();
    }

    fn worker(self: *Popup) void {
        // つないだ直後は AAP がまだ開かないことがあるので、何度か試す
        var tries: u32 = 0;
        while (tries < 4 and !self.quit.load(.acquire)) : (tries += 1) {
            if (tries > 0) std.time.sleep(800 * std.time.ns_per_ms);
            const fd = ap.connectL2cap(&self.addr, &self.quit) orelse continue;
            defer _ = c.close(fd);
            if (!ap.sendPkt(fd, &ap.HANDSHAKE)) continue;
            std.time.sleep(200 * std.time.ns_per_ms);
            _ = ap.sendPkt(fd, &ap.REQUEST_NOTIFICATIONS);
            var buf: [512]u8 = undefined;
            const t0 = std.time.milliTimestamp();
            while (std.time.milliTimestamp() - t0 < 3000 and !self.quit.load(.acquire)) {
                var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
                const n = std.posix.poll(&pfd, 200) catch break;
                if (n == 0) continue;
                const r = c.recv(fd, &buf, buf.len, 0);
                if (r <= 0) break;
                var b: ap.Batteries = undefined;
                if (!ap.parseBattery(buf[0..@intCast(r)], &b)) continue;
                var m = Msg{ .lv = .{ 255, 255, 255 }, .chg = .{ 0, 0, 0 } };
                for (0..3) |i| {
                    if (b[i].level) |l| m.lv[i] = l;
                    m.chg[i] = @intFromBool(b[i].charging);
                }
                _ = c.write(self.wfd, &m, @sizeOf(Msg));
                return;
            }
        }
    }

    // ---- 描画 ----

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *Popup = @ptrCast(@alignCast(ctx));
        _ = s;
        const app = self.app;
        var springs = [_]*Spring{ &self.show_s, &self.fill };
        const moving = anim.stepAll(&springs, dt);
        const e = self.show_s.x;
        if (!self.visible and !moving and e < 0.01) {
            app.reap_pending = true;
            return false;
        }
        const acc = theme.accent(app);
        const txt = theme.text(app);
        const sub = theme.subtext(app);
        const x = (@as(f32, W) - CARD_W) / 2;
        const y0 = @as(f32, H) - CARD_H - 30;
        // 下から上がってくる(少し行き過ぎて戻る)
        const y = y0 + (1 - e) * (CARD_H + 40);
        cv.save();
        cv.opacity(std.math.clamp(e * 1.4, 0, 1));
        cv.shadow(x, y + 14, CARD_W, CARD_H, 34, 40, black.alpha(0.45));
        cv.glass(x, y, CARD_W, CARD_H, 34, theme.glassStrong(app));
        cv.rectBorder(x, y, CARD_W, CARD_H, 34, .{ .a = 0 }, white.alpha(0.14), 1);

        // 上: 名前と「接続しました」
        const mid = x + CARD_W / 2;
        _ = cv.text(mid, y + 38, 18, txt, self.name[0..self.name_len], .{ .bold = true, .alignment = .center, .max_w = CARD_W - 40 });
        _ = cv.text(mid, y + 60, 13, sub, "接続しました", .{ .alignment = .center });

        // 真ん中: AirPods の絵(左右のイヤホンとケース)
        drawBuds(cv, mid - 72, y + 120, 1);
        drawCase(cv, mid + 78, y + 128);

        // 下: 左・右・ケースの電池
        const labels = [_][]const u8{ "左", "右", "ケース" };
        const cols = [_]f32{ mid - 100, mid - 44, mid + 78 };
        for (0..3) |i| drawBattery(cv, cols[i], y + 218, labels[i], self.batt[i], self.have_batt, self.fill.x, acc, txt, sub);
        cv.restore();
        return moving or self.visible and e < 0.999;
    }

    fn pointer(ctx: *anyopaque, _: *Surface, ev: surface.PointerEvent) void {
        const self: *Popup = @ptrCast(@alignCast(ctx));
        if (ev.kind == .press) self.hide();
    }
};

/// 左右のイヤホン(白い丸い頭と、下へ伸びる軸)。cx は 2 つの真ん中、cy は頭の高さ
fn drawBuds(cv: *gfx.Canvas, cx: f32, cy: f32, s: f32) void {
    for ([_]f32{ -1, 1 }) |side| {
        const hx = cx + side * 26 * s;
        // 軸(外側へ少し傾けたかわりに、外側へずらす)
        const sx = hx + side * 9 * s;
        cv.shadow(sx - 6 * s, cy + 4 * s, 12 * s, 52 * s, 6 * s, 8, black.alpha(0.35));
        cv.rectGrad(sx - 6 * s, cy + 2 * s, 12 * s, 52 * s, 6 * s, Color.hex(0xffffff), Color.hex(0xd9dde4));
        // 軸の先の金具
        cv.rect(sx - 4 * s, cy + 46 * s, 8 * s, 6 * s, 3 * s, Color.hex(0xa9afb9));
        // 頭
        cv.shadow(hx - 19 * s, cy - 20 * s, 38 * s, 36 * s, 18 * s, 10, black.alpha(0.35));
        cv.rectGrad(hx - 19 * s, cy - 20 * s, 38 * s, 36 * s, 18 * s, Color.hex(0xffffff), Color.hex(0xe2e5ea));
        // 耳に入る黒いメッシュ(内側)
        cv.rect(hx - side * 7 * s - 6 * s, cy - 8 * s, 12 * s, 10 * s, 5 * s, Color.hex(0x2b2f36));
        // 光の当たり
        cv.rect(hx - 10 * s, cy - 16 * s, 14 * s, 5 * s, 2.5 * s, white.alpha(0.8));
    }
}

/// 充電ケース(角の丸い白い箱。ふたの線と、前の小さなランプ)。cx, cy は真ん中
fn drawCase(cv: *gfx.Canvas, cx: f32, cy: f32) void {
    const w: f32 = 86;
    const h: f32 = 68;
    cv.shadow(cx - w / 2, cy - h / 2 + 6, w, h, 22, 14, black.alpha(0.4));
    cv.rectGrad(cx - w / 2, cy - h / 2, w, h, 22, Color.hex(0xffffff), Color.hex(0xd6dae1));
    // ふたの境目
    cv.rect(cx - w / 2 + 3, cy - h / 2 + h * 0.34, w - 6, 1.2, 0.6, Color.hex(0x9aa1ac).alpha(0.8));
    // ランプ
    cv.rect(cx - 2.5, cy + h * 0.12, 5, 5, 2.5, Color.hex(0x34c759));
    cv.rect(cx - w / 2 + 8, cy - h / 2 + 5, w * 0.5, 4, 2, white.alpha(0.85));
}

/// 電池: リング(残り)と、中の % か稲妻。下に名前
fn drawBattery(cv: *gfx.Canvas, cx: f32, cy: f32, label: []const u8, b: ap.Battery, have: bool, fill: f32, acc: Color, txt: Color, sub: Color) void {
    _ = acc;
    const r: f32 = 20;
    if (b.level) |lv| {
        const f = @as(f32, @floatFromInt(lv)) / 100 * fill;
        const col = if (b.charging) Color.hex(0x34c759) else if (lv <= 20) Color.hex(0xff9f0a) else Color.hex(0x34c759);
        cv.arc(cx, cy, r, 4.5, 1, white.alpha(0.14), .{ .a = 0 });
        cv.arc(cx, cy, r, 4.5, f, col, .{ .a = 0 });
        if (b.charging) {
            _ = cv.text(cx, cy + 6, 15, col, I_BOLT, .{ .alignment = .center });
        } else {
            var pb: [8]u8 = undefined;
            _ = cv.text(cx, cy + 4.5, 12, txt, std.fmt.bufPrint(&pb, "{d}", .{lv}) catch "", .{ .bold = true, .alignment = .center });
        }
        var lb: [24]u8 = undefined;
        const s = if (b.charging) (std.fmt.bufPrint(&lb, "{s} {d}%", .{ label, lv }) catch label) else label;
        _ = cv.text(cx, cy + r + 20, 12, sub, s, .{ .alignment = .center });
    } else {
        cv.arc(cx, cy, r, 4.5, 1, white.alpha(0.10), .{ .a = 0 });
        _ = cv.text(cx, cy + 4.5, 12, sub, if (have) "–" else "…", .{ .alignment = .center });
        _ = cv.text(cx, cy + r + 20, 12, sub, label, .{ .alignment = .center });
    }
}
