// 枠の右側・角のドロワーの中身:
//   通知(右上)/ ユーティリティ(右下)/ サイドバー=通知センター(右)/ セッション(右中央)/
//   OSD(右中央、音量・明るさの縦スライダー)/ バーのポップアウト(左)
const std = @import("std");
const c = @import("../c.zig");
const anim = @import("../anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("../gfx.zig");
const theme = @import("../theme.zig");
const surface = @import("../surface.zig");
const sys = @import("../platform/sys.zig");
const data = @import("data.zig");
const vbar = @import("vbar.zig");
const Frame = @import("frame.zig").Frame;

pub const Which = enum { dashboard, launcher, notifs, utilities, sidebar, session, osd, popout, net };

pub const SessionAction = enum { lock, logout, sleep, reboot, poweroff };

pub const State = struct {
    hover: i32 = -1,
    hl: [12]Spring = [_]Spring{Spring.init(0, 0.2, 1.0)} ** 12,
    /// 危険な操作は 2 回押しで実行(1 回目で「もう一度押すと…」に変わる)
    confirm: ?SessionAction = null,
    sess_sel: usize = 0,
    osd_drag: i32 = -1,
    profile: data.Profile = .unknown,
    recording: bool = false,
    inhibit: bool = false,
    scroll: f32 = 0,
};

const session_items = [_]struct { a: SessionAction, icon: []const u8, label: []const u8 }{
    .{ .a = .lock, .icon = "\u{F033E}", .label = "ロック" },
    .{ .a = .logout, .icon = "\u{F0343}", .label = "ログアウト" },
    .{ .a = .sleep, .icon = "\u{F04B2}", .label = "スリープ" },
    .{ .a = .reboot, .icon = "\u{F0709}", .label = "再起動" },
    .{ .a = .poweroff, .icon = "\u{F0425}", .label = "電源オフ" },
};

// ---------------------------------------------------------------------------
// 通知(右上のドロワー)
// ---------------------------------------------------------------------------

const CARD_GAP: f32 = 8;

pub fn notifHeight(f: *Frame) f32 {
    var h: f32 = 0;
    for (f.app.notifs.active.items) |n| {
        if (n.leaving) continue;
        h += n.height + CARD_GAP;
    }
    return if (h > 0) h + 12 else 0;
}

/// 通知カードのスプリング(出入り・詰め)を進める。消え終わったカードの片付けを依頼。
pub fn stepNotifs(f: *Frame, dt: f32) bool {
    var animating = false;
    var y: f32 = 6;
    for (f.app.notifs.active.items) |*n| {
        if (!n.leaving) {
            n.ypos.set(y);
            y += n.height + CARD_GAP;
        }
        if (n.slide.step(dt)) animating = true;
        if (n.ypos.step(dt)) animating = true;
        if (n.leaving and n.slide.x > 0.98) f.app.reap_pending = true;
    }
    return animating;
}

fn drawNotifs(f: *Frame, cv: *gfx.Canvas, w: f32) bool {
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    for (app.notifs.active.items, 0..) |*n, i| {
        const t = n.slide.x;
        if (t > 0.99) continue;
        const y = n.ypos.x;
        const crit = n.urgency == 2;
        const col = if (crit) theme.danger(app) else acc;
        const hv: f32 = if (f.sidev.hover == @as(i32, @intCast(i))) 1 else 0;
        cv.save();
        cv.translate(t * (w + 20), 0);
        cv.opacity(1 - t);
        const x: f32 = 10;
        const cw = w - 20;
        cv.rect(x, y, cw, n.height, 14, Color.hex(0xffffff).alpha(0.05 + 0.04 * hv));
        cv.rectGrad(x + 8, y + 12, 3, n.height - 24, 1.5, col.lighten(0.3), col);
        _ = cv.text(x + 20, y + 24, 12, col, n.appName(), .{ .bold = true, .max_w = cw - 100 });
        _ = cv.text(x + cw - 12, y + 24, 11.5, sub, n.time_str[0..5], .{ .alignment = .right });
        _ = cv.text(x + 20, y + 47, 15, txt, n.summaryText(), .{ .bold = true, .max_w = cw - 34 });
        if (n.body_len > 0) cv.textWrap(x + 20, y + 69, 13, sub, n.bodyText(), cw - 34, 2, 18);
        cv.restore();
    }
    return false;
}

// ---------------------------------------------------------------------------
// ユーティリティ(右下): トグルと電源プロファイル、録画
// ---------------------------------------------------------------------------

const UtilBtn = enum(u8) { wifi, bt, dnd, inhibit, record, screenshot, saver, balanced, perf };

fn utilButtons(f: *Frame) [9]struct { b: UtilBtn, icon: []const u8, label: []const u8, on: bool } {
    const d = f.app.dashboard;
    return .{
        .{ .b = .wifi, .icon = "\u{F05A9}", .label = "Wi-Fi", .on = d.store.wifi_on != 0 },
        .{ .b = .bt, .icon = "\u{F00AF}", .label = "Bluetooth", .on = d.store.bt_on != 0 },
        .{ .b = .dnd, .icon = "\u{F009B}", .label = "通知停止", .on = d.dnd },
        .{ .b = .inhibit, .icon = "\u{F0176}", .label = "スリープ防止", .on = f.sidev.inhibit },
        .{ .b = .record, .icon = if (f.sidev.recording) "\u{F04DB}" else "\u{F044A}", .label = if (f.sidev.recording) "録画停止" else "録画", .on = f.sidev.recording },
        .{ .b = .screenshot, .icon = "\u{F0100}", .label = "スクショ", .on = false },
        .{ .b = .saver, .icon = "\u{F032A}", .label = "省電力", .on = f.sidev.profile == .saver },
        .{ .b = .balanced, .icon = "\u{F05D1}", .label = "バランス", .on = f.sidev.profile == .balanced },
        .{ .b = .perf, .icon = "\u{F0463}", .label = "高性能", .on = f.sidev.profile == .performance },
    };
}

fn utilRect(i: usize, w: f32) [4]f32 {
    const pad: f32 = 14;
    if (i < 6) {
        const bw = (w - pad * 2 - 2 * 8) / 3;
        const col: f32 = @floatFromInt(i % 3);
        const row: f32 = @floatFromInt(i / 3);
        return .{ pad + col * (bw + 8), 44 + row * 58, bw, 50 };
    }
    const bw = (w - pad * 2 - 2 * 8) / 3;
    const col: f32 = @floatFromInt(i - 6);
    return .{ pad + col * (bw + 8), 44 + 2 * 58 + 6, bw, 34 };
}

fn drawUtil(f: *Frame, cv: *gfx.Canvas, w: f32) bool {
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const st = &app.sys;
    var buf: [64]u8 = undefined;
    const bat = if (st.battery.present) (std.fmt.bufPrint(&buf, "バッテリー {d}%{s}", .{ st.battery.percent, if (st.battery.charging) "(充電中)" else "" }) catch "") else "バッテリーなし";
    _ = cv.text(16, 28, 13, txt, bat, .{ .bold = true });
    _ = cv.text(w - 16, 28, 11.5, sub, "ユーティリティ", .{ .alignment = .right });
    for (utilButtons(f), 0..) |b, i| {
        const r = utilRect(i, w);
        const hv: f32 = if (f.sidev.hover == @as(i32, @intCast(i))) 1 else 0;
        const top = if (b.on) acc.lighten(0.25) else Color.hex(0xffffff).alpha(0.06 + 0.08 * hv);
        const bot = if (b.on) acc else Color.hex(0xffffff).alpha(0.03 + 0.08 * hv);
        if (b.on) cv.shadow(r[0], r[1] + 2, r[2], r[3], 14, 8, acc.alpha(0.4));
        cv.rectGrad(r[0], r[1], r[2], r[3], 14, top, bot);
        const fg = if (b.on) Color.hex(0x08101e) else txt;
        if (i < 6) {
            _ = cv.text(r[0] + r[2] / 2, r[1] + 22, 17, fg, b.icon, .{ .alignment = .center });
            _ = cv.text(r[0] + r[2] / 2, r[1] + 41, 10.5, fg, b.label, .{ .alignment = .center, .max_w = r[2] - 8 });
        } else {
            _ = cv.text(r[0] + 18, r[1] + 23, 14, fg, b.icon, .{ .alignment = .center });
            _ = cv.text(r[0] + 32, r[1] + 22, 11, fg, b.label, .{ .max_w = r[2] - 36 });
        }
    }
    return false;
}

fn utilPress(f: *Frame, i: usize) void {
    const app = f.app;
    const b = utilButtons(f)[i].b;
    var out: [128]u8 = undefined;
    switch (b) {
        .wifi => {
            _ = sys.run(&.{ "nmcli", "radio", "wifi", if (app.dashboard.store.wifi_on != 0) "off" else "on" }, &out);
            app.dashboard.queryRadiosPub();
        },
        .bt => {
            _ = sys.run(&.{ "bluetoothctl", "power", if (app.dashboard.store.bt_on != 0) "off" else "on" }, &out);
            app.dashboard.queryRadiosPub();
            f.bar.bt_on = app.dashboard.store.bt_on != 0;
        },
        .dnd => app.dashboard.dnd = !app.dashboard.dnd,
        .inhibit => {
            f.sidev.inhibit = !f.sidev.inhibit;
            f.setIdleInhibit(f.sidev.inhibit);
        },
        .record => {
            // ユーザーの録画スクリプトがあればそれを使う(無ければ wf-recorder を直接)
            const home = std.posix.getenv("HOME") orelse "";
            var p: [512]u8 = undefined;
            const script = std.fmt.bufPrintZ(&p, "{s}/.local/bin/toggle-record.sh", .{home}) catch return;
            if (c.access(script.ptr, c.X_OK) == 0) {
                sys.spawnDetached(script.ptr);
            } else if (f.sidev.recording) {
                sys.spawnDetached("pkill -INT wf-recorder");
            } else {
                sys.spawnDetached("mkdir -p ~/Videos && wf-recorder -f ~/Videos/rec_$(date +%Y%m%d_%H%M%S).mp4");
            }
            f.sidev.recording = !f.sidev.recording;
        },
        .screenshot => {
            f.closeAll();
            sys.spawnDetached("sleep 0.4; mkdir -p ~/Pictures/Screenshots && grim -g \"$(slurp)\" ~/Pictures/Screenshots/shot_$(date +%Y%m%d_%H%M%S).png");
        },
        .saver => data.setPowerProfile(.saver),
        .balanced => data.setPowerProfile(.balanced),
        .perf => data.setPowerProfile(.performance),
    }
    if (b == .saver or b == .balanced or b == .perf) f.sidev.profile = data.powerProfile();
}

// ---------------------------------------------------------------------------
// サイドバー(通知センター)
// ---------------------------------------------------------------------------

fn drawSidebar(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32) bool {
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const hist = app.notifs.history.items;
    _ = cv.text(18, 34, 17, txt, "通知センター", .{ .bold = true });
    const hv_clear: f32 = if (f.sidev.hover == 100) 1 else 0;
    const hv_dnd: f32 = if (f.sidev.hover == 101) 1 else 0;
    cv.rect(w - 112, 14, 96, 28, 14, acc.alpha(0.15 + 0.2 * hv_clear));
    _ = cv.text(w - 64, 33, 12, txt, "すべて消去", .{ .alignment = .center });
    const dnd = app.dashboard.dnd;
    cv.rect(w - 160, 14, 40, 28, 14, (if (dnd) Color.hex(0xffb35c) else Color.hex(0xffffff)).alpha(if (dnd) 0.8 else 0.06 + 0.1 * hv_dnd));
    _ = cv.text(w - 140, 34, 15, if (dnd) Color.hex(0x08101e) else txt, "\u{F009B}", .{ .alignment = .center });
    var y: f32 = 58 - f.sidev.scroll;
    if (hist.len == 0) {
        _ = cv.text(w / 2, h / 2 - 10, 40, sub.alpha(0.6), "\u{F009A}", .{ .alignment = .center });
        _ = cv.text(w / 2, h / 2 + 24, 14, sub, "通知はありません", .{ .alignment = .center });
        return false;
    }
    for (hist) |n| {
        if (y > h) break;
        if (y + 70 > 50) {
            cv.rect(12, y, w - 24, 66, 14, Color.hex(0xffffff).alpha(0.05));
            _ = cv.text(26, y + 21, 11.5, acc, n.appName(), .{ .bold = true, .max_w = w - 110 });
            _ = cv.text(w - 26, y + 21, 11, sub, n.time_str[0..5], .{ .alignment = .right });
            _ = cv.text(26, y + 41, 14, txt, n.summaryText(), .{ .bold = true, .max_w = w - 52 });
            _ = cv.text(26, y + 58, 12, sub, n.bodyText(), .{ .max_w = w - 52 });
        }
        y += 74;
    }
    return false;
}

// ---------------------------------------------------------------------------
// セッション(右中央、縦に大きなボタン)
// ---------------------------------------------------------------------------

fn drawSession(f: *Frame, cv: *gfx.Canvas, w: f32) bool {
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    for (session_items, 0..) |it, i| {
        const y = 12 + @as(f32, @floatFromInt(i)) * 76;
        const hv: f32 = if (f.sidev.hover == @as(i32, @intCast(i)) or (f.session.by_key and f.sidev.sess_sel == i)) 1 else 0;
        const armed = f.sidev.confirm == it.a;
        const danger = it.a == .reboot or it.a == .poweroff;
        const base = if (armed) theme.danger(app) else if (danger) Color.mix(acc, theme.danger(app), 0.4) else acc;
        const s = 64 + 4 * hv;
        const x = w / 2 - s / 2 - 4;
        if (hv > 0 or armed) cv.shadow(x, y + 2, s, s, s * 0.32, 10, base.alpha(0.45));
        cv.rectGrad(x, y, s, s, s * 0.32, base.alpha(0.18 + 0.5 * hv + (if (armed) @as(f32, 0.5) else 0)), base.alpha(0.10 + 0.4 * hv));
        _ = cv.text(x + s / 2, y + s / 2 + 4, 24, if (armed) Color.hex(0x08101e) else Color.mix(txt, base, 0.3), it.icon, .{ .alignment = .center });
        _ = cv.text(x + s / 2, y + s - 6, 9.5, if (armed) Color.hex(0x08101e) else txt, if (armed) "もう一度" else it.label, .{ .alignment = .center });
    }
    return false;
}

fn runSession(f: *Frame, a: SessionAction) void {
    const app = f.app;
    // ロック以外は取り返しがつかないので、同じボタンを 2 回押したときだけ実行する
    if (a != .lock and f.sidev.confirm != a) {
        f.sidev.confirm = a;
        return;
    }
    f.sidev.confirm = null;
    f.closeAll();
    switch (a) {
        .lock => _ = app.lock.lock(),
        .logout => app.riverCommand(&.{"exit"}),
        .sleep => {
            _ = app.lock.lock();
            sys.spawnDetached("sleep 1; loginctl suspend");
        },
        .reboot => sys.spawnDetached("loginctl reboot"),
        .poweroff => sys.spawnDetached("loginctl poweroff"),
    }
}

pub fn sessionKey(f: *Frame, ev: surface.KeyEvent) void {
    switch (ev.sym) {
        c.XKB_KEY_Down, c.XKB_KEY_j, c.XKB_KEY_Tab => f.sidev.sess_sel = @min(f.sidev.sess_sel + 1, session_items.len - 1),
        c.XKB_KEY_Up, c.XKB_KEY_k => f.sidev.sess_sel -|= 1,
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_space => runSession(f, session_items[f.sidev.sess_sel].a),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// OSD(右中央、音量と明るさの縦スライダー。ドラッグ・ホイールで操作)
// ---------------------------------------------------------------------------

fn drawOsd(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32) bool {
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const has_bri = app.sys.brightness != null;
    const vals = [2]f32{ if (app.sys.volume.muted) 0 else app.sys.volume.level, app.sys.brightness orelse 0 };
    const icons = [2][]const u8{ if (app.sys.volume.muted) "\u{F075F}" else "\u{F057E}", "\u{F00E0}" };
    const n: usize = if (has_bri) 2 else 1;
    const sh = (h - 24) / @as(f32, @floatFromInt(n)) - 10;
    for (0..n) |i| {
        const y = 12 + @as(f32, @floatFromInt(i)) * (sh + 10);
        const x = w / 2 - 14;
        const v = std.math.clamp(vals[i], 0, 1);
        const track_h = sh - 34;
        cv.rect(x, y, 28, track_h, 14, Color.hex(0xffffff).alpha(0.08));
        cv.shadow(x, y + track_h * (1 - v), 28, track_h * v, 14, 8, acc.alpha(0.4));
        cv.rectGrad(x, y + track_h * (1 - v), 28, @max(track_h * v, 28), 14, acc.lighten(0.3), acc);
        cv.rect(x + 7, y + track_h * (1 - v) + 4, 14, 4, 2, Color.hex(0xffffff).alpha(0.9));
        _ = cv.text(w / 2, y + track_h + 26, 17, txt, icons[i], .{ .alignment = .center });
    }
    return false;
}

fn osdSet(f: *Frame, i: i32, ly: f32) void {
    const app = f.app;
    const has_bri = app.sys.brightness != null;
    const n: f32 = if (has_bri) 2 else 1;
    const sh = (f.osd.h.x - 24) / n - 10;
    const y = 12 + @as(f32, @floatFromInt(i)) * (sh + 10);
    const v = std.math.clamp(1 - (ly - y) / (sh - 34), 0, 1);
    if (i == 0) {
        sys.setVolume(v);
        app.sys.volume = sys.volume();
        app.redrawBars();
    } else {
        var arg: [16]u8 = undefined;
        const a = std.fmt.bufPrintZ(&arg, "{d}%", .{@as(u32, @intFromFloat(@max(v, 0.01) * 100))}) catch return;
        var out: [8]u8 = undefined;
        _ = sys.run(&.{ "brightnessctl", "-q", "set", a.ptr }, &out);
        app.sys.brightness = sys.brightness();
    }
}

// ---------------------------------------------------------------------------
// 共通の入口
// ---------------------------------------------------------------------------

pub fn draw(f: *Frame, which: Which, cv: *gfx.Canvas, w: f32, h: f32, dt: f32) bool {
    return switch (which) {
        .notifs => drawNotifs(f, cv, w),
        .utilities => drawUtil(f, cv, w),
        .sidebar => drawSidebar(f, cv, w, h),
        .session => drawSession(f, cv, w),
        .osd => drawOsd(f, cv, w, h),
        .popout => vbar.drawPopout(f, cv, w, h),
        .net => @import("netpanel.zig").draw(f, cv, w, h, dt),
        else => false,
    };
}

pub fn pointer(f: *Frame, which: Which, ev: surface.PointerEvent, lx: f32, ly: f32) bool {
    const app = f.app;
    const st = &f.sidev;
    var hov: i32 = -1;
    if (ev.kind != .leave) switch (which) {
        .notifs => {
            for (app.notifs.active.items, 0..) |n, i| {
                if (!n.leaving and ly >= n.ypos.x and ly < n.ypos.x + n.height) hov = @intCast(i);
            }
        },
        .utilities => {
            for (0..9) |i| {
                const r = utilRect(i, f.util.w.x);
                if (lx >= r[0] and lx < r[0] + r[2] and ly >= r[1] and ly < r[1] + r[3]) hov = @intCast(i);
            }
        },
        .session => {
            if (ly >= 12) {
                const i: i32 = @intFromFloat((ly - 12) / 76);
                if (i >= 0 and i < session_items.len) hov = i;
            }
        },
        .sidebar => {
            const w = f.side.w.x;
            if (ly >= 14 and ly < 42 and lx >= w - 112 and lx < w - 16) hov = 100;
            if (ly >= 14 and ly < 42 and lx >= w - 160 and lx < w - 120) hov = 101;
        },
        .osd => {
            const n: f32 = if (app.sys.brightness != null) 2 else 1;
            const sh = (f.osd.h.x - 24) / n - 10;
            hov = @intFromFloat(@max(0, (ly - 12) / (sh + 10)));
        },
        else => {},
    };
    const redraw = hov != st.hover;
    st.hover = hov;
    if (which == .notifs) app.notifs.hover_idx = if (hov >= 0) @intCast(hov) else null;
    switch (ev.kind) {
        .press => switch (which) {
            .notifs => if (hov >= 0) {
                const n = app.notifs.active.items[@intCast(hov)];
                app.notifs.dismiss(n.id, 2);
            },
            .utilities => if (hov >= 0) utilPress(f, @intCast(hov)),
            .session => if (hov >= 0) runSession(f, session_items[@intCast(hov)].a),
            .sidebar => {
                if (hov == 100) app.notifs.clearAll();
                if (hov == 101) app.dashboard.dnd = !app.dashboard.dnd;
            },
            .osd => if (hov >= 0) {
                st.osd_drag = hov;
                osdSet(f, hov, ly);
            },
            .popout => switch (f.pop_kind) {
                .clock => f.toggleDashboard(),
                .network => f.toggleNet(0),
                .bluetooth => f.toggleNet(1),
                .battery => f.toggleUtilities(),
                .volume => {
                    sys.toggleMute();
                    app.sys.volume = sys.volume();
                },
                else => {},
            },
            else => {},
        },
        .motion => if (which == .osd and st.osd_drag >= 0 and f.pressed) osdSet(f, st.osd_drag, ly),
        .release, .leave => st.osd_drag = -1,
        .scroll => switch (which) {
            .osd => if (hov == 0) {
                sys.setVolumeDelta(if (ev.scroll < 0) 3 else -3);
                app.sys.volume = sys.volume();
                app.redrawBars();
            } else if (hov == 1) {
                sys.setBrightnessDelta(if (ev.scroll < 0) 3 else -3);
                app.sys.brightness = sys.brightness();
            },
            .sidebar => {
                const max = @max(0, @as(f32, @floatFromInt(app.notifs.history.items.len)) * 74 + 70 - f.side.h.x);
                st.scroll = std.math.clamp(st.scroll + ev.scroll * 3, 0, max);
            },
            .popout => if (f.pop_kind == .volume) {
                sys.setVolumeDelta(if (ev.scroll < 0) 3 else -3);
                app.sys.volume = sys.volume();
            },
            else => {},
        },
        else => {},
    }
    return redraw or ev.kind == .press or ev.kind == .scroll or (which == .osd and st.osd_drag >= 0);
}
