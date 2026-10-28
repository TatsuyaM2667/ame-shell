// 動画・GIF のライブ壁紙(libmpv の描画 API を dlopen で使う)。
//
// libmpv(C ライブラリ)は実行時に読み込むので、ビルドにヘッダや開発パッケージは要らない。
// 無い環境では動画壁紙だけが使えない(GIF は 1 コマ目の静止画になる)。
// 復号は mpv(VA-API のハードウェア復号を優先)、描画は ame-shell の共有 GL コンテキストで
// FBO のテクスチャへ。新しいコマができたときだけ mpv の別スレッドから通知が来るので、
// 壁紙はそのときだけ描き直す(動画の fps 以上には描かない)。
const std = @import("std");
const c = @import("c.zig");
const gfx = @import("gfx.zig");
const loop = @import("platform/loop.zig");

const log = std.log.scoped(.video);

// ---- libmpv の型と定数(mpv/client.h, mpv/render.h, mpv/render_gl.h より) ----
const MpvHandle = opaque {};
const MpvRenderCtx = opaque {};
const RenderParam = extern struct { type: c_int, data: ?*anyopaque };
const GlInitParams = extern struct {
    get_proc_address: *const fn (?*anyopaque, [*:0]const u8) callconv(.C) ?*anyopaque,
    ctx: ?*anyopaque,
};
const GlFbo = extern struct { fbo: c_int, w: c_int, h: c_int, internal_format: c_int };
const MpvEvent = extern struct { event_id: c_int, err: c_int, reply_userdata: u64, data: ?*anyopaque };

const PARAM_API_TYPE = 1;
const PARAM_OPENGL_INIT_PARAMS = 2;
const PARAM_OPENGL_FBO = 3;
const PARAM_FLIP_Y = 4;
const PARAM_BLOCK_FOR_TARGET_TIME = 12;
const UPDATE_FRAME: u64 = 1;
const FORMAT_INT64 = 4;
const EVENT_NONE = 0;
const EVENT_VIDEO_RECONFIG = 17;
const EVENT_END_FILE = 7;
const END_FILE_REASON_ERROR = 4;
const EndFile = extern struct { reason: c_int, err: c_int };

const Api = struct {
    create: *const fn () callconv(.C) ?*MpvHandle,
    initialize: *const fn (*MpvHandle) callconv(.C) c_int,
    set_option_string: *const fn (*MpvHandle, [*:0]const u8, [*:0]const u8) callconv(.C) c_int,
    command: *const fn (*MpvHandle, [*]const ?[*:0]const u8) callconv(.C) c_int,
    get_property: *const fn (*MpvHandle, [*:0]const u8, c_int, *anyopaque) callconv(.C) c_int,
    wait_event: *const fn (*MpvHandle, f64) callconv(.C) *MpvEvent,
    set_wakeup_callback: *const fn (*MpvHandle, ?*const fn (?*anyopaque) callconv(.C) void, ?*anyopaque) callconv(.C) void,
    terminate_destroy: *const fn (*MpvHandle) callconv(.C) void,
    rc_create: *const fn (*?*MpvRenderCtx, *MpvHandle, [*]RenderParam) callconv(.C) c_int,
    rc_set_update_callback: *const fn (*MpvRenderCtx, ?*const fn (?*anyopaque) callconv(.C) void, ?*anyopaque) callconv(.C) void,
    rc_update: *const fn (*MpvRenderCtx) callconv(.C) u64,
    rc_render: *const fn (*MpvRenderCtx, [*]RenderParam) callconv(.C) c_int,
    rc_free: *const fn (*MpvRenderCtx) callconv(.C) void,
};

var api: ?Api = null;
var api_tried = false;

/// 直近の失敗の理由(壁紙を切り替えたときの通知に出す)
pub var last_error: []const u8 = "";
const no_libmpv_hint = if (@import("builtin").os.tag == .freebsd) "libmpv が見つかりません(doas pkg install mpv)" else "libmpv が見つかりません(mpv-libs などのパッケージを入れてください)";

fn loadApi() ?Api {
    if (api_tried) return api;
    api_tried = true;
    const h = std.c.dlopen("libmpv.so.2", std.c.RTLD.LAZY) orelse std.c.dlopen("libmpv.so", std.c.RTLD.LAZY) orelse {
        log.warn("動画壁紙は使えません: {s}", .{no_libmpv_hint});
        last_error = no_libmpv_hint;
        return null;
    };
    var a: Api = undefined;
    inline for (.{
        .{ "create", "mpv_create" },
        .{ "initialize", "mpv_initialize" },
        .{ "set_option_string", "mpv_set_option_string" },
        .{ "command", "mpv_command" },
        .{ "get_property", "mpv_get_property" },
        .{ "wait_event", "mpv_wait_event" },
        .{ "set_wakeup_callback", "mpv_set_wakeup_callback" },
        .{ "terminate_destroy", "mpv_terminate_destroy" },
        .{ "rc_create", "mpv_render_context_create" },
        .{ "rc_set_update_callback", "mpv_render_context_set_update_callback" },
        .{ "rc_update", "mpv_render_context_update" },
        .{ "rc_render", "mpv_render_context_render" },
        .{ "rc_free", "mpv_render_context_free" },
    }) |p| {
        const sym = std.c.dlsym(h, p[1]) orelse {
            log.warn("libmpv に {s} がありません", .{p[1]});
            last_error = "libmpv が古いか壊れています";
            return null;
        };
        @field(a, p[0]) = @ptrCast(sym);
    }
    api = a;
    return a;
}

pub fn available() bool {
    return loadApi() != null;
}

/// 拡張子で動画(mpv で再生するもの)かを判定
pub fn isVideoPath(path: []const u8) bool {
    const exts = [_][]const u8{ ".mp4", ".webm", ".mkv", ".mov", ".m4v", ".avi", ".gif" };
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(path, e)) return true;
    return false;
}

fn getProc(_: ?*anyopaque, name: [*:0]const u8) callconv(.C) ?*anyopaque {
    return @ptrCast(@constCast(c.eglGetProcAddress(name)));
}

/// 1 本の動画を繰り返し再生し、コマを GL テクスチャへ描く。
/// 通常は libmpv(ハードウェア復号・GPU で描画)。libmpv が無い・再生できないときは ffmpeg のプロセスで
/// 復号したコマ(RGBA)をパイプで受け取ってテクスチャへ送る(ff が非 null。mpv / rc は使わない)
pub const Player = struct {
    mpv: *MpvHandle = undefined,
    rc: *MpvRenderCtx = undefined,
    ff: ?*Ff = null,
    /// mpv のスレッド → メインループへの通知(新しいコマ / イベント)
    pipe_r: c_int,
    pipe_w: c_int,
    fbo: c.GLuint = 0,
    tex: c.GLuint = 0,
    w: c_int = 0,
    h: c_int = 0,
    /// 描き直しが必要(新しいコマが来た)
    frame_ready: bool = false,
    /// 再生できなかった(形式やデコーダの問題)
    failed: bool = false,
    max_w: c_int,
    max_h: c_int,

    /// GL コンテキストが current の状態で呼ぶ。
    /// wl_display は mpv に渡さない: VA-API が別の場所でラウンドトリップし、イベントループの読み込み準備と
    /// 噛み合って固まるため(ハードウェア復号は DRM のレンダーノード経由で行われる)
    pub fn create(alloc: std.mem.Allocator, path: []const u8, max_w: c_int, max_h: c_int) ?*Player {
        last_error = "";
        const a = loadApi() orelse {
            last_error = no_libmpv_hint;
            return null;
        };
        const m = a.create() orelse return null;
        // 壁紙向け: 音なし・無限ループ・ハードウェア復号・字幕や OSD なし
        const opts = [_][2][*:0]const u8{
            .{ "vo", "libmpv" },
            .{ "hwdec", "auto-safe" },
            .{ "loop-file", "inf" },
            .{ "audio", "no" },
            .{ "sub-auto", "no" },
            .{ "osd-level", "0" },
            .{ "terminal", "no" },
            .{ "input-default-bindings", "no" },
            .{ "keep-open", "yes" },
            .{ "video-sync", "display-desync" },
            .{ "config", "no" },
        };
        for (opts) |o| _ = a.set_option_string(m, o[0], o[1]);
        if (a.initialize(m) < 0) {
            last_error = "mpv を初期化できません";
            a.terminate_destroy(m);
            return null;
        }
        var init_params = GlInitParams{ .get_proc_address = getProc, .ctx = null };
        var params = [_]RenderParam{
            .{ .type = PARAM_API_TYPE, .data = @constCast(@ptrCast("opengl")) },
            .{ .type = PARAM_OPENGL_INIT_PARAMS, .data = &init_params },
            .{ .type = 0, .data = null },
        };
        var rc: ?*MpvRenderCtx = null;
        if (a.rc_create(&rc, m, &params) < 0 or rc == null) {
            log.warn("mpv の描画コンテキストを作れません", .{});
            last_error = "mpv の描画(OpenGL)を準備できません";
            a.terminate_destroy(m);
            return null;
        }
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) {
            a.rc_free(rc.?);
            a.terminate_destroy(m);
            return null;
        }
        const self = alloc.create(Player) catch return null;
        self.* = .{ .mpv = m, .rc = rc.?, .pipe_r = fds[0], .pipe_w = fds[1], .max_w = max_w, .max_h = max_h };
        a.rc_set_update_callback(self.rc, onMpvUpdate, self);
        a.set_wakeup_callback(m, onMpvUpdate, self);
        var pz: [600]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return self;
        const cmd = [_]?[*:0]const u8{ "loadfile", p.ptr, null };
        _ = a.command(m, &cmd);
        return self;
    }

    pub fn destroy(self: *Player, alloc: std.mem.Allocator) void {
        if (self.ff) |f| {
            f.destroy(alloc);
            if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
            if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
            _ = c.close(self.pipe_r);
            alloc.destroy(self);
            return;
        }
        const a = api.?;
        a.rc_set_update_callback(self.rc, null, null);
        a.set_wakeup_callback(self.mpv, null, null);
        a.rc_free(self.rc);
        a.terminate_destroy(self.mpv);
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        _ = c.close(self.pipe_r);
        _ = c.close(self.pipe_w);
        alloc.destroy(self);
    }

    /// mpv の内部スレッドから呼ばれる。ここでは何もせずメインループを起こすだけ
    fn onMpvUpdate(ctx: ?*anyopaque) callconv(.C) void {
        const self: *Player = @ptrCast(@alignCast(ctx.?));
        _ = c.write(self.pipe_w, "u", 1);
    }

    /// メインループで pipe_r が読めるようになったら呼ぶ。描き直しが要るなら true
    pub fn pump(self: *Player) bool {
        if (self.ff) |f| {
            switch (f.read(self.pipe_r)) {
                .frame => self.frame_ready = true,
                .eof => {
                    log.warn("ffmpeg: 動画を再生できません", .{});
                    last_error = "動画を再生できません(ffmpeg で読めない形式です)";
                    self.failed = true;
                },
                .none => {},
            }
            return self.frame_ready;
        }
        const a = api.?;
        var drain: [64]u8 = undefined;
        while (c.read(self.pipe_r, &drain, drain.len) > 0) {}
        // イベントを捨てる(溜めると mpv が詰まる)。動画の大きさが決まったら FBO を作り直す
        while (true) {
            const ev = a.wait_event(self.mpv, 0);
            if (ev.event_id == EVENT_NONE) break;
            if (ev.event_id == EVENT_VIDEO_RECONFIG) self.resize();
            if (ev.event_id == EVENT_END_FILE) if (ev.data) |d| {
                const ef: *const EndFile = @ptrCast(@alignCast(d));
                if (ef.reason == END_FILE_REASON_ERROR) {
                    log.warn("mpv: 動画を再生できません(エラー {d})", .{ef.err});
                    last_error = "動画を再生できません(形式かデコーダの問題)";
                    self.failed = true;
                }
            };
        }
        if (a.rc_update(self.rc) & UPDATE_FRAME != 0) self.frame_ready = true;
        return self.frame_ready;
    }

    fn resize(self: *Player) void {
        const a = api.?;
        var vw: i64 = 0;
        var vh: i64 = 0;
        if (a.get_property(self.mpv, "dwidth", FORMAT_INT64, &vw) < 0 or a.get_property(self.mpv, "dheight", FORMAT_INT64, &vh) < 0) return;
        if (vw <= 0 or vh <= 0) return;
        // 画面より大きい動画は画面の大きさまで縮めて描く(4K 動画でも描画の負荷を抑える)
        const sx = @as(f64, @floatFromInt(self.max_w)) / @as(f64, @floatFromInt(vw));
        const sy = @as(f64, @floatFromInt(self.max_h)) / @as(f64, @floatFromInt(vh));
        const s = @min(1.0, @max(sx, sy));
        self.w = @intFromFloat(@round(@as(f64, @floatFromInt(vw)) * s));
        self.h = @intFromFloat(@round(@as(f64, @floatFromInt(vh)) * s));
        if (self.tex == 0) c.glGenTextures(1, &self.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, self.w, self.h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        if (self.fbo == 0) c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex, 0);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        self.frame_ready = true;
        log.info("動画 {d}x{d} → {d}x{d}", .{ vw, vh, self.w, self.h });
    }

    /// 新しいコマを FBO のテクスチャへ描く(GL コンテキストが current の状態で)
    pub fn render(self: *Player) void {
        if (self.ff) |f| {
            if (!self.frame_ready) return;
            self.frame_ready = false;
            if (self.tex == 0) self.allocTarget(f.w, f.h);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
            c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
            c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, f.w, f.h, c.GL_RGBA, c.GL_UNSIGNED_BYTE, f.front.ptr);
            return;
        }
        if (!self.frame_ready or self.fbo == 0) return;
        self.frame_ready = false;
        const a = api.?;
        var fbo = GlFbo{ .fbo = @intCast(self.fbo), .w = self.w, .h = self.h, .internal_format = 0 };
        // 壁紙のシェーダは画像を「上が v=0」で扱う(stb_image と同じ向き)
        var flip: c_int = 0;
        var block: c_int = 0;
        var params = [_]RenderParam{
            .{ .type = PARAM_OPENGL_FBO, .data = &fbo },
            .{ .type = PARAM_FLIP_Y, .data = &flip },
            .{ .type = PARAM_BLOCK_FOR_TARGET_TIME, .data = &block },
            .{ .type = 0, .data = null },
        };
        _ = a.rc_render(self.rc, &params);
        // mpv が変えた GL の状態を、ame-shell の描画が前提とする状態へ戻す
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glDisable(c.GL_DEPTH_TEST);
        c.glDisable(c.GL_STENCIL_TEST);
        c.glDisable(c.GL_CULL_FACE);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);
        c.glPixelStorei(c.GL_PACK_ALIGNMENT, 4);
        c.glBindBuffer(c.GL_PIXEL_UNPACK_BUFFER, 0);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
        c.glBindVertexArray(0);
        c.glUseProgram(0);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glColorMask(c.GL_TRUE, c.GL_TRUE, c.GL_TRUE, c.GL_TRUE);
    }

    /// ffmpeg 版: コマを受けるテクスチャと(配色の読み戻し用の)FBO
    fn allocTarget(self: *Player, w: c_int, h: c_int) void {
        self.w = w;
        self.h = h;
        c.glGenTextures(1, &self.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex, 0);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    }

    /// libmpv を使わず、ffmpeg のプロセスで復号する(libmpv が無い・再生できないときの代わり)。
    /// 画面を覆うように拡大・切り抜きした RGBA を受け取る。CPU で復号するので、大きさは横 1280 まで・30fps
    pub fn createFfmpeg(alloc: std.mem.Allocator, path: []const u8, max_w: c_int, max_h: c_int) ?*Player {
        if (max_w <= 0 or max_h <= 0) return null;
        const scale = @min(1.0, 1280.0 / @as(f32, @floatFromInt(max_w)));
        const w: c_int = @divTrunc(@as(c_int, @intFromFloat(@as(f32, @floatFromInt(max_w)) * scale)), 2) * 2;
        const h: c_int = @divTrunc(@as(c_int, @intFromFloat(@as(f32, @floatFromInt(max_h)) * scale)), 2) * 2;
        const f = Ff.spawn(alloc, path, w, h) orelse {
            last_error = "動画を再生できません(ffmpeg がありません)";
            return null;
        };
        const self = alloc.create(Player) catch {
            f.destroy(alloc);
            return null;
        };
        self.* = .{ .ff = f, .pipe_r = f.fd, .pipe_w = -1, .max_w = max_w, .max_h = max_h, .w = w, .h = h };
        log.info("動画を ffmpeg で再生します({d}x{d})", .{ w, h });
        return self;
    }

    /// 一時停止(画面ロック中など)
    pub fn setPaused(self: *Player, paused: bool) void {
        if (self.ff) |f| {
            _ = c.kill(-f.pid, if (paused) c.SIGSTOP else c.SIGCONT);
            return;
        }
        const a = api.?;
        const cmd = [_]?[*:0]const u8{ "set", "pause", if (paused) "yes" else "no", null };
        _ = a.command(self.mpv, &cmd);
    }
};

/// ffmpeg のプロセスと、パイプから受け取るコマ(back に読み込み、そろったら front と入れ替える)
const Ff = struct {
    pid: c.pid_t,
    fd: c_int,
    w: c_int,
    h: c_int,
    front: []u8,
    back: []u8,
    filled: usize = 0,

    const ReadResult = enum { none, frame, eof };

    fn spawn(alloc: std.mem.Allocator, path: []const u8, w: c_int, h: c_int) ?*Ff {
        var pz: [600]u8 = undefined;
        const in = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return null;
        // まず VA-API(GPU で復号・縮小。4K でも CPU は軽い)、使えなければ CPU で復号する。
        // どちらも画面を覆うように拡大して切り抜く(壁紙のシェーダの cover と同じ見た目)。動画のパスは $1 で渡す
        var sb: [900]u8 = undefined;
        const script = std.fmt.bufPrintZ(&sb,
            \\common="-nostdin -loglevel error -stream_loop -1 -re"
            \\ffmpeg $common -hwaccel vaapi -hwaccel_output_format vaapi -i "$1" -an -sn \
            \\  -vf "scale_vaapi=w={d}:h={d}:force_original_aspect_ratio=increase,hwdownload,format=nv12,crop={d}:{d},fps=30,format=rgba" \
            \\  -f rawvideo - ||
            \\exec ffmpeg $common -i "$1" -an -sn \
            \\  -vf "scale={d}:{d}:force_original_aspect_ratio=increase,crop={d}:{d},fps=30" -pix_fmt rgba -f rawvideo -
        , .{ w, h, w, h, w, h, w, h }) catch return null;
        const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", script.ptr, "ame-video", in.ptr, null };
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return null;
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return null;
        }
        if (pid == 0) {
            // 自分のプロセスグループにする(止めるときに sh と ffmpeg をまとめて止める)
            _ = c.setpgid(0, 0);
            const devnull = c.open("/dev/null", c.O_RDWR);
            if (devnull >= 0) {
                _ = c.dup2(devnull, 0);
                _ = c.dup2(devnull, 2);
            }
            _ = c.dup2(fds[1], 1);
            // ame-shell の SIGCHLD などのマスクを引き継がない
            var sigset: c.sigset_t = undefined;
            _ = c.sigemptyset(&sigset);
            _ = c.sigprocmask(c.SIG_SETMASK, &sigset, null);
            _ = c.execv("/bin/sh", @ptrCast(&argv));
            c._exit(127);
        }
        _ = c.close(fds[1]);
        _ = c.fcntl(fds[0], c.F_SETFL, c.fcntl(fds[0], c.F_GETFL) | c.O_NONBLOCK);
        const size: usize = @intCast(w * h * 4);
        const self = alloc.create(Ff) catch return null;
        const front = alloc.alloc(u8, size) catch return null;
        const back = alloc.alloc(u8, size) catch return null;
        self.* = .{ .pid = pid, .fd = fds[0], .w = w, .h = h, .front = front, .back = back };
        return self;
    }

    /// 読めるだけ読む。コマがそろったら .frame(複数そろったら最後のもの)、ffmpeg が終わったら .eof
    fn read(self: *Ff, fd: c_int) ReadResult {
        var got = false;
        while (true) {
            const n = c.read(fd, self.back.ptr + self.filled, self.back.len - self.filled);
            if (n == 0) return .eof;
            if (n < 0) break; // EAGAIN: 今は読むものが無い
            self.filled += @intCast(n);
            if (self.filled == self.back.len) {
                std.mem.swap([]u8, &self.front, &self.back);
                self.filled = 0;
                got = true;
            }
        }
        return if (got) .frame else .none;
    }

    fn destroy(self: *Ff, alloc: std.mem.Allocator) void {
        // 止めてすぐ回収する(ゾンビを残さない。SIGKILL なら待ち時間はほぼ無い)
        _ = c.kill(-self.pid, c.SIGKILL);
        _ = c.waitpid(self.pid, null, 0);
        alloc.free(self.front);
        alloc.free(self.back);
        alloc.destroy(self);
    }
};

/// 動画の 1 コマ目のサムネイル(ffmpeg で ~/.cache/ame-shell/thumbs に PNG を作る)。
/// 別スレッドから呼ぶ前提(ffmpeg の実行を待つ)。成功したら PNG のパスを buf に書いて返す
pub fn thumbnail(path: []const u8, buf: []u8) ?[:0]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    var h = std.hash.Wyhash.init(0);
    h.update(path);
    if (std.fs.cwd().statFile(path)) |st| h.update(std.mem.asBytes(&st.mtime)) else |_| {}
    var db: [512]u8 = undefined; // buf とは別(同じバッファから読んで書くと重なる)
    const dir = if (std.posix.getenv("XDG_CACHE_HOME")) |x|
        std.fmt.bufPrint(&db, "{s}/ame-shell/thumbs", .{x}) catch return null
    else
        std.fmt.bufPrint(&db, "{s}/.cache/ame-shell/thumbs", .{home}) catch return null;
    std.fs.cwd().makePath(dir) catch {};
    const out = std.fmt.bufPrintZ(buf, "{s}/{x:0>16}.png", .{ dir, h.final() }) catch return null;
    if (std.fs.cwd().access(out, .{})) |_| return out else |_| {}
    var pz: [600]u8 = undefined;
    const in = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return null;
    // 1 秒目(短い動画・GIF は先頭)のコマを 640 幅で
    const argv = [_]?[*:0]const u8{ "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", "1", "-i", in.ptr, "-frames:v", "1", "-vf", "scale=640:-2", out.ptr, null };
    const argv0 = [_]?[*:0]const u8{ "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", in.ptr, "-frames:v", "1", "-vf", "scale=640:-2", out.ptr, null };
    if (runWait(&argv) and std.fs.cwd().access(out, .{}) != error.FileNotFound) return out;
    if (runWait(&argv0) and std.fs.cwd().access(out, .{}) != error.FileNotFound) return out;
    return null;
}

fn runWait(argv: []const ?[*:0]const u8) bool {
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
        }
        _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return status == 0;
}
