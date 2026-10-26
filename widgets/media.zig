// メディア: MPRIS(ホストが playerctl で取得)のアルバムアート・曲名・進捗・操作ボタン。
// アートの主色はホストが Odin で抽出してアクセント色に反映するので、ここでは accent を使うだけ。
const ame = @import("ame.zig");

pub const W = struct {
    pub var state: extern struct {
        hover: i32 = -1,
        btn: [3]ame.Spring = .{ ame.Spring.init(0, 0.2, 0.7), ame.Spring.init(0, 0.2, 0.7), ame.Spring.init(0, 0.2, 0.7) },
        play: ame.Spring = ame.Spring.init(0, 0.3, 0.8), // 再生アイコンの切替
    } = .{};

    pub fn height(_: f32) f32 {
        return if (ame.store.media_status == 0) 62 else 148;
    }

    fn mmss(sec: f32) []const u8 {
        const t: u32 = @intFromFloat(@max(sec, 0));
        return ame.fmt("{d}:{d:0>2}", .{ t / 60, t % 60 });
    }

    var last_w: f32 = 380;

    pub fn frame(dt: f32, w: f32, _: f32) bool {
        const s = &ame.store;
        const st = &state;
        last_w = w;
        if (s.media_status == 0) {
            ame.text(30, 38, 20, ame.rgba(s.subtext, 0.8), "\u{F075A}", false, .center, 0, 0);
            ame.text(52, 36, 14, ame.rgba(s.subtext, 1), "再生中のメディアはありません", false, .left, 0, 0);
            return false;
        }
        var anim = false;
        for (&st.btn, 0..) |*b, i| {
            b.target = if (st.hover == @as(i32, @intCast(i))) 1 else 0;
            if (b.step(dt)) anim = true;
        }
        st.play.target = if (s.media_status == 1) 1 else 0;
        if (st.play.step(dt)) anim = true;

        const art_s: f32 = 116;
        if (s.has_art != 0) {
            ame.shadow(4, 8, art_s, art_s, 16, 14, ame.rgba(s.accent, 0.45));
            ame.art(4, 4, art_s, art_s, 16);
        } else {
            ame.grad(4, 4, art_s, art_s, 16, ame.rgba(ame.mix(s.accent, 0xffffff, 0.3), 1), ame.rgba(s.accent, 1));
            ame.text(4 + art_s / 2, 4 + art_s / 2 + 16, 44, ame.rgba(0xffffff, 0.9), "\u{F075A}", false, .center, 0, 0);
        }
        const tx: f32 = art_s + 20;
        const tw = w - tx - 8;
        ame.text(tx, 22, 11.5, ame.rgba(s.accent, 1), s.player[0..s.player_len], true, .left, tw, 0);
        ame.text(tx, 46, 16, ame.rgba(s.text, 1), s.title[0..s.title_len], true, .left, tw, 0);
        ame.text(tx, 68, 13, ame.rgba(s.subtext, 1), s.artist[0..s.artist_len], false, .left, tw, 0);
        // 進捗
        const p = if (s.media_len > 0) @min(s.media_pos / s.media_len, 1) else 0;
        ame.rect(tx, 82, tw, 4, 2, ame.rgba(0xffffff, 0.12));
        ame.grad(tx, 82, @max(tw * p, 4), 4, 2, ame.rgba(ame.mix(s.accent, 0xffffff, 0.3), 1), ame.rgba(s.accent, 1));
        ame.rect(tx + tw * p - 4, 80, 8, 8, 4, ame.rgba(0xffffff, 0.95));
        if (s.media_len > 0) {
            ame.text(tx, 102, 11, ame.rgba(s.subtext, 1), mmss(s.media_pos), false, .left, 0, 0);
            ame.text(tx + tw, 102, 11, ame.rgba(s.subtext, 1), mmss(s.media_len), false, .right, 0, 0);
        }
        // ボタン: 前 / 再生・一時停止 / 次
        const icons = [3][]const u8{ "\u{F04AE}", if (st.play.x > 0.5) "\u{F03E4}" else "\u{F040A}", "\u{F04AD}" };
        const cx0 = tx + tw / 2;
        for (0..3) |i| {
            const bx = cx0 + (@as(f32, @floatFromInt(i)) - 1) * 50;
            const hv = st.btn[i].x;
            const big = i == 1;
            const r: f32 = if (big) 20 else 16;
            if (big) {
                ame.shadow(bx - r, 128 - r, r * 2, r * 2, r, 10, ame.rgba(s.accent, 0.5));
                ame.grad(bx - r, 128 - r, r * 2, r * 2, r, ame.rgba(ame.mix(s.accent, 0xffffff, 0.35 + 0.2 * hv), 1), ame.rgba(s.accent, 1));
            } else {
                ame.rect(bx - r, 128 - r, r * 2, r * 2, r, ame.rgba(0xffffff, 0.04 + 0.12 * hv));
            }
            ame.text(bx, 128 + (if (big) @as(f32, 8) else 7), if (big) 22 else 18, ame.rgba(if (big) 0x08101e else s.text, 1), icons[i], false, .center, 0, 0);
        }
        return anim;
    }

    pub fn pointer(kind: ame.PointerKind, x: f32, y: f32) bool {
        const s = &ame.store;
        if (s.media_status == 0) return false;
        const tx: f32 = 116 + 20;
        const tw = last_w - tx - 8;
        const cx0 = tx + tw / 2;
        var hv: i32 = -1;
        if (kind != .leave and y > 104 and y < 150) {
            for (0..3) |i| {
                const bx = cx0 + (@as(f32, @floatFromInt(i)) - 1) * 50;
                if (x > bx - 22 and x < bx + 22) hv = @intCast(i);
            }
        }
        const changed = hv != state.hover;
        state.hover = hv;
        if (kind == .press and hv >= 0) {
            ame.act(switch (hv) {
                0 => .media_prev,
                1 => .media_toggle,
                else => .media_next,
            }, 0);
            state.btn[@intCast(hv)].v = -8; // 押し込み
            return true;
        }
        return changed;
    }
};

comptime {
    ame.exportWidget(W);
}
