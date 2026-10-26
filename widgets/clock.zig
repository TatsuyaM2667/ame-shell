// 時計ウィジェット: 大きな時刻(発光)・日付・挨拶。分の変わり目に数字がスプリングで入れ替わる。
const ame = @import("ame.zig");

pub const W = struct {
    pub var state: extern struct {
        last_min: i32 = -1,
        flip: ame.Spring = ame.Spring.init(1, 0.45, 0.75),
        appear: ame.Spring = ame.Spring.init(0, 0.6, 0.8),
    } = .{};

    pub fn height(_: f32) f32 {
        return 112;
    }

    pub fn frame(dt: f32, w: f32, _: f32) bool {
        const s = &ame.store;
        const st = &state;
        if (st.last_min != s.min) {
            if (st.last_min >= 0) {
                st.flip.x = 0;
                st.flip.target = 1;
            }
            st.last_min = s.min;
        }
        st.appear.target = 1;
        var anim = st.flip.step(dt);
        if (st.appear.step(dt)) anim = true;
        const t = st.appear.x;
        const greet = if (s.hour >= 5 and s.hour < 10) "おはようございます" else if (s.hour >= 10 and s.hour < 17) "こんにちは" else if (s.hour >= 17 and s.hour < 23) "こんばんは" else "おやすみなさい";
        ame.text(6 - (1 - t) * 20, 22, 14, ame.rgba(s.accent, t), greet, true, .left, 0, 0);
        // 時刻: 分が変わると下から持ち上がる
        const f = st.flip.x;
        const time = ame.fmt("{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(s.hour)), @as(u32, @intCast(s.min)) });
        ame.text(2, 74 + (1 - f) * 14, 58, ame.rgba(ame.mix(s.text, s.accent, 0.15), f * t), time, true, .left, 0, 8);
        const wd = [_][]const u8{ "日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日" };
        const date = ame.fmt("{d}年{d}月{d}日 {s}", .{ @as(u32, @intCast(s.year)), @as(u32, @intCast(s.month)), @as(u32, @intCast(s.mday)), wd[@intCast(@mod(s.wday, 7))] });
        ame.text(6, 102, 15, ame.rgba(s.subtext, t), date, false, .left, 0, 0);
        // 右側にバッテリーの円
        if (s.battery >= 0) {
            const col: u32 = if (s.charging != 0) 0x7dffc4 else if (s.battery < 0.15) 0xff7a90 else s.accent;
            ame.arc(w - 44, 62, 34, 6, s.battery * t, ame.rgba(col, 1), ame.rgba(0xffffff, 0.10));
            ame.text(w - 44, 68, 16, ame.rgba(s.text, 1), ame.fmt("{d}%", .{@as(u32, @intFromFloat(s.battery * 100 + 0.5))}), true, .center, 0, 0);
            ame.text(w - 44, 116 - 4, 11, ame.rgba(s.subtext, 1), if (s.charging != 0) "充電中" else "バッテリー", false, .center, 0, 0);
        }
        return anim;
    }

    pub fn pointer(_: ame.PointerKind, _: f32, _: f32) bool {
        return false;
    }
};

comptime {
    ame.exportWidget(W);
}
