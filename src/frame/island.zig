// ダイナミックアイランド: 枠の上の中央から生える小さな島。状況に合わせて、ばねで伸び縮みする。
//   ふだん      … AI の目(まばたき・きょろきょろ・カーソルを見る・眠る)。乗せると手を振る、右クリックでつつくと目を隠す。
//                 押すと AI チャット。電池が少ないと困り眉
//   ワークスペース … 切り替えたとき番号を少し出す(目は移った方を見る)
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
/// 何も起きないまま、これだけたつと眠くなる
const SLEEP_MS = 90_000;
/// カーソルが止まってから、また自分できょろきょろし始めるまで
const IDLE_MS = 4000;

const Peek = enum { none, notif, done, event };
/// 手: 手を振る / 両手を上げて喜ぶ / 両手で目を隠す(つつかれた)
const Gesture = enum { none, wave, yay, cover, stretch };
const WS_MS = 1400;

const State = struct {
    timer: ?loop.Timer = null,
    app: ?*App = null,
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(1),
    // 目
    look_x: Spring = Spring.init(0, 0.24, 0.62),
    look_y: Spring = Spring.init(0, 0.24, 0.62),
    /// 伸び縮み(+ で縦に伸びる・- でつぶれる)と、ぴょんと跳ねる高さ。どちらも少し揺れて戻るばね(ぽよん)
    squash: Spring = Spring.init(0, 0.32, 0.42),
    hop: Spring = Spring.init(0, 0.3, 0.45),
    /// 最後に何か起きた時刻(カーソル・通知・乗せる)。しばらく何もなければ眠くなる
    last_activity: u64 = 0,
    sleepy: bool = false,
    /// 手の動き(出番のときだけ出てくる)
    gesture: Gesture = .none,
    gesture_t0: u64 = 0,
    /// ワークスペースを切り替えた: 島に番号を少し出す(目は移った方を見る)
    ws_num: u8 = 0,
    ws_until: u64 = 0,
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
    /// 充電器のつなぎ外し(変わったときに反応する)
    prev_ac: ?bool = null,
    /// 島の色(ジャケットの色へ少しずつ寄る)
    col: Color = .{},
    col_init: bool = false,
    /// リズム: 直前の低音の強さ・最後に跳ねた時刻・揺れる向き
    prev_bass: f32 = 0,
    last_beat: u64 = 0,
    sway: f32 = 1,
    /// 起動の伸びが終わった(目を開けて跳ねた)
    stretched: bool = false,
    /// 今日の飾り(季節・記念日)。描くたびに決める
    decor: Decor = .none,
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
    st.last_activity = now;
    // 起動: 眠った顔から、んーっと伸びをして目を覚ます
    st.gesture = .stretch;
    st.gesture_t0 = now;
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
    if (st.ws_until != 0) next = @min(next, st.ws_until);
    if (!st.sleepy) next = @min(next, st.last_activity + sleepMs());
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
    if (!st.sleepy and now >= st.last_activity + sleepMs()) {
        st.sleepy = true;
        st.look_x.set(0);
        st.look_y.set(0.3); // うとうと: 少し下を向く
    }
    if (now >= st.next_blink) {
        st.blink_t0 = now;
        // 開くときに、ぽよんと縦に伸びて戻る
        st.squash.x = -0.22;
        st.squash.set(0);
        // ときどき 2 回続けてまばたき
        st.next_blink = now + if (st.sleepy) 6000 + r.uintLessThan(u64, 4000) else if (r.float(f32) < 0.2) @as(u64, 260) else 2200 + r.uintLessThan(u64, 4200);
    }
    if (now >= st.next_glance) {
        if (st.sleepy) {
            st.next_glance = now + 8000;
        } else if (!st.following) {
            // よそ見: たまに左右や上を見て、また前を向く
            if (st.look_x.target == 0 and st.look_y.target == 0) {
                st.look_x.set((r.float(f32) * 2 - 1) * 0.9);
                st.look_y.set((r.float(f32) * 2 - 1) * 0.5);
                st.next_glance = now + 900 + r.uintLessThan(u64, 900);
            } else {
                st.look_x.set(0);
                st.look_y.set(0);
                // 電池が少ないと焦って、きょろきょろが速い(とても少ないと、びくっと目が泳ぐ)
                st.next_glance = switch (battery()) {
                    .ok => now + 5000 + r.uintLessThan(u64, 7000),
                    .low => now + 600 + r.uintLessThan(u64, 900),
                    .critical => now + 300 + r.uintLessThan(u64, 500),
                };
                if (battery() == .critical) react(-0.12, 70);
                if (battery() == .ok) fidget(r);
            }
        } else st.next_glance = now + 4000;
    }
    if (st.peek != .none and now >= st.peek_until) st.peek = .none;
    if (st.ws_until != 0 and now >= st.ws_until) {
        st.ws_until = 0;
        if (!st.following) st.look_x.set(0);
    }
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
    // びっくりして目を見開き、ぴょんと跳ねる
    react(0.4, 260);
    gesture(.yay);
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
    wake();
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
    wake();
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

const Kind = enum { idle, music, busy, recording, peek, workspace, music_big };

fn agentBusy() bool {
    const agent = @import("../agent.zig");
    return agent.busy() or @import("../ai.zig").busy();
}

fn kindOf(f: *Frame) Kind {
    const app = f.app;
    const playing = app.media.status != .none;
    if (st.hover and playing) return .music_big;
    if (st.peek != .none) return .peek;
    if (st.ws_until != 0) return .workspace;
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
        .idle => .{ 210, 46 },
        .workspace => .{ 250, 46 },
        .music => .{ 272, 38 },
        .busy => .{ 250, 34 },
        .recording => .{ 176, 34 },
        .peek => .{ 400, 66 },
        .music_big => .{ 400, 148 },
    };
}

pub fn draw(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32) bool {
    const app = f.app;
    // 再生中は、ジャケットの色に少しずつ染まる
    const playing = app.media.status == .playing;
    const want_col = if (app.media.status != .none) (app.media.art_color orelse theme.accent(app)) else theme.accent(app);
    const col_moving = !sameColor(st.col, want_col);
    st.col = if (st.col_init) Color.mix(st.col, want_col, 0.12) else want_col;
    st.col_init = true;
    const acc = st.col;
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const now = loop.nowMs();
    var animating = false;
    // 乗せているか(枠のカーソルの位置から)
    const hv = f.ptr_in and f.island.contains(f.px, f.py, 6);
    if (hv != st.hover) {
        st.hover = hv;
        animating = true;
        // 乗せた: にっこりして、ぴょんと跳ねる
        if (hv) {
            wake();
            react(0.25, 200);
            gesture(.wave);
        }
    }
    // AI の作業が終わった: 少しだけ知らせる
    const busy = agentBusy();
    if (busy) {
        const agent = @import("../agent.zig");
        set(&st.busy_name, &st.busy_name_len, if (agent.isActive()) agent.name(agent.current()) else "AI");
    } else if (st.was_busy) {
        st.peek = .done;
        gesture(.yay);
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

    // 充電器をつないだ: 喜ぶ
    const ac = app.sys.battery.on_ac;
    if (st.prev_ac) |pa| if (!pa and ac) {
        react(0.3, 220);
        gesture(.yay);
    };
    st.prev_ac = ac;
    // 今日の飾り(季節・記念日)
    const td = today(clock());
    st.decor = if (td) |d| d.decor else .none;
    var sp = [_]*Spring{ &st.look_x, &st.look_y, &st.squash, &st.hop };
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
    if (col_moving) animating = true;
    // 再生中: 島の中をジャケットの色でほんのり染める(上の角は枠の外なので、上へはみ出して描く)
    if (app.media.status != .none) {
        const R = f.R();
        cv.rectGrad(0, -R, w, h + R, R, acc.alpha(0.10), acc.alpha(0.32));
    }
    // リズムに乗る: 低音が強く来たら、ぴょこっと跳ねて体を左右に揺らす
    if (playing and f.spectrum.running()) {
        const v = f.spectrum.values;
        const b = @max(v[0], @max(v[1], v[2]));
        if (b > st.prev_bass + 0.16 and b > 0.35 and now -| st.last_beat > 200) {
            st.last_beat = now;
            st.sway = -st.sway;
            st.squash.x = 0.1 + 0.25 * b;
            st.squash.set(0);
            st.hop.v = -(90 + 140 * b);
            st.hop.set(0);
            if (!st.following) st.look_x.set(st.sway * 0.35);
        }
        st.prev_bass = b;
        animating = true;
    }
    switch (kindOf(f)) {
        .idle => {
            const covered = st.gesture == .cover and handsActive(now);
            const low = battery() != .ok;
            var mood: Mood = if (covered) .squint else if (st.hover) .happy else if (st.sleepy) .sleepy else if (low) .worried else .normal;
            // 起動の伸び: すやすや → んーっ(目をぎゅっ・縦に伸びる)→ ぱっと目を開けて跳ねる
            if (st.gesture == .stretch and handsActive(now)) {
                const p = @as(f32, @floatFromInt(now - st.gesture_t0)) / 2600.0;
                if (p < 0.3) mood = .sleepy else if (p < 0.72) {
                    mood = .squint;
                    const v = 0.4 * @sin((p - 0.3) / 0.42 * std.math.pi);
                    st.squash.x = v;
                    st.squash.target = v;
                    st.squash.v = 0;
                } else if (!st.stretched) {
                    st.stretched = true;
                    react(0.45, 300);
                    // 記念日なら「今日は○○」
                    if (td) |d| {
                        st.peek = .event;
                        st.peek_until = now + PEEK_MS;
                        set(&st.peek_app, &st.peek_app_len, "今日は");
                        set(&st.peek_text, &st.peek_text_len, d.name);
                        arm();
                    }
                }
            }
            drawEyes(cv, w / 2, h / 2 - 1, 1, blink, mood, acc);
            if (low and mood != .sleepy) drawSweat(cv, w / 2 + 30, h / 2 - 12, 1);
            drawDecor(cv, w / 2, h / 2 - 1, 1, now, acc);
            if (drawHands(cv, w / 2, h / 2 - 1, 1, now, acc)) animating = true;
        },
        .workspace => {
            drawEyes(cv, 46, h / 2 - 1, 0.75, blink, .normal, acc);
            var b: [48]u8 = undefined;
            _ = cv.text(92, h / 2 + 6, 15, txt, std.fmt.bufPrint(&b, "ワークスペース {d}", .{st.ws_num}) catch "", .{ .bold = true });
        },
        .peek => {
            drawEyes(cv, 54, h / 2, 0.8, blink, .happy, acc);
            if (drawHands(cv, 54, h / 2, 0.8, now, acc)) animating = true;
            if (st.peek == .done) {
                var b: [120]u8 = undefined;
                _ = cv.text(104, h / 2 - 4, 13.5, txt, std.fmt.bufPrint(&b, "{s} が終わりました", .{st.busy_name[0..st.busy_name_len]}) catch "", .{ .bold = true, .max_w = w - 120 });
                _ = cv.text(104, h / 2 + 15, 12, sub, "押すと結果を見られます", .{ .max_w = w - 120 });
            } else {
                _ = cv.text(104, h / 2 - 4, 12, acc.lighten(0.3), st.peek_app[0..st.peek_app_len], .{ .bold = true, .max_w = w - 120 });
                _ = cv.text(104, h / 2 + 15, 13.5, txt, st.peek_text[0..st.peek_text_len], .{ .max_w = w - 120 });
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
            drawEyes(cv, w - 34, h / 2, 0.55, blink, if (st.sleepy) .sleepy else .normal, acc);
        },
        .music_big => if (drawMusicBig(f, cv, w, h, acc, txt, sub)) {
            animating = true;
        },
    }
    cv.opacity(1);
    return animating;
}

/// 目: (cx, cy) が真ん中。open = まぶたの開き(1 で全開)、happy = にっこり(^ ^)
const Mood = enum { normal, happy, sleepy, worried, squint };

/// 目: (cx, cy) が真ん中、k が大きさ。open = まぶたの開き(1 で全開)
fn drawEyes(cv: *gfx.Canvas, cx: f32, cy: f32, k: f32, open: f32, mood: Mood, acc: Color) void {
    const white = Color.hex(0xffffff);
    const orange = Color.hex(0xffa040);
    const tint = if (st.decor == .halloween) orange else Color.mix(white, acc.lighten(0.45), 0.35);
    const gap = 17 * k;
    const s = std.math.clamp(st.squash.x, -0.6, 0.8);
    // 伸びると細く、つぶれると太く(体積を保つように)
    const ew = 14 * k * (1 - 0.45 * s);
    const eh = 23 * k * (1 + s);
    const ox = st.look_x.x * 8 * k;
    const oy = st.look_y.x * 4 * k + st.hop.x * k;
    for ([_]f32{ -1, 1 }) |side| {
        // 見ている方の目を少し大きく(顔ごと向いたように)
        var pk = 1 + side * st.look_x.x * 0.1;
        if (st.decor == .fool) pk *= if (side < 0) 0.75 else 1.25; // エイプリルフール: 左右で大きさがちぐはぐ
        const x = cx + side * gap + ox * 1.15;
        const y = cy + oy;
        switch (mood) {
            .happy => {
                // にっこり(^ ^)と、ほっぺの赤み
                const a = ew * 0.62 * pk;
                cv.line(x - a, y + 3 * k, x, y - 5 * k, 3.4 * k, white);
                cv.line(x, y - 5 * k, x + a, y + 3 * k, 3.4 * k, white);
                cv.shadow(x + side * 8 * k - 7 * k, y + 7 * k, 14 * k, 6 * k, 3 * k, 7 * k, Color.hex(0xff8fb3).alpha(0.8));
            },
            .squint => {
                // ぎゅっ(> <)
                const a = ew * 0.55;
                cv.line(x - side * a, y - 5 * k, x + side * a, y, 3 * k, white);
                cv.line(x + side * a, y, x - side * a, y + 5 * k, 3 * k, white);
            },
            .sleepy => {
                // すやすや(閉じた目の ‿)
                const a = ew * 0.55;
                cv.line(x - a, y, x, y + 3 * k, 2.6 * k, tint);
                cv.line(x, y + 3 * k, x + a, y, 2.6 * k, tint);
            },
            .normal, .worried => {
                if (st.decor == .heart and mood == .normal) {
                    heart(cv, x, y, 15 * k * pk, Color.hex(0xff7aa8));
                    continue;
                }
                const w2 = ew * pk * (1 + 0.25 * (1 - open)); // まばたきの間は少し横に広がる
                const h2 = @max(eh * pk * open, 3 * k);
                // ほんのり光る、まるい縦長の目。上は白、下は少し色づく
                cv.shadow(x - w2 / 2, y - h2 / 2, w2, h2, w2 / 2, 9 * k, (if (st.decor == .halloween) orange else acc.lighten(0.4)).alpha(0.38));
                cv.rectGrad(x - w2 / 2, y - h2 / 2, w2, h2, w2 / 2, white, tint);
                if (mood == .worried) {
                    // 困り眉(内側が上がる「八」の字)
                    const bx = w2 * 0.7;
                    cv.line(x + side * bx, y - h2 / 2 - 3 * k, x - side * bx * 0.3, y - h2 / 2 - 8 * k, 2.4 * k, tint);
                }
            },
        }
    }
    // 眠いときは小さな z
    if (mood == .sleepy) {
        _ = cv.text(cx + gap + 14 * k, cy - 4 * k, 9 * k, white.alpha(0.55), "z", .{});
        _ = cv.text(cx + gap + 21 * k, cy - 11 * k, 12 * k, white.alpha(0.7), "Z", .{});
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
    // 右クリック: つつく(両手で目を隠して、ぷるぷる)
    if (ev.button == 0x111 and kind == .idle) {
        wake();
        gesture(.cover);
        react(-0.3, 120);
        return true;
    }
    switch (kind) {
        .music_big => switch (b) {
            0 => app.media.prev(),
            1 => app.media.toggle(),
            2 => app.media.next(),
            else => f.openDashTab(1), // メディアのタブ
        },
        .peek => if (st.peek == .event) {
            st.peek = .none;
        } else if (st.peek == .done) {
            if (!f.aiOpen()) f.toggleAi();
            st.peek = .none;
        } else {
            st.peek = .none;
            f.toggleSidebar();
        },
        .idle, .busy => f.toggleAi(),
        .music, .recording, .workspace => {},
    }
    return true;
}

/// 反応する: 縦に伸びて(s)、上へ跳ねる(速さ v)。ばねで少し揺れながら戻る
fn react(s: f32, v: f32) void {
    st.squash.x = s;
    st.squash.set(0);
    st.hop.v = -v;
    st.hop.set(0);
    st.last_activity = loop.nowMs();
    redrawAll();
}

/// 何か起きた: 眠っていたら、びっくりして起きる
fn wake() void {
    st.last_activity = loop.nowMs();
    if (!st.sleepy) return;
    st.sleepy = false;
    st.look_y.set(0);
    react(0.5, 300);
    arm();
}

fn gestureMs(g: Gesture) u64 {
    return switch (g) {
        .none => 0,
        .wave => 1500,
        .yay => 1300,
        .cover => 1400,
        .stretch => 2600,
    };
}

fn gesture(g: Gesture) void {
    st.gesture = g;
    st.gesture_t0 = loop.nowMs();
    redrawAll();
}

fn handsActive(now: u64) bool {
    return st.gesture != .none and now -| st.gesture_t0 < gestureMs(st.gesture);
}

/// ワークスペースを切り替えた(wm.zig)。dir = +1 で右(次)へ、-1 で左へ
pub fn workspace(app: *App, n: u8, dir: f32) void {
    if (!app.cfg.island or st.timer == null) return;
    st.ws_num = n;
    st.ws_until = loop.nowMs() + WS_MS;
    st.look_x.set(dir * 0.9);
    react(0.2, 180);
    arm();
}

/// 手(白いまるい手に、ピンクの肉球)。出番のときだけ、ぴょこっと出て引っ込む。動いている間は true
fn drawHands(cv: *gfx.Canvas, cx: f32, cy: f32, k: f32, now: u64, acc: Color) bool {
    if (!handsActive(now)) {
        st.gesture = .none;
        return false;
    }
    const p = @as(f32, @floatFromInt(now - st.gesture_t0)) / @as(f32, @floatFromInt(gestureMs(st.gesture)));
    // 出てくる・引っ込む(最初と最後の 15% で大きさを 0 ⇄ 1)
    const pop = std.math.clamp(@min(p, 1 - p) / 0.15, 0, 1);
    const sc = pop * (1 + 0.15 * @sin(pop * std.math.pi)); // 出るときに少し大きくなって戻る
    const gap = 17 * k;
    const side_x = gap + 34 * k;
    const wave = @sin(p * std.math.pi * 7);
    switch (st.gesture) {
        .wave => paw(cv, cx + side_x + wave * 5 * k, cy - 4 * k - @abs(wave) * 3 * k, k * sc, wave * 0.5, acc),
        .yay => {
            const bob = @abs(@sin(p * std.math.pi * 5)) * 5 * k;
            paw(cv, cx - side_x + 4 * k, cy - 8 * k - bob, k * sc, -0.4, acc);
            paw(cv, cx + side_x - 4 * k, cy - 8 * k - bob, k * sc, 0.4, acc);
        },
        .stretch => {
            // 両手を上げて、ぷるぷる伸びる(すやすやの間は出さない)
            const q = std.math.clamp((p - 0.25) / 0.55, 0, 1);
            if (q <= 0 or q >= 1) return true;
            const up = @sin(q * std.math.pi);
            const tremble = @sin(p * std.math.pi * 30) * 1.2 * k * up;
            paw(cv, cx - side_x * 0.85 + tremble, cy + 8 * k - up * 22 * k, k * up, -0.3, acc);
            paw(cv, cx + side_x * 0.85 - tremble, cy + 8 * k - up * 22 * k, k * up, 0.3, acc);
        },
        .cover => {
            const shake = @sin(p * std.math.pi * 16) * 2 * k;
            paw(cv, cx - gap + shake, cy + 1 * k, k * sc * 1.25, 0.2, acc);
            paw(cv, cx + gap + shake, cy + 1 * k, k * sc * 1.25, -0.2, acc);
        },
        .none => {},
    }
    return true;
}

/// まるい手: 白い手のひらに、ピンクの肉球と 3 つの指の豆。tilt = 傾き(-1〜1、指の豆の並びをずらす)
fn paw(cv: *gfx.Canvas, x: f32, y: f32, k: f32, tilt: f32, acc: Color) void {
    if (k < 0.05) return;
    const r = 8 * k;
    const white = Color.hex(0xffffff);
    const pink = Color.hex(0xff9dbb);
    cv.shadow(x - r, y - r, r * 2, r * 2, r, 8 * k, acc.lighten(0.4).alpha(0.35));
    cv.rect(x - r, y - r, r * 2, r * 2, r, white);
    cv.rect(x - 3 * k, y - 0.5 * k, 6 * k, 4.5 * k, 2.25 * k, pink);
    for ([_]f32{ -1, 0, 1 }) |i| {
        const bx = x + (i * 3.6 + tilt * 1.5) * k;
        const by = y - 4.2 * k + @abs(i) * 1.2 * k;
        cv.rect(bx - 1.3 * k, by - 1.3 * k, 2.6 * k, 2.6 * k, 1.3 * k, pink);
    }
}

// ---------------------------------------------------------------------------
// PC の状態・時間・記念日
// ---------------------------------------------------------------------------

const Battery = enum { ok, low, critical };

fn battery() Battery {
    const app = st.app orelse return .ok;
    const b = app.sys.battery;
    if (!b.present or b.on_ac) return .ok;
    if (b.percent <= 5) return .critical;
    if (b.percent <= 15) return .low;
    return .ok;
}

const Clock = struct { month: u8, day: u8, hour: u8 };

/// 今の日付と時刻(試験用: AME_DEBUG があれば AME_ISLAND_DATE="MM-DD" で日付を変えられる)
fn clock() Clock {
    const c = @import("../c.zig");
    var t: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&t, &tm);
    var r = Clock{ .month = @intCast(tm.tm_mon + 1), .day = @intCast(tm.tm_mday), .hour = @intCast(tm.tm_hour) };
    if (std.posix.getenv("AME_DEBUG") != null) if (std.posix.getenv("AME_ISLAND_DATE")) |d| if (d.len == 5) {
        r.month = std.fmt.parseInt(u8, d[0..2], 10) catch r.month;
        r.day = std.fmt.parseInt(u8, d[3..5], 10) catch r.day;
    };
    return r;
}

/// 夜中(0〜5 時)はすぐ眠くなる
fn sleepMs() u64 {
    const h = clock().hour;
    return if (h < 6) 30_000 else SLEEP_MS;
}

pub const Decor = enum { none, newyear, sparkle, heart, cat, fool, tanabata, halloween, xmas };

const Day = struct { m: u8, d0: u8, d1: u8, decor: Decor, name: []const u8 };

/// 主な季節の行事・記念日(日本)
const days = [_]Day{
    .{ .m = 1, .d0 = 1, .d1 = 3, .decor = .newyear, .name = "お正月" },
    .{ .m = 2, .d0 = 3, .d1 = 3, .decor = .sparkle, .name = "節分" },
    .{ .m = 2, .d0 = 14, .d1 = 14, .decor = .heart, .name = "バレンタインデー" },
    .{ .m = 2, .d0 = 22, .d1 = 22, .decor = .cat, .name = "猫の日" },
    .{ .m = 3, .d0 = 3, .d1 = 3, .decor = .sparkle, .name = "ひな祭り" },
    .{ .m = 3, .d0 = 14, .d1 = 14, .decor = .heart, .name = "ホワイトデー" },
    .{ .m = 4, .d0 = 1, .d1 = 1, .decor = .fool, .name = "エイプリルフール" },
    .{ .m = 5, .d0 = 5, .d1 = 5, .decor = .sparkle, .name = "こどもの日" },
    .{ .m = 7, .d0 = 7, .d1 = 7, .decor = .tanabata, .name = "七夕" },
    .{ .m = 10, .d0 = 25, .d1 = 31, .decor = .halloween, .name = "ハロウィン" },
    .{ .m = 11, .d0 = 11, .d1 = 11, .decor = .sparkle, .name = "ポッキーの日" },
    .{ .m = 12, .d0 = 20, .d1 = 25, .decor = .xmas, .name = "クリスマス" },
    .{ .m = 12, .d0 = 31, .d1 = 31, .decor = .sparkle, .name = "大晦日" },
};

pub fn today(cl: Clock) ?Day {
    for (days) |d| if (d.m == cl.month and cl.day >= d.d0 and cl.day <= d.d1) return d;
    return null;
}

test "seasonal days" {
    try std.testing.expectEqual(Decor.halloween, today(.{ .month = 10, .day = 31, .hour = 0 }).?.decor);
    try std.testing.expectEqual(Decor.xmas, today(.{ .month = 12, .day = 24, .hour = 0 }).?.decor);
    try std.testing.expect(today(.{ .month = 6, .day = 10, .hour = 0 }) == null);
}

/// ハート(2 つの丸と、下へすぼまる三角)
fn heart(cv: *gfx.Canvas, x: f32, y: f32, s: f32, col: Color) void {
    const r = s * 0.3;
    cv.shadow(x - s / 2, y - s / 2, s, s, s / 2, s * 0.5, col.alpha(0.4));
    cv.rect(x - s * 0.5, y - s * 0.42, r * 2, r * 2, r, col);
    cv.rect(x - s * 0.5 + r * 1.35, y - s * 0.42, r * 2, r * 2, r, col);
    var t: f32 = 0;
    while (t < 1) : (t += 0.25) {
        const hw = s * 0.5 * (1 - t);
        cv.rect(x - hw, y - s * 0.12 + t * s * 0.55, hw * 2, s * 0.18, s * 0.09, col);
    }
}

/// きらっ(十字の光)
fn sparkle(cv: *gfx.Canvas, x: f32, y: f32, r: f32, col: Color) void {
    cv.line(x - r, y, x + r, y, r * 0.35, col);
    cv.line(x, y - r, x, y + r, r * 0.35, col);
    cv.rect(x - r * 0.3, y - r * 0.3, r * 0.6, r * 0.6, r * 0.3, Color.hex(0xffffff));
}

/// 冷や汗(右の目の外側に、しずく)
fn drawSweat(cv: *gfx.Canvas, x: f32, y: f32, k: f32) void {
    const col = Color.hex(0x9fd8ff);
    cv.rect(x - 3 * k, y, 6 * k, 7 * k, 3 * k, col);
    cv.line(x, y - 4 * k, x - 2.4 * k, y + 2 * k, 2 * k, col);
    cv.line(x, y - 4 * k, x + 2.4 * k, y + 2 * k, 2 * k, col);
}

/// 季節・記念日の飾り(目のまわり)
fn drawDecor(cv: *gfx.Canvas, cx: f32, cy: f32, k: f32, now: u64, acc: Color) void {
    _ = acc;
    const gap = 17 * k;
    const white = Color.hex(0xffffff);
    const gold = Color.hex(0xffd36b);
    // ゆっくりまたたく(描き直したときに少し変わるだけ。そのために描き続けはしない)
    const tw = 0.6 + 0.4 * @sin(@as(f32, @floatFromInt(now % 4000)) / 4000.0 * std.math.tau);
    switch (st.decor) {
        .none, .heart, .fool => {},
        .sparkle => {
            sparkle(cv, cx - gap - 30 * k, cy - 8 * k, 4 * k, Color.hex(0xffb3d9).alpha(tw));
            sparkle(cv, cx + gap + 30 * k, cy + 6 * k, 3.5 * k, Color.hex(0xb3e5ff).alpha(1.4 - tw));
        },
        .newyear => {
            sparkle(cv, cx - gap - 32 * k, cy - 6 * k, 4.5 * k, gold.alpha(tw));
            sparkle(cv, cx + gap + 32 * k, cy - 2 * k, 4 * k, gold.alpha(1.4 - tw));
            sparkle(cv, cx + gap + 46 * k, cy + 9 * k, 2.5 * k, Color.hex(0xff6b6b).alpha(tw));
        },
        .tanabata => {
            for ([_][3]f32{ .{ -52, -8, 3.5 }, .{ -40, 8, 2.5 }, .{ 44, -6, 3 }, .{ 56, 7, 2 } }, 0..) |s, i| {
                const a = if (i % 2 == 0) tw else 1.4 - tw;
                sparkle(cv, cx + s[0] * k, cy + s[1] * k, s[2] * k, gold.alpha(a));
            }
        },
        .cat => {
            // 猫耳(目の上に、ピンクの内側つき)
            for ([_]f32{ -1, 1 }) |side| {
                const x = cx + side * (gap + 3 * k);
                const top = cy - 19 * k;
                cv.line(x - 7 * k, top + 9 * k, x - side * 1 * k, top, 3.5 * k, white);
                cv.line(x - side * 1 * k, top, x + 7 * k, top + 9 * k, 3.5 * k, white);
                cv.line(x - 3 * k, top + 8 * k, x - side * 0.5 * k, top + 3 * k, 2 * k, Color.hex(0xff9dbb));
            }
        },
        .halloween => {
            // かぼちゃ(右に)
            const px = cx + gap + 42 * k;
            const py = cy + 3 * k;
            const orange = Color.hex(0xff8a1f);
            cv.shadow(px - 11 * k, py - 9 * k, 22 * k, 18 * k, 9 * k, 6 * k, orange.alpha(0.4));
            cv.rect(px - 11 * k, py - 9 * k, 22 * k, 18 * k, 9 * k, orange);
            cv.line(px - 4 * k, py - 8 * k, px - 4 * k, py + 8 * k, 1.2 * k, Color.hex(0xc85f00));
            cv.line(px + 4 * k, py - 8 * k, px + 4 * k, py + 8 * k, 1.2 * k, Color.hex(0xc85f00));
            cv.rect(px - 1.5 * k, py - 13 * k, 3 * k, 5 * k, 1.5 * k, Color.hex(0x4caf50));
        },
        .xmas => {
            // サンタ帽(左の目の上に斜めに)と、雪
            const hx = cx - gap;
            const hy = cy - 11 * k;
            const red = Color.hex(0xe53935);
            var i: f32 = 0;
            while (i < 4) : (i += 1) {
                const wv = (16 - i * 3.6) * k;
                cv.rect(hx - wv / 2 + i * 1.8 * k, hy - i * 3.2 * k, wv, 4.5 * k, 2 * k, red);
            }
            cv.rect(hx - 10 * k, hy + 2.5 * k, 20 * k, 4 * k, 2 * k, white);
            cv.rect(hx + 7.5 * k, hy - 14 * k, 5 * k, 5 * k, 2.5 * k, white);
            for ([_][2]f32{ .{ 40, -10 }, .{ 52, 4 }, .{ -46, 8 }, .{ 30, 12 } }) |s| {
                cv.rect(cx + s[0] * k - 1.5 * k, cy + s[1] * k - 1.5 * k, 3 * k, 3 * k, 1.5 * k, white.alpha(0.8));
            }
        },
    }
}

fn sameColor(a: Color, b: Color) bool {
    return @abs(a.r - b.r) < 0.004 and @abs(a.g - b.g) < 0.004 and @abs(a.b - b.b) < 0.004;
}

/// 再生中で島が出ているときは、リズムに乗るために音のスペクトラムを取る(frame.zig)
pub fn wantsSpectrum(f: *Frame) bool {
    return f.app.cfg.island and f.app.media.status == .playing and f.island.visible() and !f.dash.visible();
}

/// ひまなときの癖(よそ見から前を向いたときに、ときどき)
fn fidget(r: std.Random) void {
    const x = r.float(f32);
    if (x < 0.10) {
        // ぷるぷるっと首を振る
        st.look_x.v = 6;
        st.look_x.set(0);
        react(-0.15, 60);
    } else if (x < 0.18) {
        // ふと何かに気づいて、ぴょんと跳ねる
        react(0.3, 220);
    } else if (x < 0.22) {
        // 小さく手を振る(誰かいないかな)
        gesture(.wave);
    }
}

/// 窓が開いた・閉じた(wm.zig)。(gx, gy) は窓の真ん中(グローバル)。開いたら そちらを見て喜び、閉じたら しゅんとする
pub fn windowEvent(app: *App, outs: anytype, gx: i32, gy: i32, opened: bool) void {
    if (!app.cfg.island or st.timer == null) return;
    wake();
    for (outs) |wo| {
        const ao = wo.ame orelse continue;
        const f = ao.frame orelse continue;
        if (!f.island.visible() or gx < wo.x or gx >= wo.x + wo.w) continue;
        lookAt(f, @as(f32, @floatFromInt(gx - wo.x)), @as(f32, @floatFromInt(gy - wo.y)));
    }
    st.following = true; // 少しの間そちらを見て、また前を向く
    st.last_move = loop.nowMs() -| (IDLE_MS - 1500);
    if (opened) react(0.3, 200) else react(-0.25, 40);
    arm();
}
