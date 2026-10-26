// システムモニタ: CPU / メモリ / 温度 を円弧で。値はスプリングで追従(急な変化でもなめらか)。
const ame = @import("ame.zig");

pub const W = struct {
    pub var state: extern struct {
        v: [3]ame.Spring = .{ ame.Spring.init(0, 0.6, 0.9), ame.Spring.init(0, 0.6, 0.9), ame.Spring.init(0, 0.6, 0.9) },
    } = .{};

    pub fn height(_: f32) f32 {
        return 116;
    }

    pub fn frame(dt: f32, w: f32, _: f32) bool {
        const s = &ame.store;
        const st = &state;
        const temp_known = s.temp >= 0;
        const vals = [3]f32{ s.cpu, s.mem, if (temp_known) s.temp / 100.0 else 0 };
        const labels = [3][]const u8{ "CPU", "メモリ", "温度" };
        var anim = false;
        for (0..3) |i| {
            st.v[i].target = vals[i];
            if (st.v[i].step(dt)) anim = true;
        }
        const cw = w / 3;
        for (0..3) |i| {
            const cx = cw * @as(f32, @floatFromInt(i)) + cw / 2;
            const v = st.v[i].x;
            // 高負荷ほど赤寄りに
            const col = ame.mix(s.accent, 0xff7a90, @max(0, (v - 0.7) / 0.3));
            ame.arc(cx, 50, 38, 7, v, ame.rgba(col, 1), ame.rgba(0xffffff, 0.08));
            const txt = if (i == 2)
                (if (temp_known) ame.fmt("{d}°", .{@as(u32, @intFromFloat(s.temp + 0.5))}) else "--")
            else
                ame.fmt("{d}%", .{@as(u32, @intFromFloat(v * 100 + 0.5))});
            ame.text(cx, 57, 18, ame.rgba(s.text, 1), txt, true, .center, 0, 0);
            ame.text(cx, 108, 12, ame.rgba(s.subtext, 1), labels[i], false, .center, 0, 0);
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
