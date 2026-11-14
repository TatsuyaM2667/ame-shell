// ame-rec: 画面を動画に録る(wf-recorder の代わり)。
//
//   ame-rec -f 保存先.mp4 [-o 出力の名前] [-r 1 秒のコマ数] [--no-audio] [--cpu]
//
// 撮るのは自分(ext-image-copy-capture-v1。画面が変わったときだけ 1 コマ)、動画にするのは ffmpeg(標準入力に生の画素を流す)。
// 音は既定の出力で鳴っている音(PulseAudio の口の @DEFAULT_MONITOR@)。
// 変換は GPU(VAAPI の h264)を先に試し、使えなければ CPU(libx264)。--cpu で初めから CPU。
// 止めるのは SIGINT / SIGTERM(ffmpeg に終わりを伝え、ファイルを閉じてから終わる)。
// 終了コード: 0 保存した / 1 画面につながらない・撮れない・ffmpeg が無い / 2 使い方の誤り
const std = @import("std");
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("ext-image-capture-source-v1-client-protocol.h");
    @cInclude("ext-image-copy-capture-v1-client-protocol.h");
});

extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;

// wl_shm の形式(リトルエンディアン)と、ffmpeg での名前
const FMT_ARGB8888: u32 = 0;
const FMT_XRGB8888: u32 = 1;
const FMT_ABGR8888: u32 = 0x34324241;
const FMT_XBGR8888: u32 = 0x34324258;

fn pixFmt(fmt: u32) ?[:0]const u8 {
    return switch (fmt) {
        FMT_XRGB8888, FMT_ARGB8888 => "bgr0", // メモリ上は B G R X
        FMT_XBGR8888, FMT_ABGR8888 => "rgb0",
        else => null,
    };
}

fn die(comptime msg: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("ame-rec: " ++ msg ++ "\n", args) catch {};
    std.process.exit(1);
}

fn usage() noreturn {
    std.io.getStdErr().writeAll("使い方: ame-rec -f 保存先.mp4 [-o 出力の名前] [-r 1 秒のコマ数] [--no-audio] [--cpu]\n") catch {};
    std.process.exit(2);
}

// ---------------- 画面の部品 ----------------

const Out = struct { wl: *c.struct_wl_output, name: [64]u8 = undefined, name_len: usize = 0 };
var outs: [8]Out = undefined;
var n_outs: usize = 0;
var shm: ?*c.struct_wl_shm = null;
var src_mgr: ?*c.struct_ext_output_image_capture_source_manager_v1 = null;
var cap_mgr: ?*c.struct_ext_image_copy_capture_manager_v1 = null;

fn oName(data: ?*anyopaque, _: ?*c.struct_wl_output, name: [*c]const u8) callconv(.C) void {
    const o: *Out = @ptrCast(@alignCast(data.?));
    const s = std.mem.sliceTo(name, 0);
    o.name_len = @min(s.len, o.name.len);
    @memcpy(o.name[0..o.name_len], s[0..o.name_len]);
}
fn oGeometry(_: ?*anyopaque, _: ?*c.struct_wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.C) void {}
fn oMode(_: ?*anyopaque, _: ?*c.struct_wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.C) void {}
fn oDone(_: ?*anyopaque, _: ?*c.struct_wl_output) callconv(.C) void {}
fn oScale(_: ?*anyopaque, _: ?*c.struct_wl_output, _: i32) callconv(.C) void {}
fn oDesc(_: ?*anyopaque, _: ?*c.struct_wl_output, _: [*c]const u8) callconv(.C) void {}
const out_listener = c.struct_wl_output_listener{ .geometry = oGeometry, .mode = oMode, .done = oDone, .scale = oScale, .name = oName, .description = oDesc };

fn onGlobal(_: ?*anyopaque, reg: ?*c.struct_wl_registry, id: u32, iface: [*c]const u8, ver: u32) callconv(.C) void {
    const s = std.mem.sliceTo(iface, 0);
    const eq = std.mem.eql;
    if (eq(u8, s, "wl_shm")) shm = @ptrCast(c.wl_registry_bind(reg, id, &c.wl_shm_interface, 1));
    if (eq(u8, s, "ext_output_image_capture_source_manager_v1")) src_mgr = @ptrCast(c.wl_registry_bind(reg, id, &c.ext_output_image_capture_source_manager_v1_interface, 1));
    if (eq(u8, s, "ext_image_copy_capture_manager_v1")) cap_mgr = @ptrCast(c.wl_registry_bind(reg, id, &c.ext_image_copy_capture_manager_v1_interface, 1));
    if (eq(u8, s, "wl_output") and n_outs < outs.len) {
        const o = &outs[n_outs];
        o.* = .{ .wl = @ptrCast(c.wl_registry_bind(reg, id, &c.wl_output_interface, @min(ver, 4))) };
        _ = c.wl_output_add_listener(o.wl, &out_listener, o);
        n_outs += 1;
    }
}
fn onRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.C) void {}
const reg_listener = c.struct_wl_registry_listener{ .global = onGlobal, .global_remove = onRemove };

// ---------------- 撮る ----------------

const Cap = struct {
    session: ?*c.struct_ext_image_copy_capture_session_v1 = null,
    w: u32 = 0,
    h: u32 = 0,
    format: ?u32 = null,
    ready: bool = false, // done を受けて、バッファを作った
    buffer: ?*c.struct_wl_buffer = null,
    map: ?[]align(std.mem.page_size) u8 = null,
    frame: ?*c.struct_ext_image_copy_capture_frame_v1 = null,
    got: bool = false, // 1 コマ届いた(まだ渡していない)
    failed: bool = false,
    stopped: bool = false,
};
var cap = Cap{};

fn sBufferSize(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.C) void {
    if (cap.ready and (w != cap.w or h != cap.h)) cap.stopped = true; // 録画中に大きさが変わった: そこで終える
    cap.w = w;
    cap.h = h;
}
fn sShmFormat(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, fmt: u32) callconv(.C) void {
    // XRGB / ARGB を優先(どのコンポジタも持つ)。BGR 系は無いときだけ
    if (fmt == FMT_XRGB8888 or fmt == FMT_ARGB8888) {
        if (cap.format == null or (cap.format.? != FMT_XRGB8888 and cap.format.? != FMT_ARGB8888)) cap.format = fmt;
    } else if ((fmt == FMT_XBGR8888 or fmt == FMT_ABGR8888) and cap.format == null) cap.format = fmt;
}
fn sDmabufDevice(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: ?*c.struct_wl_array) callconv(.C) void {}
fn sDmabufFormat(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: u32, _: ?*c.struct_wl_array) callconv(.C) void {}
fn sDone(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.C) void {
    if (cap.ready) return;
    const fmt = cap.format orelse die("対応する画素の形式がありません", .{});
    if (cap.w == 0 or cap.h == 0) die("画面の大きさが分かりません", .{});
    const size: usize = @as(usize, cap.w) * cap.h * 4;
    const fd = memfd_create("ame-rec", 1);
    if (fd < 0) die("メモリを確保できません", .{});
    defer std.posix.close(fd);
    std.posix.ftruncate(fd, size) catch die("メモリを確保できません", .{});
    cap.map = std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0) catch die("メモリを確保できません", .{});
    const pool = c.wl_shm_create_pool(shm, fd, @intCast(size));
    cap.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(cap.w), @intCast(cap.h), @intCast(cap.w * 4), fmt);
    c.wl_shm_pool_destroy(pool);
    cap.ready = true;
}
fn sStopped(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.C) void {
    cap.stopped = true;
}
const session_listener = c.struct_ext_image_copy_capture_session_v1_listener{
    .buffer_size = sBufferSize,
    .shm_format = sShmFormat,
    .dmabuf_device = sDmabufDevice,
    .dmabuf_format = sDmabufFormat,
    .done = sDone,
    .stopped = sStopped,
};

fn fTransform(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: u32) callconv(.C) void {}
fn fDamage(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: i32, _: i32, _: i32, _: i32) callconv(.C) void {}
fn fTime(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: u32, _: u32, _: u32) callconv(.C) void {}
fn fReady(_: ?*anyopaque, f: ?*c.struct_ext_image_copy_capture_frame_v1) callconv(.C) void {
    c.ext_image_copy_capture_frame_v1_destroy(f);
    cap.frame = null;
    cap.got = true;
}
fn fFailed(_: ?*anyopaque, f: ?*c.struct_ext_image_copy_capture_frame_v1, reason: u32) callconv(.C) void {
    c.ext_image_copy_capture_frame_v1_destroy(f);
    cap.frame = null;
    // 1 = 大きさなどが変わった(バッファの作り直しが要る)、2 = 止められた。どちらもそこで終える
    if (reason != 0) cap.stopped = true else cap.failed = true;
}
const frame_listener = c.struct_ext_image_copy_capture_frame_v1_listener{ .transform = fTransform, .damage = fDamage, .presentation_time = fTime, .ready = fReady, .failed = fFailed };

/// 次の 1 コマを頼む(画面が変わったときに届く)
fn requestFrame() void {
    const f = c.ext_image_copy_capture_session_v1_create_frame(cap.session) orelse die("撮影を頼めません", .{});
    _ = c.ext_image_copy_capture_frame_v1_add_listener(f, &frame_listener, null);
    c.ext_image_copy_capture_frame_v1_attach_buffer(f, cap.buffer);
    c.ext_image_copy_capture_frame_v1_damage_buffer(f, 0, 0, @intCast(cap.w), @intCast(cap.h));
    c.ext_image_copy_capture_frame_v1_capture(f);
    cap.frame = f;
}

// ---------------- ffmpeg ----------------

const Opts = struct { path: []const u8 = "", output: ?[]const u8 = null, fps: u32 = 30, audio: bool = true, cpu: bool = false };

/// ffmpeg の引数(標準入力 = 生の画素)。gpu なら VAAPI で h264、でなければ libx264
fn ffmpegArgs(a: std.mem.Allocator, o: Opts, pix: []const u8, w: u32, h: u32, gpu: bool) ![]const []const u8 {
    var v = std.ArrayList([]const u8).init(a);
    try v.appendSlice(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-thread_queue_size", "64", "-f", "rawvideo", "-pix_fmt", pix, "-s", try std.fmt.allocPrint(a, "{d}x{d}", .{ w, h }), "-use_wallclock_as_timestamps", "1", "-i", "-" });
    if (o.audio) try v.appendSlice(&.{ "-thread_queue_size", "1024", "-f", "pulse", "-i", "@DEFAULT_MONITOR@" });
    if (gpu) {
        try v.appendSlice(&.{ "-vaapi_device", "/dev/dri/renderD128", "-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-qp", "22" });
    } else {
        try v.appendSlice(&.{ "-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p" });
    }
    if (o.audio) try v.appendSlice(&.{ "-c:a", "aac", "-b:a", "192k" });
    // 画面が止まっている間はコマを送らないので、届いた時刻のまま書く(passthrough。vfr だと 25 コマ/秒に並べ直されて短くなる)
    try v.appendSlice(&.{ "-fps_mode", "passthrough", "-movflags", "+faststart", o.path });
    return v.items;
}

var stop_flag = std.atomic.Value(bool).init(false);
fn onSignal(_: c_int) callconv(.C) void {
    stop_flag.store(true, .release);
}

fn parse(args: []const []const u8) Opts {
    var o = Opts{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.eql(u8, s, "--no-audio")) {
            o.audio = false;
        } else if (std.mem.eql(u8, s, "--cpu")) {
            o.cpu = true;
        } else if (std.mem.eql(u8, s, "-f") or std.mem.eql(u8, s, "-o") or std.mem.eql(u8, s, "-r")) {
            i += 1;
            if (i >= args.len) usage();
            const v = args[i];
            switch (s[1]) {
                'f' => o.path = v,
                'o' => o.output = v,
                else => {
                    o.fps = std.fmt.parseInt(u32, v, 10) catch usage();
                    if (o.fps == 0 or o.fps > 240) usage();
                },
            }
        } else usage();
    }
    if (o.path.len == 0) usage();
    return o;
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return 2;
    const o = parse(argv[1..]);

    const dpy = c.wl_display_connect(null) orelse die("画面(Wayland)につながりません", .{});
    const reg = c.wl_display_get_registry(dpy);
    _ = c.wl_registry_add_listener(reg, &reg_listener, null);
    _ = c.wl_display_roundtrip(dpy);
    _ = c.wl_display_roundtrip(dpy); // 出力の名前
    if (shm == null or src_mgr == null or cap_mgr == null) die("このコンポジタは画面の撮影(ext-image-copy-capture-v1)に対応していません", .{});
    if (n_outs == 0) die("画面がありません", .{});
    var out = &outs[0];
    if (o.output) |want| {
        for (outs[0..n_outs]) |*x| if (std.mem.eql(u8, x.name[0..x.name_len], want)) {
            out = x;
        };
        if (!std.mem.eql(u8, out.name[0..out.name_len], want)) die("出力 {s} がありません", .{want});
    }
    const source = c.ext_output_image_capture_source_manager_v1_create_source(src_mgr, out.wl);
    // 1 = マウスのカーソルも描く
    cap.session = c.ext_image_copy_capture_manager_v1_create_session(cap_mgr, source, 1);
    _ = c.ext_image_copy_capture_session_v1_add_listener(cap.session, &session_listener, null);
    while (!cap.ready) if (c.wl_display_dispatch(dpy) < 0) die("画面とのつながりが切れました", .{});

    const pix = pixFmt(cap.format.?).?;
    const act = std.posix.Sigaction{ .handler = .{ .handler = onSignal }, .mask = std.posix.empty_sigset, .flags = 0 };
    std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
    std.posix.sigaction(std.posix.SIG.TERM, &act, null) catch {};
    // ffmpeg が先に終わったら(書けなくなったら)、write の失敗で知る
    const ign = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.empty_sigset, .flags = 0 };
    std.posix.sigaction(std.posix.SIG.PIPE, &ign, null) catch {};

    var gpu = !o.cpu and blk: {
        std.fs.cwd().access("/dev/dri/renderD128", .{}) catch break :blk false;
        break :blk true;
    };
    var frames: u64 = 0;
    const frame_ns: u64 = std.time.ns_per_s / o.fps;
    var last: u64 = 0;
    const size: usize = @as(usize, cap.w) * cap.h * 4;
    const still = a.alloc(u8, size) catch die("メモリが足りません", .{});
    attempt: while (true) {
        var ch = std.process.Child.init(ffmpegArgs(a, o, pix, cap.w, cap.h, gpu) catch die("メモリが足りません", .{}), a);
        ch.stdin_behavior = .Pipe;
        ch.spawn() catch die("ffmpeg を起動できません(ffmpeg を入れてください)", .{});
        const in = ch.stdin.?;
        frames = 0;
        requestFrame();
        const fd = c.wl_display_get_fd(dpy);
        while (!stop_flag.load(.acquire) and !cap.stopped) {
            _ = c.wl_display_flush(dpy);
            // シグナルで起きられるよう、待つのは poll(0.2 秒ごとに止める合図を見る)
            var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&pfd, 200) catch 0;
            if (n > 0) {
                if (c.wl_display_dispatch(dpy) < 0) break;
            } else _ = c.wl_display_dispatch_pending(dpy);
            if (cap.failed) {
                cap.failed = false;
                requestFrame();
                continue;
            }
            if (!cap.got) {
                // 画面が止まっている間も 1 秒ごとに同じコマを送る(動画が途中で終わって音が切られないように)
                const t: u64 = @intCast(std.time.nanoTimestamp());
                if (frames > 0 and t - last >= std.time.ns_per_s) {
                    in.writeAll(still) catch die("ffmpeg が止まりました", .{});
                    last = t;
                }
                continue;
            }
            cap.got = false;
            // コマ数の上限: 前のコマから間が無ければ少し待つ
            const now: u64 = @intCast(std.time.nanoTimestamp());
            if (last != 0 and now - last < frame_ns) std.time.sleep(frame_ns - (now - last));
            last = @intCast(std.time.nanoTimestamp());
            in.writeAll(cap.map.?[0..size]) catch {
                // 最初のコマで ffmpeg が終わった = GPU の変換が使えない。CPU でやり直す
                _ = ch.wait() catch {};
                if (gpu and frames == 0) {
                    std.io.getStdErr().writeAll("ame-rec: GPU(VAAPI)で変換できないので CPU で録ります\n") catch {};
                    gpu = false;
                    continue :attempt;
                }
                die("ffmpeg が止まりました", .{});
            };
            frames += 1;
            @memcpy(still, cap.map.?[0..size]); // 次のコマを撮っている間に書き換わらない写し
            requestFrame();
        }
        // 止めた時刻まで動画が続くよう、最後のコマをもう一度
        if (frames > 0) in.writeAll(still) catch {};
        // 終わり: 入力を閉じると ffmpeg がファイルを仕上げて終わる
        in.close();
        ch.stdin = null;
        // 音の入力は終わらないので、SIGINT で仕上げてもらう(ffmpeg はファイルを閉じてから 255 で終わる)
        std.posix.kill(ch.id, std.posix.SIG.INT) catch {};
        const term = ch.wait() catch die("ffmpeg を待てません", .{});
        if (frames == 0) die("1 コマも撮れませんでした", .{});
        if (term != .Exited or (term.Exited != 0 and term.Exited != 255)) die("ffmpeg が失敗しました", .{});
        const st = std.fs.cwd().statFile(o.path) catch die("保存できませんでした", .{});
        if (st.size == 0) die("保存できませんでした", .{});
        return 0;
    }
}

test "引数" {
    const o = parse(&.{ "-f", "a.mp4", "-r", "60", "--no-audio" });
    try std.testing.expectEqualStrings("a.mp4", o.path);
    try std.testing.expectEqual(@as(u32, 60), o.fps);
    try std.testing.expect(!o.audio);
}

test "画素の形式" {
    try std.testing.expectEqualStrings("bgr0", pixFmt(FMT_XRGB8888).?);
    try std.testing.expectEqualStrings("rgb0", pixFmt(FMT_XBGR8888).?);
    try std.testing.expect(pixFmt(12345) == null);
}
