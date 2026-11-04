// ハンドのポーズの設定画面: 片手・両手のポーズを、アプリの起動や操作に割り当てる(poses.zig に保存)。
//
//   左: 今の割り当ての一覧(× で消す)
//   右: 1. ポーズ … よく使う形の一覧から「手 1」を選ぶ。「両手にする」で「手 2」も選ぶ。
//                   ハンド操作がオンなら「今の手のポーズを使う」で、カメラに映した形をそのまま使える
//       2. 操作   … [操作] ランチャー・スクリーンショット・ワークスペースなど / [アプリ] 入っているアプリ
//                   (文字を打つと絞り込む)/ [コマンド] 好きなコマンドを打つ
//       「追加」で保存。同じポーズがあれば置き換える。Esc・× で閉じる
// 手でも操作できる(ハンド操作のカーソルでつまむとクリックになるため)。
// 開く: ランチャーの「ハンドのポーズ」・手のメニューの「ポーズの設定」・ame-ctl hand poses
const std = @import("std");
const anim = @import("../anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const appmod = @import("../app.zig");
const App = appmod.App;
const Output = appmod.Output;
const c = @import("../c.zig");
const gfx = @import("../gfx.zig");
const theme = @import("../theme.zig");
const surface = @import("../surface.zig");
const Surface = surface.Surface;
const poses = @import("poses.zig");
const custom = @import("custom.zig");
const loop = @import("../platform/loop.zig");

const white = Color.hex(0xffffff);
const black = Color.hex(0x000000);

const Tab = enum { action, app, command };
const HitKind = enum { close, del, preset, which_a, which_b, two, use_live, tab, op, app, add, cmdbox, custom_pose, cdel, add_custom, rec_start, rec_cancel, mode_full, mode_poses };
const Hit = struct { r: [4]f32, kind: HitKind, i: usize = 0 };

var st: struct {
    app: ?*App = null,
    surf: ?*Surface = null,
    out: ?*Output = null,
    show: Spring = Spring.init(0, 0.38, 0.85),
    open: bool = false,
    // 編集中の割り当て
    a: u8 = poses.NONE,
    b: u8 = poses.NONE,
    two: bool = false,
    editing_b: bool = false,
    tab: Tab = .action,
    op: ?poses.Op = null,
    app_idx: ?usize = null,
    text: [200]u8 = undefined,
    text_len: usize = 0,
    /// アプリの絞り込み
    filter: [64]u8 = undefined,
    filter_len: usize = 0,
    app_scroll: usize = 0,
    list_scroll: usize = 0,
    msg: [160]u8 = undefined,
    msg_len: usize = 0,
    hover: i32 = -1,
    hits: [320]Hit = undefined,
    n_hits: usize = 0,
    /// 「カメラに映っている手のポーズを使う」を押した時刻(0 = 数えていない)
    live_t0: u64 = 0,
    // ---- 自分のポーズの登録 ----
    rec: enum { off, naming, countdown, capture } = .off,
    rec_name: [48]u8 = undefined,
    rec_name_len: usize = 0,
    rec_t0: u64 = 0,
    rec_samples: [48][2]custom.Shape = undefined,
    /// コマごとに映っていた手の数
    rec_hands: [48]u8 = undefined,
    rec_n: usize = 0,
    rec_seq: u32 = 0,
} = .{};

pub fn isOpen() bool {
    return st.open;
}

pub fn open(app: *App) void {
    st.app = app;
    if (st.surf == null) {
        const out = app.activeOutput() orelse return;
        const all = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        st.surf = Surface.createLayer(app, .{ .ctx = &st, .draw = draw, .pointer = pointer, .key = key }, .{
            .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            .anchor = @intCast(all),
            .exclusive = -1,
            .keyboard = c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
            .namespace = "ame-hand-poses",
            .output = out.wl,
        }) catch return;
        st.out = out;
        st.surf.?.output = out;
        st.show.snap(0);
    }
    st.open = true;
    st.show.set(1);
    st.msg_len = 0;
    poses.reload();
    st.surf.?.schedule();
}

pub fn close() void {
    st.open = false;
    st.show.set(0);
    if (st.surf) |s| {
        if (s.layer) |l| c.zwlr_layer_surface_v1_set_keyboard_interactivity(l, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        s.setInputRect(0, 0, 0, 0);
        s.schedule();
    }
}

pub fn reap() void {
    if (st.surf == null or st.open or st.show.x > 0.01 or st.show.moving()) return;
    st.surf.?.destroy();
    st.surf = null;
    st.out = null;
}

pub fn outputRemoved(o: *Output) void {
    if (st.out != o) return;
    if (st.surf) |s| s.destroy();
    st.surf = null;
    st.out = null;
    st.open = false;
}

fn setMsg(s: []const u8) void {
    st.msg_len = @min(s.len, st.msg.len);
    @memcpy(st.msg[0..st.msg_len], s[0..st.msg_len]);
}

fn addHit(r: [4]f32, kind: HitKind, i: usize) void {
    if (st.n_hits >= st.hits.len) return;
    st.hits[st.n_hits] = .{ .r = r, .kind = kind, .i = i };
    st.n_hits += 1;
}

fn hitAt(x: f32, y: f32) ?Hit {
    var i = st.n_hits;
    while (i > 0) {
        i -= 1;
        const h = st.hits[i];
        if (x >= h.r[0] and x <= h.r[0] + h.r[2] and y >= h.r[1] and y <= h.r[1] + h.r[3]) return h;
    }
    return null;
}

fn hoverIdx(x: f32, y: f32) i32 {
    var i = st.n_hits;
    while (i > 0) {
        i -= 1;
        const h = st.hits[i].r;
        if (x >= h[0] and x <= h[0] + h[2] and y >= h[1] and y <= h[1] + h[3]) return @intCast(i);
    }
    return -1;
}

/// 手の絵: 手のひらと 5 本の指。伸びている指は長く明るく、曲げている指は短く暗く
pub fn drawHand(cv: *gfx.Canvas, x: f32, y: f32, s: f32, mask: u8, col: Color) void {
    // 自分のポーズ: 星の色の手の印(両手のポーズは 2 つ)
    if (custom.isTwoHanded(mask)) {
        _ = cv.text(x + s / 2, y + s * 0.68, s * 0.42, Color.hex(0xffd36b), "\u{F1821}\u{F1821}", .{ .alignment = .center });
        return;
    }
    if (custom.isId(mask)) {
        _ = cv.text(x + s / 2, y + s * 0.72, s * 0.62, Color.hex(0xffd36b), "\u{F1821}", .{ .alignment = .center });
        return;
    }
    if (mask == poses.NONE) {
        _ = cv.text(x + s / 2, y + s * 0.62, s * 0.4, col.alpha(0.4), "–", .{ .alignment = .center });
        return;
    }
    const pw = s * 0.52;
    const ph = s * 0.36;
    const px = x + s * 0.28;
    const py = y + s * 0.56;
    cv.rect(px, py, pw, ph, s * 0.12, col.alpha(0.9));
    // 人差し指〜小指
    const fw = pw / 4.6;
    for (0..4) |i| {
        const on = mask & (@as(u8, 2) << @intCast(i)) != 0;
        const len = if (on) s * @as(f32, if (i == 1) 0.46 else if (i == 3) 0.32 else 0.42) else s * 0.1;
        const fx = px + fw * 0.3 + @as(f32, @floatFromInt(i)) * (fw * 1.1);
        cv.rect(fx, py - len + s * 0.04, fw, len, fw / 2, if (on) col else col.alpha(0.45));
    }
    // 親指(左下から斜めに)
    const ton = mask & poses.THUMB != 0;
    if (ton) {
        cv.rect(x + s * 0.06, y + s * 0.5, s * 0.26, fw, fw / 2, col);
    } else cv.rect(x + s * 0.2, y + s * 0.62, s * 0.11, fw, fw / 2, col.alpha(0.45));
}

// ---- 描画 ----

fn draw(_: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
    const app = st.app orelse return false;
    const moving = st.show.step(dt);
    const e = st.show.x;
    if (!st.open and !moving and e < 0.01) {
        app.reap_pending = true;
        return false;
    }
    st.n_hits = 0;
    const W: f32 = @floatFromInt(s.width);
    const H: f32 = @floatFromInt(s.height);
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    cv.rect(0, 0, W, H, 0, black.alpha(0.45 * e));
    const pw = @min(1060, W - 60);
    const ph = @min(680, H - 60);
    const x0 = (W - pw) / 2;
    const y0 = (H - ph) / 2 + (1 - e) * 30;
    cv.save();
    cv.opacity(e);
    cv.shadow(x0, y0 + 14, pw, ph, 30, 50, black.alpha(0.5));
    cv.glass(x0, y0, pw, ph, 30, theme.glassStrong(app));
    cv.rectBorder(x0, y0, pw, ph, 30, .{ .a = 0 }, white.alpha(0.14), 1);

    // 見出し
    _ = cv.text(x0 + 30, y0 + 44, 22, txt, "ハンドのポーズ", .{ .bold = true });
    _ = cv.text(x0 + 30, y0 + 68, 12.5, sub, "片手・両手のポーズを、アプリや操作に割り当てます。ポーズを 0.7 秒止めると動きます", .{ .max_w = pw - 120 });
    const cr = [4]f32{ x0 + pw - 54, y0 + 22, 32, 32 };
    cv.rect(cr[0], cr[1], cr[2], cr[3], 16, white.alpha(if (isHover(.close, 0)) 0.2 else 0.08));
    _ = cv.text(cr[0] + 16, cr[1] + 22, 16, txt, "\u{F0156}", .{ .alignment = .center });
    addHit(cr, .close, 0);
    // ハンド操作の動き方: 全部(カーソル・クリック・ポーズ)/ ポーズだけ(割り当てたポーズでアプリの起動など)
    {
        const hand = @import("hand.zig");
        const po = if (hand.enabled()) hand.posesOnly() else app.cfg.hand_poses_only;
        const mx = x0 + pw - 340;
        _ = cv.text(mx - 8, y0 + 43, 12, sub, if (hand.enabled()) "ハンド操作(オン)" else "ハンド操作(オフ)", .{ .alignment = .right });
        const segs = [_]struct { k: HitKind, label: []const u8, on: bool }{
            .{ .k = .mode_full, .label = "全部", .on = !po },
            .{ .k = .mode_poses, .label = "ポーズだけ", .on = po },
        };
        for (segs, 0..) |sg, k| {
            const r = [4]f32{ mx + @as(f32, @floatFromInt(k)) * 132, y0 + 22, 128, 32 };
            cv.rect(r[0], r[1], r[2], r[3], 16, if (sg.on) acc.alpha(0.5) else white.alpha(if (isHover(sg.k, 0)) 0.14 else 0.07));
            _ = cv.text(r[0] + r[2] / 2, r[1] + 21, 12.5, txt, sg.label, .{ .alignment = .center, .bold = sg.on });
            addHit(r, sg.k, 0);
        }
    }

    const top = y0 + 92;
    const lw = pw * 0.4;
    drawList(app, cv, x0 + 24, top, lw - 24, y0 + ph - 24 - top, acc, txt, sub);
    drawEditor(app, cv, x0 + lw + 16, top, pw - lw - 40, y0 + ph - 24 - top, acc, txt, sub);
    const rec_anim = drawRecord(app, cv, x0, y0, pw, ph, acc, txt, sub);
    const live_anim = tickLive();
    cv.restore();
    return moving or e < 0.999 or rec_anim or live_anim;
}

// ---- 自分のポーズの登録: 名前 → 3 秒数える → 1.5 秒撮る ----

const COUNT_MS = 3000;
const LIVE_MS = 3000;

/// 「カメラに映っている手のポーズを使う」: 3 秒数えてから取り込む(ハンド操作がオフならオンにする)
fn startLive(app: *App) void {
    const hand = @import("hand.zig");
    if (!hand.enabled()) hand.enableMode(app, app.cfg.hand_poses_only);
    st.live_t0 = loop.nowMs();
    setMsg("3 秒後に、カメラに映っている手のポーズを取り込みます");
}

/// 数え終わったら取り込む(描くたびに呼ぶ)。数えている間は true
fn tickLive() bool {
    if (st.live_t0 == 0) return false;
    if (loop.nowMs() -| st.live_t0 < LIVE_MS) return true;
    st.live_t0 = 0;
    const cp = @import("hand.zig").currentPose() orelse {
        setMsg("手が見えませんでした(カメラの前で、もう一度)");
        return false;
    };
    st.a = cp[0];
    st.b = cp[1];
    st.two = cp[1] != poses.NONE;
    st.editing_b = false;
    var mb: [160]u8 = undefined;
    setMsg(if (st.two)
        (std.fmt.bufPrint(&mb, "取り込みました: {s} + {s}", .{ poses.poseName(st.a), poses.poseName(st.b) }) catch "取り込みました")
    else
        (std.fmt.bufPrint(&mb, "取り込みました: {s}", .{poses.poseName(st.a)}) catch "取り込みました"));
    return false;
}
const CAPTURE_MS = 1500;

fn startRecord(app: *App) void {
    if (st.rec_name_len == 0) {
        setMsg("名前を打ってください");
        return;
    }
    const hand = @import("hand.zig");
    if (!hand.enabled()) hand.enable(app);
    st.rec = .countdown;
    st.rec_t0 = loop.nowMs();
    st.rec_n = 0;
}

fn finishRecord() void {
    st.rec = .off;
    // 撮ったコマの半分以上で両手が映っていれば両手のポーズ(両手のコマだけ使う)、でなければ片手のポーズ
    var two: usize = 0;
    for (st.rec_hands[0..st.rec_n]) |h| two += @intFromBool(h == 2);
    const hands: u8 = if (two * 2 >= st.rec_n and two > 0) 2 else 1;
    var k: usize = 0;
    for (0..st.rec_n) |i| {
        if ((hands == 2) != (st.rec_hands[i] == 2) and hands == 2) continue;
        st.rec_samples[k] = st.rec_samples[i];
        k += 1;
    }
    if (k < 6) {
        setMsg("手がよく見えなかったので、登録できませんでした(カメラの前で、もう一度)");
        return;
    }
    const idx = custom.add(st.rec_name[0..st.rec_name_len], hands, st.rec_samples[0..k]) orelse {
        setMsg("登録できませんでした(多すぎます。使わないポーズを消してください)");
        return;
    };
    st.rec_n = k;
    poses.reload();
    const id = custom.BASE + @as(u8, @intCast(idx));
    if (st.editing_b) st.b = id else st.a = id;
    var mb: [160]u8 = undefined;
    setMsg(std.fmt.bufPrint(&mb, "「{s}」を{s}のポーズとして登録しました({d} コマ)。下で操作を選んで「追加」してください", .{ custom.poses()[idx].nameStr(), if (hands == 2) "両手" else "片手", st.rec_n }) catch "登録しました");
    // 両手のポーズは、それだけで 1 つのポーズ(手 2 は使わない)
    if (hands == 2) {
        st.a = id;
        st.b = poses.NONE;
        st.two = false;
        st.editing_b = false;
    }
}

fn drawRecord(app: *App, cv: *gfx.Canvas, x0: f32, y0: f32, pw: f32, ph: f32, acc: Color, txt: Color, sub: Color) bool {
    if (st.rec == .off) return false;
    const now = loop.nowMs();
    const live = @import("hand.zig").latestShape();
    // 時間で進める
    if (st.rec == .countdown and now -| st.rec_t0 >= COUNT_MS) {
        st.rec = .capture;
        st.rec_t0 = now;
        st.rec_n = 0;
    }
    if (st.rec == .capture) {
        if (live) |l| if (l.seq != st.rec_seq and st.rec_n < st.rec_samples.len) {
            st.rec_seq = l.seq;
            st.rec_samples[st.rec_n] = .{ l.a, l.b };
            st.rec_hands[st.rec_n] = l.hands;
            st.rec_n += 1;
        };
        if (now -| st.rec_t0 >= CAPTURE_MS) {
            finishRecord();
            return true;
        }
    }
    // 画面: 設定画面を暗くして、真ん中にカード
    cv.rect(x0, y0, pw, ph, 30, black.alpha(0.5));
    const cw: f32 = 460;
    const ch: f32 = 250;
    const cx = x0 + (pw - cw) / 2;
    const cy = y0 + (ph - ch) / 2;
    cv.shadow(cx, cy + 10, cw, ch, 24, 40, black.alpha(0.5));
    cv.glass(cx, cy, cw, ch, 24, theme.glassStrong(app));
    cv.rectBorder(cx, cy, cw, ch, 24, .{ .a = 0 }, white.alpha(0.16), 1);
    _ = cv.text(cx + 24, cy + 38, 18, txt, "自分のポーズを登録", .{ .bold = true });
    switch (st.rec) {
        .naming => {
            const fr = [4]f32{ cx + 24, cy + 58, cw - 48, 38 };
            cv.rect(fr[0], fr[1], fr[2], fr[3], 12, white.alpha(0.1));
            _ = cv.text(fr[0] + 12, fr[1] + 25, 14, if (st.rec_name_len > 0) txt else sub, if (st.rec_name_len > 0) st.rec_name[0..st.rec_name_len] else "名前を打つ(例: OK サイン)", .{ .max_w = fr[2] - 24 });
            _ = cv.text(cx + 24, cy + 122, 12, sub, "「撮影を始める」の 3 秒後から 1.5 秒撮ります。カメラの前で形を作り、", .{ .max_w = cw - 48 });
            _ = cv.text(cx + 24, cy + 140, 12, sub, "撮っている間に、形と向きを保ったまま少しずつ動かすと見分けやすくなります。", .{ .max_w = cw - 48 });
            _ = cv.text(cx + 24, cy + 158, 12, sub, "両手を映せば両手のポーズ(カメラを構える形など)、手の向きも覚えます。", .{ .max_w = cw - 48 });
            const cr = [4]f32{ cx + cw - 300, cy + ch - 58, 120, 38 };
            cv.rect(cr[0], cr[1], cr[2], cr[3], 19, white.alpha(if (isHover(.rec_cancel, 0)) 0.16 else 0.08));
            _ = cv.text(cr[0] + cr[2] / 2, cr[1] + 25, 13, txt, "やめる", .{ .alignment = .center });
            addHit(cr, .rec_cancel, 0);
            const sr = [4]f32{ cx + cw - 168, cy + ch - 58, 144, 38 };
            const ok = st.rec_name_len > 0;
            cv.rect(sr[0], sr[1], sr[2], sr[3], 19, if (ok) acc else white.alpha(0.08));
            _ = cv.text(sr[0] + sr[2] / 2, sr[1] + 25, 13, if (ok) Color.hex(0x08101e) else sub, "撮影を始める", .{ .alignment = .center, .bold = true });
            addHit(sr, .rec_start, 0);
        },
        .countdown => {
            const left: u64 = (COUNT_MS -| (now -| st.rec_t0) + 999) / 1000;
            var nb: [8]u8 = undefined;
            _ = cv.text(cx + cw / 2, cy + 150, 72, acc.lighten(0.3), std.fmt.bufPrint(&nb, "{d}", .{left}) catch "", .{ .alignment = .center, .bold = true });
            _ = cv.text(cx + cw / 2, cy + 200, 13, if (live != null) txt else theme.danger(app).lighten(0.3), if (live != null) "カメラの前で形を作ってください" else "手が見えません(カメラの前に手を出してください)", .{ .alignment = .center, .max_w = cw - 40 });
        },
        .capture => {
            const p = std.math.clamp(@as(f32, @floatFromInt(now -| st.rec_t0)) / CAPTURE_MS, 0, 1);
            cv.rect(cx + 24, cy + 120, cw - 48, 10, 5, white.alpha(0.15));
            cv.rect(cx + 24, cy + 120, (cw - 48) * p, 10, 5, acc);
            var mb: [64]u8 = undefined;
            const now_two = if (live) |l| l.hands == 2 else false;
            _ = cv.text(cx + cw / 2, cy + 170, 14, txt, std.fmt.bufPrint(&mb, "撮っています… {d} コマ({s})", .{ st.rec_n, if (now_two) "両手" else "片手" }) catch "", .{ .alignment = .center });
            _ = cv.text(cx + cw / 2, cy + 196, 12, sub, "形を保ったまま、少しずつ向きを変えてください", .{ .alignment = .center });
        },
        .off => {},
    }
    return st.rec != .naming;
}

fn isHover(kind: HitKind, i: usize) bool {
    if (st.hover < 0 or st.hover >= st.n_hits) return false;
    const h = st.hits[@intCast(st.hover)];
    return h.kind == kind and h.i == i;
}

fn drawList(app: *App, cv: *gfx.Canvas, x: f32, y: f32, w: f32, h: f32, acc: Color, txt: Color, sub: Color) void {
    _ = acc;
    _ = cv.text(x, y + 14, 14, txt, "割り当て", .{ .bold = true });
    const list = poses.bindings();
    const row_h: f32 = 58;
    const ly = y + 28;
    const rows_fit: usize = @intFromFloat(@max(1, (h - 28 - 120) / row_h));
    if (list.len == 0) {
        _ = cv.text(x, ly + 30, 13, sub, "まだありません。右で作ってください", .{});
    }
    if (st.list_scroll + rows_fit > list.len) st.list_scroll = list.len -| rows_fit;
    var i = st.list_scroll;
    var ry = ly;
    while (i < list.len and i < st.list_scroll + rows_fit) : (i += 1) {
        const bn = &list[i];
        cv.rect(x, ry, w, row_h - 8, 14, white.alpha(0.06));
        drawHand(cv, x + 8, ry + 4, 42, bn.a, txt);
        var nx = x + 56;
        if (bn.b != poses.NONE) {
            _ = cv.text(nx + 2, ry + 30, 14, sub, "+", .{});
            drawHand(cv, nx + 12, ry + 4, 42, bn.b, txt);
            nx += 58;
        }
        var nb: [96]u8 = undefined;
        const pname = if (bn.b != poses.NONE)
            (std.fmt.bufPrint(&nb, "{s} + {s}", .{ poses.poseName(bn.a), poses.poseName(bn.b) }) catch "")
        else
            poses.poseName(bn.a);
        _ = cv.text(nx, ry + 20, 13, txt, pname, .{ .bold = true, .max_w = x + w - 44 - nx });
        var db: [160]u8 = undefined;
        _ = cv.text(nx, ry + 39, 12, sub, poses.describe(app, bn, &db), .{ .max_w = x + w - 44 - nx });
        const dr = [4]f32{ x + w - 38, ry + 9, 30, 30 };
        cv.rect(dr[0], dr[1], dr[2], dr[3], 15, if (isHover(.del, i)) theme.danger(app).alpha(0.5) else white.alpha(0.06));
        _ = cv.text(dr[0] + 15, dr[1] + 21, 14, txt, "\u{F0156}", .{ .alignment = .center });
        addHit(dr, .del, i);
        ry += row_h;
    }
    // 元からある動き(割り当てなければこれ)
    const by = y + h - 112;
    const hints = [_][]const u8{
        "元からある動き",
        "パー: 手のメニュー / 握りこぶし: 窓を閉じる",
        "いいね・ピース・3 本・4 本: ワークスペース",
        "つまむ: クリック・ドラッグ / 親指と中指: 右クリック",
        "ピースを上下・左右に動かす: スクロール",
        "片手のポーズを割り当てると、元の動きの代わりになります",
    };
    for (hints, 0..) |t, k| _ = cv.text(x, by + @as(f32, @floatFromInt(k)) * 18, 11.5, sub, t, .{ .max_w = w, .bold = k == 0 });
}

fn drawEditor(app: *App, cv: *gfx.Canvas, x: f32, y: f32, w: f32, h: f32, acc: Color, txt: Color, sub: Color) void {
    // ---- 1. ポーズ ----
    _ = cv.text(x, y + 14, 14, txt, "1. ポーズ", .{ .bold = true });
    // 手 1 / 手 2 の切り替えと「両手にする」
    var cx = x + 90;
    const chip_h: f32 = 28;
    {
        const r = [4]f32{ cx, y - 2, 120, chip_h };
        cv.rect(r[0], r[1], r[2], r[3], 14, if (!st.editing_b) acc.alpha(0.5) else white.alpha(0.07));
        var b1: [64]u8 = undefined;
        _ = cv.text(r[0] + r[2] / 2, r[1] + 19, 12, txt, std.fmt.bufPrint(&b1, "手 1: {s}", .{if (st.a == poses.NONE) "未選択" else poses.poseName(st.a)}) catch "", .{ .alignment = .center, .max_w = r[2] - 10 });
        addHit(r, .which_a, 0);
        cx += 128;
    }
    {
        const r = [4]f32{ cx, y - 2, 110, chip_h };
        cv.rect(r[0], r[1], r[2], r[3], 14, if (st.two) acc.alpha(0.35) else white.alpha(0.07));
        _ = cv.text(r[0] + r[2] / 2, r[1] + 19, 12, txt, if (st.two) "両手 \u{F012C}" else "両手にする", .{ .alignment = .center });
        addHit(r, .two, 0);
        cx += 118;
    }
    if (st.two) {
        const r = [4]f32{ cx, y - 2, 120, chip_h };
        cv.rect(r[0], r[1], r[2], r[3], 14, if (st.editing_b) acc.alpha(0.5) else white.alpha(0.07));
        var b2: [64]u8 = undefined;
        _ = cv.text(r[0] + r[2] / 2, r[1] + 19, 12, txt, std.fmt.bufPrint(&b2, "手 2: {s}", .{if (st.b == poses.NONE) "未選択" else poses.poseName(st.b)}) catch "", .{ .alignment = .center, .max_w = r[2] - 10 });
        addHit(r, .which_b, 0);
    }
    // ポーズの一覧(8 列 × 3 段): よく使う形 → 自分のポーズ → 「+ 自分のポーズ」
    const gy = y + 36;
    const cols: usize = 8;
    const gap: f32 = 6;
    const tw = (w - @as(f32, @floatFromInt(cols - 1)) * gap) / @as(f32, @floatFromInt(cols));
    const th: f32 = 66;
    const cur = if (st.editing_b) st.b else st.a;
    const mine = custom.poses();
    const n_tiles = @min(poses.presets.len + mine.len + 1, cols * 3);
    for (0..n_tiles) |i| {
        const col: f32 = @floatFromInt(i % cols);
        const row: f32 = @floatFromInt(i / cols);
        const r = [4]f32{ x + col * (tw + gap), gy + row * (th + gap), tw, th };
        if (i < poses.presets.len) {
            const p = poses.presets[i];
            const sel = p.mask == cur;
            cv.rect(r[0], r[1], r[2], r[3], 12, if (sel) acc.alpha(0.45) else white.alpha(if (isHover(.preset, i)) 0.14 else 0.06));
            drawHand(cv, r[0] + r[2] / 2 - 19, r[1] + 4, 38, p.mask, txt);
            _ = cv.text(r[0] + r[2] / 2, r[1] + th - 8, 10.5, txt, p.name, .{ .alignment = .center, .max_w = r[2] - 4 });
            addHit(r, .preset, i);
        } else if (i - poses.presets.len < mine.len) {
            // 自分のポーズ(星の付いた手。右上の × で消す)
            const k = i - poses.presets.len;
            const id = custom.BASE + @as(u8, @intCast(k));
            const sel = id == cur;
            cv.rect(r[0], r[1], r[2], r[3], 12, if (sel) acc.alpha(0.45) else white.alpha(if (isHover(.custom_pose, k)) 0.14 else 0.06));
            drawHand(cv, r[0] + r[2] / 2 - 19, r[1] + 4, 38, id, txt);
            _ = cv.text(r[0] + r[2] / 2, r[1] + th - 8, 10.5, txt, mine[k].nameStr(), .{ .alignment = .center, .max_w = r[2] - 4 });
            addHit(r, .custom_pose, k);
            const dr = [4]f32{ r[0] + r[2] - 20, r[1] + 3, 17, 17 };
            if (isHover(.custom_pose, k) or isHover(.cdel, k)) {
                cv.rect(dr[0], dr[1], dr[2], dr[3], 8.5, if (isHover(.cdel, k)) theme.danger(app).alpha(0.7) else white.alpha(0.15));
                _ = cv.text(dr[0] + 8.5, dr[1] + 12.5, 10, txt, "\u{F0156}", .{ .alignment = .center });
            }
            addHit(dr, .cdel, k);
        } else {
            // 自分のポーズを登録する
            cv.rectBorder(r[0], r[1], r[2], r[3], 12, white.alpha(if (isHover(.add_custom, 0)) 0.12 else 0.03), acc.alpha(0.6), 1.2);
            _ = cv.text(r[0] + r[2] / 2, r[1] + 32, 22, acc.lighten(0.3), "+", .{ .alignment = .center, .bold = true });
            _ = cv.text(r[0] + r[2] / 2, r[1] + th - 8, 10.5, txt, "自分のポーズ", .{ .alignment = .center, .max_w = r[2] - 4 });
            addHit(r, .add_custom, 0);
        }
    }
    const rows_used: f32 = @floatFromInt((n_tiles + cols - 1) / cols);
    var yy = gy + rows_used * (th + gap) + 2;
    // カメラに映した手のポーズを使う: 押してから 3 秒後に取り込む(両手でポーズしていても、押してから作ればよい)
    {
        const r = [4]f32{ x, yy, w, 34 };
        const counting = st.live_t0 != 0;
        cv.rect(r[0], r[1], r[2], r[3], 12, if (counting) acc.alpha(0.3) else white.alpha(if (isHover(.use_live, 0)) 0.16 else 0.07));
        if (@import("hand.zig").currentPose()) |cp| {
            drawHand(cv, r[0] + 8, r[1] + 2, 30, cp[0], acc.lighten(0.3));
            if (cp[1] != poses.NONE) drawHand(cv, r[0] + 40, r[1] + 2, 30, cp[1], acc.lighten(0.3));
        } else _ = cv.text(r[0] + 22, r[1] + 23, 16, sub, "\u{F1821}", .{ .alignment = .center });
        var lb: [96]u8 = undefined;
        const label = if (counting)
            (std.fmt.bufPrint(&lb, "あと {d} 秒で取り込みます。ポーズを作ってください(両手でも)", .{(LIVE_MS -| (loop.nowMs() -| st.live_t0) + 999) / 1000}) catch "")
        else
            "3 秒後に、カメラに映っている手のポーズを使う(スペースでも)";
        _ = cv.text(r[0] + 80, r[1] + 22, 12.5, txt, label, .{ .max_w = w - 90 });
        addHit(r, .use_live, 0);
        yy += 42;
    }

    // ---- 2. 操作 ----
    _ = cv.text(x, yy + 16, 14, txt, "2. 割り当てる操作", .{ .bold = true });
    const tabs = [_][]const u8{ "操作", "アプリを起動", "コマンド" };
    var tx = x + 150;
    for (tabs, 0..) |t, i| {
        const r = [4]f32{ tx, yy, 104, 26 };
        const on = @intFromEnum(st.tab) == i;
        cv.rect(r[0], r[1], r[2], r[3], 13, if (on) acc.alpha(0.45) else white.alpha(0.07));
        _ = cv.text(r[0] + r[2] / 2, r[1] + 18, 12, txt, t, .{ .alignment = .center });
        addHit(r, .tab, i);
        tx += 110;
    }
    yy += 36;
    const area_h = y + h - 56 - yy;
    switch (st.tab) {
        .action => {
            const ocols: usize = 4;
            const ow = (w - @as(f32, @floatFromInt(ocols - 1)) * 6) / @as(f32, @floatFromInt(ocols));
            const oh: f32 = 28;
            const n_ops = @typeInfo(poses.Op).Enum.fields.len;
            for (0..n_ops) |i| {
                const col: f32 = @floatFromInt(i % ocols);
                const row: f32 = @floatFromInt(i / ocols);
                const r = [4]f32{ x + col * (ow + 6), yy + row * (oh + 6), ow, oh };
                if (r[1] + r[3] > yy + area_h) break;
                const op: poses.Op = @enumFromInt(i);
                const sel = st.op != null and st.op.? == op;
                cv.rect(r[0], r[1], r[2], r[3], 10, if (sel) acc.alpha(0.45) else white.alpha(if (isHover(.op, i)) 0.14 else 0.06));
                _ = cv.text(r[0] + r[2] / 2, r[1] + 19, 11.5, txt, op.label(), .{ .alignment = .center, .max_w = r[2] - 8 });
                addHit(r, .op, i);
            }
        },
        .app => {
            // 絞り込み(文字を打つ)
            const fr = [4]f32{ x, yy, w, 28 };
            cv.rect(fr[0], fr[1], fr[2], fr[3], 10, white.alpha(0.08));
            _ = cv.text(fr[0] + 10, fr[1] + 19, 12, if (st.filter_len > 0) txt else sub, if (st.filter_len > 0) st.filter[0..st.filter_len] else "\u{F0349} 文字を打って絞り込む", .{ .max_w = w - 20 });
            const entries = app.launcher.appEntries();
            const row_h: f32 = 36;
            const ry0 = yy + 34;
            const fit: usize = @intFromFloat(@max(1, (area_h - 34) / row_h));
            var shown: usize = 0;
            var skipped: usize = 0;
            for (entries, 0..) |*en, i| {
                if (!matches(en.display(), en.name)) continue;
                if (skipped < st.app_scroll) {
                    skipped += 1;
                    continue;
                }
                if (shown >= fit) break;
                const r = [4]f32{ x, ry0 + @as(f32, @floatFromInt(shown)) * row_h, w, row_h - 4 };
                const sel = st.app_idx != null and st.app_idx.? == i;
                cv.rect(r[0], r[1], r[2], r[3], 10, if (sel) acc.alpha(0.45) else white.alpha(if (isHover(.app, i)) 0.14 else 0.05));
                app.launcher.drawIcon(cv, en, r[0] + 6, r[1] + 4, 24);
                _ = cv.text(r[0] + 40, r[1] + 21, 12.5, txt, en.display(), .{ .max_w = w - 50 });
                addHit(r, .app, i);
                shown += 1;
            }
        },
        .command => {
            const r = [4]f32{ x, yy, w, 34 };
            cv.rect(r[0], r[1], r[2], r[3], 10, white.alpha(0.1));
            _ = cv.text(r[0] + 10, r[1] + 22, 13, if (st.text_len > 0) txt else sub, if (st.text_len > 0) st.text[0..st.text_len] else "コマンドを打つ(例: ame-ctl screenshot region)", .{ .max_w = w - 20 });
            addHit(r, .cmdbox, 0);
        },
    }

    // ---- 追加 ----
    const ar = [4]f32{ x + w - 140, y + h - 44, 140, 38 };
    const ready = canAdd();
    cv.rect(ar[0], ar[1], ar[2], ar[3], 19, if (ready) (if (isHover(.add, 0)) acc.lighten(0.15) else acc) else white.alpha(0.08));
    _ = cv.text(ar[0] + ar[2] / 2, ar[1] + 25, 14, if (ready) Color.hex(0x08101e) else sub, "追加", .{ .alignment = .center, .bold = true });
    addHit(ar, .add, 0);
    if (st.msg_len > 0) _ = cv.text(x, y + h - 20, 12, sub, st.msg[0..st.msg_len], .{ .max_w = w - 160 });
}

fn matches(a: []const u8, b: []const u8) bool {
    if (st.filter_len == 0) return true;
    const f = st.filter[0..st.filter_len];
    return std.ascii.indexOfIgnoreCase(a, f) != null or std.ascii.indexOfIgnoreCase(b, f) != null;
}

fn canAdd() bool {
    if (st.a == poses.NONE) return false;
    if (st.two and st.b == poses.NONE) return false;
    if (!st.two and st.a == poses.POINT) return false;
    return switch (st.tab) {
        .action => st.op != null,
        .app => st.app_idx != null,
        .command => st.text_len > 0,
    };
}

fn doAdd() void {
    const app = st.app orelse return;
    if (!canAdd()) {
        setMsg(if (!st.two and st.a == poses.POINT) "指さし(人差し指だけ)はカーソルなので割り当てられません" else "ポーズと操作を選んでください");
        return;
    }
    var bn = poses.Binding{ .a = st.a, .b = if (st.two) st.b else poses.NONE };
    switch (st.tab) {
        .action => {
            bn.kind = .action;
            bn.op = st.op.?;
        },
        .app => {
            bn.kind = .app;
            const entries = app.launcher.appEntries();
            if (st.app_idx.? >= entries.len) return;
            bn.setArg(entries[st.app_idx.?].id);
        },
        .command => {
            bn.kind = .command;
            bn.setArg(st.text[0..st.text_len]);
        },
    }
    if (!poses.add(bn)) {
        setMsg("追加できませんでした(多すぎるか、使えないポーズです)");
        return;
    }
    if (bn.b == poses.NONE) {
        if (poses.builtinOf(bn.a)) |b| {
            var mb: [160]u8 = undefined;
            setMsg(std.fmt.bufPrint(&mb, "追加しました(元の「{s}」の代わりになります)", .{b}) catch "追加しました");
            return;
        }
    }
    setMsg("追加しました");
}

// ---- 入力 ----

fn pointer(_: *anyopaque, s: *Surface, ev: surface.PointerEvent) void {
    if (!st.open) return;
    switch (ev.kind) {
        .motion, .enter => {
            const h = hoverIdx(ev.x, ev.y);
            if (h != st.hover) {
                st.hover = h;
                s.schedule();
            }
        },
        .leave => st.hover = -1,
        .scroll => {
            const down = ev.scroll > 0;
            if (st.tab == .app and ev.x > (@as(f32, @floatFromInt(s.width)) / 2)) {
                st.app_scroll = if (down) st.app_scroll + 2 else st.app_scroll -| 2;
            } else st.list_scroll = if (down) st.list_scroll + 1 else st.list_scroll -| 1;
            s.schedule();
        },
        .press => {
            const h = hitAt(ev.x, ev.y) orelse return;
            // 登録のカードが出ている間は、カードのボタンだけ
            if (st.rec != .off and h.kind != .rec_start and h.kind != .rec_cancel) return;
            switch (h.kind) {
                .custom_pose => {
                    const id = custom.BASE + @as(u8, @intCast(h.i));
                    if (st.editing_b) st.b = id else st.a = id;
                    if (st.two and !st.editing_b and st.b == poses.NONE) st.editing_b = true;
                },
                .cdel => {
                    custom.remove(h.i);
                    // 番号がずれるので、割り当てを名前から読み直す(消したポーズの割り当ては使われなくなる)
                    poses.reload();
                    st.a = poses.NONE;
                    st.b = poses.NONE;
                    setMsg("自分のポーズを消しました");
                },
                .add_custom => {
                    st.rec = .naming;
                    st.rec_name_len = 0;
                },
                .rec_start => if (st.rec == .naming) startRecord(st.app.?),
                .rec_cancel => st.rec = .off,
                .close => close(),
                .del => poses.remove(h.i),
                .preset => {
                    const m = poses.presets[h.i].mask;
                    if (st.editing_b) st.b = m else st.a = m;
                    // 両手で手 1 を選んだら、次は手 2
                    if (st.two and !st.editing_b and st.b == poses.NONE) st.editing_b = true;
                },
                .which_a => st.editing_b = false,
                .which_b => st.editing_b = true,
                .two => {
                    st.two = !st.two;
                    st.editing_b = st.two and st.a != poses.NONE;
                    if (!st.two) st.b = poses.NONE;
                },
                .use_live => startLive(st.app.?),
                .mode_full => @import("hand.zig").enableMode(st.app.?, false),
                .mode_poses => @import("hand.zig").enableMode(st.app.?, true),
                .tab => st.tab = @enumFromInt(h.i),
                .op => st.op = @enumFromInt(h.i),
                .app => st.app_idx = h.i,
                .cmdbox => {},
                .add => doAdd(),
            }
            s.schedule();
        },
        else => {},
    }
}

fn key(_: *anyopaque, s: *Surface, ev: surface.KeyEvent) void {
    if (!st.open) return;
    // 登録のカード: 名前を打つ / Enter で撮影 / Esc でやめる
    if (st.rec != .off) {
        switch (ev.sym) {
            c.XKB_KEY_Escape => st.rec = .off,
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => if (st.rec == .naming) startRecord(st.app.?),
            c.XKB_KEY_BackSpace => if (st.rec == .naming) {
                st.rec_name_len = backspace(st.rec_name[0..st.rec_name_len]);
            },
            else => if (st.rec == .naming and ev.utf8.len > 0 and ev.utf8[0] >= 0x20 and !ev.ctrl) {
                if (st.rec_name_len + ev.utf8.len <= st.rec_name.len) {
                    @memcpy(st.rec_name[st.rec_name_len .. st.rec_name_len + ev.utf8.len], ev.utf8);
                    st.rec_name_len += ev.utf8.len;
                }
            },
        }
        s.schedule();
        return;
    }
    // スペース(操作のタブ): 3 秒後に、カメラに映っている手のポーズを取り込む
    if (ev.sym == c.XKB_KEY_space and st.tab == .action) {
        startLive(st.app.?);
        s.schedule();
        return;
    }
    switch (ev.sym) {
        c.XKB_KEY_Escape => close(),
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => doAdd(),
        c.XKB_KEY_BackSpace => {
            if (st.tab == .command) st.text_len = backspace(st.text[0..st.text_len]) else if (st.tab == .app) {
                st.filter_len = backspace(st.filter[0..st.filter_len]);
                st.app_scroll = 0;
            }
        },
        else => if (ev.utf8.len > 0 and ev.utf8[0] >= 0x20 and !ev.ctrl) {
            if (st.tab == .command) {
                if (st.text_len + ev.utf8.len <= st.text.len) {
                    @memcpy(st.text[st.text_len .. st.text_len + ev.utf8.len], ev.utf8);
                    st.text_len += ev.utf8.len;
                }
            } else {
                // 操作のタブで文字を打ったら、アプリを探す
                st.tab = .app;
                if (st.filter_len + ev.utf8.len <= st.filter.len) {
                    @memcpy(st.filter[st.filter_len .. st.filter_len + ev.utf8.len], ev.utf8);
                    st.filter_len += ev.utf8.len;
                    st.app_scroll = 0;
                }
            }
        },
    }
    s.schedule();
}

/// UTF-8 の最後の 1 文字を消した長さ
fn backspace(s: []const u8) usize {
    if (s.len == 0) return 0;
    var i = s.len - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}
