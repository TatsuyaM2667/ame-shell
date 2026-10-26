// ダッシュボード(上の縁から生えるドロワー)。タブ: ダッシュボード / メディア / パフォーマンス / ワークスペース。
// タブを切り替えるとドロワー自体の大きさがスプリングで変わり、中身はクロスフェードする。
const std = @import("std");
const c = @import("../c.zig");
const anim = @import("../anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("../gfx.zig");
const theme = @import("../theme.zig");
const surface = @import("../surface.zig");
const sys = @import("../platform/sys.zig");
const barmod = @import("../bar.zig");
const data = @import("data.zig");
const abi = @import("../widget_abi.zig");
const Frame = @import("frame.zig").Frame;

const TAB_H: f32 = 58;
const PAD: f32 = 14;
const GAP: f32 = 10;

const tabs = [_]struct { icon: []const u8, label: []const u8 }{
    .{ .icon = "\u{F056E}", .label = "ダッシュボード" },
    .{ .icon = "\u{F075A}", .label = "メディア" },
    .{ .icon = "\u{F04C5}", .label = "パフォーマンス" },
    .{ .icon = "\u{F0570}", .label = "ワークスペース" },
};

const Btn = enum(u8) { none, tab0, tab1, tab2, tab3, prev, play, next, big_prev, big_play, big_next, ws0, shuffle, loop };

pub const View = struct {
    tab: usize = 0,
    ind_a: Spring = Spring.init(0, 0.22, 0.75),
    ind_b: Spring = Spring.init(0, 0.40, 0.92),
    fade: Spring = Spring.init(1, 0.32, 1.0),
    hover: Btn = .none,
    hover_ws: i32 = -1,
    hl: [16]Spring = [_]Spring{Spring.init(0, 0.2, 1.0)} ** 16,
    perf_v: [4]Spring = [_]Spring{Spring.init(0, 0.6, 0.9)} ** 4,
    res_v: [3]Spring = [_]Spring{Spring.init(0, 0.6, 0.9)} ** 3,
    vinyl_angle: f32 = 0,
    arm: Spring = Spring.init(0, 0.6, 0.85),
    lyr_scroll: Spring = Spring.init(0, 0.45, 0.9),
    // カレンダー(WASM)の配置(入力の転送用)
    cal_rect: [4]f32 = .{ 0, 0, 0, 0 },
    btn_rects: [16][4]f32 = undefined,
    btn_kinds: [16]Btn = undefined,
    n_btn: usize = 0,
};

pub fn size(f: *Frame) [2]f32 {
    return switch (f.dashv.tab) {
        0 => .{ 900, TAB_H + 100 + GAP + 250 + PAD },
        // メディアは横に広いので、画面に収まる幅に抑える(中身は幅に合わせて配置する)
        1 => .{ @min(1180, f.W - f.BW() - f.T() - 2 * f.R() - 30), TAB_H + 380 + PAD },
        2 => .{ @min(1040, f.W - f.BW() - f.T() - 2 * f.R() - 30), TAB_H + 330 + PAD },
        else => .{ 620, TAB_H + 3 * 64 + 2 * 8 + PAD * 2 },
    };
}

fn card(cv: *gfx.Canvas, x: f32, y: f32, w: f32, h: f32) void {
    cv.rectGrad(x, y, w, h, 16, Color.hex(0xffffff).alpha(0.07), Color.hex(0xffffff).alpha(0.03));
    cv.rectBorder(x, y, w, h, 16, .{ .a = 0 }, Color.hex(0xffffff).alpha(0.07), 1);
}

fn addBtn(v: *View, kind: Btn, x: f32, y: f32, w: f32, h: f32) f32 {
    if (v.n_btn < v.btn_rects.len) {
        v.btn_rects[v.n_btn] = .{ x, y, w, h };
        v.btn_kinds[v.n_btn] = kind;
        v.n_btn += 1;
    }
    return if (v.hover == kind) 1 else 0;
}

pub fn draw(f: *Frame, cv: *gfx.Canvas, dt: f32) bool {
    const v = &f.dashv;
    const app = f.app;
    const w = f.dash.w.x;
    var animating = false;
    v.ind_a.set(@floatFromInt(v.tab));
    v.ind_b.set(@floatFromInt(v.tab));
    var sp = [_]*Spring{ &v.ind_a, &v.ind_b, &v.fade };
    if (anim.stepAll(&sp, dt)) animating = true;
    v.n_btn = 0;

    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);

    // ---- タブ(下線のインジケータは 2 本のスプリングで伸びながら移動) ----
    const tw = w / @as(f32, @floatFromInt(tabs.len));
    for (tabs, 0..) |t, i| {
        const fi: f32 = @floatFromInt(i);
        const hv = addBtn(v, @enumFromInt(@as(u8, @intCast(1 + i))), fi * tw, 4, tw, TAB_H - 8);
        const on = std.math.clamp(1 - @abs(fi - v.ind_a.x), 0, 1);
        const col = Color.mix(Color.mix(sub, txt, hv), acc, on);
        _ = cv.text(fi * tw + tw / 2, 28, 18, col, t.icon, .{ .alignment = .center, .glow = 3 * on, .glow_color = acc.alpha(0.5) });
        _ = cv.text(fi * tw + tw / 2, 48, 11.5, col, t.label, .{ .alignment = .center, .bold = on > 0.5 });
    }
    {
        const a_ = @min(v.ind_a.x, v.ind_b.x);
        const b_ = @max(v.ind_a.x, v.ind_b.x);
        const ix = a_ * tw + tw * 0.25;
        const iw = (b_ - a_) * tw + tw * 0.5;
        cv.rect(PAD, TAB_H - 3, w - PAD * 2, 1, 0.5, Color.hex(0xffffff).alpha(0.08));
        cv.shadow(ix, TAB_H - 5, iw, 3, 1.5, 6, acc.alpha(0.6));
        cv.rect(ix, TAB_H - 5, iw, 3, 1.5, acc);
    }

    cv.save();
    cv.translate(0, TAB_H);
    cv.opacity(v.fade.x);
    const r = switch (v.tab) {
        0 => drawDash(f, cv, dt, w),
        1 => drawMedia(f, cv, dt, w),
        2 => drawPerf(f, cv, dt, w),
        else => drawWorkspaces(f, cv, dt, w),
    };
    cv.restore();
    if (r) animating = true;
    // メディアタブを見ている間だけ cava を動かす
    const want_cava = v.tab == 1 and f.dash.open and app.media.status == .playing;
    if (want_cava and !f.cava.running()) f.cava.start();
    if (!want_cava and f.cava.running()) f.cava.stop();
    // 再生中は進捗を滑らかに見せるため描き続ける(ダッシュボードが開いている間だけ)
    if (f.dash.open and app.media.status == .playing and (v.tab == 1 or v.tab == 0)) animating = true;
    return animating;
}

// ---------------------------------------------------------------------------
// タブ 0: ダッシュボード
// ---------------------------------------------------------------------------

fn drawDash(f: *Frame, cv: *gfx.Canvas, dt: f32, w: f32) bool {
    const app = f.app;
    const v = &f.dashv;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    var animating = false;
    const y0: f32 = 6;
    const media_w: f32 = 270;
    const media_x = w - PAD - media_w;
    const left_w = media_x - GAP - PAD;
    var buf: [128]u8 = undefined;

    // 天気
    const ww: f32 = 230;
    card(cv, PAD, y0, ww, 100);
    if (f.weather.ok) {
        _ = cv.text(PAD + 44, y0 + 66, 40, acc, f.weather.icon(), .{ .alignment = .center, .glow = 6, .glow_color = acc.alpha(0.4) });
        _ = cv.text(PAD + 92, y0 + 48, 26, txt, f.weather.temp[0..f.weather.temp_len], .{ .bold = true });
        _ = cv.text(PAD + 92, y0 + 72, 13, sub, f.weather.cond[0..f.weather.cond_len], .{ .max_w = ww - 100 });
        _ = cv.text(PAD + 92, y0 + 90, 11, sub.alpha(0.8), f.weather.place[0..f.weather.place_len], .{ .max_w = ww - 100 });
    } else {
        _ = cv.text(PAD + 44, y0 + 66, 40, sub, "\u{F0590}", .{ .alignment = .center });
        _ = cv.text(PAD + 92, y0 + 56, 13, sub, if (f.weather.fd >= 0) "天気を取得中…" else "天気を取得できません", .{});
    }

    // ユーザー
    {
        const ux = PAD + ww + GAP;
        const uw = left_w - ww - GAP;
        card(cv, ux, y0, uw, 100);
        const user = std.posix.getenv("USER") orelse "user";
        cv.shadow(ux + 16, y0 + 18, 64, 64, 32, 10, acc.alpha(0.5));
        cv.rectGrad(ux + 16, y0 + 18, 64, 64, 32, acc.lighten(0.35), acc);
        var ini: [4]u8 = undefined;
        const n = std.unicode.utf8ByteSequenceLength(user[0]) catch 1;
        @memcpy(ini[0..n], user[0..n]);
        if (ini[0] >= 'a' and ini[0] <= 'z') ini[0] -= 32;
        _ = cv.text(ux + 48, y0 + 61, 28, Color.hex(0x08101e), ini[0..n], .{ .bold = true, .alignment = .center });
        var ob: [64]u8 = undefined;
        var ub: [64]u8 = undefined;
        // OS・機種・CPU・GPU(+ 起動からの時間)
        const hw = &f.hw;
        const rows = [_]struct { icon: []const u8, text: []const u8, col: Color }{
            .{ .icon = "\u{F0E17}", .text = std.fmt.bufPrint(&buf, "{s}  ・  {s}", .{ data.osName(&ob), data.uptime(&ub) }) catch "", .col = txt },
            .{ .icon = "\u{F0322}", .text = hw.modelName(), .col = txt },
            .{ .icon = "\u{F0EE0}", .text = hw.cpuName(), .col = sub },
            .{ .icon = "\u{F0379}", .text = hw.gpuName(), .col = sub },
        };
        for (rows, 0..) |row, ri| {
            const ry = y0 + 26 + @as(f32, @floatFromInt(ri)) * 21;
            _ = cv.text(ux + 98, ry, 12.5, acc.lighten(0.2), row.icon, .{ .alignment = .center });
            _ = cv.text(ux + 114, ry, 12.5, row.col, row.text, .{ .max_w = uw - 126 });
        }
    }

    // 日時(縦: 時 / ・・・ / 分 / 曜日と日)
    const y1 = y0 + 100 + GAP;
    const dtw: f32 = 110;
    card(cv, PAD, y1, dtw, 250);
    {
        const tm = barmod.localTime();
        const cx = PAD + dtw / 2;
        _ = cv.text(cx, y1 + 76, 44, txt, std.fmt.bufPrint(&buf, "{d:0>2}", .{@as(u32, @intCast(tm.tm_hour))}) catch "", .{ .bold = true, .alignment = .center });
        for (0..3) |i| cv.rect(cx - 14 + @as(f32, @floatFromInt(i)) * 12, y1 + 98, 5, 5, 2.5, acc);
        _ = cv.text(cx, y1 + 154, 44, Color.mix(txt, acc, 0.4), std.fmt.bufPrint(&buf, "{d:0>2}", .{@as(u32, @intCast(tm.tm_min))}) catch "", .{ .bold = true, .alignment = .center });
        const wd = barmod.weekdays_ja[@intCast(tm.tm_wday)];
        _ = cv.text(cx, y1 + 206, 15, sub, std.fmt.bufPrint(&buf, "{s}曜日", .{wd}) catch "", .{ .alignment = .center });
        _ = cv.text(cx, y1 + 228, 13, sub, std.fmt.bufPrint(&buf, "{d}月{d}日", .{ @as(u32, @intCast(tm.tm_mon + 1)), @as(u32, @intCast(tm.tm_mday)) }) catch "", .{ .alignment = .center });
    }

    // カレンダー(WASM ウィジェットを流用)
    const res_w: f32 = 132;
    const calx = PAD + dtw + GAP;
    const calw = left_w - dtw - GAP - res_w - GAP;
    card(cv, calx, y1, calw, 250);
    v.cal_rect = .{ calx + 10, y1 + 6, calw - 20, 238 };
    if (drawWidget(f, cv, "calendar", calx + 10, y1 + 6 + TAB_H, calw - 20, 238, dt)) animating = true;

    // リソース(縦のバー)
    {
        const rx = calx + calw + GAP;
        card(cv, rx, y1, res_w, 250);
        const vals = [3]f32{ app.sys.cpu, app.sys.mem, if (f.perf.disk_total > 0) f.perf.disk_used / f.perf.disk_total else 0 };
        const icons = [3][]const u8{ "\u{F0EE0}", "\u{F035B}", "\u{F02CA}" };
        for (0..3) |i| {
            v.res_v[i].set(vals[i]);
            if (v.res_v[i].step(dt)) animating = true;
            const bx = rx + 20 + @as(f32, @floatFromInt(i)) * 36;
            const bh: f32 = 170;
            const by = y1 + 22;
            const val = std.math.clamp(v.res_v[i].x, 0, 1);
            cv.rect(bx, by, 14, bh, 7, Color.hex(0xffffff).alpha(0.08));
            const col = Color.mix(acc, Color.hex(0xff7a90), @max(0, (val - 0.75) / 0.25));
            cv.rectGrad(bx, by + bh * (1 - val), 14, @max(bh * val, 14), 7, col.lighten(0.3), col);
            _ = cv.text(bx + 7, by + bh + 26, 15, sub, icons[i], .{ .alignment = .center });
            _ = cv.text(bx + 7, by + bh + 46, 10.5, sub, std.fmt.bufPrint(&buf, "{d}", .{@as(u32, @intFromFloat(val * 100))}) catch "", .{ .alignment = .center });
        }
    }

    // メディア(縦長のカード)
    {
        card(cv, media_x, y0, media_w, 100 + GAP + 250);
        if (drawMediaSmall(f, cv, media_x, y0, media_w, 360)) animating = true;
    }
    return animating;
}

fn mmss(buf: []u8, sec: f32) []const u8 {
    const t: u32 = @intFromFloat(@max(sec, 0));
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ t / 60, t % 60 }) catch "";
}

fn drawMediaSmall(f: *Frame, cv: *gfx.Canvas, x: f32, y: f32, w: f32, h: f32) bool {
    _ = h;
    const app = f.app;
    const v = &f.dashv;
    const m = app.media;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const cs: f32 = 150;
    const cx = x + w / 2;
    // ジャケット(円形)と進捗の円弧
    if (m.status != .none) {
        const p = if (m.length_s > 0) m.position() / m.length_s else 0;
        cv.arc(cx, y + 28 + cs / 2, cs / 2 + 10, 4, p, acc, Color.hex(0xffffff).alpha(0.08));
    }
    if (m.art_tex != 0) {
        cv.shadow(cx - cs / 2, y + 32, cs, cs, cs / 2, 14, acc.alpha(0.4));
        cv.image(m.art_tex, cx - cs / 2, y + 28, cs, cs, cs / 2);
    } else {
        cv.rectGrad(cx - cs / 2, y + 28, cs, cs, cs / 2, acc.lighten(0.3).alpha(0.6), acc.alpha(0.4));
        _ = cv.text(cx, y + 28 + cs / 2 + 18, 48, Color.hex(0xffffff).alpha(0.8), "\u{F075A}", .{ .alignment = .center });
    }
    if (m.status == .none) {
        _ = cv.text(cx, y + 230, 14, sub, "再生中のメディアはありません", .{ .alignment = .center });
        return false;
    }
    _ = cv.text(cx, y + 222, 15, txt, m.title[0..m.title_len], .{ .bold = true, .alignment = .center, .max_w = w - 30 });
    _ = cv.text(cx, y + 244, 12.5, sub, m.artist[0..m.artist_len], .{ .alignment = .center, .max_w = w - 30 });
    // 同期歌詞があれば、プレイヤー名の代わりに今の一節を出す
    const cur = m.lyrics.current(m.position());
    if (cur.idx) |li| {
        _ = cv.text(cx, y + 264, 12, acc.lighten(0.3), m.lyrics.lines.items[li].text, .{ .alignment = .center, .max_w = w - 30, .glow = 3, .glow_color = acc.alpha(0.4) });
    } else _ = cv.text(cx, y + 262, 11, acc, m.player[0..m.player_len], .{ .alignment = .center, .max_w = w - 30 });
    // 操作ボタン
    const icons = [3][]const u8{ "\u{F04AE}", if (m.status == .playing) "\u{F03E4}" else "\u{F040A}", "\u{F04AD}" };
    const kinds = [3]Btn{ .prev, .play, .next };
    for (0..3) |i| {
        const bx = cx + (@as(f32, @floatFromInt(i)) - 1) * 56;
        const big = i == 1;
        const rr: f32 = if (big) 22 else 17;
        const by = y + 310;
        const hv = addBtn(v, kinds[i], bx - rr, by - rr - TAB_H * 0 + TAB_H, rr * 2, rr * 2);
        if (big) {
            cv.shadow(bx - rr, by - rr, rr * 2, rr * 2, rr, 10, acc.alpha(0.5));
            cv.rectGrad(bx - rr, by - rr, rr * 2, rr * 2, rr, acc.lighten(0.35 + 0.2 * hv), acc);
        } else cv.rect(bx - rr, by - rr, rr * 2, rr * 2, rr, Color.hex(0xffffff).alpha(0.05 + 0.12 * hv));
        _ = cv.text(bx, by + (if (big) @as(f32, 8) else 6), if (big) 22 else 17, if (big) Color.hex(0x08101e) else txt, icons[i], .{ .alignment = .center });
    }
    return false;
}

// ---------------------------------------------------------------------------
// タブ 1: メディア(cava のスペクトラムをジャケットの周りに放射状に)
// ---------------------------------------------------------------------------

fn drawMedia(f: *Frame, cv: *gfx.Canvas, dt: f32, w: f32) bool {
    const app = f.app;
    const v = &f.dashv;
    const m = app.media;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const H: f32 = 380;
    var animating = false;
    var buf: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    const playing = m.status == .playing;

    // ---- 背景: ジャケットを大きくぼかして敷き、下へ向かって暗く ----
    if (m.art_tex != 0) {
        const box_aspect = (w - 24) / H;
        const span = 1 / box_aspect; // 正方形の画像を横長の枠に cover で
        cv.imageEx(m.art_tex, 12, 4, w - 24, H, 18, .{ 0, 0.5 - span / 2, 1, 0.5 + span / 2 }, 6.5, 0, 0.55, 0.9);
        cv.rectGrad(12, 4, w - 24, H, 18, Color.hex(0x05070f).alpha(0.25), Color.hex(0x05070f).alpha(0.75));
    } else {
        cv.rectGrad(12, 4, w - 24, H, 18, acc.alpha(0.12), Color.hex(0x05070f).alpha(0.5));
    }
    if (m.status == .none) {
        _ = cv.text(w / 2, H / 2 - 10, 54, sub.alpha(0.5), "\u{F075A}", .{ .alignment = .center });
        _ = cv.text(w / 2, H / 2 + 40, 17, sub, "再生中のメディアはありません", .{ .alignment = .center });
        return false;
    }

    // ---- 左: レコード ----
    const cx: f32 = 200;
    const cy: f32 = H / 2 + 4;
    const R: f32 = 128;
    if (playing) {
        // 33⅓ 回転のつもりで 1 周約 6 秒
        v.vinyl_angle += dt * std.math.tau / 6.0;
        if (v.vinyl_angle > std.math.tau) v.vinyl_angle -= std.math.tau;
        animating = true;
    }
    // スペクトラム(cava)をレコードの外周に放射状に
    const n = data.BARS;
    for (0..n) |i| {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * std.math.tau - std.math.pi / 2.0 + v.vinyl_angle * 0.15;
        const val = if (f.cava.running()) f.cava.values[i] else 0.05;
        const r0 = R + 10;
        const r1 = r0 + 4 + val * 44;
        const ca = @cos(a);
        const sa = @sin(a);
        cv.line(cx + ca * r0, cy + sa * r0, cx + ca * r1, cy + sa * r1, 4, Color.mix(acc, acc.lighten(0.6), val).alpha(0.5 + 0.5 * val));
    }
    cv.shadow(cx - R, cy - R + 10, R * 2, R * 2, R, 24, Color.hex(0x000000).alpha(0.6));
    cv.rect(cx - R, cy - R, R * 2, R * 2, R, Color.hex(0x0b0b10));
    // 溝(細い同心円)と、光の当たり具合
    var gr: f32 = R - 6;
    while (gr > 76) : (gr -= 7) cv.arc(cx, cy, gr, 1, 1, Color.hex(0xffffff).alpha(0.045), .{ .a = 0 });
    cv.rectGrad(cx - R, cy - R, R * 2, R * 2, R, Color.hex(0xffffff).alpha(0.07), Color.hex(0xffffff).alpha(0.0));
    // 中央のラベル = 回るジャケット
    const lr: f32 = 70;
    if (m.art_tex != 0) {
        cv.imageEx(m.art_tex, cx - lr, cy - lr, lr * 2, lr * 2, lr, .{ 0, 0, 1, 1 }, 0, v.vinyl_angle, 1, 1);
    } else cv.rectGrad(cx - lr, cy - lr, lr * 2, lr * 2, lr, acc.lighten(0.3), acc);
    cv.rect(cx - 6, cy - 6, 12, 12, 6, Color.hex(0x0b0b10));
    // トーンアーム: 再生中はレコードに乗り、止めると持ち上がって外へ
    v.arm.set(if (playing) 1 else 0);
    if (v.arm.step(dt)) animating = true;
    {
        const px = cx + R + 26;
        const py = cy - R + 6;
        const ang = std.math.pi * (0.62 + 0.13 * v.arm.x); // 外 → 盤面へ
        const len: f32 = R * 1.25;
        const ex = px + @cos(ang) * len;
        const ey = py + @sin(ang) * len;
        cv.line(px, py, ex, ey, 6, Color.hex(0xc8ccd6));
        cv.line(ex, ey, ex - 10, ey + 14, 10, Color.hex(0x9aa0ad));
        cv.rect(px - 13, py - 13, 26, 26, 13, Color.hex(0x2a2e38));
        cv.rect(px - 6, py - 6, 12, 12, 6, Color.hex(0xc8ccd6));
    }

    // 右の歌詞欄の幅を先に決め、中央の曲情報はその残りに収める
    const lw = std.math.clamp(w * 0.32, 240, 420);
    const lx = w - 28 - lw;
    // ---- 中央: 曲情報と操作 ----
    const tx: f32 = 390;
    const tw: f32 = @max(200, lx - 40 - tx);
    cv.rect(tx, 40, cv.measure(m.player[0..m.player_len], 11.5, true) + 20, 22, 11, acc.alpha(0.25));
    _ = cv.text(tx + 10, 56, 11.5, acc.lighten(0.3), m.player[0..m.player_len], .{ .bold = true });
    cv.textWrap(tx, 100, 25, txt, m.title[0..m.title_len], tw, 2, 31);
    _ = cv.text(tx, 166, 16, sub, m.artist[0..m.artist_len], .{ .max_w = tw });
    if (m.length_s > 0) {
        const p = std.math.clamp(m.position() / m.length_s, 0, 1);
        cv.rect(tx, 200, tw, 6, 3, Color.hex(0xffffff).alpha(0.12));
        cv.shadow(tx, 200, tw * p, 6, 3, 8, acc.alpha(0.5));
        cv.rectGrad(tx, 200, @max(tw * p, 6), 6, 3, acc.lighten(0.3), acc);
        cv.rect(tx + tw * p - 7, 196, 14, 14, 7, Color.hex(0xffffff));
        _ = cv.text(tx, 230, 12, sub, mmss(&buf, m.position()), .{});
        _ = cv.text(tx + tw, 230, 12, sub, mmss(&buf2, m.length_s), .{ .alignment = .right });
    } else {
        _ = cv.text(tx, 220, 12, sub, "ライブ / 長さ不明", .{});
    }
    const icons = [5][]const u8{ "\u{F049D}", "\u{F04AE}", if (playing) "\u{F03E4}" else "\u{F040A}", "\u{F04AD}", if (m.loop_mode == 2) "\u{F0458}" else "\u{F0456}" };
    const kinds = [5]Btn{ .shuffle, .big_prev, .big_play, .big_next, .loop };
    const on = [5]bool{ m.shuffle, false, false, false, m.loop_mode != 0 };
    for (0..5) |i| {
        const bx = tx + tw / 2 + (@as(f32, @floatFromInt(i)) - 2) * 62;
        const big = i == 2;
        const rr: f32 = if (big) 30 else if (i == 0 or i == 4) 17 else 22;
        const by: f32 = 300;
        const hv = addBtn(v, kinds[i], bx - rr, by - rr + TAB_H, rr * 2, rr * 2);
        if (big) {
            cv.shadow(bx - rr, by - rr + 4, rr * 2, rr * 2, rr, 16, acc.alpha(0.6));
            cv.rectGrad(bx - rr, by - rr, rr * 2, rr * 2, rr, acc.lighten(0.4 + 0.2 * hv), acc);
        } else {
            cv.rect(bx - rr, by - rr, rr * 2, rr * 2, rr, (if (on[i]) acc else Color.hex(0xffffff)).alpha(if (on[i]) 0.35 else 0.06 + 0.12 * hv));
        }
        const fg = if (big) Color.hex(0x08101e) else if (on[i]) acc.lighten(0.4) else txt;
        _ = cv.text(bx, by + rr * 0.36, rr * 0.95, fg, icons[i], .{ .alignment = .center });
    }

    // ---- 右: 歌詞 ----
    cv.rect(lx, 18, lw, H - 28, 16, Color.hex(0x000000).alpha(0.22));
    const ly = &m.lyrics.*;
    const pos = m.position();
    const center_y: f32 = 18 + (H - 28) / 2;
    cv.setClip(lx, 20, lw, H - 32);
    switch (ly.state) {
        .idle, .fetching => {
            _ = cv.text(lx + lw / 2, center_y, 14, sub, "歌詞を検索中…", .{ .alignment = .center });
        },
        .none => {
            _ = cv.text(lx + lw / 2, center_y - 6, 30, sub.alpha(0.5), "\u{F075A}", .{ .alignment = .center });
            _ = cv.text(lx + lw / 2, center_y + 26, 13, sub, "歌詞が見つかりません", .{ .alignment = .center });
        },
        .plain => {
            // 同期情報なし: 曲の進み具合に合わせてゆっくり送る
            const frac = if (m.length_s > 0) std.math.clamp(pos / m.length_s, 0, 1) else 0;
            const total = @as(f32, @floatFromInt(ly.lines.items.len)) * 28;
            const off = frac * @max(0, total - (H - 80));
            for (ly.lines.items, 0..) |l, i| {
                const yy = 52 + @as(f32, @floatFromInt(i)) * 28 - off;
                if (yy < 0 or yy > H) continue;
                _ = cv.text(lx + 20, yy, 14, txt.alpha(0.8), l.text, .{ .max_w = lw - 40 });
            }
        },
        .synced => {
            const cur = ly.current(pos);
            const target: f32 = if (cur.idx) |i| @floatFromInt(i) else -1;
            if (v.lyr_scroll.target != target) v.lyr_scroll.set(target);
            if (v.lyr_scroll.step(dt)) animating = true;
            const LH: f32 = 40;
            for (ly.lines.items, 0..) |l, i| {
                const fi: f32 = @floatFromInt(i);
                const yy = center_y + (fi - v.lyr_scroll.x) * LH;
                if (yy < -LH or yy > H + LH) continue;
                const dist = @abs(fi - v.lyr_scroll.x);
                const is_cur = cur.idx != null and cur.idx.? == i;
                const fsz: f32 = if (is_cur) 21 else 15.5 - @min(dist, 3) * 0.6;
                const alpha = std.math.clamp(1 - dist * 0.3, 0.12, 1);
                const text_ = if (l.text.len > 0) l.text else "♪";
                if (is_cur) {
                    // カラオケ風: 行の時間の進みに合わせて左から明るく塗る
                    const tw2 = @min(cv.measure(text_, fsz, true), lw - 40);
                    const x0 = lx + lw / 2 - tw2 / 2;
                    _ = cv.text(lx + lw / 2, yy + 7, fsz, sub.alpha(0.55), text_, .{ .bold = true, .alignment = .center, .max_w = lw - 40 });
                    cv.setClip(x0 - 4, yy - 30, tw2 * cur.frac + 4, 50);
                    _ = cv.text(lx + lw / 2, yy + 7, fsz, Color.mix(txt, acc.lighten(0.5), 0.35), text_, .{ .bold = true, .alignment = .center, .max_w = lw - 40, .glow = 2.5, .glow_color = acc.lighten(0.3).alpha(0.5) });
                    cv.setClip(lx, 20, lw, H - 32);
                } else {
                    _ = cv.text(lx + lw / 2, yy + 6, fsz, txt.alpha(alpha * 0.7), text_, .{ .alignment = .center, .max_w = lw - 40 });
                }
            }
            if (playing) animating = true; // カラオケの塗りを滑らかに
        },
    }
    cv.setClip(0, 0, 0, 0);
    return animating;
}

// ---------------------------------------------------------------------------
// タブ 2: パフォーマンス
// ---------------------------------------------------------------------------

fn drawPerf(f: *Frame, cv: *gfx.Canvas, dt: f32, w: f32) bool {
    const app = f.app;
    const v = &f.dashv;
    const pf = &f.perf;
    const hw = &f.hw;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    var animating = false;
    var hb: [160]u8 = undefined;

    // 見出し: 機種名と構成
    _ = cv.text(PAD + 8, 34, 16, txt, hw.modelName(), .{ .bold = true, .max_w = w * 0.55 });
    const mem_total = if (pf.mem_total > 0) pf.mem_total else 0;
    _ = cv.text(w - PAD - 8, 34, 12.5, sub, std.fmt.bufPrint(&hb, "{d} スレッド ・ メモリ {d:.1} GiB ・ ストレージ {d:.0} GiB", .{ hw.cores, mem_total, pf.disk_total }) catch "", .{ .alignment = .right });

    const Ring = struct { val: f32, big: []const u8, label: []const u8, name: []const u8, extra: []const u8, temp: ?f32, icon: []const u8 };
    var b0: [32]u8 = undefined;
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    var e2: [48]u8 = undefined;
    var e3: [48]u8 = undefined;
    const mem_frac = if (pf.mem_total > 0) pf.mem_used / pf.mem_total else 0;
    const disk_frac = if (pf.disk_total > 0) pf.disk_used / pf.disk_total else 0;
    const rings = [4]Ring{
        .{ .val = app.sys.cpu, .big = std.fmt.bufPrint(&b0, "{d}%", .{@as(u32, @intFromFloat(app.sys.cpu * 100 + 0.5))}) catch "", .label = "CPU", .name = hw.cpuName(), .extra = "", .temp = pf.cpu_temp, .icon = "\u{F0EE0}" },
        .{ .val = pf.gpu_busy orelse 0, .big = if (pf.gpu_busy) |g| std.fmt.bufPrint(&b1, "{d}%", .{@as(u32, @intFromFloat(g * 100 + 0.5))}) catch "" else "--", .label = "GPU", .name = hw.gpuName(), .extra = "", .temp = pf.gpu_temp, .icon = "\u{F0379}" },
        .{ .val = mem_frac, .big = std.fmt.bufPrint(&b2, "{d}%", .{@as(u32, @intFromFloat(mem_frac * 100 + 0.5))}) catch "", .label = "メモリ", .name = std.fmt.bufPrint(&e2, "{d:.1} / {d:.1} GiB", .{ pf.mem_used, pf.mem_total }) catch "", .extra = "", .temp = null, .icon = "\u{F035B}" },
        .{ .val = disk_frac, .big = std.fmt.bufPrint(&b3, "{d}%", .{@as(u32, @intFromFloat(disk_frac * 100 + 0.5))}) catch "", .label = "ストレージ", .name = std.fmt.bufPrint(&e3, "{d:.0} / {d:.0} GiB", .{ pf.disk_used, pf.disk_total }) catch "", .extra = hw.diskName(), .temp = null, .icon = "\u{F02CA}" },
    };
    const cw = (w - PAD * 2) / 4;
    for (rings, 0..) |rg, i| {
        v.perf_v[i].set(rg.val);
        if (v.perf_v[i].step(dt)) animating = true;
        const cx = PAD + cw * @as(f32, @floatFromInt(i)) + cw / 2;
        const cy: f32 = 150;
        const R: f32 = @min(84, cw / 2 - 18);
        const val = std.math.clamp(v.perf_v[i].x, 0, 1);
        // 使用率が高いほど赤寄りに
        const col = Color.mix(acc, Color.hex(0xff7a90), @max(0, (val - 0.75) / 0.25));
        card(cv, cx - cw / 2 + 6, 56, cw - 12, 262);
        cv.shadow(cx - R, cy - R, R * 2, R * 2, R, 14, col.alpha(0.18 * val + 0.05));
        cv.arc(cx, cy, R, 12, val, col, Color.hex(0xffffff).alpha(0.07));
        // 温度は内側の細い円弧(橙)
        if (rg.temp) |t| cv.arc(cx, cy, R - 17, 4, std.math.clamp(t / 100, 0, 1), Color.hex(0xffb35c), Color.hex(0xffffff).alpha(0.05));
        _ = cv.text(cx, cy - 18, 17, col.lighten(0.3), rg.icon, .{ .alignment = .center });
        _ = cv.text(cx, cy + 16, 30, txt, rg.big, .{ .bold = true, .alignment = .center });
        if (rg.temp) |t| {
            _ = cv.text(cx, cy + 38, 12, Color.hex(0xffb35c), std.fmt.bufPrint(&hb, "{d}°C", .{@as(u32, @intFromFloat(t + 0.5))}) catch "", .{ .alignment = .center });
        }
        _ = cv.text(cx, cy + R + 32, 14, txt, rg.label, .{ .bold = true, .alignment = .center });
        _ = cv.text(cx, cy + R + 52, 11.5, sub, rg.name, .{ .alignment = .center, .max_w = cw - 28 });
        if (rg.extra.len > 0) _ = cv.text(cx, cy + R + 69, 10.5, sub.alpha(0.75), rg.extra, .{ .alignment = .center, .max_w = cw - 28 });
    }
    return animating;
}

// ---------------------------------------------------------------------------
// タブ 3: ワークスペース(River のタグ 3x3)
// ---------------------------------------------------------------------------

fn drawWorkspaces(f: *Frame, cv: *gfx.Canvas, dt: f32, w: f32) bool {
    _ = dt;
    const app = f.app;
    const v = &f.dashv;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const tile_w = (w - PAD * 2 - 16) / 3;
    const tile_h: f32 = 64;
    for (0..9) |i| {
        const col_i: f32 = @floatFromInt(i % 3);
        const row_i: f32 = @floatFromInt(i / 3);
        const x = PAD + col_i * (tile_w + 8);
        const y = PAD + row_i * (tile_h + 8);
        const focused = (f.out.focused_tags >> @intCast(i)) & 1 == 1;
        const occ = (f.out.view_tags >> @intCast(i)) & 1 == 1;
        const urgent = (f.out.urgent_tags >> @intCast(i)) & 1 == 1;
        const hv = if (v.hover_ws == @as(i32, @intCast(i))) @as(f32, 1) else 0;
        if (focused) {
            cv.shadow(x, y + 3, tile_w, tile_h, 16, 10, acc.alpha(0.5));
            cv.rectGrad(x, y, tile_w, tile_h, 16, acc.lighten(0.25), acc);
        } else {
            cv.rect(x, y, tile_w, tile_h, 16, Color.hex(0xffffff).alpha(0.05 + 0.08 * hv));
            cv.rectBorder(x, y, tile_w, tile_h, 16, .{ .a = 0 }, (if (urgent) Color.hex(0xff7a90) else Color.hex(0xffffff)).alpha(if (urgent) 0.8 else 0.08), 1);
        }
        var lab: [1]u8 = .{'1' + @as(u8, @intCast(i))};
        const fg = if (focused) Color.hex(0x08101e) else if (occ) txt else sub;
        _ = cv.text(x + 22, y + tile_h / 2 + 10, 26, fg, lab[0..], .{ .bold = true });
        _ = cv.text(x + tile_w - 16, y + tile_h / 2 + 6, 12, fg.alpha(0.8), if (focused) "表示中" else if (occ) "ウィンドウあり" else "空", .{ .alignment = .right });
    }
    return false;
}

// ---------------------------------------------------------------------------
// WASM ウィジェットの埋め込み
// ---------------------------------------------------------------------------

/// ダッシュボード(classic)で読み込んだ WASM ウィジェットを、枠のドロワー内に描く
fn drawWidget(f: *Frame, cv: *gfx.Canvas, name: []const u8, x: f32, y_abs: f32, w: f32, h: f32, dt: f32) bool {
    _ = y_abs;
    const d = f.app.dashboard;
    const wd = d.widgetByName(name) orelse return false;
    d.refreshStore();
    wd.writeStore(&d.store);
    cv.save();
    cv.translate(x, f.dashv.cal_rect[1]);
    const res = wd.frame(dt, w, h);
    d.runCmdsPub(cv, wd, res.cmds, h);
    cv.restore();
    return res.animating;
}

// ---------------------------------------------------------------------------
// 入力
// ---------------------------------------------------------------------------

pub fn pointer(f: *Frame, ev: surface.PointerEvent, lx: f32, ly: f32) bool {
    const v = &f.dashv;
    const app = f.app;
    var hov: Btn = .none;
    if (ev.kind != .leave and ly >= 0) {
        for (v.btn_rects[0..v.n_btn], 0..) |r, i| {
            if (lx >= r[0] and lx < r[0] + r[2] and ly >= r[1] and ly < r[1] + r[3]) {
                hov = v.btn_kinds[i];
                break;
            }
        }
    }
    var redraw = hov != v.hover;
    v.hover = hov;
    // カレンダー(WASM)へ転送
    if (v.tab == 0) {
        const cr = v.cal_rect;
        const cy = ly - TAB_H;
        if (f.app.dashboard.widgetByName("calendar")) |wd| {
            const inside = lx >= cr[0] and lx < cr[0] + cr[2] and cy >= cr[1] and cy < cr[1] + cr[3];
            const k: abi.PointerKind = if (!inside or ev.kind == .leave) .leave else switch (ev.kind) {
                .press => .press,
                .release => .release,
                .scroll => if (ev.scroll < 0) .scroll_up else .scroll_down,
                else => .motion,
            };
            if (wd.pointer(k, lx - cr[0], cy - cr[1])) redraw = true;
        }
    }
    // ワークスペースのタイル
    if (v.tab == 3) {
        const w = f.dash.w.x;
        const tile_w = (w - PAD * 2 - 16) / 3;
        const cy = ly - TAB_H - PAD;
        const cx = lx - PAD;
        var hw: i32 = -1;
        if (ev.kind != .leave and cx >= 0 and cy >= 0) {
            const ci: i32 = @intFromFloat(cx / (tile_w + 8));
            const ri: i32 = @intFromFloat(cy / 72);
            if (ci < 3 and ri < 3) hw = ri * 3 + ci;
        }
        if (hw != v.hover_ws) redraw = true;
        v.hover_ws = hw;
        if (ev.kind == .press and hw >= 0) app.focusTags(@as(u32, 1) << @intCast(hw));
    }
    if (ev.kind == .press) {
        switch (hov) {
            .tab0, .tab1, .tab2, .tab3 => {
                const t: usize = @intFromEnum(hov) - 1;
                if (t != v.tab) {
                    v.tab = t;
                    v.fade.snap(0);
                    v.fade.set(1);
                    if (t == 2) f.perf.sample();
                    if (t == 1) app.media.queryModesPub();
                }
            },
            .prev, .big_prev => app.media.prev(),
            .play, .big_play => app.media.toggle(),
            .next, .big_next => app.media.next(),
            .shuffle => app.media.toggleShufflePub(),
            .loop => app.media.cycleLoopPub(),
            else => {},
        }
        redraw = true;
    }
    if (ev.kind == .scroll and ly < TAB_H) {
        // タブ上のホイールで切り替え
        const nt: i32 = @as(i32, @intCast(v.tab)) + @as(i32, if (ev.scroll > 0) 1 else -1);
        if (nt >= 0 and nt < tabs.len) {
            v.tab = @intCast(nt);
            v.fade.snap(0);
            v.fade.set(1);
        }
        redraw = true;
    }
    return redraw;
}
