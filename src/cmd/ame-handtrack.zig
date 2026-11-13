// ame-handtrack: カメラに映った手を追い、形と位置を 1 行 1 つの JSON で流し続ける(止めるまで)。
//
//   ame-handtrack [-d /dev/videoN]
//
//   {"event":"status","status":"downloading|loading|running|no_camera|no_model|failed"}
//   {"event":"frame","w":640,"h":480,"hands":[手, …]}     手が映っていなければ "hands":[]
//     手 = {"gesture":"none|point|pinch|open|fist|other|number","fingers":本数,
//           "cx","cy"(カーソル。画面の 0〜1)・"px","py"(手のひらの中心。カメラの 0〜1)・
//           "pinch","pinch_mid","pinch_ring"(親指と人差し指・中指・薬指の近さ ÷ 手の大きさ)・
//           "ext"(伸びている指のビット)・"size"(手の大きさ ÷ 画像の幅)・"right"(右手らしさ)・
//           "pts"(関節 21 点の [x, y, z]。画像の画素)}
//     先頭の手がカーソルを動かす手(先に見つかった方。消えたらもう一方)。2 つまで。
//
// 手の認識(推論・追跡・形)は ame-hand(github.com/TatsuyaM2667/ame-hand)。モデル(MediaPipe の
// hand_landmarker.task、Apache-2.0)は $XDG_DATA_HOME/ame-shell/models に無ければ ame-yatagarasu で取ってくる(版を決めた URL。SHA-256 を確かめる)。
// 手を追っている間は 1 秒に 30 コマまで、見つかっていない間は 4 コマまで。SIGTERM / SIGINT でカメラを閉じて終わる。
// ame-shell のハンド操作はこれを動かして、出てくる行を操作にしている(カメラ・推論で詰まっても画面は止まらない)。
const std = @import("std");
const handlib = @import("ame-hand");
const v4l2 = handlib.v4l2;
const track = handlib.track;
const nn = handlib.nn;
const zip = handlib.zip;
const gesture = handlib.gesture;

/// モデル(MediaPipe の Hand Landmarker、Apache-2.0)。版を決めた URL と、その中身の SHA-256。
/// 取ってきたもの・置いてあるものがこれと違えば使わない(差し替えられたモデルで推論しないように。顔のモデルと同じ)
const MODEL_URL = "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task";
const MODEL_SHA256 = "fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1";

fn modelOk(b: []const u8) bool {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(b, &h, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&h)}) catch return false;
    return std.mem.eql(u8, &hex, MODEL_SHA256) and zip.isHandModel(b);
}

var out: std.io.BufferedWriter(16384, std.fs.File.Writer) = undefined;
var quit = std.atomic.Value(bool).init(false);

fn emit(v: anytype) void {
    const w = out.writer();
    std.json.stringify(v, .{}, w) catch return;
    w.writeByte('\n') catch return;
    out.flush() catch quit.store(true, .release); // 読む側がいなくなった
}

fn status(s: []const u8) void {
    emit(.{ .event = "status", .status = s });
}

fn onSignal(_: c_int) callconv(.C) void {
    quit.store(true, .release);
}

fn modelPath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |d| if (d.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell/models/hand_landmarker.task", .{d}) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/share/ame-shell/models/hand_landmarker.task", .{home}) catch null;
}

/// モデルを読む。無い・壊れていれば取ってくる(一時ファイルに書いてから置き換える)
fn loadModel(a: std.mem.Allocator) ?[]u8 {
    var pb: [512]u8 = undefined;
    const path = modelPath(&pb) orelse return null;
    if (std.fs.cwd().readFileAlloc(a, path, 64 << 20)) |b| {
        if (modelOk(b)) return b;
        a.free(b);
    } else |_| {}
    status("downloading");
    const dir = std.fs.path.dirname(path) orelse return null;
    std.fs.cwd().makePath(dir) catch {};
    var tb: [520]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.part", .{path}) catch return null;
    var ch = std.process.Child.init(&.{ "ame-yatagarasu", "-sSfL", "--max-time", "180", "-o", tmp, MODEL_URL }, a);
    ch.stdin_behavior = .Ignore;
    ch.stdout_behavior = .Ignore;
    const term = ch.spawnAndWait() catch return null;
    if (term != .Exited or term.Exited != 0) return null;
    std.fs.cwd().rename(tmp, path) catch return null;
    const b = std.fs.cwd().readFileAlloc(a, path, 64 << 20) catch return null;
    if (modelOk(b)) return b;
    a.free(b);
    std.fs.cwd().deleteFile(path) catch {};
    return null;
}

/// 指定のカメラ、無ければ /dev/video0〜9 で YUYV を出せる最初のもの
fn openCamera(dev: ?[]const u8) ?v4l2.Camera {
    var buf: [64]u8 = undefined;
    if (dev) |d| {
        const p = std.fmt.bufPrintZ(&buf, "{s}", .{d}) catch return null;
        return v4l2.Camera.open(p.ptr, 640, 480, 30) catch |e| {
            std.log.warn("{s} を開けません: {}", .{ d, e });
            return null;
        };
    }
    for (0..10) |i| {
        const p = std.fmt.bufPrintZ(&buf, "/dev/video{d}", .{i}) catch continue;
        if (v4l2.Camera.open(p.ptr, 640, 480, 30)) |cam| return cam else |_| {}
    }
    return null;
}

const HandOut = struct {
    gesture: []const u8,
    fingers: u8,
    cx: f32,
    cy: f32,
    px: f32,
    py: f32,
    pinch: f32,
    pinch_mid: f32,
    pinch_ring: f32,
    ext: u8,
    size: f32,
    right: f32,
    pts: [21][3]f32,
};

fn handOut(f: gesture.Features, h: track.Hand) HandOut {
    return .{
        .gesture = @tagName(f.gesture),
        .fingers = f.fingers,
        .cx = f.cx,
        .cy = f.cy,
        .px = f.px,
        .py = f.py,
        .pinch = f.pinch,
        .pinch_mid = f.pinch_mid,
        .pinch_ring = f.pinch_ring,
        .ext = f.ext,
        .size = f.size,
        .right = h.right,
        .pts = h.pts,
    };
}

pub fn main() !u8 {
    out = .{ .unbuffered_writer = std.io.getStdOut().writer() };
    const act = std.posix.Sigaction{ .handler = .{ .handler = onSignal }, .mask = std.posix.empty_sigset, .flags = 0 };
    try std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    try std.posix.sigaction(std.posix.SIG.INT, &act, null);
    // 推論のメモリは全部この領域から取り、終わるときに丸ごと返す
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    var dev: ?[]const u8 = null;
    if (args.len == 3 and std.mem.eql(u8, args[1], "-d")) {
        dev = args[2];
    } else if (args.len != 1) {
        std.io.getStdErr().writeAll("使い方: ame-handtrack [-d /dev/videoN]\n") catch {};
        return 2;
    }

    // モデルのファイル(7MB)は読み終えたらすぐ返したいので、別に取る
    const fa = std.heap.page_allocator;
    const bytes = loadModel(fa) orelse {
        status("no_model");
        return 1;
    };
    var det_b: []const u8 = undefined;
    var lmk_b: []const u8 = undefined;
    if (!zip.unzipStored(bytes, "hand_detector.tflite", &det_b) or !zip.unzipStored(bytes, "hand_landmarks_detector.tflite", &lmk_b)) {
        status("failed");
        return 1;
    }
    status("loading");
    var det = nn.Net.init(a, det_b, 2) catch {
        status("failed");
        return 1;
    };
    defer det.deinit();
    var lmk = nn.Net.init(a, lmk_b, 2) catch {
        status("failed");
        return 1;
    };
    defer lmk.deinit();
    fa.free(bytes); // 重みは f32 に変換済み
    var mt = track.MultiTracker.init(&det, &lmk);
    mt.det_signed = false;

    var cam = openCamera(dev) orelse {
        status("no_camera");
        return 1;
    };
    defer cam.close();
    const rgb = try a.alloc(u8, cam.w * cam.h * 3);
    status("running");

    var ans = [_]gesture.Analyzer{ .{}, .{} };
    var had = [_]bool{ false, false };
    var primary: usize = 0;
    var lut: [256]u8 = undefined;
    var last_run: i64 = 0;
    var logged_dark = false;
    while (!quit.load(.acquire)) {
        var pfd = [_]std.posix.pollfd{.{ .fd = cam.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 150) catch break;
        // 手を追っている間は 1 秒に 30 回まで、見つかっていない間は検出を 1 秒に 4 回まで(軽くするため)
        const now = std.time.milliTimestamp();
        const gap: i64 = if (mt.count() == 0) 250 else 30;
        if (now - last_run < gap) {
            _ = cam.grab(null, true); // 処理しないコマは変換せずに捨てる
            continue;
        }
        if (!cam.grab(rgb, true)) continue;
        last_run = now;
        // 暗い映像は持ち上げる(手の認識は暗いと精度が大きく落ちる)
        var sum: u64 = 0;
        var cnt: u64 = 0;
        var i: usize = 0;
        while (i < rgb.len) : (i += 3 * 37) {
            sum += rgb[i] + @as(u64, rgb[i + 1]) * 2 + rgb[i + 2];
            cnt += 4;
        }
        const mean = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(@max(cnt, 1)));
        if (gesture.brightLut(mean, &lut)) {
            for (rgb) |*px| px.* = lut[px.*];
            if (!logged_dark and mean < 40) {
                std.log.warn("カメラの映像がとても暗い(平均 {d:.0}/255)。カメラのシャッターや部屋の明るさを確かめてください", .{mean});
                logged_dark = true;
            }
        }
        const img = track.Image{ .rgb = rgb, .w = cam.w, .h = cam.h };
        var hands: [track.MAX_HANDS]?track.Hand = .{ null, null };
        mt.step(img, &hands) catch {};
        const t = @as(f32, @floatFromInt(now)) / 1000;
        var feats: [2]?gesture.Features = .{ null, null };
        for (0..2) |k| {
            if (hands[k]) |hd| {
                if (!had[k]) ans[k].reset();
                had[k] = true;
                feats[k] = ans[k].step(hd.pts, @floatFromInt(cam.w), @floatFromInt(cam.h), t);
            } else had[k] = false;
        }
        if (feats[primary] == null and feats[1 - primary] != null) primary = 1 - primary;
        var list: [2]HandOut = undefined;
        var n: usize = 0;
        for ([_]usize{ primary, 1 - primary }) |k| if (feats[k]) |f| {
            list[n] = handOut(f, hands[k].?);
            n += 1;
        };
        emit(.{ .event = "frame", .w = cam.w, .h = cam.h, .hands = list[0..n] });
    }
    return 0;
}
