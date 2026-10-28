// ame-shell ウィジェット SDK(wasm32-freestanding 用)。
//
// ホストとの取り決め(ゼロコピー):
//  * ウィジェットは自分のリニアメモリ上に「描画コマンド配列」と「データストア」を持ち、
//    そのアドレスを ame_cmds() / ame_store() で教える。
//  * ホストは毎フレーム前にストアへ直接値を書き込み、ame_frame() の後にコマンド配列を
//    直接読む。文字列もウィジェットのメモリ上のポインタ+長さで渡すのでコピーが無い。
//  * ウィジェットが外界に作用できるのは import の action() だけ(ファイル/ネットワーク不可)。
//
// アニメーションは Odin のスプリング(anim.odin を wasm32 にビルドしたもの)をそのまま使う。
const std = @import("std");

const abi = @import("abi");
pub const CmdKind = abi.CmdKind;
pub const Cmd = abi.Cmd;
pub const Store = abi.Store;
pub const Action = abi.Action;
pub const PointerKind = abi.PointerKind;

// ---- ホストと共有するレイアウト(src/widget_abi.zig) ----
extern "ame" fn action(id: u32, value: f32) void;

pub fn act(a: Action, v: f32) void {
    action(@intFromEnum(a), v);
}

// ---- Odin のスプリング ----

pub const Spring = extern struct {
    x: f32 = 0,
    v: f32 = 0,
    target: f32 = 0,
    response: f32 = 0.35,
    damping: f32 = 0.85,

    pub fn init(v: f32, response: f32, damping: f32) Spring {
        return .{ .x = v, .target = v, .response = response, .damping = damping };
    }
    pub fn step(self: *Spring, dt: f32) bool {
        return ame_spring_step(self, dt) != 0;
    }
};
extern fn ame_spring_step(s: *Spring, dt: f32) i32;

// ---- 共有バッファ ----

pub var store: Store = .{};
pub var cmds: [256]Cmd = undefined;
pub var n_cmds: u32 = 0;
var str_pool: [4096]u8 = undefined;
var str_used: usize = 0;

pub fn begin() void {
    n_cmds = 0;
    str_used = 0;
}

fn push(c: Cmd) void {
    if (n_cmds >= cmds.len) return;
    cmds[n_cmds] = c;
    n_cmds += 1;
}

fn base(kind: CmdKind, x: f32, y: f32, w: f32, h: f32) Cmd {
    return .{ .kind = @intFromEnum(kind), .x = x, .y = y, .w = w, .h = h, .r = 0, .col = 0, .col2 = 0, .a = 0, .b = 0, .str_ptr = 0, .str_len = 0, .flags = 0 };
}

pub fn rect(x: f32, y: f32, w: f32, h: f32, r: f32, col: u32) void {
    var c = base(.rect, x, y, w, h);
    c.r = r;
    c.col = col;
    push(c);
}
pub fn grad(x: f32, y: f32, w: f32, h: f32, r: f32, top: u32, bottom: u32) void {
    var c = base(.grad, x, y, w, h);
    c.r = r;
    c.col = top;
    c.col2 = bottom;
    push(c);
}
pub fn border(x: f32, y: f32, w: f32, h: f32, r: f32, col: u32, width: f32) void {
    var c = base(.border, x, y, w, h);
    c.r = r;
    c.col = col;
    c.a = width;
    push(c);
}
pub fn glass(x: f32, y: f32, w: f32, h: f32, r: f32) void {
    var c = base(.glass, x, y, w, h);
    c.r = r;
    push(c);
}
pub fn shadow(x: f32, y: f32, w: f32, h: f32, r: f32, blur: f32, col: u32) void {
    var c = base(.shadow, x, y, w, h);
    c.r = r;
    c.a = blur;
    c.col = col;
    push(c);
}
pub const Align = enum(u32) { left = 0, center = 1, right = 2 };
pub fn text(x: f32, y: f32, size: f32, col: u32, s: []const u8, bold: bool, al: Align, max_w: f32, glow: f32) void {
    var c = base(.text, x, y, max_w, 0);
    c.a = size;
    c.b = glow;
    c.col = col;
    c.col2 = col & 0xffffff00 | 0x80;
    c.str_ptr = @intFromPtr(s.ptr);
    c.str_len = @intCast(s.len);
    c.flags = @as(u32, @intFromBool(bold)) | (@intFromEnum(al) << 1);
    push(c);
}
pub fn arc(cx: f32, cy: f32, radius: f32, thick: f32, progress: f32, fg: u32, track: u32) void {
    var c = base(.arc, cx, cy, radius, 0);
    c.a = thick;
    c.b = progress;
    c.col = fg;
    c.col2 = track;
    push(c);
}
pub fn art(x: f32, y: f32, w: f32, h: f32, r: f32) void {
    var c = base(.art, x, y, w, h);
    c.r = r;
    push(c);
}
pub fn clip(x: f32, y: f32, w: f32, h: f32) void {
    push(base(.clip, x, y, w, h));
}

/// 一時的な文字列(このフレームの間だけ有効)を作る
pub fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    const s = std.fmt.bufPrint(str_pool[str_used..], f, args) catch return "";
    str_used += s.len;
    return s;
}

// ---- 色 ----

pub fn rgba(rgb: u32, a: f32) u32 {
    const aa: u32 = @intFromFloat(std.math.clamp(a, 0, 1) * 255);
    return (rgb << 8) | aa;
}

pub fn mix(a: u32, b: u32, t: f32) u32 {
    const tt = std.math.clamp(t, 0, 1);
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const ca: f32 = @floatFromInt((a >> sh) & 0xff);
        const cb: f32 = @floatFromInt((b >> sh) & 0xff);
        out |= @as(u32, @intFromFloat(ca + (cb - ca) * tt)) << sh;
    }
    return out;
}

pub fn hit(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32) bool {
    return px >= x and px < x + w and py >= y and py < y + h;
}

/// 各ウィジェットが `pub const W = struct { ... }` を定義し、この関数でエクスポートを生成する。
pub fn exportWidget(comptime W: type) void {
    const S = struct {
        fn ame_cmds() callconv(.C) u32 {
            return @intFromPtr(&cmds);
        }
        fn ame_store() callconv(.C) u32 {
            return @intFromPtr(&store);
        }
        fn ame_state() callconv(.C) u32 {
            return @intFromPtr(&W.state);
        }
        fn ame_state_size() callconv(.C) u32 {
            return @sizeOf(@TypeOf(W.state));
        }
        fn ame_height(w: f32) callconv(.C) f32 {
            return W.height(w);
        }
        fn ame_frame(dt: f32, w: f32, h: f32) callconv(.C) u32 {
            begin();
            const animating = W.frame(dt, w, h);
            return (n_cmds << 1) | @intFromBool(animating);
        }
        fn ame_pointer(kind: u32, x: f32, y: f32) callconv(.C) u32 {
            return @intFromBool(W.pointer(@enumFromInt(kind), x, y));
        }
    };
    @export(S.ame_cmds, .{ .name = "ame_cmds" });
    @export(S.ame_store, .{ .name = "ame_store" });
    @export(S.ame_state, .{ .name = "ame_state" });
    @export(S.ame_state_size, .{ .name = "ame_state_size" });
    @export(S.ame_height, .{ .name = "ame_height" });
    @export(S.ame_frame, .{ .name = "ame_frame" });
    @export(S.ame_pointer, .{ .name = "ame_pointer" });
}
