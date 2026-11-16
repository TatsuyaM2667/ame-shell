// 浮いた窓をドラッグしたときの「紙・液体のようにぺらっとたわむ」動き。
//
// River の WM は窓の位置と切り抜きしか決められず、窓そのものを変形できない。そこで:
//   1. ドラッグを始めたら、その窓の中身を 1 枚の絵として写す(wincap.zig)
//   2. 全面のオーバーレイに、その絵を 16×12 の網目にして描く。つかんだ所はカーソルにぴったり付いて行き、
//      遠い所ほど柔らかいばね(臨界減衰)ですーっと遅れて付いてくる。隣の点との長さを保つので、伸びずに紙のように曲がる
//   3. 本物の窓は、オーバーレイが描けている間だけ 1 画素に切り抜いて隠す(wm.zig の render)。
//      離して揺れが収まったら、オーバーレイを片付けて本物を見せる(その間に窓は新しい位置へ移っている)
// 撮影できない(古い River など)ときは何もしない(普通に動く)。
const std = @import("std");
const c = @import("../c.zig");
const gfx = @import("../gfx/gfx.zig");
const anim = @import("../gfx/anim.zig");
const appmod = @import("../core/app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("../core/surface.zig");
const Surface = surface.Surface;
const wincap = @import("wincap.zig");

const log = std.log.scoped(.wobble);
const ca = std.heap.c_allocator;

const GX = 16;
const GY = 12;
const N = GX * GY;

const Node = struct { p: [2]f32 = .{ 0, 0 }, v: [2]f32 = .{ 0, 0 }, k: f32 = 0 };

const Phase = enum { idle, capturing, active };

const State = struct {
    app: ?*App = null,
    phase: Phase = .idle,
    win: ?*const anyopaque = null,
    // 撮影
    cap: wincap.Capture = .{ .ctx = undefined, .done = onCaptured },
    px: ?[]u8 = null,
    buf_w: u32 = 0,
    buf_h: u32 = 0,
    tex: c.GLuint = 0,
    // オーバーレイ
    surf: ?*Surface = null,
    out: ?*Output = null,
    ox: f32 = 0,
    oy: f32 = 0,
    drawn: bool = false,
    // 形
    rest_w: f32 = 0,
    rest_h: f32 = 0,
    grab: [2]f32 = .{ 0, 0 }, // つかんだ所(窓の中の位置)
    target: [2]f32 = .{ 0, 0 }, // 窓の左上(グローバル)
    nodes: [N]Node = [_]Node{.{}} ** N,
    released: bool = false,
    finished: bool = false,
    // GL
    prog: c.GLuint = 0,
    vao: c.GLuint = 0,
    vbo: c.GLuint = 0,
};
var st: State = .{};

// ---------------------------------------------------------------------------
// wm.zig から
// ---------------------------------------------------------------------------

/// ドラッグを始めた。rect = 窓の中身の矩形(グローバル)、ptr = カーソル(グローバル)
pub fn begin(win: *const anyopaque, ident: []const u8, rect: [4]f32, ptr: [2]f32, out: *Output, out_xy: [2]f32, glassy: bool) void {
    const app = out.app;
    if (st.phase != .idle) return;
    // AME_WOBBLE=0 で使わない
    if (std.posix.getenv("AME_WOBBLE")) |v| if (std.mem.eql(u8, v, "0")) return;
    if (rect[2] < 40 or rect[3] < 40) return;
    if (!st.cap.start(ident, glassy)) return;
    st.app = app;
    st.win = win;
    st.phase = .capturing;
    st.released = false;
    st.finished = false;
    st.drawn = false;
    st.out = out;
    st.ox = out_xy[0];
    st.oy = out_xy[1];
    st.rest_w = rect[2];
    st.rest_h = rect[3];
    st.target = .{ rect[0], rect[1] };
    st.grab = .{ std.math.clamp(ptr[0] - rect[0], 0, rect[2]), std.math.clamp(ptr[1] - rect[1], 0, rect[3]) };
    // 網目: 置いた所から始め、つかんだ所から遠いほど柔らかいばね
    const diag = @sqrt(rect[2] * rect[2] + rect[3] * rect[3]);
    for (0..GY) |gy| for (0..GX) |gx| {
        const r = rest(gx, gy);
        const d = @sqrt((r[0] - st.grab[0]) * (r[0] - st.grab[0]) + (r[1] - st.grab[1]) * (r[1] - st.grab[1]));
        const t = std.math.clamp(d / (diag * 0.9), 0, 1);
        const e = t * t * (3 - 2 * t);
        st.nodes[gy * GX + gx] = .{ .p = .{ rect[0] + r[0], rect[1] + r[1] }, .v = .{ 0, 0 }, .k = 900 * (1 - e) + 38 * e };
    };
}

/// ドラッグ中: 窓の左上の目標(グローバル)
pub fn moveTo(win: *const anyopaque, x: f32, y: f32) void {
    if (st.win != win or st.phase == .idle) return;
    st.target = .{ x, y };
    if (st.surf) |s| s.schedule();
}

/// 離した: 揺れが収まったら本物の窓を見せる
pub fn release(win: *const anyopaque) void {
    if (st.win != win) return;
    st.released = true;
    if (st.phase == .capturing) return abort(); // まだ撮れていない: やめる
    if (st.surf) |s| s.schedule();
}

/// この窓を隠すべきか(オーバーレイが代わりに描いている間)
pub fn hides(win: *const anyopaque) bool {
    return st.win == win and st.phase == .active and st.drawn and !st.finished;
}

/// 窓が消えた
pub fn forget(win: *const anyopaque) void {
    if (st.win == win) abort();
}

fn rest(gx: usize, gy: usize) [2]f32 {
    return .{ st.rest_w * @as(f32, @floatFromInt(gx)) / (GX - 1), st.rest_h * @as(f32, @floatFromInt(gy)) / (GY - 1) };
}

fn abort() void {
    st.cap.cancel();
    if (st.px) |p| ca.free(p);
    st.px = null;
    st.finished = true;
    if (st.surf != null) {
        if (st.app) |a| a.reap_pending = true;
    } else {
        st.phase = .idle;
        st.win = null;
    }
}

/// 撮れた(wincap.zig): 全面のオーバーレイ(入力は透過)を出す
fn onCaptured(_: *anyopaque, got: ?wincap.Pixels) void {
    const px = got orelse return abort();
    st.px = px.px;
    st.buf_w = px.w;
    st.buf_h = px.h;
    if (st.released) return abort(); // 撮れる前に離した
    const app = st.app orelse return abort();
    const out = st.out orelse return abort();
    st.surf = Surface.createLayer(app, .{ .ctx = &st, .draw = draw }, .{
        .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        .anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        .exclusive = -1,
        .namespace = "ame-wobble",
        .output = out.wl,
    }) catch return abort();
    st.surf.?.output = out;
    st.surf.?.setInputRect(0, 0, 0, 0);
    st.surf.?.schedule();
    st.phase = .active;
}

// ---------------------------------------------------------------------------
// ばねと描画
// ---------------------------------------------------------------------------

/// 1 コマ進める。収まったら true
/// 紙らしさ: (1) ばねは臨界減衰(揺れずに、すーっと追いつく)。つかんだ所から遠いほど柔らかく、長く遅れる
///          (2) 隣り合う点の間の長さを保つ(伸びずに、曲がる)。(3) つかんだ点はカーソルにぴったり
fn step(dt_in: f32) bool {
    const dt = @min(dt_in, 1.0 / 20.0);
    var t: f32 = 0;
    const sub: f32 = 1.0 / 240.0;
    const gi = grabIndex();
    while (t < dt) : (t += sub) {
        const h = @min(sub, dt - t);
        var prev: [N][2]f32 = undefined;
        for (0..GY) |gy| for (0..GX) |gx| {
            const i = gy * GX + gx;
            const nd = &st.nodes[i];
            prev[i] = nd.p;
            const r = rest(gx, gy);
            const tx = st.target[0] + r[0];
            const ty = st.target[1] + r[1];
            const damp = 2 * 1.0 * @sqrt(nd.k);
            nd.v[0] += (nd.k * (tx - nd.p[0]) - damp * nd.v[0]) * h;
            nd.v[1] += (nd.k * (ty - nd.p[1]) - damp * nd.v[1]) * h;
            nd.p[0] += nd.v[0] * h;
            nd.p[1] += nd.v[1] * h;
        };
        // つかんだ点はカーソルに固定
        {
            const r = rest(gi % GX, gi / GX);
            st.nodes[gi].p = .{ st.target[0] + r[0], st.target[1] + r[1] };
            st.nodes[gi].v = .{ 0, 0 };
        }
        // 伸びない紙: 隣の点との長さを元に戻す(つかんだ点は動かさない)
        var iter: u32 = 0;
        while (iter < 3) : (iter += 1) {
            for (0..GY) |gy| for (0..GX) |gx| {
                const i = gy * GX + gx;
                if (gx + 1 < GX) keepLength(i, i + 1, st.rest_w / (GX - 1), gi);
                if (gy + 1 < GY) keepLength(i, i + GX, st.rest_h / (GY - 1), gi);
            };
        }
        // 長さを直した分を速さに反映(位置だけ動かすと、次の手順で跳ね返る)
        for (0..N) |i| {
            if (i == gi) continue;
            const nd = &st.nodes[i];
            const moved_x = nd.p[0] - prev[i][0];
            const moved_y = nd.p[1] - prev[i][1];
            nd.v[0] = nd.v[0] * 0.5 + (moved_x / h) * 0.5;
            nd.v[1] = nd.v[1] * 0.5 + (moved_y / h) * 0.5;
        }
    }
    var settled = true;
    for (0..GY) |gy| for (0..GX) |gx| {
        const nd = st.nodes[gy * GX + gx];
        const r = rest(gx, gy);
        if (@abs(nd.p[0] - st.target[0] - r[0]) > 0.4 or @abs(nd.p[1] - st.target[1] - r[1]) > 0.4 or @abs(nd.v[0]) + @abs(nd.v[1]) > 6) settled = false;
    };
    return settled;
}

/// つかんだ所にいちばん近い網目の点
fn grabIndex() usize {
    const gx: usize = @intFromFloat(@round(std.math.clamp(st.grab[0] / @max(st.rest_w, 1), 0, 1) * (GX - 1)));
    const gy: usize = @intFromFloat(@round(std.math.clamp(st.grab[1] / @max(st.rest_h, 1), 0, 1) * (GY - 1)));
    return gy * GX + gx;
}

/// 2 点の間の長さを len に近づける(長すぎるときだけ縮める。縮むのは許す = 紙はたわめる)
fn keepLength(i: usize, j: usize, len: f32, pinned: usize) void {
    const a = &st.nodes[i];
    const b = &st.nodes[j];
    const dx = b.p[0] - a.p[0];
    const dy = b.p[1] - a.p[1];
    const d = @sqrt(dx * dx + dy * dy);
    if (d <= len or d < 0.001) return;
    const diff = (d - len) / d;
    const wa: f32 = if (i == pinned) 0 else 1;
    const wb: f32 = if (j == pinned) 0 else 1;
    const ws = wa + wb;
    if (ws == 0) return;
    a.p[0] += dx * diff * (wa / ws);
    a.p[1] += dy * diff * (wa / ws);
    b.p[0] -= dx * diff * (wb / ws);
    b.p[1] -= dy * diff * (wb / ws);
}

const mesh_vs =
    \\#version 300 es
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec2 a_uv;
    \\layout(location = 2) in float a_shade;
    \\out vec2 v_uv; out float v_shade;
    \\void main(){ v_uv = a_uv; v_shade = a_shade; gl_Position = vec4(a_pos, 0.0, 1.0); }
;
const mesh_fs =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv; in float v_shade; uniform sampler2D u_tex; out vec4 o;
    \\void main(){ vec4 t = texture(u_tex, v_uv); o = vec4(t.rgb * v_shade, t.a); }
;

fn draw(_: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
    const app = st.app orelse return false;
    if (st.finished) {
        app.reap_pending = true;
        return false;
    }
    const settled = step(dt);
    const W: f32 = @floatFromInt(s.width);
    const H: f32 = @floatFromInt(s.height);
    // 影(目標の位置に、ふわっと)
    cv.shadow(st.target[0] - st.ox, st.target[1] - st.oy + 10, st.rest_w, st.rest_h, 12, 34, anim.Color.hex(0x000000).alpha(0.35));
    cv.flush();
    if (st.prog == 0) {
        st.prog = gfx.program(mesh_vs, mesh_fs) catch 0;
        c.glGenVertexArrays(1, &st.vao);
        c.glGenBuffers(1, &st.vbo);
        c.glBindVertexArray(st.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, st.vbo);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(0));
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(8));
        c.glEnableVertexAttribArray(2);
        c.glVertexAttribPointer(2, 1, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(16));
        c.glBindVertexArray(0);
    }
    if (st.tex == 0) if (st.px) |p| {
        st.tex = gfx.uploadImage(p.ptr, @intCast(st.buf_w), @intCast(st.buf_h));
        ca.free(p);
        st.px = null;
    };
    if (st.prog == 0 or st.tex == 0) return true;
    // 三角形の頂点(位置は NDC、uv、陰)。たわんだ所ほど少し暗く(紙の折れ目のように)
    var verts: [(GX - 1) * (GY - 1) * 6 * 5]f32 = undefined;
    var k: usize = 0;
    const put = struct {
        fn f(v: []f32, i: *usize, gx: usize, gy: usize, w: f32, h: f32) void {
            const nd = st.nodes[gy * GX + gx];
            const r = rest(gx, gy);
            const dx = nd.p[0] - st.target[0] - r[0];
            const dy = nd.p[1] - st.target[1] - r[1];
            const dev = @sqrt(dx * dx + dy * dy);
            v[i.* + 0] = (nd.p[0] - st.ox) / w * 2 - 1;
            v[i.* + 1] = 1 - (nd.p[1] - st.oy) / h * 2;
            v[i.* + 2] = @as(f32, @floatFromInt(gx)) / (GX - 1);
            v[i.* + 3] = @as(f32, @floatFromInt(gy)) / (GY - 1);
            v[i.* + 4] = 1 - 0.22 * std.math.clamp(dev / 70, 0, 1);
            i.* += 5;
        }
    }.f;
    for (0..GY - 1) |gy| for (0..GX - 1) |gx| {
        put(&verts, &k, gx, gy, W, H);
        put(&verts, &k, gx + 1, gy, W, H);
        put(&verts, &k, gx, gy + 1, W, H);
        put(&verts, &k, gx + 1, gy, W, H);
        put(&verts, &k, gx + 1, gy + 1, W, H);
        put(&verts, &k, gx, gy + 1, W, H);
    };
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glUseProgram(st.prog);
    c.glUniform1i(c.glGetUniformLocation(st.prog, "u_tex"), 0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, st.tex);
    c.glBindVertexArray(st.vao);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, st.vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(k * 4), &verts, c.GL_STREAM_DRAW);
    c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(k / 5));
    c.glBindVertexArray(0);
    if (!st.drawn) {
        // 1 枚描けた: 本物の窓を隠してもらう
        st.drawn = true;
        if (app.wm) |wm| wm.poke();
    }
    if (st.released and settled) {
        // 収まった: 本物の窓を見せ、次のループでオーバーレイを片付ける
        st.finished = true;
        if (app.wm) |wm| wm.poke();
        app.reap_pending = true;
        return true; // 本物が出るまでの 1 コマはこの絵を出したまま
    }
    return true;
}

/// メインループから: 終わったオーバーレイを片付ける
pub fn reap(app: *App) void {
    if (!st.finished) return;
    if (st.surf) |s| {
        app.gpu.makeCurrent(s.egl_surf);
        if (st.tex != 0) c.glDeleteTextures(1, &st.tex);
        st.tex = 0;
        s.destroy();
        st.surf = null;
    }
    if (st.px) |p| ca.free(p);
    st.px = null;
    st.phase = .idle;
    st.win = null;
    st.finished = false;
}

/// 出力が抜かれた(app.zig): その出力でたわませているならやめる
pub fn outputRemoved(o: *Output) void {
    if (st.out != o) return;
    st.out = null;
    abort();
}
