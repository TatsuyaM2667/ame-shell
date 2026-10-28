// River 0.5 セッションのキー割り当て。今の ~/.config/river/init(River 0.3)と同じ操作感にしてある。
// ランチャー・ロック等は ame-shell の機能を直接呼ぶ(ame-ctl を起動するより速い)。
const std = @import("std");

const App = @import("../app.zig").App;
const c = @import("../c.zig");
const SHIFT = c.RIVER_SEAT_V1_MODIFIERS_SHIFT;
const CTRL = c.RIVER_SEAT_V1_MODIFIERS_CTRL;
const ALT = c.RIVER_SEAT_V1_MODIFIERS_MOD1;
const SUPER = c.RIVER_SEAT_V1_MODIFIERS_MOD4;
const wm = @import("wm.zig");
const Action = wm.Action;

const NONE: u32 = 0;

pub const SCRATCH: u32 = 1 << 20;
const ALL_TAGS: u32 = (1 << 9) - 1;

pub const Bind = struct { keysym: u32, mods: u32, action: Action };

const shot_region = "FILE=$HOME/Pictures/Screenshots/shot_$(date +%Y%m%d_%H%M%S).png; mkdir -p $HOME/Pictures/Screenshots; grim -g \"$(slurp)\" $FILE && wl-copy < $FILE";
const shot_full = "FILE=$HOME/Pictures/Screenshots/shot_$(date +%Y%m%d_%H%M%S).png; mkdir -p $HOME/Pictures/Screenshots; grim $FILE && wl-copy < $FILE";

const fixed = [_]Bind{
    // アプリ
    .{ .keysym = c.XKB_KEY_Return, .mods = SUPER, .action = .{ .spawn = "foot" } },
    .{ .keysym = c.XKB_KEY_t, .mods = SUPER, .action = .{ .spawn = "foot" } },
    .{ .keysym = c.XKB_KEY_b, .mods = SUPER, .action = .{ .spawn = "firefox" } },
    .{ .keysym = c.XKB_KEY_s, .mods = SUPER, .action = .{ .spawn = "$HOME/.local/bin/control-center.sh" } },
    .{ .keysym = c.XKB_KEY_r, .mods = SUPER | SHIFT, .action = .{ .spawn = "$HOME/.local/bin/toggle-record.sh" } },
    // ame-shell
    .{ .keysym = c.XKB_KEY_d, .mods = SUPER, .action = .{ .ame = "launcher toggle" } },
    .{ .keysym = c.XKB_KEY_a, .mods = SUPER, .action = .{ .ame = "dashboard toggle" } },
    .{ .keysym = c.XKB_KEY_n, .mods = SUPER, .action = .{ .ame = "notifications toggle" } },
    .{ .keysym = c.XKB_KEY_u, .mods = SUPER, .action = .{ .ame = "utilities" } },
    .{ .keysym = c.XKB_KEY_Escape, .mods = SUPER, .action = .{ .ame = "session" } },
    .{ .keysym = c.XKB_KEY_l, .mods = SUPER | SHIFT, .action = .{ .ame = "lock" } },
    .{ .keysym = c.XKB_KEY_w, .mods = SUPER | SHIFT, .action = .{ .ame = "wallpaper-picker" } },
    // ウィンドウ
    .{ .keysym = c.XKB_KEY_q, .mods = SUPER, .action = .close },
    .{ .keysym = c.XKB_KEY_e, .mods = SUPER | SHIFT, .action = .exit },
    .{ .keysym = c.XKB_KEY_f, .mods = SUPER, .action = .fullscreen },
    .{ .keysym = c.XKB_KEY_space, .mods = SUPER, .action = .float },
    .{ .keysym = c.XKB_KEY_space, .mods = SUPER | SHIFT, .action = .float },
    .{ .keysym = c.XKB_KEY_j, .mods = SUPER, .action = .focus_next },
    .{ .keysym = c.XKB_KEY_k, .mods = SUPER, .action = .focus_prev },
    .{ .keysym = c.XKB_KEY_h, .mods = SUPER, .action = .{ .ratio = -0.05 } },
    // Super+L はロック(一時的に離席するとき)。配置の比率は Super+Ctrl+H / L
    .{ .keysym = c.XKB_KEY_l, .mods = SUPER, .action = .{ .ame = "lock" } },
    .{ .keysym = c.XKB_KEY_l, .mods = SUPER | CTRL, .action = .{ .ratio = 0.05 } },
    .{ .keysym = c.XKB_KEY_h, .mods = SUPER | CTRL, .action = .{ .ratio = -0.05 } },
    .{ .keysym = c.XKB_KEY_j, .mods = SUPER | SHIFT, .action = .swap_next },
    .{ .keysym = c.XKB_KEY_k, .mods = SUPER | SHIFT, .action = .swap_prev },
    .{ .keysym = c.XKB_KEY_h, .mods = SUPER | SHIFT, .action = .swap_prev },
    .{ .keysym = c.XKB_KEY_Down, .mods = SUPER | SHIFT, .action = .swap_next },
    .{ .keysym = c.XKB_KEY_Right, .mods = SUPER | SHIFT, .action = .swap_next },
    .{ .keysym = c.XKB_KEY_Up, .mods = SUPER | SHIFT, .action = .swap_prev },
    .{ .keysym = c.XKB_KEY_Left, .mods = SUPER | SHIFT, .action = .swap_prev },
    .{ .keysym = c.XKB_KEY_period, .mods = SUPER, .action = .{ .focus_output = 1 } },
    .{ .keysym = c.XKB_KEY_comma, .mods = SUPER, .action = .{ .focus_output = -1 } },
    .{ .keysym = c.XKB_KEY_period, .mods = SUPER | SHIFT, .action = .{ .send_output = 1 } },
    .{ .keysym = c.XKB_KEY_comma, .mods = SUPER | SHIFT, .action = .{ .send_output = -1 } },
    // 全タグ・スクラッチパッド
    .{ .keysym = c.XKB_KEY_0, .mods = SUPER, .action = .{ .tags = ALL_TAGS } },
    .{ .keysym = c.XKB_KEY_0, .mods = SUPER | SHIFT, .action = .{ .move_tags = ALL_TAGS } },
    .{ .keysym = c.XKB_KEY_p, .mods = SUPER, .action = .{ .toggle_tags = SCRATCH } },
    .{ .keysym = c.XKB_KEY_p, .mods = SUPER | SHIFT, .action = .{ .move_tags = SCRATCH } },
    // スクリーンショット
    .{ .keysym = c.XKB_KEY_Print, .mods = NONE, .action = .{ .spawn = shot_region } },
    .{ .keysym = c.XKB_KEY_Print, .mods = SHIFT, .action = .{ .spawn = shot_full } },
    .{ .keysym = c.XKB_KEY_Print, .mods = SUPER, .action = .{ .spawn = "grim - | wl-copy" } },
    // メディアキー(OSD 付き)
    .{ .keysym = c.XKB_KEY_XF86AudioRaiseVolume, .mods = NONE, .action = .{ .ame = "volume up" } },
    .{ .keysym = c.XKB_KEY_XF86AudioLowerVolume, .mods = NONE, .action = .{ .ame = "volume down" } },
    .{ .keysym = c.XKB_KEY_XF86AudioMute, .mods = NONE, .action = .{ .ame = "volume mute" } },
    .{ .keysym = c.XKB_KEY_XF86MonBrightnessUp, .mods = NONE, .action = .{ .ame = "brightness up" } },
    .{ .keysym = c.XKB_KEY_XF86MonBrightnessDown, .mods = NONE, .action = .{ .ame = "brightness down" } },
    .{ .keysym = c.XKB_KEY_XF86AudioPlay, .mods = NONE, .action = .{ .spawn = "playerctl play-pause" } },
    .{ .keysym = c.XKB_KEY_XF86AudioNext, .mods = NONE, .action = .{ .spawn = "playerctl next" } },
    .{ .keysym = c.XKB_KEY_XF86AudioPrev, .mods = NONE, .action = .{ .spawn = "playerctl previous" } },
};

/// 1〜9 のタグ操作を足した全バインド
pub const all: [fixed.len + 9 * 5]Bind = blk: {
    var out: [fixed.len + 9 * 5]Bind = undefined;
    for (fixed, 0..) |b, i| out[i] = b;
    var n = fixed.len;
    for (0..9) |i| {
        const sym = c.XKB_KEY_1 + i;
        const m: u32 = 1 << i;
        out[n + 0] = .{ .keysym = sym, .mods = SUPER, .action = .{ .tags = m } };
        out[n + 1] = .{ .keysym = sym, .mods = SUPER | SHIFT, .action = .{ .move_tags = m } };
        out[n + 2] = .{ .keysym = sym, .mods = SUPER | CTRL, .action = .{ .toggle_tags = m } };
        out[n + 3] = .{ .keysym = sym, .mods = SUPER | SHIFT | CTRL, .action = .{ .toggle_view_tags = m } };
        out[n + 4] = .{ .keysym = sym, .mods = SUPER | ALT, .action = .{ .move_follow = m } };
        n += 5;
    }
    break :blk out;
};
