// Odin 製アニメーションコア(anim/anim.odin)の Zig 側バインディング。
const std = @import("std");

/// anim.odin の `Spring` とレイアウト一致。
pub const Spring = extern struct {
    x: f32 = 0,
    v: f32 = 0,
    target: f32 = 0,
    response: f32 = 0.35,
    damping: f32 = 0.86,

    pub fn init(v: f32, response: f32, damping: f32) Spring {
        return .{ .x = v, .target = v, .response = response, .damping = damping };
    }

    /// 目標を変える。現在の位置と速度はそのまま(速度連続)。
    pub fn set(self: *Spring, t: f32) void {
        self.target = t;
    }

    /// アニメーションせずに即座に値を置く(初回表示などに使う)。
    pub fn snap(self: *Spring, t: f32) void {
        self.x = t;
        self.target = t;
        self.v = 0;
    }

    /// 少し勢いを足す(クリック時の「ぷにっ」とした反応用)。
    pub fn kick(self: *Spring, dv: f32) void {
        self.v += dv;
    }

    pub fn step(self: *Spring, dt: f32) bool {
        return ame_spring_step(self, dt * speed_scale) != 0;
    }

    pub fn moving(self: *const Spring) bool {
        return self.x != self.target or self.v != 0;
    }
};

/// 設定の anim-speed。>1 で速く。dt に掛ける(応答時間を短くするのと等価)。
pub var speed_scale: f32 = 1.0;

/// 複数スプリングをまとめて進め、どれか動いていれば true。
pub fn stepAll(springs: []const *Spring, dt: f32) bool {
    var any = false;
    for (springs) |s| {
        if (s.step(dt)) any = true;
    }
    return any;
}

pub extern fn ame_spring_step(s: *Spring, dt: f32) i32;
pub extern fn ame_springs_step(arr: [*]Spring, count: i32, dt: f32) i32;
pub extern fn ame_fuzzy_score(pat: [*]const u8, pat_len: i32, text: [*]const u8, text_len: i32) i32;
pub extern fn ame_dominant_color(rgba: [*]const u8, pixel_count: i32, stride_px: i32, work: [*]u32) u32;

pub fn fuzzy(pat: []const u8, text: []const u8) i32 {
    return ame_fuzzy_score(pat.ptr, @intCast(pat.len), text.ptr, @intCast(text.len));
}

/// 色: 線形補間用の RGBA(0..1)。
pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn hex(v: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
            .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
            .b = @as(f32, @floatFromInt(v & 0xff)) / 255.0,
            .a = 1,
        };
    }

    pub fn rgba(v: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((v >> 24) & 0xff)) / 255.0,
            .g = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
            .b = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
            .a = @as(f32, @floatFromInt(v & 0xff)) / 255.0,
        };
    }

    pub fn alpha(self: Color, a: f32) Color {
        var c = self;
        c.a *= a;
        return c;
    }

    pub fn mix(a: Color, b: Color, t: f32) Color {
        return .{ .r = a.r + (b.r - a.r) * t, .g = a.g + (b.g - a.g) * t, .b = a.b + (b.b - a.b) * t, .a = a.a + (b.a - a.a) * t };
    }

    pub fn lighten(self: Color, t: f32) Color {
        return mix(self, .{ .r = 1, .g = 1, .b = 1, .a = self.a }, t);
    }
};

/// 色もスプリングで動かす(アルバムアート由来のアクセント色の遷移など)。
pub const ColorSpring = struct {
    r: Spring,
    g: Spring,
    b: Spring,

    pub fn init(col: Color, response: f32) ColorSpring {
        return .{ .r = Spring.init(col.r, response, 1), .g = Spring.init(col.g, response, 1), .b = Spring.init(col.b, response, 1) };
    }
    pub fn set(self: *ColorSpring, col: Color) void {
        self.r.set(col.r);
        self.g.set(col.g);
        self.b.set(col.b);
    }
    pub fn step(self: *ColorSpring, dt: f32) bool {
        const a = self.r.step(dt);
        const b = self.g.step(dt);
        const c = self.b.step(dt);
        return a or b or c;
    }
    pub fn get(self: *const ColorSpring) Color {
        return .{ .r = self.r.x, .g = self.g.x, .b = self.b.x, .a = 1 };
    }
};
