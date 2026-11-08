// 文字のクリップボード(ext-data-control。wl-copy / wl-paste を使わずに、コピーと貼り付け)。
// 貼り付けは「今のクリップボード」を受け取りたいときだけ読む(他のアプリのクリップボードを勝手には読まない)。
const std = @import("std");
const c = @import("../c.zig");
const App = @import("../core/app.zig").App;

const ca = std.heap.c_allocator;

const Offer = struct {
    offer: *c.struct_ext_data_control_offer_v1,
    /// 受け取れる文字の形式(良いものほど小さい番号)。0 = 無し
    best: u8 = 0,
};

const State = struct {
    app: ?*App = null,
    dev: ?*c.struct_ext_data_control_device_v1 = null,
    /// 今のクリップボードの中身の申し出
    sel: ?*Offer = null,
    // 貼り付けの受け取り
    fd: c_int = -1,
    buf: std.ArrayList(u8) = std.ArrayList(u8).init(ca),
    cb: ?*const fn ([]const u8) void = null,
};

var st: State = .{};

const mimes = [_][*:0]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING" };

fn device(app: *App) ?*c.struct_ext_data_control_device_v1 {
    st.app = app;
    if (st.dev) |d| return d;
    const mgr = app.dc_mgr orelse return null;
    const seat = app.seat orelse return null;
    st.dev = c.ext_data_control_manager_v1_get_data_device(mgr, seat);
    if (st.dev) |d| _ = c.ext_data_control_device_v1_add_listener(d, &device_listener, null);
    // 今のクリップボードは selection イベントで届く(貼り付けるときまでに)
    return st.dev;
}

/// 起動を早めるため、最初に使う前に準備だけしておく(パネルを開いたときなど)
pub fn prepare(app: *App) void {
    _ = device(app);
}

// ---- コピー ----

const Src = struct {
    src: *c.struct_ext_data_control_source_v1,
    data: []u8,
};

pub fn copy(app: *App, text: []const u8) bool {
    const mgr = app.dc_mgr orelse return false;
    const dev = device(app) orelse return false;
    const s = ca.create(Src) catch return false;
    const data = ca.dupe(u8, text) catch {
        ca.destroy(s);
        return false;
    };
    const src = c.ext_data_control_manager_v1_create_data_source(mgr) orelse {
        ca.free(data);
        ca.destroy(s);
        return false;
    };
    s.* = .{ .src = src, .data = data };
    _ = c.ext_data_control_source_v1_add_listener(src, &source_listener, s);
    for (mimes) |m| c.ext_data_control_source_v1_offer(src, m);
    c.ext_data_control_device_v1_set_selection(dev, src);
    _ = c.wl_display_flush(app.display);
    return true;
}

fn srcSend(data: ?*anyopaque, _: ?*c.struct_ext_data_control_source_v1, _: [*c]const u8, fd: i32) callconv(.C) void {
    const s: *Src = @ptrCast(@alignCast(data.?));
    // 受け取る側が遅くても止まらないよう、別スレッドで書き込む(自分で貼り付けるときも、ここで詰まらない)
    const dup = ca.dupe(u8, s.data) catch {
        std.posix.close(fd);
        return;
    };
    const th = std.Thread.spawn(.{}, sendWorker, .{ fd, dup }) catch {
        ca.free(dup);
        std.posix.close(fd);
        return;
    };
    th.detach();
}

fn sendWorker(fd: c_int, data: []u8) void {
    defer ca.free(data);
    defer std.posix.close(fd);
    const fl = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch 0;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl & ~@as(usize, @intCast(c.O_NONBLOCK))) catch {};
    var off: usize = 0;
    while (off < data.len) {
        const n = std.posix.write(fd, data[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}

fn srcCancelled(data: ?*anyopaque, src: ?*c.struct_ext_data_control_source_v1) callconv(.C) void {
    const s: *Src = @ptrCast(@alignCast(data.?));
    c.ext_data_control_source_v1_destroy(src);
    ca.free(s.data);
    ca.destroy(s);
}
const source_listener = c.struct_ext_data_control_source_v1_listener{ .send = srcSend, .cancelled = srcCancelled };

// ---- 貼り付け ----

/// 今のクリップボードの文字を読み、読み終わったら cb に渡す。文字が無ければ何もしない
pub fn paste(app: *App, cb: *const fn ([]const u8) void) bool {
    _ = device(app) orelse return false;
    if (st.fd >= 0) return true;
    const o = st.sel orelse return false;
    if (o.best == 0) return false;
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return false;
    c.ext_data_control_offer_v1_receive(o.offer, mimes[o.best - 1], fds[1]);
    _ = c.wl_display_flush(app.display);
    _ = c.close(fds[1]);
    _ = c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK);
    st.fd = fds[0];
    st.cb = cb;
    st.buf.clearRetainingCapacity();
    app.loop.add(st.fd, c.EPOLLIN | c.EPOLLHUP, &st, onRead) catch {
        _ = c.close(st.fd);
        st.fd = -1;
        return false;
    };
    return true;
}

fn onRead(_: *anyopaque, fd: c_int, _: u32) void {
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &tmp, tmp.len);
        if (n > 0) {
            if (st.buf.items.len < 1 << 20) st.buf.appendSlice(tmp[0..@intCast(n)]) catch {};
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) return;
        break;
    }
    if (st.app) |a| a.loop.remove(fd);
    _ = c.close(fd);
    st.fd = -1;
    if (st.cb) |cb| cb(st.buf.items);
}

fn offerMime(data: ?*anyopaque, _: ?*c.struct_ext_data_control_offer_v1, mime: [*c]const u8) callconv(.C) void {
    const o: *Offer = @ptrCast(@alignCast(data.?));
    const m = std.mem.span(mime);
    for (mimes, 0..) |want, i| {
        if (std.mem.eql(u8, m, std.mem.span(want))) {
            const rank: u8 = @intCast(i + 1);
            if (o.best == 0 or rank < o.best) o.best = rank;
        }
    }
}
const offer_listener = c.struct_ext_data_control_offer_v1_listener{ .offer = offerMime };

fn devOffer(_: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1, offer: ?*c.struct_ext_data_control_offer_v1) callconv(.C) void {
    const off = offer orelse return;
    const o = ca.create(Offer) catch {
        c.ext_data_control_offer_v1_destroy(off);
        return;
    };
    o.* = .{ .offer = off };
    _ = c.ext_data_control_offer_v1_add_listener(off, &offer_listener, o);
}

fn dropOffer(o: *Offer) void {
    c.ext_data_control_offer_v1_destroy(o.offer);
    ca.destroy(o);
}

fn devSelection(_: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1, offer: ?*c.struct_ext_data_control_offer_v1) callconv(.C) void {
    if (st.sel) |old| dropOffer(old);
    st.sel = null;
    const off = offer orelse return;
    st.sel = @ptrCast(@alignCast(c.ext_data_control_offer_v1_get_user_data(off)));
}

fn devPrimary(_: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1, offer: ?*c.struct_ext_data_control_offer_v1) callconv(.C) void {
    // 中ボタンの貼り付け(primary)は使わない
    const off = offer orelse return;
    if (c.ext_data_control_offer_v1_get_user_data(off)) |p| {
        dropOffer(@ptrCast(@alignCast(p)));
    } else c.ext_data_control_offer_v1_destroy(off);
}

fn devFinished(_: ?*anyopaque, dev: ?*c.struct_ext_data_control_device_v1) callconv(.C) void {
    c.ext_data_control_device_v1_destroy(dev);
    st.dev = null;
    if (st.sel) |o| dropOffer(o);
    st.sel = null;
}

const device_listener = c.struct_ext_data_control_device_v1_listener{
    .data_offer = devOffer,
    .selection = devSelection,
    .finished = devFinished,
    .primary_selection = devPrimary,
};
