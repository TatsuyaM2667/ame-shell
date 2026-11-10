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

/// 画面の四隅(ホーム画面のウィジェットの置き場所)
pub const Corner = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,

    pub fn parse(s: []const u8) ?Corner {
        const eq = std.mem.eql;
        if (eq(u8, s, "top-left")) return .top_left;
        if (eq(u8, s, "top-right")) return .top_right;
        if (eq(u8, s, "bottom-left")) return .bottom_left;
        if (eq(u8, s, "bottom-right")) return .bottom_right;
        return null;
    }

    pub fn name(c: Corner) []const u8 {
        return switch (c) {
            .top_left => "top-left",
            .top_right => "top-right",
            .bottom_left => "bottom-left",
            .bottom_right => "bottom-right",
        };
    }

    pub fn left(c: Corner) bool {
        return c == .top_left or c == .bottom_left;
    }

    pub fn top(c: Corner) bool {
        return c == .top_left or c == .top_right;
    }

    pub fn of(is_left: bool, is_top: bool) Corner {
        return if (is_top) (if (is_left) .top_left else .top_right) else (if (is_left) .bottom_left else .bottom_right);
    }
};
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
    /// タッチパッドのタップでクリック(River 0.5 のセッション)
    tap_to_click: bool = true,
    /// ハンド操作(hand/hand.zig): 起動時にオンにするか・使うカメラ(空 = /dev/video* から自動)
    hand_enabled: bool = false,
    /// ハンド操作の動き方: 全部(カーソル・クリック・ポーズ)/ 窓の操作(クリック無し: つまんで窓を動かす・ワークスペース・メニュー)/
    /// アプリ起動だけ(ポーズでアプリを起動するだけ)
    hand_mode: HandMode = .full,
    hand_camera: Str = .{},
    /// 指の軌跡に波を立てる
    hand_trail: bool = true,
    /// AI チャット(ai.zig): 初めて使うときの会社(パネルで選び直したものが優先)・カスタムの OpenAI 互換サーバ・最初の指示
    ai_provider: Str = .{},
    ai_custom_url: Str = .{},
    ai_custom_model: Str = .{},
    ai_system: Str = .{},
    /// コーディング CLI の新しいプロジェクトを作る場所(名前だけ入れたとき。空 = ~/projects、無ければホーム)
    ai_projects_dir: Str = .{},
    /// 顔認証でロックを外す(face/unlock.zig)。登録した顔があるときだけ使う。カメラ(空 = 赤外線カメラを自動で)・一致とみなす近さ
    face_enabled: bool = true,
    face_camera: Str = .{},
    face_threshold: f32 = 0.6,
    /// 赤外線カメラでだけ登録・照合する(画面に映した写真では外れない)。普通のカメラしか無いときだけ off に
    face_require_ir: bool = true,
    /// ホーム画面の曲のウィジェット(musicwidget.zig): 出すか・四隅のどこか(ドラッグで動かすと state に覚える)
    music_widget: bool = true,
    music_corner: Corner = .bottom_right,
    /// 充電器をつないだときの全画面のアニメーション(chargeanim.zig)
    charge_anim: bool = true,
    /// ダイナミックアイランド(枠の上の中央。frame/island.zig)
    island: bool = true,
    /// メモリが尽きそうなら知らせ、固まる直前にはカーネルが選ぶのと同じプロセスを止める(syswatch.zig)
    memory_guard: bool = true,
    /// AirPods の頭の動きで操作する(airpods.zig)
    airpods_enabled: bool = false,
    airpods_yaw: f32 = 25,
    airpods_pitch: f32 = 18,
    airpods_invert_yaw: bool = false,
    airpods_invert_pitch: bool = false,
    /// AirPods をつないだときのカード(airpodspopup.zig)
    airpods_popup: bool = true,
    /// スリープから戻ったら、前につながっていたイヤホン・スピーカーをつなぎ直す(btresume.zig)
    bt_reconnect: bool = true,
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
    // lyrics: 歌詞の取り寄せ先(music-tui の歌詞サーバ → LRCLIB → NetEase の順)
    lyrics_music_tui: Str = Str.of(""), // 空なら ~/music-tui-bsd/.env(または ~/music-tui/.env)の WORKERS_URL
    lyrics_music_tui_on: bool = true,
    lyrics_lrclib: bool = true,
    lyrics_netease: bool = true,
    lyrics_kugou: bool = true,
    // apps
    terminal: Str = Str.of("ame-terminal"),
    // notifications
    notify_timeout_ms: u32 = 6000,
    /// バッテリーの残りが少なくなったとき(20% / 10% / 5%)に知らせる
    notify_battery: bool = true,
    /// USB の機器を挿した・抜いたときに知らせる
    notify_usb: bool = true,
    // lock
    lock_enabled: bool = true,
};

/// 固定長文字列(設定は再読込で丸ごと差し替えるので、ヒープを使わない方が扱いやすい)。
pub const HandMode = enum { full, windows, poses };

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
    buf: [2048]u8 = undefined,
    len: usize = 0,
    fn add(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt ++ "\n", args) catch return;
        self.len += s.len;
    }
    pub fn get(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

/// 使う設定ファイルの場所: $AME_CONFIG → $XDG_CONFIG_HOME/ame-shell/config.ame → ~/.config/ame-shell/config.ame。
/// (ここに無ければ、ame-shell は入れた場所の既定の config.ame を使う)
pub fn userPath(buf: []u8) []const u8 {
    if (std.posix.getenv("AME_CONFIG")) |p| return p;
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell/config.ame", .{x}) catch "";
    return std.fmt.bufPrint(buf, "{s}/.config/ame-shell/config.ame", .{std.posix.getenv("HOME") orelse "/"}) catch "";
}

/// src を解析して base に上書きする。
pub fn parse(src: []const u8, base: Config, diag: *Diag) Config {
    var cfg = base;
    var lx = Lexer{ .src = src };
    var section: []const u8 = "";
    var depth: usize = 0;
    var words: [8][]const u8 = undefined;
    var nw: usize = 0;
    var key_line: usize = 1; // いま読んでいるキーの行(区切りの改行を読んだあとの lx.line は次の行になっている)
    var pending_section: ?[]const u8 = null;
    while (true) {
        const t = lx.next();
        switch (t) {
            .word, .string => |w| {
                if (nw == 0) key_line = lx.line;
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
                if (nw >= 2 and depth == 0) diag.add("line {d}: '{s}' is outside of a section", .{ key_line, words[0] });
                if (nw >= 2 and depth > 0) {
                    apply(&cfg, section, words[0], words[1], diag, key_line);
                } else if (nw == 1 and depth > 0) {
                    // 値の無いキー = true(例: "show-seconds")
                    apply(&cfg, section, words[0], "true", diag, key_line);
                }
                nw = 0;
                if (t == .rbrace) {
                    if (depth == 0) diag.add("line {d}: unmatched '}}'", .{lx.line});
                    if (depth > 0) depth -= 1;
                    section = "";
                }
                if (t == .eof) {
                    if (depth > 0) diag.add("line {d}: missing '}}' (section '{s}' is not closed)", .{ lx.line, pending_section orelse "" });
                    break;
                }
            },
        }
    }
    return cfg;
}

fn num(v: []const u8) ?f32 {
    const f = std.fmt.parseFloat(f32, v) catch return null;
    return if (std.math.isFinite(f)) f else null; // nan は clamp を素通りして @intFromFloat で未定義動作になる
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
        } else if (eq(u8, key, "tap-to-click")) {
            cfg.tap_to_click = boolean(val) orelse true;
        } else if (eq(u8, key, "super-launcher")) {
            cfg.super_launcher = boolean(val) orelse true;
        } else if (eq(u8, key, "frame-opacity")) {
            if (num(val)) |n| cfg.frame_opacity = std.math.clamp(n, 0, 1) else ok = false;
        } else if (eq(u8, key, "charge-animation")) {
            cfg.charge_anim = boolean(val) orelse true;
        } else if (eq(u8, key, "island")) {
            cfg.island = boolean(val) orelse true;
        } else if (eq(u8, key, "memory-guard")) {
            cfg.memory_guard = boolean(val) orelse true;
        } else ok = false;
    } else if (eq(u8, sec, "hand")) {
        if (eq(u8, key, "enabled")) {
            cfg.hand_enabled = boolean(val) orelse false;
        } else if (eq(u8, key, "mode")) {
            cfg.hand_mode = std.meta.stringToEnum(HandMode, val) orelse .full;
        } else if (eq(u8, key, "trail")) {
            cfg.hand_trail = boolean(val) orelse true;
        } else if (eq(u8, key, "camera")) {
            cfg.hand_camera.set(val);
        } else ok = false;
    } else if (eq(u8, sec, "ai")) {
        if (eq(u8, key, "provider")) {
            cfg.ai_provider.set(val);
        } else if (eq(u8, key, "custom-url")) {
            cfg.ai_custom_url.set(std.mem.trimRight(u8, val, "/"));
        } else if (eq(u8, key, "custom-model")) {
            cfg.ai_custom_model.set(val);
        } else if (eq(u8, key, "system")) {
            cfg.ai_system.set(val);
        } else if (eq(u8, key, "projects-dir")) {
            cfg.ai_projects_dir.set(std.mem.trimRight(u8, val, "/"));
        } else ok = false;
    } else if (eq(u8, sec, "face")) {
        if (eq(u8, key, "enabled")) {
            cfg.face_enabled = boolean(val) orelse true;
        } else if (eq(u8, key, "camera")) {
            cfg.face_camera.set(val);
        } else if (eq(u8, key, "threshold")) {
            if (num(val)) |n| cfg.face_threshold = std.math.clamp(n, 0.5, 0.95) else ok = false;
        } else if (eq(u8, key, "require_ir")) {
            cfg.face_require_ir = boolean(val) orelse true;
        } else ok = false;
    } else if (eq(u8, sec, "airpods")) {
        if (eq(u8, key, "enabled")) {
            cfg.airpods_enabled = boolean(val) orelse false;
        } else if (eq(u8, key, "yaw-angle")) {
            if (num(val)) |n| cfg.airpods_yaw = std.math.clamp(n, 10, 60) else ok = false;
        } else if (eq(u8, key, "pitch-angle")) {
            if (num(val)) |n| cfg.airpods_pitch = std.math.clamp(n, 8, 45) else ok = false;
        } else if (eq(u8, key, "invert-yaw")) {
            cfg.airpods_invert_yaw = boolean(val) orelse false;
        } else if (eq(u8, key, "invert-pitch")) {
            cfg.airpods_invert_pitch = boolean(val) orelse false;
        } else if (eq(u8, key, "popup")) {
            cfg.airpods_popup = boolean(val) orelse true;
        } else if (eq(u8, key, "reconnect-after-sleep")) {
            cfg.bt_reconnect = boolean(val) orelse true;
        } else ok = false;
    } else if (eq(u8, sec, "music-widget")) {
        if (eq(u8, key, "enabled")) {
            cfg.music_widget = boolean(val) orelse true;
        } else if (eq(u8, key, "corner")) {
            cfg.music_corner = Corner.parse(val) orelse blk: {
                ok = false;
                break :blk cfg.music_corner;
            };
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
        } else if (eq(u8, key, "battery")) {
            cfg.notify_battery = boolean(val) orelse true;
        } else if (eq(u8, key, "usb")) {
            cfg.notify_usb = boolean(val) orelse true;
        } else ok = false;
    } else if (eq(u8, sec, "lyrics")) {
        if (eq(u8, key, "music-tui")) {
            // on / off、または歌詞サーバの URL
            if (boolean(val)) |b| cfg.lyrics_music_tui_on = b else cfg.lyrics_music_tui.set(val);
        } else if (eq(u8, key, "lrclib")) {
            cfg.lyrics_lrclib = boolean(val) orelse true;
        } else if (eq(u8, key, "netease")) {
            cfg.lyrics_netease = boolean(val) orelse true;
        } else if (eq(u8, key, "kugou")) {
            cfg.lyrics_kugou = boolean(val) orelse true;
        } else ok = false;
    } else if (eq(u8, sec, "lock")) {
        if (eq(u8, key, "enabled")) cfg.lock_enabled = boolean(val) orelse true else ok = false;
    } else ok = false;
    if (!ok) diag.add("line {d}: unknown or invalid '{s}.{s} {s}'", .{ line, sec, key, val });
}

test "structure warnings" {
    var d = Diag{};
    _ = parse("accent #ffffff\ntheme {\n  radius 4\n}\n}\nbar {\n  height 30\n", .{}, &d);
    const g = d.get();
    try std.testing.expect(std.mem.indexOf(u8, g, "line 1: 'accent' is outside") != null);
    try std.testing.expect(std.mem.indexOf(u8, g, "unmatched '}'") != null);
    try std.testing.expect(std.mem.indexOf(u8, g, "missing '}' (section 'bar'") != null);
    // 警告の行番号は、そのキーの行
    var d2 = Diag{};
    _ = parse("theme {\n  radius 4\n  bogus 1\n}\n", .{}, &d2);
    try std.testing.expect(std.mem.startsWith(u8, d2.get(), "line 3: "));
}

test "nan / inf は数として受けない" {
    var d = Diag{};
    const cfg = parse("notifications { timeout nan }\ntheme { blur inf }\n", .{}, &d);
    try std.testing.expectEqual((Config{}).notify_timeout_ms, cfg.notify_timeout_ms);
    try std.testing.expectEqual((Config{}).blur, cfg.blur);
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
