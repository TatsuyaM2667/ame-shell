// ダイナミックアイランド: 枠の上の中央から生える小さな島。状況に合わせて、ばねで伸び縮みする。
//   ふだん      … AI の目(ときどきまばたき・きょろきょろ。カーソルが近づくとそちらを見る)。押すと AI チャット
//   再生中      … ジャケットと曲名と目。乗せると広がって、進み具合と 前 / 再生 / 次
//   通知        … 4 秒だけ広がって、アプリ名と要約(目は嬉しい形)。押すと通知センター
//   AI の作業中 … 回るしるし(終わったら「終わりました」を少し出す)。押すと AI チャット
//   録画中      … 赤い点と経過時間
// 待機中に描き続けない: まばたき・よそ見・表示を戻す時刻は timerfd で「次に変わる時刻」にだけ起きる。
// 目はカーソル(WM のカーソル位置)を見る。しばらく動かさなければ、また自分できょろきょろする。
const std = @import("std");
const anim = @import("../anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("../gfx.zig");
const theme = @import("../theme.zig");
const surface = @import("../surface.zig");
const loop = @import("../platform/loop.zig");
const App = @import("../app.zig").App;
const Frame = @import("frame.zig").Frame;

const PEEK_MS = 4000;
const DONE_MS = 3000;
const BLINK_MS = 170;
/// カーソルが止まってから、また自分できょろきょろし始めるまで
const IDLE_MS = 4000;

const Peek = enum { none, notif, done };

const State = struct {
    timer: ?loop.Timer = null,
    app: ?*App = null,
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(1),
    // 目
    look_x: Spring = Spring.init(0, 0.22, 0.8),
    look_y: Spring = Spring.init(0, 0.22, 0.8),
    next_blink: u64 = 0,
    blink_t0: u64 = 0,
    next_glance: u64 = 0,
    following: bool = false,
    last_move: u64 = 0,
    // 一時的に広げる
    peek: Peek = .none,
    peek_until: u64 = 0,
    peek_app: [64]u8 = undefined,
    peek_app_len: usize = 0,
    peek_text: [200]u8 = undefined,
    peek_text_len: usize = 0,
    was_busy: bool = false,
    busy_name: [64]u8 = undefined,
    busy_name_len: usize = 0,
    rec_since: u64 = 0,
    hover: bool = false,
    hover_btn: i8 = -1,
};

var st: State = .{};

fn set(buf: []u8, len: *usize, s: []const u8) void {
    var n = @min(s.len, buf.len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1; // UTF-8 の途中で切らない
    @memcpy(buf[0..n], s[0..n]);
    len.* = n;
}

fn ensure(app: *App) void {
    if (st.timer != null) return;
    st.app = app;
    st.rng = std.Random.DefaultPrng.init(loop.nowMs());
    st.timer = loop.Timer.init() catch return;
    app.loop.add(st.timer.?.fd, @import("../c.zig").EPOLLIN, &st, onTimer) catch {};
    const now = loop.nowMs();
    st.next_blink = now + 2500;
    st.next_glance = now + 6000;
    arm();
}

fn redrawAll() void {
    const app = st.app orelse return;
    for (app.outputs.items) |o| if (o.frame) |f| f.schedule();
}

/// 次に起きる時刻(まばたき・よそ見・表示を戻す)にタイマーを合わせる
fn arm() void {
    const t = st.timer orelse return;
    const now = loop.nowMs();
    var next = @min(st.next_blink, st.next_glance);
    if (st.peek != .none) next = @min(next, st.peek_until);
    if (st.rec_since != 0) next = @min(next, now + 1000 - (now - st.rec_since) % 1000);
    if (st.following) next = @min(next, st.last_move + IDLE_MS);
    t.arm(@max(1, next -| now), 0);
}

fn onTimer(_: *anyopaque, _: c_int, _: u32) void {
    if (st.timer) |t| t.ack();
    const now = loop.nowMs();
    const r = st.rng.random();
    // カーソルが止まって少したった: 前を向いて、また自分できょろきょろ
    if (st.following and now >= st.last_move + IDLE_MS) {
        st.following = false;
        st.look_x.set(0);
        st.look_y.set(0);
        st.next_glance = now + 1500;
    }
    if (now >= st.next_blink) {
        st.blink_t0 = now;
        // ときどき 2 回続けてまばたき
        st.next_blink = now + if (r.float(f32) < 0.2) @as(u64, 260) else 2200 + r.uintLessThan(u64, 4200);
    }
    if (now >= st.next_glance) {
        if (!st.following) {
            // よそ見: たまに左右や上を見て、また前を向く
            if (st.look_x.target == 0 and st.look_y.target == 0) {
                st.look_x.set((r.float(f32) * 2 - 1) * 0.9);
                st.look_y.set((r.float(f32) * 2 - 1) * 0.5);
                st.next_glance = now + 900 + r.uintLessThan(u64, 900);
            } else {
                st.look_x.set(0);
                st.look_y.set(0);
                st.next_glance = now + 5000 + r.uintLessThan(u64, 7000);
            }
        } else st.next_glance = now + 4000;
    }
    if (st.peek != .none and now >= st.peek_until) st.peek = .none;
    arm();
    redrawAll();
}

// ---------------------------------------------------------------------------
// 外からの合図
// ---------------------------------------------------------------------------

/// 通知が来た(notify.zig)
pub fn peekNotif(app: *App, app_name: []const u8, summary: []const u8) void {
    if (!app.cfg.island) return;
    ensure(app);
    st.peek = .notif;
    st.peek_until = loop.nowMs() + PEEK_MS;
    set(&st.peek_app, &st.peek_app_len, app_name);
    set(&st.peek_text, &st.peek_text_len, summary);
    arm();
    redrawAll();
}

/// WM のカーソルの位置(グローバル)。島の近くなら目で追う
pub fn pointerMoved(app: *App, outs: anytype, gx: i32, gy: i32) void {
    if (!app.cfg.island or st.timer == null) return;
    const was = st.following;
    st.following = true;
    st.last_move = loop.nowMs();
    if (!was) arm(); // 止まったら戻るための時刻
    for (outs) |wo| {
        const ao = wo.ame orelse continue;
        const f = ao.frame orelse continue;
        if (!f.island.visible()) continue;
        lookAt(f, @as(f32, @floatFromInt(gx - wo.x)), @as(f32, @floatFromInt(gy - wo.y)));
    }
}

/// ame-shell のサーフェス(壁紙・枠)の上のカーソル。窓の上の動きは WM から(窓に入ったときなど)しか届かない
pub fn surfacePointer(app: *App, s: *const @import("../surface.zig").Surface, x: f32, y: f32) void {
    if (!app.cfg.island or st.timer == null) return;
    const ao: *@import("../app.zig").Output = @ptrCast(@alignCast(s.output orelse return));
    const f = ao.frame orelse return;
    // 画面全体を覆う面(枠・壁紙)だけ: 座標が画面の論理座標そのまま
    const full = s == f.surf or (if (ao.wall) |w| s == w.surf else false);
    if (!full or !f.island.visible()) return;
    if (!st.following) {
        st.following = true;
        st.last_move = loop.nowMs();
        arm();
    }
    st.last_move = loop.nowMs();
    lookAt(f, x, y);
}

/// 画面の論理座標 (x, y) を見る(画面の端まで目いっぱい、真下なら正面)
fn lookAt(f: *Frame, x: f32, y: f32) void {
    const lx = x / f.S;
    const ly = y / f.S;
    const r = f.island.vis;
    const tx = std.math.clamp((lx - (r[0] + r[2] / 2)) / (f.W / 2), -1, 1);
    const ty = std.math.clamp((ly - (r[1] + r[3] / 2)) / (f.H * 0.6), -1, 1);
    if (@abs(tx - st.look_x.target) > 0.03 or @abs(ty - st.look_y.target) > 0.03) {
        st.look_x.set(tx);
        st.look_y.set(ty);
        f.schedule();
    }
}

// ---------------------------------------------------------------------------
// 大きさと描画
// ---------------------------------------------------------------------------

const Kind = enum { idle, music, busy, recording, peek, music_big };

fn agentBusy() bool {
    const agent = @import("../agent.zig");
    return agent.busy() or @import("../ai.zig").busy();
}

fn kindOf(f: *Frame) Kind {
    const app = f.app;
    const playing = app.media.status != .none;
    if (st.hover and playing) return .music_big;
    if (st.peek != .none) return .peek;
    if (f.sidev.recording) return .recording;
    if (agentBusy()) return .busy;
    if (playing) return .music;
    return .idle;
}

/// 開くか・中身の大きさ(島の見えている部分。null = 隠す)
pub fn size(f: *Frame) ?[2]f32 {
    const app = f.app;
    if (!app.cfg.island) return null;
    ensure(app);
    // ダッシュボードを開いている間は引っ込む(同じ場所)
    if (f.dash.visible()) return null;
    return switch (kindOf(f)) {
        .idle => .{ 132, 42 },
        .music => .{ 272, 38 },
        .busy => .{ 250, 34 },
        .recording => .{ 176, 34 },
        .peek => .{ 380, 66 },
        .music_big => .{ 400, 148 },
    };
}

pub fn draw(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32) bool {
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const now = loop.nowMs();
    var animating = false;
    // 乗せているか(枠のカーソルの位置から)
    const hv = f.ptr_in and f.island.contains(f.px, f.py, 6);
    if (hv != st.hover) {
        st.hover = hv;
        animating = true;
    }
    // AI の作業が終わった: 少しだけ知らせる
    const busy = agentBusy();
    if (busy) {
        const agent = @import("../agent.zig");
        set(&st.busy_name, &st.busy_name_len, if (agent.isActive()) agent.name(agent.current()) else "AI");
    } else if (st.was_busy) {
        st.peek = .done;
        st.peek_until = now + DONE_MS;
        arm();
    }
    st.was_busy = busy;
    if (f.sidev.recording) {
        if (st.rec_since == 0) {
            st.rec_since = now;
            arm();
        }
    } else st.rec_since = 0;

    var sp = [_]*Spring{ &st.look_x, &st.look_y };
    if (anim.stepAll(&sp, 1.0 / 60.0)) animating = true;
    const blink: f32 = if (now -| st.blink_t0 < BLINK_MS) blk: {
        animating = true;
        const t = @as(f32, @floatFromInt(now - st.blink_t0)) / BLINK_MS;
        break :blk 1 - @sin(t * std.math.pi);
    } else 1;

    // 中身は、島が大きさに追いつく途中でも崩れないよう、見えている幅に合わせて薄く出す
    const tw = size(f) orelse return animating;
    const fit = std.math.clamp(@min(w / tw[0], h / tw[1]), 0, 1);
    if (fit < 0.75) return true;
    cv.opacity((fit - 0.75) * 4);
    switch (kindOf(f)) {
        .idle => drawEyes(cv, w / 2, h / 2 - 1, 1, blink, false, acc),
        .peek => {
            drawEyes(cv, 34, h / 2, 0.8, blink, true, acc);
            if (st.peek == .done) {
                var b: [120]u8 = undefined;
                _ = cv.text(64, h / 2 - 4, 13.5, txt, std.fmt.bufPrint(&b, "{s} が終わりました", .{st.busy_name[0..st.busy_name_len]}) catch "", .{ .bold = true, .max_w = w - 80 });
                _ = cv.text(64, h / 2 + 15, 12, sub, "押すと結果を見られます", .{ .max_w = w - 80 });
            } else {
                _ = cv.text(64, h / 2 - 4, 12, acc.lighten(0.3), st.peek_app[0..st.peek_app_len], .{ .bold = true, .max_w = w - 80 });
                _ = cv.text(64, h / 2 + 15, 13.5, txt, st.peek_text[0..st.peek_text_len], .{ .max_w = w - 80 });
            }
        },
        .busy => {
            // 回るしるし(3 つの点が順に明るくなる)
            const t = @as(f32, @floatFromInt(now % 900)) / 900.0;
            for (0..3) |k| {
                const ph = @mod(t - @as(f32, @floatFromInt(k)) / 3.0, 1.0);
                cv.rect(16 + @as(f32, @floatFromInt(k)) * 11, h / 2 - 3, 6, 6, 3, acc.lighten(0.3).alpha(0.3 + 0.7 * (1 - ph)));
            }
            animating = true;
            var b: [120]u8 = undefined;
            _ = cv.text(56, h / 2 + 5, 12.5, txt, std.fmt.bufPrint(&b, "{s} が作業中", .{st.busy_name[0..st.busy_name_len]}) catch "", .{ .max_w = w - 70 });
        },
        .recording => {
            cv.rect(16, h / 2 - 5, 10, 10, 5, theme.danger(app));
            const s = (now -| st.rec_since) / 1000;
            var b: [32]u8 = undefined;
            _ = cv.text(34, h / 2 + 5, 12.5, txt, std.fmt.bufPrint(&b, "録画中 {d}:{d:0>2}", .{ s / 60, s % 60 }) catch "", .{});
        },
        .music => {
            const m = app.media;
            const a: f32 = 24;
            if (m.art_tex != 0) cv.image(m.art_tex, 10, (h - a) / 2, a, a, 6) else cv.rect(10, (h - a) / 2, a, a, 6, acc.alpha(0.4));
            _ = cv.text(42, h / 2 + 5, 12.5, txt, m.title[0..m.title_len], .{ .max_w = w - 100 });
            drawEyes(cv, w - 34, h / 2, 0.55, blink, false, acc);
        },
        .music_big => if (drawMusicBig(f, cv, w, h, acc, txt, sub)) {
            animating = true;
        },
    }
    cv.opacity(1);
    return animating;
}

/// 目: (cx, cy) が真ん中。open = まぶたの開き(1 で全開)、happy = にっこり(^ ^)
fn drawEyes(cv: *gfx.Canvas, cx: f32, cy: f32, k: f32, open: f32, happy: bool, acc: Color) void {
    const col = Color.mix(Color.hex(0xffffff), acc.lighten(0.5), 0.25);
    const gap = 17 * k;
    const ew = 13 * k;
    const eh = 24 * k;
    const ox = st.look_x.x * 8 * k;
    const oy = st.look_y.x * 4 * k;
    for ([_]f32{ -1, 1 }) |side| {
        const x = cx + side * gap + ox;
        const y = cy + oy;
        if (happy) {
            // ^ の形
            cv.line(x - ew * 0.6, y + 3 * k, x, y - 5 * k, 3.2 * k, col);
            cv.line(x, y - 5 * k, x + ew * 0.6, y + 3 * k, 3.2 * k, col);
            continue;
        }
        const hh = @max(eh * open, 3 * k);
        // ほんのり光る、縦長の白い目(coucou のような)
        cv.shadow(x - ew / 2, y - hh / 2, ew, hh, ew / 2, 8 * k, acc.lighten(0.4).alpha(0.35));
        cv.rect(x - ew / 2, y - hh / 2, ew, hh, ew / 2, col);
    }
}

fn drawMusicBig(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, acc: Color, txt: Color, sub: Color) bool {
    const m = f.app.media;
    const a: f32 = 72;
    if (m.art_tex != 0) cv.image(m.art_tex, 16, 16, a, a, 12) else cv.rect(16, 16, a, a, 12, acc.alpha(0.4));
    _ = cv.text(104, 40, 15, txt, m.title[0..m.title_len], .{ .bold = true, .max_w = w - 120 });
    _ = cv.text(104, 62, 12.5, sub, m.artist[0..m.artist_len], .{ .max_w = w - 120 });
    // 進み具合
    const pos = m.position();
    const frac: f32 = if (m.length_s > 0) std.math.clamp(pos / m.length_s, 0, 1) else 0;
    cv.rect(104, 78, w - 120, 4, 2, Color.hex(0xffffff).alpha(0.15));
    cv.rect(104, 78, (w - 120) * frac, 4, 2, acc.lighten(0.3));
    // 前 / 再生・一時停止 / 次
    const icons = [_][]const u8{ "\u{F04AE}", if (m.status == .playing) "\u{F03E4}" else "\u{F040A}", "\u{F04AD}" };
    for (icons, 0..) |ic, i| {
        const bx = w / 2 + (@as(f32, @floatFromInt(i)) - 1) * 64;
        const on = st.hover_btn == @as(i8, @intCast(i));
        cv.rect(bx - 20, h - 50, 40, 40, 20, Color.hex(0xffffff).alpha(if (on) 0.16 else 0.0));
        _ = cv.text(bx, h - 22, if (i == 1) 24 else 20, txt, ic, .{ .alignment = .center });
    }
    // 再生中は進み具合を動かす(乗せて広げている間だけ)
    return m.status == .playing;
}

fn buttonAt(w: f32, h: f32, lx: f32, ly: f32) i8 {
    if (ly < h - 54) return -1;
    for (0..3) |i| {
        const bx = w / 2 + (@as(f32, @floatFromInt(i)) - 1) * 64;
        if (@abs(lx - bx) < 26) return @intCast(i);
    }
    return -1;
}

pub fn pointer(f: *Frame, ev: surface.PointerEvent, lx: f32, ly: f32) bool {
    const app = f.app;
    const kind = kindOf(f);
    const w = f.island.w.x;
    const h = f.island.h.x;
    const b: i8 = if (kind == .music_big) buttonAt(w, h, lx, ly) else -1;
    const changed = b != st.hover_btn;
    st.hover_btn = b;
    if (ev.kind != .press) return changed or ev.kind == .enter or ev.kind == .motion;
    switch (kind) {
        .music_big => switch (b) {
            0 => app.media.prev(),
            1 => app.media.toggle(),
            2 => app.media.next(),
            else => f.openDashTab(1), // メディアのタブ
        },
        .peek => if (st.peek == .done) {
            if (!f.aiOpen()) f.toggleAi();
            st.peek = .none;
        } else {
            st.peek = .none;
            f.toggleSidebar();
        },
        .idle, .busy => f.toggleAi(),
        .music => {},
        .recording => {},
    }
    return true;
}
