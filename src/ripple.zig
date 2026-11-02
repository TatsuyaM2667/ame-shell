// ロック解除の水の波紋(Win+L のロック画面から解除したとき)。
//
// ロック中はコンポジタがデスクトップを見せないので、ロック画面の上で「透けていく」演出はできない。そこで:
//   1. 解除が決まったら、ロック画面の今の絵を出力ごとにテクスチャへ写し取る(lock.zig)
//   2. その絵をそのまま映す全面のオーバーレイ(layer-shell の OVERLAY・入力は透過)を出す
//   3. オーバーレイが 1 回描けたら、ロックを外す(見た目は同じなので切り替わりは見えない)
//   4. 中心から波紋が広がり、波が通り過ぎた所からデスクトップが透けて見える(gfx.zig の ripple_fs)。
//      広がりきったらオーバーレイを片付ける
const std = @import("std");
const c = @import("c.zig");
const gfx = @import("gfx.zig");
const appmod = @import("app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("surface.zig");
const Surface = surface.Surface;
const loop = @import("platform/loop.zig");

const MAX = 8;
/// 波紋が画面の端まで届く時間
const DUR_MS: f32 = 1400;

pub const Snap = struct { out: *Output, tex: c.GLuint, w: c_int, h: c_int };

const View = struct {
    surf: *Surface,
    snap: Snap,
    drawn: bool = false,
};

const State = struct {
    app: ?*App = null,
    views: [MAX]?View = [_]?View{null} ** MAX,
    /// ロックを外した時刻(0 = まだ。それまでは写しをそのまま映す)
    start_ms: u64 = 0,
    done: bool = false,
};
var st: State = .{};

pub fn active() bool {
    for (st.views) |v| if (v != null) return true;
    return false;
}

/// 写しを受け取ってオーバーレイを出す。出せなければ false(テクスチャは呼んだ側が捨てる)
pub fn start(app: *App, snaps: []const Snap) bool {
    if (active() or snaps.len == 0) return false;
    st = .{ .app = app };
    var n: usize = 0;
    for (snaps) |sn| {
        if (n >= MAX) break;
        const s = Surface.createLayer(app, .{ .ctx = &st, .draw = draw }, .{
            .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            .anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
            .exclusive = -1,
            .namespace = "ame-unlock",
            .output = sn.out.wl,
        }) catch continue;
        s.output = sn.out;
        s.setInputRect(0, 0, 0, 0); // クリックは下のアプリへ
        s.schedule();
        st.views[n] = .{ .surf = s, .snap = sn };
        n += 1;
    }
    return n > 0;
}

/// ロックを外した: ここから波紋を進める
pub fn begin() void {
    st.start_ms = loop.nowMs();
    for (st.views) |v| if (v) |vv| vv.surf.schedule();
}

/// どのビューも 1 回描けたか(描けたらロックを外してよい)
pub fn ready() bool {
    var any = false;
    for (st.views) |v| if (v) |vv| {
        if (!vv.drawn) return false;
        any = true;
    };
    return any;
}

fn draw(_: *anyopaque, s: *Surface, cv: *gfx.Canvas, _: f32) bool {
    const app = st.app orelse return false;
    var view: ?*View = null;
    for (&st.views) |*v| if (v.*) |*vv| if (vv.surf == s) {
        view = vv;
    };
    const v = view orelse return false;
    const first = !v.drawn;
    v.drawn = true;
    // 最初の 1 枚が全部の出力で描けたら、ロックを外してもらう
    if (first and st.start_ms == 0 and ready()) app.reap_pending = true;

    const t: f32 = if (st.start_ms == 0) 0 else std.math.clamp(@as(f32, @floatFromInt(loop.nowMs() - st.start_ms)) / DUR_MS, 0, 1);
    cv.flush();
    const pw: f32 = @floatFromInt(@as(i32, @intCast(s.width)) * s.scale);
    const ph: f32 = @floatFromInt(@as(i32, @intCast(s.height)) * s.scale);
    const diag = @sqrt(pw * pw + ph * ph);
    const w = diag * 0.075;
    // 速く広がって、端でゆっくり(ease-out)
    const e = 1 - (1 - t) * (1 - t) * (1 - t);
    const r = -w * 1.5 + e * (diag * 0.5 + w * 4.5);
    const g = &app.gpu;
    c.glDisable(c.GL_BLEND);
    c.glUseProgram(g.ripple);
    c.glUniform2f(c.glGetUniformLocation(g.ripple, "u_res"), pw, ph);
    c.glUniform1f(c.glGetUniformLocation(g.ripple, "u_r"), r);
    c.glUniform1f(c.glGetUniformLocation(g.ripple, "u_w"), w);
    c.glUniform1f(c.glGetUniformLocation(g.ripple, "u_t"), t);
    c.glUniform1i(c.glGetUniformLocation(g.ripple, "u_tex"), 0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, v.snap.tex);
    c.glBindVertexArray(g.empty_vao);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    c.glBindVertexArray(0);
    if (t >= 1) {
        st.done = true;
        app.reap_pending = true;
        return false;
    }
    return true;
}

/// メインループから: 広がりきったら片付ける
pub fn reap(app: *App) void {
    if (!st.done) return;
    st.done = false;
    for (&st.views) |*v| if (v.*) |vv| {
        app.gpu.makeCurrent(vv.surf.egl_surf);
        var tex = vv.snap.tex;
        c.glDeleteTextures(1, &tex);
        vv.surf.destroy();
        v.* = null;
    };
}

/// ロック画面の今の描き先(既定のフレームバッファ)を写し取る。lock.zig の描画の最後に呼ぶ
pub fn capture(pw: c_int, ph: c_int) c.GLuint {
    var tex: c.GLuint = 0;
    c.glGenTextures(1, &tex);
    c.glBindTexture(c.GL_TEXTURE_2D, tex);
    c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, 0);
    c.glCopyTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, 0, 0, pw, ph, 0);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    return tex;
}

/// 出力が抜かれた(app.zig): その出力の波紋だけ片付ける
pub fn outputRemoved(app: *App, o: *Output) void {
    for (&st.views) |*v| if (v.*) |vv| if (vv.snap.out == o) {
        app.gpu.makeCurrent(vv.surf.egl_surf);
        var tex = vv.snap.tex;
        c.glDeleteTextures(1, &tex);
        vv.surf.destroy();
        v.* = null;
    };
}
