// ame-copy / ame-paste: Wayland のクリップボードに入れる / 出す(wl-copy・wl-paste の代わり)。
//
//   echo hi | ame-copy            標準入力をクリップボードに入れる(裏に残って、貼り付けられるたびに渡す)
//   ame-copy -t image/png < a.png 種類を決めて入れる(省くと文字。PNG の頭なら image/png)
//   ame-paste                     クリップボードの中身を標準出力へ(文字を優先)
//   ame-paste -t image/png        その種類で出す
//   ame-paste -l                  入っている種類の一覧
//
// 1 つの実行ファイルで、呼ばれた名前(ame-copy / ame-paste)で動きを変える。
// コンポジタの ext-data-control-v1 を使う(River 0.5 / wlroots 0.19 以降。River 0.3 には無い)。
// ame-copy は、ほかのアプリがクリップボードを取るまで裏で動き続ける(wl-copy と同じ)。
// 終了コード: 0 できた / 1 画面につながらない・コンポジタが対応していない・空 / 2 使い方の誤り
const std = @import("std");
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("ext-data-control-v1-client-protocol.h");
});

extern "c" fn setsid() c_int;
const A = std.heap.c_allocator;
const text_types = [_][*:0]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT" };

var mgr: ?*c.struct_ext_data_control_manager_v1 = null;
var seat: ?*c.struct_wl_seat = null;

fn onGlobal(_: ?*anyopaque, reg: ?*c.struct_wl_registry, name: u32, iface: [*c]const u8, _: u32) callconv(.C) void {
    const s = std.mem.sliceTo(iface, 0);
    if (std.mem.eql(u8, s, "ext_data_control_manager_v1")) mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.ext_data_control_manager_v1_interface, 1));
    if (std.mem.eql(u8, s, "wl_seat") and seat == null) seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, 1));
}
fn onRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.C) void {}
const reg_listener = c.struct_wl_registry_listener{ .global = onGlobal, .global_remove = onRemove };

fn fail(comptime msg: []const u8) noreturn {
    std.io.getStdErr().writeAll(msg ++ "\n") catch {};
    std.process.exit(1);
}

fn usage(for_paste: bool) noreturn {
    std.io.getStdErr().writeAll(if (for_paste) "使い方: ame-paste [-t 種類 | -l]\n" else "使い方: ame-copy [-t 種類] < データ\n") catch {};
    std.process.exit(2);
}

/// 画面につなぎ、ext-data-control の device を作る
fn connect() struct { dpy: *c.struct_wl_display, dev: *c.struct_ext_data_control_device_v1 } {
    const dpy = c.wl_display_connect(null) orelse fail("画面(Wayland)につながりません");
    const reg = c.wl_display_get_registry(dpy);
    _ = c.wl_registry_add_listener(reg, &reg_listener, null);
    _ = c.wl_display_roundtrip(dpy);
    const m = mgr orelse fail("このコンポジタはクリップボードの操作(ext-data-control-v1)に対応していません");
    const dev = c.ext_data_control_manager_v1_get_data_device(m, seat orelse fail("seat がありません")) orelse fail("クリップボードを開けません");
    return .{ .dpy = dpy, .dev = dev };
}

// ---------------- ame-copy ----------------

var data: []const u8 = "";
var done = false;

fn srcSend(_: ?*anyopaque, _: ?*c.struct_ext_data_control_source_v1, _: [*c]const u8, fd: i32) callconv(.C) void {
    // 受け取る側が読み終わるまで書く(ブロックに戻してから)
    const fl = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch 0;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl & ~@as(usize, 0o4000)) catch {};
    var off: usize = 0;
    while (off < data.len) {
        const n = std.posix.write(fd, data[off..]) catch break; // 相手が閉じた
        if (n == 0) break;
        off += n;
    }
    std.posix.close(fd);
}
fn srcCancelled(_: ?*anyopaque, _: ?*c.struct_ext_data_control_source_v1) callconv(.C) void {
    done = true; // ほかのアプリがクリップボードを取った
}
const source_listener = c.struct_ext_data_control_source_v1_listener{ .send = srcSend, .cancelled = srcCancelled };

fn isPng(d: []const u8) bool {
    return std.mem.startsWith(u8, d, "\x89PNG\r\n\x1a\n");
}

fn copy(mime: ?[:0]const u8) void {
    data = std.io.getStdIn().readToEndAlloc(A, 1 << 30) catch fail("標準入力を読めません");
    const conn = connect();
    const src = c.ext_data_control_manager_v1_create_data_source(mgr.?) orelse fail("クリップボードに入れられません");
    _ = c.ext_data_control_source_v1_add_listener(src, &source_listener, null);
    if (mime) |m| {
        c.ext_data_control_source_v1_offer(src, m.ptr);
    } else if (isPng(data)) {
        c.ext_data_control_source_v1_offer(src, "image/png");
    } else for (text_types) |t| c.ext_data_control_source_v1_offer(src, t);
    c.ext_data_control_device_v1_set_selection(conn.dev, src);
    _ = c.wl_display_roundtrip(conn.dpy);
    // 呼んだ端末を待たせないよう、裏に回って渡し続ける
    const pid = std.posix.fork() catch fail("裏に回れません");
    if (pid != 0) std.process.exit(0);
    _ = setsid();
    while (!done and c.wl_display_dispatch(conn.dpy) >= 0) {}
}

// ---------------- ame-paste ----------------

const max_types = 32;
var types: [max_types][128]u8 = undefined;
var type_lens: [max_types]usize = undefined;
var n_types: usize = 0;
var pending: ?*c.struct_ext_data_control_offer_v1 = null;
var selection: ?*c.struct_ext_data_control_offer_v1 = null;

fn offerType(_: ?*anyopaque, offer: ?*c.struct_ext_data_control_offer_v1, mime: [*c]const u8) callconv(.C) void {
    // 一覧は「今の選択」のぶんだけ要る。新しい offer が来たら数え直す(devOffer で 0 に)
    if (offer != pending) return;
    const s = std.mem.sliceTo(mime, 0);
    if (n_types >= max_types or s.len > 127) return;
    @memcpy(types[n_types][0..s.len], s);
    type_lens[n_types] = s.len;
    n_types += 1;
}
const offer_listener = c.struct_ext_data_control_offer_v1_listener{ .offer = offerType };

fn devOffer(_: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1, offer: ?*c.struct_ext_data_control_offer_v1) callconv(.C) void {
    pending = offer;
    n_types = 0;
    _ = c.ext_data_control_offer_v1_add_listener(offer, &offer_listener, null);
}
fn devSelection(_: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1, offer: ?*c.struct_ext_data_control_offer_v1) callconv(.C) void {
    selection = offer;
}
fn devPrimary(_: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1, _: ?*c.struct_ext_data_control_offer_v1) callconv(.C) void {}
fn devFinished(_: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1) callconv(.C) void {}
const device_listener = c.struct_ext_data_control_device_v1_listener{ .data_offer = devOffer, .selection = devSelection, .finished = devFinished, .primary_selection = devPrimary };

fn typeAt(i: usize) []const u8 {
    return types[i][0..type_lens[i]];
}

/// 出す種類: 指定があればそれ(無ければ null)、無ければ文字を優先して、無ければ最初のもの
fn pick(want: ?[]const u8) ?usize {
    if (want) |w| {
        for (0..n_types) |i| if (std.mem.eql(u8, typeAt(i), w)) return i;
        return null;
    }
    for (text_types) |t| for (0..n_types) |i| if (std.mem.eql(u8, typeAt(i), std.mem.span(t))) return i;
    return if (n_types > 0) 0 else null;
}

fn paste(want: ?[]const u8, list: bool) void {
    const conn = connect();
    _ = c.ext_data_control_device_v1_add_listener(conn.dev, &device_listener, null);
    _ = c.wl_display_roundtrip(conn.dpy);
    _ = c.wl_display_roundtrip(conn.dpy);
    const offer = selection orelse fail("クリップボードは空です");
    if (offer != pending) fail("クリップボードは空です");
    const out = std.io.getStdOut().writer();
    if (list) {
        for (0..n_types) |i| out.print("{s}\n", .{typeAt(i)}) catch {};
        return;
    }
    const i = pick(want) orelse fail("その種類はクリップボードにありません(ame-paste -l で一覧)");
    var mime: [129]u8 = undefined;
    @memcpy(mime[0..type_lens[i]], typeAt(i));
    mime[type_lens[i]] = 0;
    const p = std.posix.pipe() catch fail("pipe を作れません");
    c.ext_data_control_offer_v1_receive(offer, @ptrCast(&mime), p[1]);
    _ = c.wl_display_flush(conn.dpy);
    std.posix.close(p[1]);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(p[0], &buf) catch break;
        if (n == 0) break;
        out.writeAll(buf[0..n]) catch break;
    }
}

pub fn main() u8 {
    var it = std.process.args();
    const argv0 = std.fs.path.basename(it.next() orelse "ame-copy");
    const is_paste = std.mem.indexOf(u8, argv0, "paste") != null;
    var mime: ?[:0]const u8 = null;
    var list = false;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "-t")) {
            mime = it.next() orelse usage(is_paste);
            if (mime.?.len == 0 or mime.?.len > 127) usage(is_paste);
        } else if (is_paste and std.mem.eql(u8, a, "-l")) {
            list = true;
        } else usage(is_paste);
    }
    if (is_paste) paste(mime, list) else copy(mime);
    return 0;
}

test "PNG の見分け" {
    try std.testing.expect(isPng("\x89PNG\r\n\x1a\nxxxx"));
    try std.testing.expect(!isPng("hello"));
}
