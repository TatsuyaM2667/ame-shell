// カレンダー: 月表示。‹ › で月を移動するとグリッドが横にスライドする。今日は発光する丸。
// 表示中の月オフセットは state に入るので、ホットリロードしても見ている月が保たれる。
const ame = @import("ame.zig");

pub const W = struct {
    pub var state: extern struct {
        offset: i32 = 0,
        slide: ame.Spring = ame.Spring.init(0, 0.4, 0.82),
        hover: i32 = -1,
        hl: ame.Spring = ame.Spring.init(0, 0.2, 1.0),
    } = .{};

    const CELL_H: f32 = 30;

    pub fn height(_: f32) f32 {
        return 34 + 22 + 6 * CELL_H + 4;
    }

    fn daysIn(y: i32, m: i32) i32 {
        const d = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if (m == 2 and (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0))) return 29;
        return d[@intCast(m - 1)];
    }

    /// 曜日(0=日)。Sakamoto の方法。
    fn dow(y0: i32, m: i32, d: i32) i32 {
        const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
        const y = if (m < 3) y0 - 1 else y0;
        return @mod(y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + t[@intCast(m - 1)] + d, 7);
    }

    pub fn frame(dt: f32, w: f32, _: f32) bool {
        const s = &ame.store;
        const st = &state;
        last_w = w;
        var anim = st.slide.step(dt);
        if (st.hl.step(dt)) anim = true;
        // 表示する年月
        var ym = s.year * 12 + (s.month - 1) + st.offset;
        const y = @divFloor(ym, 12);
        ym = @mod(ym, 12);
        const m = ym + 1;
        // ヘッダ
        ame.text(8, 24, 17, ame.rgba(s.text, 1), ame.fmt("{d}年 {d}月", .{ @as(u32, @intCast(y)), @as(u32, @intCast(m)) }), true, .left, 0, 0);
        const hov_l: f32 = if (st.hover == 100) 1 else 0;
        const hov_r: f32 = if (st.hover == 101) 1 else 0;
        ame.rect(w - 76, 4, 32, 28, 10, ame.rgba(0xffffff, 0.06 + 0.10 * hov_l));
        ame.rect(w - 38, 4, 32, 28, 10, ame.rgba(0xffffff, 0.06 + 0.10 * hov_r));
        ame.text(w - 60, 24, 15, ame.rgba(s.text, 1), "‹", true, .center, 0, 0);
        ame.text(w - 22, 24, 15, ame.rgba(s.text, 1), "›", true, .center, 0, 0);
        if (st.offset != 0) ame.text(w - 86, 24, 12, ame.rgba(s.accent, 1), "今日へ", false, .right, 0, 0);

        const cw = w / 7;
        const names = [_][]const u8{ "日", "月", "火", "水", "木", "金", "土" };
        for (names, 0..) |n, i| {
            const col: u32 = if (i == 0) 0xff8a9b else if (i == 6) 0x8ab4ff else s.subtext;
            ame.text(cw * @as(f32, @floatFromInt(i)) + cw / 2, 52, 12, ame.rgba(col, 0.9), n, true, .center, 0, 0);
        }
        ame.clip(0, 58, w, 6 * CELL_H + 4);
        const sx = st.slide.x * w; // 月送りのスライド
        const first = dow(y, m, 1);
        const nd = daysIn(y, m);
        var d: i32 = 1;
        while (d <= nd) : (d += 1) {
            const idx = first + d - 1;
            const col_i = @mod(idx, 7);
            const row = @divFloor(idx, 7);
            const cx = cw * @as(f32, @floatFromInt(col_i)) + cw / 2 + sx;
            const cy = 60 + CELL_H * @as(f32, @floatFromInt(row)) + CELL_H / 2;
            const today = st.offset == 0 and d == s.mday;
            if (today) {
                ame.shadow(cx - 14, cy - 13, 28, 26, 13, 8, ame.rgba(s.accent, 0.6));
                ame.grad(cx - 14, cy - 13, 28, 26, 13, ame.rgba(ame.mix(s.accent, 0xffffff, 0.3), 1), ame.rgba(s.accent, 1));
            } else if (st.hover == idx) {
                ame.rect(cx - 14, cy - 13, 28, 26, 13, ame.rgba(0xffffff, 0.10 * st.hl.x));
            }
            const col: u32 = if (today) 0x08101e else if (col_i == 0) 0xff8a9b else if (col_i == 6) 0x8ab4ff else s.text;
            ame.text(cx, cy + 5, 13.5, ame.rgba(col, 1), ame.fmt("{d}", .{@as(u32, @intCast(d))}), today, .center, 0, 0);
        }
        ame.clip(0, 0, 0, 0);
        return anim;
    }

    pub fn pointer(kind: ame.PointerKind, x: f32, y: f32) bool {
        const st = &state;
        var hv: i32 = -1;
        if (y < 34) {
            if (x > lastW() - 80 and x < lastW() - 42) hv = 100 else if (x >= lastW() - 40) hv = 101 else if (x > lastW() - 130 and state.offset != 0) hv = 102;
        } else if (y > 58) {
            const cw = lastW() / 7;
            const col: i32 = @intFromFloat(x / cw);
            const row: i32 = @intFromFloat((y - 60) / CELL_H);
            if (col >= 0 and col < 7 and row >= 0 and row < 6) hv = row * 7 + col;
        }
        if (kind == .leave) hv = -1;
        var redraw = false;
        if (hv != st.hover) {
            st.hover = hv;
            st.hl.x = 0;
            st.hl.target = 1;
            redraw = true;
        }
        if (kind == .press or kind == .scroll_up or kind == .scroll_down) {
            var dir: i32 = 0;
            if ((kind == .press and hv == 100) or kind == .scroll_up) dir = -1;
            if ((kind == .press and hv == 101) or kind == .scroll_down) dir = 1;
            if (kind == .press and hv == 102) {
                st.slide.x = if (st.offset > 0) -1 else 1;
                st.offset = 0;
                st.slide.target = 0;
                return true;
            }
            if (dir != 0) {
                st.offset += dir;
                // 新しい月が進行方向から入ってくる
                st.slide.x = @floatFromInt(dir);
                st.slide.target = 0;
                redraw = true;
            }
        }
        return redraw;
    }

    var last_w: f32 = 380;
    fn lastW() f32 {
        return last_w;
    }
};

comptime {
    ame.exportWidget(W);
}
