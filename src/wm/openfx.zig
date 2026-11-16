// アプリの窓を開くときの水の波紋(ロック解除の波紋 ripple.zig と同じ見た目を、窓の大きさで)。
//
// River の WM は窓そのものに絵の効果をかけられないので、wobble.zig と同じく:
//   1. 開いた窓が最初に描けたら、その中身を 1 枚の絵として撮る(wincap.zig)。撮っている間は窓を 1 画素に切り抜いて隠す
//   2. 窓の場所に全面のオーバーレイ(入力は透過)で、窓の真ん中から波紋が広がり、波が通った所から窓が現れる
//   3. 広がりきったら本物の窓を見せて、オーバーレイを片付ける
// 撮れない(古い River・撮るのに時間がかかる)ときは、wm.zig のふつうの開き方(中心から広がる)にする。
// shortcut: 一度に 1 つの窓だけ(同時に開いた 2 つ目以降はふつうの開き方)。たくさん同時に開くなら複数持つ
const std = @import("std");
const c = @import("../c.zig");
const gfx = @import("../gfx/gfx.zig");
const appmod = @import("../core/app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("../core/surface.zig");
const Surface = surface.Surface;
const loop = @import("../platform/loop.zig");
const wincap = @import("wincap.zig");

const ca = std.heap.c_allocator;

/// 波紋が窓の端まで届く時間
const DUR_MS: f32 = 650;
/// 撮れるまで待つ長さ(超えたらふつうの開き方)
const CAPTURE_WAIT_MS: u64 = 250;

const Phase = enum { idle, capturing, active };

const State = struct {
    app: ?*App = null,
    phase: Phase = .idle,
    win: ?*const anyopaque = null,
    /// 撮れなかったときに呼ぶ(wm.zig のふつうの開き方)
    fallback: ?*const fn (win: *const anyopaque) void = null,
    cap: wincap.Capture = .{ .ctx = undefined, .done = onCaptured },
    capture_ms: u64 = 0,
    px: ?wincap.Pixels = null,
    tex: c.GLuint = 0,
    surf: ?*Surface = null,
    out: ?*Output = null,
    /// 窓の中身の矩形(出力の中の座標)
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    start_ms: u64 = 0,
    drawn: bool = false,
    finished: bool = false,
    prog: c.GLuint = 0,
};
var st: State = .{};

/// 窓が最初に描けた。始められれば true(そのあいだ wm.zig は hides で窓を隠す)
pub fn begin(win: *const anyopaque, ident: []const u8, rect: [4]f32, out: *Output, out_xy: [2]f32, glassy: bool, fallback: *const fn (win: *const anyopaque) void) bool {
    if (st.phase != .idle) return false;
    if (std.posix.getenv("AME_OPEN_RIPPLE")) |v| if (std.mem.eql(u8, v, "0")) return false;
    if (rect[2] < 40 or rect[3] < 40) return false;
    if (!st.cap.start(ident, glassy)) return false;
    st = .{ .cap = st.cap, .prog = st.prog };
    st.app = out.app;
    st.phase = .capturing;
    st.win = win;
    st.fallback = fallback;
    st.out = out;
    st.capture_ms = loop.nowMs();
    st.rect = .{ rect[0] - out_xy[0], rect[1] - out_xy[1], rect[2], rect[3] };
    return true;
}

/// 本物の窓を隠すべきか(撮っている間と、波紋が広がっている間)
pub fn hides(win: *const anyopaque) bool {
    if (st.win != win) return false;
    if (st.phase == .capturing and loop.nowMs() -| st.capture_ms > CAPTURE_WAIT_MS) {
        giveUp();
        return false;
    }
    return st.phase != .idle and !st.finished;
}

/// 窓が閉じた・動いた
pub fn forget(win: *const anyopaque) void {
    if (st.win != win) return;
    st.fallback = null;
    stop();
}

/// 撮れなかった: ふつうの開き方にする
fn giveUp() void {
    const fb = st.fallback;
    const w = st.win;
    stop();
    if (fb) |f| if (w) |ww| f(ww);
}

fn stop() void {
    st.cap.cancel();
    if (st.px) |p| ca.free(p.px);
    st.px = null;
    st.finished = true;
    st.win = null;
    if (st.surf != null) {
        if (st.app) |a| a.reap_pending = true;
    } else st.phase = .idle;
}

fn onCaptured(_: *anyopaque, got: ?wincap.Pixels) void {
    const px = got orelse return giveUp();
    st.px = px;
    const app = st.app orelse return giveUp();
    const out = st.out orelse return giveUp();
    st.surf = Surface.createLayer(app, .{ .ctx = &st, .draw = draw }, .{
        .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        .anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        .exclusive = -1,
        .namespace = "ame-open",
        .output = out.wl,
    }) catch return giveUp();
    st.surf.?.output = out;
    st.surf.?.setInputRect(0, 0, 0, 0);
    st.surf.?.schedule();
    st.phase = .active;
}

/// ロック解除の波紋(gfx.zig の ripple_fs)の逆: 波が通った所に窓が現れる。u_rect は窓(画素、上が原点)
const open_fs =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv; uniform sampler2D u_tex; uniform vec2 u_res; uniform vec4 u_rect; uniform float u_r; uniform float u_w; uniform float u_t; out vec4 o;
    \\void main(){
    \\  vec2 p = vec2(v_uv.x, 1.0 - v_uv.y) * u_res;
    \\  vec2 q = p - u_rect.xy;
    \\  if (q.x < 0.0 || q.y < 0.0 || q.x > u_rect.z || q.y > u_rect.w) { o = vec4(0.0); return; }
    \\  vec2 d = q - u_rect.zw * 0.5;
    \\  float dist = length(d);
    \\  vec2 n = d / max(dist, 1.0);
    \\  float x = (dist - u_r) / u_w;
    \\  float band = exp(-x * x * 1.4);
    \\  float wave = sin(x * 8.0) * band;
    \\  vec2 off = n * wave * u_w * 0.12;
    \\  vec4 col = texture(u_tex, clamp((q + off) / u_rect.zw, 0.0, 1.0));
    \\  float a = 1.0 - smoothstep(-0.35, 0.45, x);
    \\  float light = dot(n, normalize(vec2(-0.6, 0.8))) * cos(x * 8.0) * band;
    \\  col.rgb = col.rgb * (1.0 + 0.25 * light) + vec3(pow(max(wave, 0.0), 3.0) * 0.4) * col.a;
    \\  float behind = max(-x, 0.0);
    \\  float rings = pow(max(sin(dist / (u_w * 0.32) - u_t * 16.0), 0.0), 6.0) * exp(-behind * 0.22) * (1.0 - u_t) * 0.14 * a;
    \\  o = vec4(col.rgb * a + vec3(rings), col.a * a + rings);
    \\}
;

fn draw(_: *anyopaque, s: *Surface, cv: *gfx.Canvas, _: f32) bool {
    const app = st.app orelse return false;
    if (st.finished) {
        app.reap_pending = true;
        return false;
    }
    cv.flush();
    if (st.prog == 0) st.prog = gfx.program(gfx.fs_vs, open_fs) catch return giveUpDraw();
    if (st.tex == 0) if (st.px) |p| {
        st.tex = gfx.uploadImage(p.px.ptr, @intCast(p.w), @intCast(p.h));
        ca.free(p.px);
        st.px = null;
    };
    if (st.tex == 0) return giveUpDraw();
    if (st.start_ms == 0) st.start_ms = loop.nowMs();
    const t = std.math.clamp(@as(f32, @floatFromInt(loop.nowMs() - st.start_ms)) / DUR_MS, 0, 1);
    const sc: f32 = @floatFromInt(s.scale);
    const pw: f32 = @as(f32, @floatFromInt(s.width)) * sc;
    const ph: f32 = @as(f32, @floatFromInt(s.height)) * sc;
    const r = [4]f32{ st.rect[0] * sc, st.rect[1] * sc, st.rect[2] * sc, st.rect[3] * sc };
    const half_diag = @sqrt(r[2] * r[2] + r[3] * r[3]) * 0.5;
    const w = @max(half_diag * 0.18, 24);
    // 速く広がって、端でゆっくり(ease-out)
    const e = 1 - (1 - t) * (1 - t) * (1 - t);
    const rad = -w * 1.5 + e * (half_diag + w * 3.5);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glUseProgram(st.prog);
    c.glUniform2f(c.glGetUniformLocation(st.prog, "u_res"), pw, ph);
    c.glUniform4f(c.glGetUniformLocation(st.prog, "u_rect"), r[0], r[1], r[2], r[3]);
    c.glUniform1f(c.glGetUniformLocation(st.prog, "u_r"), rad);
    c.glUniform1f(c.glGetUniformLocation(st.prog, "u_w"), w);
    c.glUniform1f(c.glGetUniformLocation(st.prog, "u_t"), t);
    c.glUniform1i(c.glGetUniformLocation(st.prog, "u_tex"), 0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, st.tex);
    c.glBindVertexArray(app.gpu.empty_vao);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    c.glBindVertexArray(0);
    if (!st.drawn) {
        st.drawn = true;
        if (app.wm) |wm| wm.poke();
    }
    if (t >= 1) {
        // 広がりきった: 本物の窓を見せる(この絵は本物が出るまでの 1 コマ残す)
        st.finished = true;
        st.win = null;
        if (app.wm) |wm| wm.poke();
        app.reap_pending = true;
    }
    return true;
}

fn giveUpDraw() bool {
    giveUp();
    return false;
}

/// メインループから: 終わったオーバーレイを片付ける
pub fn reap(app: *App) void {
    if (!st.finished or st.phase == .idle) return;
    if (st.surf) |s| {
        app.gpu.makeCurrent(s.egl_surf);
        if (st.tex != 0) c.glDeleteTextures(1, &st.tex);
        st.tex = 0;
        s.destroy();
        st.surf = null;
    }
    if (st.px) |p| ca.free(p.px);
    st.px = null;
    st.phase = .idle;
    st.finished = false;
}

/// 出力が抜かれた(app.zig)
pub fn outputRemoved(o: *Output) void {
    if (st.out != o) return;
    st.out = null;
    st.fallback = null;
    stop();
}
