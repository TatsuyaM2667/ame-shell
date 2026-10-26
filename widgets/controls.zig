// クイックコントロール: 音量・明るさのスライダー(ドラッグ可)と Wi-Fi / Bluetooth / 通知停止 のトグル。
const ame = @import("ame.zig");

pub const W = struct {
    pub var state: extern struct {
        vol: ame.Spring = ame.Spring.init(0, 0.25, 0.9),
        bri: ame.Spring = ame.Spring.init(0, 0.25, 0.9),
        drag: i32 = -1, // 0=音量 1=明るさ
        hover: i32 = -1,
        tog: [3]ame.Spring = .{ ame.Spring.init(0, 0.3, 0.75), ame.Spring.init(0, 0.3, 0.75), ame.Spring.init(0, 0.3, 0.75) },
        hov: [3]ame.Spring = .{ ame.Spring.init(0, 0.2, 1), ame.Spring.init(0, 0.2, 1), ame.Spring.init(0, 0.2, 1) },
        last_sent: f32 = -1,
        init_done: u32 = 0,
    } = .{};

    var last_w: f32 = 380;
    const TRACK_X: f32 = 44;
    const ROW1: f32 = 22;
    const ROW2: f32 = 64;
    const TOG_Y: f32 = 96;

    fn has_bri() bool {
        return ame.store.brightness >= 0;
    }

    pub fn height(_: f32) f32 {
        return if (has_bri()) 150 else 108;
    }

    fn trackW(w: f32) f32 {
        return w - TRACK_X - 62;
    }

    pub fn frame(dt: f32, w: f32, _: f32) bool {
        const s = &ame.store;
        const st = &state;
        last_w = w;
        // ドラッグ中はホストの値で上書きしない(指の位置が正)
        if (st.drag != 0) st.vol.target = if (s.muted != 0) 0 else s.volume;
        if (st.drag != 1 and has_bri()) st.bri.target = s.brightness;
        if (st.init_done == 0) {
            st.vol.x = st.vol.target;
            st.bri.x = st.bri.target;
            st.init_done = 1;
        }
        var anim = st.vol.step(dt);
        if (st.bri.step(dt)) anim = true;
        const on = [3]u32{ s.wifi_on, s.bt_on, s.dnd };
        for (0..3) |i| {
            st.tog[i].target = if (on[i] != 0) 1 else 0;
            st.hov[i].target = if (st.hover == @as(i32, @intCast(10 + i))) 1 else 0;
            if (st.tog[i].step(dt)) anim = true;
            if (st.hov[i].step(dt)) anim = true;
        }
        const tw = trackW(w);
        slider(ROW1, if (s.muted != 0) "\u{F075F}" else "\u{F057E}", st.vol.x, tw, st.drag == 0 or st.hover == 0);
        var y = TOG_Y;
        if (has_bri()) {
            slider(ROW2, "\u{F00E0}", st.bri.x, tw, st.drag == 1 or st.hover == 1);
        } else y = ROW2 - 6;

        const labels = [3][]const u8{ "Wi-Fi", "Bluetooth", "通知停止" };
        const icons = [3][]const u8{ "\u{F05A9}", "\u{F00AF}", "\u{F009B}" };
        const bw = (w - 16) / 3;
        for (0..3) |i| {
            const bx = @as(f32, @floatFromInt(i)) * (bw + 8);
            const t = st.tog[i].x;
            const hv = st.hov[i].x;
            const top = ame.mix(0x2a3550, ame.mix(s.accent, 0xffffff, 0.25), t);
            const bot = ame.mix(0x1c2438, s.accent, t);
            if (t > 0.05) ame.shadow(bx, y + 3, bw, 44, 14, 10, ame.rgba(s.accent, 0.4 * t));
            ame.grad(bx, y, bw, 44, 14, ame.rgba(top, 0.55 + 0.45 * t + 0.1 * hv), ame.rgba(bot, 0.55 + 0.45 * t));
            ame.border(bx, y, bw, 44, 14, ame.rgba(0xffffff, 0.12 + 0.2 * hv), 1);
            const fg = ame.mix(s.text, 0x08101e, t);
            ame.text(bx + 18, y + 29, 17, ame.rgba(fg, 1), icons[i], false, .center, 0, 0);
            ame.text(bx + 32, y + 27, 12.5, ame.rgba(fg, 1), labels[i], true, .left, bw - 36, 0);
        }
        return anim;
    }

    fn slider(y: f32, icon: []const u8, v: f32, tw: f32, active: bool) void {
        const s = &ame.store;
        ame.text(16, y + 7, 18, ame.rgba(s.text, 1), icon, false, .center, 0, 0);
        const h: f32 = if (active) 12 else 8;
        ame.rect(TRACK_X, y - h / 2, tw, h, h / 2, ame.rgba(0xffffff, 0.10));
        ame.shadow(TRACK_X, y - h / 2, tw * v, h, h / 2, 8, ame.rgba(s.accent, 0.45));
        ame.grad(TRACK_X, y - h / 2, @max(tw * v, h), h, h / 2, ame.rgba(ame.mix(s.accent, 0xffffff, 0.3), 1), ame.rgba(s.accent, 1));
        const kx = TRACK_X + tw * v;
        ame.rect(kx - 8, y - 8, 16, 16, 8, ame.rgba(0xffffff, 1));
        ame.text(TRACK_X + tw + 58, y + 5, 13, ame.rgba(s.text, 1), ame.fmt("{d}%", .{@as(u32, @intFromFloat(v * 100 + 0.5))}), true, .right, 0, 0);
    }

    fn valueAt(x: f32) f32 {
        return @min(@max((x - TRACK_X) / trackW(last_w), 0), 1);
    }

    pub fn pointer(kind: ame.PointerKind, x: f32, y: f32) bool {
        const st = &state;
        var hv: i32 = -1;
        if (@abs(y - ROW1) < 16) hv = 0 else if (has_bri() and @abs(y - ROW2) < 16) hv = 1;
        const ty = if (has_bri()) TOG_Y else ROW2 - 6;
        if (y >= ty and y < ty + 44) {
            const bw = (last_w - 16) / 3;
            const i: i32 = @intFromFloat(x / (bw + 8));
            if (i >= 0 and i < 3) hv = 10 + i;
        }
        if (kind == .leave) hv = -1;
        var redraw = hv != st.hover;
        st.hover = hv;
        switch (kind) {
            .press => {
                if (hv == 0 or hv == 1) {
                    st.drag = hv;
                    redraw = true;
                    setFrom(x);
                } else if (hv >= 10) {
                    ame.act(switch (hv) {
                        10 => .toggle_wifi,
                        11 => .toggle_bt,
                        else => .toggle_dnd,
                    }, 0);
                    st.tog[@intCast(hv - 10)].v += 6;
                    redraw = true;
                }
            },
            .motion => if (st.drag >= 0) {
                setFrom(x);
                redraw = true;
            },
            .release, .leave => {
                if (st.drag >= 0) setFrom(x);
                st.drag = -1;
                st.last_sent = -1;
                redraw = true;
            },
            .scroll_up, .scroll_down => if (hv == 0 or hv == 1) {
                const d: f32 = if (kind == .scroll_up) 0.05 else -0.05;
                const sp = if (hv == 0) &st.vol else &st.bri;
                const nv = @min(@max(sp.target + d, 0), 1);
                sp.target = nv;
                ame.act(if (hv == 0) .set_volume else .set_brightness, nv);
                redraw = true;
            },
            _ => {},
        }
        return redraw;
    }

    fn setFrom(x: f32) void {
        const st = &state;
        const v = valueAt(x);
        const sp = if (st.drag == 0) &st.vol else &st.bri;
        sp.target = v;
        // 外部コマンドを叩きすぎないよう 1% 以上変わったときだけ送る
        if (@abs(v - st.last_sent) >= 0.01) {
            st.last_sent = v;
            ame.act(if (st.drag == 0) .set_volume else .set_brightness, v);
        }
    }
};

comptime {
    ame.exportWidget(W);
}
