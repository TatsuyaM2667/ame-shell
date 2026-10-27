// 設定 DSL(KDL/TOML 風の小さな言語)のパーサ。
//
// 例:
//   // コメント(# の後に空白、でも可)
//   theme {
//     accent #7ab8ff
//     radius 18
//   }
//   wallpaper { mode aurora; fps 30 }
//
// 文法: <セクション名> { <キー> <値> (改行 or ;) ... }
// 値: 数値 / 文字列("…") / 裸の単語 / #RRGGBB / true|false
// 未知のキーは警告して無視(古い設定でも起動できるように)。
const std = @import("std");

pub const WallMode = enum(c_int) { aurora = 0, rain = 1, image = 2, video = 3 };
pub const BarPos = enum { top, bottom };
pub const Layout = enum { caelestia, classic };

pub const Config = struct {
    // theme
    accent: u32 = 0x7ab8ff,
    tint: u32 = 0x0b1730,
    tint_strength: f32 = 0.42,
    text: u32 = 0xeaf2ff,
    subtext: u32 = 0x9fb4d6,
    radius: f32 = 18,
    blur: u32 = 3,
    refraction: f32 = 10,
    sparkle: f32 = 0.7,
    anim_speed: f32 = 1.0,
    media_accent: bool = true, // 再生中のアルバムアートの色をアクセントにする
    auto_color: bool = true, // 壁紙から配色(アクセント・ガラス・文字色)を自動で作る
    // shell: caelestia = 枠 + 縦バー + 縁から生えるドロワー / classic = 浮いた横バー
    layout: Layout = .caelestia,
    frame_thickness: f32 = 10,
    frame_rounding: f32 = 25,
    frame_smoothing: f32 = 20,
    frame_bar_width: f32 = 46,
    frame_opacity: f32 = 0.82,
    ui_scale: f32 = 1.25,
    super_launcher: bool = true,
    /// 天気の場所(空 = IP アドレスから推定)。例: "Sapporo"、"Osaka"
    weather_location: Str = .{},
    // bar
    bar_height: f32 = 38,
    bar_margin: f32 = 8,
    bar_position: BarPos = .top,
    clock_24h: bool = true,
    show_seconds: bool = false,
    // wallpaper
    wall_mode: WallMode = .aurora,
    wall_image: Str = .{},
    wall_fps: f32 = 30,
    wall_battery_fps: f32 = 12,
    wall_scale: f32 = 0.5,
    wall_animate: bool = true,
    /// ピッカーで切り替えるときの演出: -1=ランダム 0=波紋 1=円 2=斜めワイプ 3=短冊
    wall_transition: c_int = -1,
    aurora_a: u32 = 0x29d6b0,
    aurora_b: u32 = 0x3d7bff,
    aurora_c: u32 = 0x9a5cff,
    // font
    font_ui: Str = Str.of("Noto Sans CJK JP"),
    font_icon: Str = Str.of("JetBrainsMono Nerd Font Propo"),
    // apps
    terminal: Str = Str.of("foot"),
    // notifications
    notify_timeout_ms: u32 = 6000,
    // lock
    lock_enabled: bool = true,
};

/// 固定長文字列(設定は再読込で丸ごと差し替えるので、ヒープを使わない方が扱いやすい)。
pub const Str = struct {
    buf: [256]u8 = [_]u8{0} ** 256,
    len: usize = 0,

    pub fn of(s: []const u8) Str {
        var r = Str{};
        r.set(s);
        return r;
    }
    pub fn set(self: *Str, s: []const u8) void {
        self.len = @min(s.len, self.buf.len - 1);
        @memcpy(self.buf[0..self.len], s[0..self.len]);
        self.buf[self.len] = 0;
    }
    pub fn get(self: *const Str) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn z(self: *const Str) [:0]const u8 {
        return self.buf[0..self.len :0];
    }
};

const Tok = union(enum) { word: []const u8, string: []const u8, lbrace, rbrace, sep, eof };

const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    line: usize = 1,

    fn next(self: *Lexer) Tok {
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == '\n') {
                self.line += 1;
                self.i += 1;
                return .sep;
            }
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                self.i += 1;
                continue;
            }
            // コメント: "//" か、"#" の直後が空白/改行/終端
            const is_hash_comment = ch == '#' and (self.i + 1 >= self.src.len or self.src[self.i + 1] == ' ' or self.src[self.i + 1] == '\n' or self.src[self.i + 1] == '#');
            if (is_hash_comment or (ch == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '/')) {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                continue;
            }
            if (ch == '{') {
                self.i += 1;
                return .lbrace;
            }
            if (ch == '}') {
                self.i += 1;
                return .rbrace;
            }
            if (ch == ';') {
                self.i += 1;
                return .sep;
            }
            if (ch == '"') {
                const start = self.i + 1;
                var j = start;
                while (j < self.src.len and self.src[j] != '"' and self.src[j] != '\n') j += 1;
                self.i = @min(j + 1, self.src.len);
                return .{ .string = self.src[start..j] };
            }
            const start = self.i;
            while (self.i < self.src.len) {
                const d = self.src[self.i];
                if (d == ' ' or d == '\t' or d == '\n' or d == '\r' or d == '{' or d == '}' or d == ';' or d == '"') break;
                self.i += 1;
            }
            return .{ .word = self.src[start..self.i] };
        }
        return .eof;
    }
};

pub const Diag = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    fn add(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt ++ "\n", args) catch return;
        self.len += s.len;
    }
    pub fn get(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

/// src を解析して base に上書きする。
pub fn parse(src: []const u8, base: Config, diag: *Diag) Config {
    var cfg = base;
    var lx = Lexer{ .src = src };
    var section: []const u8 = "";
    var depth: usize = 0;
    var words: [8][]const u8 = undefined;
    var nw: usize = 0;
    var pending_section: ?[]const u8 = null;
    while (true) {
        const t = lx.next();
        switch (t) {
            .word, .string => |w| {
                if (nw < words.len) {
                    words[nw] = w;
                    nw += 1;
                }
            },
            .lbrace => {
                if (nw >= 1) pending_section = words[0];
                section = pending_section orelse "";
                depth += 1;
                nw = 0;
            },
            .rbrace, .sep, .eof => {
                if (nw >= 2 and depth > 0) {
                    apply(&cfg, section, words[0], words[1], diag, lx.line);
                } else if (nw == 1 and depth > 0) {
                    // 値の無いキー = true(例: "show-seconds")
                    apply(&cfg, section, words[0], "true", diag, lx.line);
                }
                nw = 0;
                if (t == .rbrace) {
                    if (depth > 0) depth -= 1;
                    section = "";
                }
                if (t == .eof) break;
            },
        }
    }
    return cfg;
}

fn num(v: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, v) catch null;
}

fn color(v: []const u8) ?u32 {
    var s = v;
    if (std.mem.startsWith(u8, s, "#")) s = s[1..] else if (std.mem.startsWith(u8, s, "0x")) s = s[2..];
    if (s.len != 6) return null;
    return std.fmt.parseInt(u32, s, 16) catch null;
}

fn boolean(v: []const u8) ?bool {
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "yes")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "no")) return false;
    return null;
}

fn apply(cfg: *Config, sec: []const u8, key: []const u8, val: []const u8, diag: *Diag, line: usize) void {
    const eq = std.mem.eql;
    var ok = true;
    if (eq(u8, sec, "theme")) {
        if (eq(u8, key, "accent")) cfg.accent = color(val) orelse blk: {
            ok = false;
            break :blk cfg.accent;
        } else if (eq(u8, key, "tint")) {
            if (color(val)) |cv| cfg.tint = cv else ok = false;
        } else if (eq(u8, key, "tint-strength")) {
            if (num(val)) |n| cfg.tint_strength = std.math.clamp(n, 0, 1) else ok = false;
        } else if (eq(u8, key, "text")) {
            if (color(val)) |cv| cfg.text = cv else ok = false;
        } else if (eq(u8, key, "subtext")) {
            if (color(val)) |cv| cfg.subtext = cv else ok = false;
        } else if (eq(u8, key, "radius")) {
            if (num(val)) |n| cfg.radius = std.math.clamp(n, 0, 40) else ok = false;
        } else if (eq(u8, key, "blur")) {
            if (num(val)) |n| cfg.blur = @intFromFloat(std.math.clamp(n, 1, 4)) else ok = false;
        } else if (eq(u8, key, "refraction")) {
            if (num(val)) |n| cfg.refraction = std.math.clamp(n, 0, 40) else ok = false;
        } else if (eq(u8, key, "sparkle")) {
            if (num(val)) |n| cfg.sparkle = std.math.clamp(n, 0, 2) else ok = false;
        } else if (eq(u8, key, "auto-color")) {
            cfg.auto_color = boolean(val) orelse true;
        } else if (eq(u8, key, "media-accent")) {
            cfg.media_accent = boolean(val) orelse true;
        } else if (eq(u8, key, "anim-speed")) {
            if (num(val)) |n| cfg.anim_speed = std.math.clamp(n, 0.2, 4) else ok = false;
        } else ok = false;
    } else if (eq(u8, sec, "shell")) {
        if (eq(u8, key, "layout")) {
            cfg.layout = if (eq(u8, val, "classic")) .classic else .caelestia;
        } else if (eq(u8, key, "frame-thickness")) {
            if (num(val)) |n| cfg.frame_thickness = std.math.clamp(n, 2, 40) else ok = false;
        } else if (eq(u8, key, "frame-rounding")) {
            if (num(val)) |n| cfg.frame_rounding = std.math.clamp(n, 0, 60) else ok = false;
        } else if (eq(u8, key, "frame-smoothing")) {
            if (num(val)) |n| cfg.frame_smoothing = std.math.clamp(n, 0, 60) else ok = false;
        } else if (eq(u8, key, "bar-width")) {
            if (num(val)) |n| cfg.frame_bar_width = std.math.clamp(n, 30, 80) else ok = false;
        } else if (eq(u8, key, "ui-scale")) {
            if (num(val)) |n| cfg.ui_scale = std.math.clamp(n, 0.75, 2.5) else ok = false;
        } else if (eq(u8, key, "weather-location")) {
            cfg.weather_location.set(val);
        } else if (eq(u8, key, "super-launcher")) {
            cfg.super_launcher = boolean(val) orelse true;
        } else if (eq(u8, key, "frame-opacity")) {
            if (num(val)) |n| cfg.frame_opacity = std.math.clamp(n, 0, 1) else ok = false;
        } else ok = false;
    } else if (eq(u8, sec, "bar")) {
        if (eq(u8, key, "height")) {
            if (num(val)) |n| cfg.bar_height = std.math.clamp(n, 24, 80) else ok = false;
        } else if (eq(u8, key, "margin")) {
            if (num(val)) |n| cfg.bar_margin = std.math.clamp(n, 0, 40) else ok = false;
        } else if (eq(u8, key, "position")) {
            cfg.bar_position = if (eq(u8, val, "bottom")) .bottom else .top;
        } else if (eq(u8, key, "clock-24h")) {
            cfg.clock_24h = boolean(val) orelse true;
        } else if (eq(u8, key, "show-seconds")) {
            cfg.show_seconds = boolean(val) orelse false;
        } else ok = false;
    } else if (eq(u8, sec, "wallpaper")) {
        if (eq(u8, key, "mode")) {
            cfg.wall_mode = if (eq(u8, val, "rain")) .rain else if (eq(u8, val, "image")) .image else if (eq(u8, val, "video")) .video else .aurora;
        } else if (eq(u8, key, "image")) {
            cfg.wall_image.set(val);
        } else if (eq(u8, key, "fps")) {
            if (num(val)) |n| cfg.wall_fps = std.math.clamp(n, 1, 240) else ok = false;
        } else if (eq(u8, key, "battery-fps")) {
            if (num(val)) |n| cfg.wall_battery_fps = std.math.clamp(n, 1, 240) else ok = false;
        } else if (eq(u8, key, "scale")) {
            if (num(val)) |n| cfg.wall_scale = std.math.clamp(n, 0.2, 1) else ok = false;
        } else if (eq(u8, key, "transition")) {
            cfg.wall_transition = if (eq(u8, val, "ripple")) 0 else if (eq(u8, val, "circle")) 1 else if (eq(u8, val, "slant")) 2 else if (eq(u8, val, "shards")) 3 else -1;
        } else if (eq(u8, key, "animate")) {
            cfg.wall_animate = boolean(val) orelse true;
        } else if (eq(u8, key, "aurora-a")) {
            if (color(val)) |cv| cfg.aurora_a = cv else ok = false;
        } else if (eq(u8, key, "aurora-b")) {
            if (color(val)) |cv| cfg.aurora_b = cv else ok = false;
        } else if (eq(u8, key, "aurora-c")) {
            if (color(val)) |cv| cfg.aurora_c = cv else ok = false;
        } else ok = false;
    } else if (eq(u8, sec, "font")) {
        if (eq(u8, key, "ui")) cfg.font_ui.set(val) else if (eq(u8, key, "icon")) cfg.font_icon.set(val) else ok = false;
    } else if (eq(u8, sec, "apps")) {
        if (eq(u8, key, "terminal")) cfg.terminal.set(val) else ok = false;
    } else if (eq(u8, sec, "notifications")) {
        if (eq(u8, key, "timeout")) {
            if (num(val)) |n| cfg.notify_timeout_ms = @intFromFloat(std.math.clamp(n, 500, 600000)) else ok = false;
        } else ok = false;
    } else if (eq(u8, sec, "lock")) {
        if (eq(u8, key, "enabled")) cfg.lock_enabled = boolean(val) orelse true else ok = false;
    } else ok = false;
    if (!ok) diag.add("line {d}: unknown or invalid '{s}.{s} {s}'", .{ line, sec, key, val });
}

test "parse basic" {
    var d = Diag{};
    const src =
        \\# comment
        \\theme {
        \\  accent #ff0000
        \\  radius 10 // trailing
        \\}
        \\wallpaper { mode rain; fps 60 }
        \\font { ui "Noto Sans CJK JP" }
    ;
    const cfg = parse(src, .{}, &d);
    try std.testing.expectEqual(@as(u32, 0xff0000), cfg.accent);
    try std.testing.expectEqual(@as(f32, 10), cfg.radius);
    try std.testing.expectEqual(WallMode.rain, cfg.wall_mode);
    try std.testing.expectEqual(@as(f32, 60), cfg.wall_fps);
    try std.testing.expectEqualStrings("Noto Sans CJK JP", cfg.font_ui.get());
    try std.testing.expectEqual(@as(usize, 0), d.len);
}
