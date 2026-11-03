// カメラの読み取り(V4L2)。Linux と、FreeBSD の webcamd(同じ V4L2 の API を出す)で使う。
//
// YUYV(4:2:2)を mmap した 4 枚の置き場で受け取る。圧縮(MJPEG)は使わない(復号が要らず、遅れが少ない)。
// 呼び方: open → 読めるようになったら(poll / epoll の fd)grab で 1 枚 → close。
// ioctl の番号の作り方だけが OS で違う(Linux の _IOC_WRITE は 1<<30、FreeBSD の IOC_IN は 2<<30。読み書き両方は同じ)。
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig");

const is_bsd = builtin.os.tag == .freebsd;

fn ioc(rw: bool, nr: u32, size: usize) u32 {
    const dir: u32 = if (rw) 3 << 30 else if (is_bsd) 2 << 30 else 1 << 30;
    return dir | (@as(u32, @intCast(size & 0x1fff)) << 16) | ('V' << 8) | nr;
}

const PixFormat = extern struct {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    priv: u32,
    flags: u32,
    ycbcr_enc: u32,
    quantization: u32,
    xfer_func: u32,
};

const Format = extern struct {
    type: u32,
    _pad: u32 = 0, // 共用体は 8 バイト境界(中にポインタを持つ型があるため)
    fmt: extern union { pix: PixFormat, raw: [200]u8 },
};

const ReqBufs = extern struct { count: u32, type: u32, memory: u32, capabilities: u32 = 0, flags: u8 = 0, reserved: [3]u8 = .{ 0, 0, 0 } };

const Timeval = extern struct { sec: i64, usec: i64 };
const Timecode = extern struct { type: u32, flags: u32, frames: u8, seconds: u8, minutes: u8, hours: u8, userbits: [4]u8 };

const Buffer = extern struct {
    index: u32 = 0,
    type: u32 = 0,
    bytesused: u32 = 0,
    flags: u32 = 0,
    field: u32 = 0,
    timestamp: Timeval = .{ .sec = 0, .usec = 0 },
    timecode: Timecode = std.mem.zeroes(Timecode),
    sequence: u32 = 0,
    memory: u32 = 0,
    m: extern union { offset: u32, userptr: u64 } = .{ .userptr = 0 },
    length: u32 = 0,
    reserved2: u32 = 0,
    request_fd: i32 = 0,
};

const StreamParm = extern struct {
    type: u32,
    parm: extern union {
        capture: extern struct { capability: u32, capturemode: u32, num: u32, den: u32, extendedmode: u32, readbuffers: u32, reserved: [4]u32 },
        raw: [200]u8,
    },
};

comptime {
    // 64 bit の Linux / FreeBSD の大きさ(ioctl の番号に入るので、ずれると通らない)
    std.debug.assert(@sizeOf(Format) == 208);
    std.debug.assert(@sizeOf(ReqBufs) == 20);
    std.debug.assert(@sizeOf(Buffer) == 88);
    std.debug.assert(@sizeOf(StreamParm) == 204);
}

const BUF_TYPE_CAPTURE = 1;
const MEMORY_MMAP = 1;
const FIELD_NONE = 1;
const FMT_YUYV: u32 = 'Y' | ('U' << 8) | ('Y' << 16) | ('V' << 24);

const S_FMT = 5;
const REQBUFS = 8;
const QUERYBUF = 9;
const QBUF = 15;
const DQBUF = 17;
const STREAMON = 18;
const STREAMOFF = 19;
const S_PARM = 22;

const NBUF = 4;

pub const Camera = struct {
    fd: c_int,
    w: u32,
    h: u32,
    stride: u32,
    maps: [NBUF][]align(std.mem.page_size) u8 = undefined,
    n_maps: usize = 0,

    /// 開いて撮り始める。w×h(YUYV)・fps を頼む(カメラが近いものに決める)
    pub fn open(path: [*:0]const u8, w: u32, h: u32, fps: u32) !Camera {
        const fd = c.open(path, c.O_RDWR | c.O_NONBLOCK | c.O_CLOEXEC);
        if (fd < 0) return error.OpenFailed;
        errdefer _ = c.close(fd);
        var f = std.mem.zeroes(Format);
        f.type = BUF_TYPE_CAPTURE;
        f.fmt.pix.width = w;
        f.fmt.pix.height = h;
        f.fmt.pix.pixelformat = FMT_YUYV;
        f.fmt.pix.field = FIELD_NONE;
        if (!io(fd, ioc(true, S_FMT, @sizeOf(Format)), &f)) return error.FormatFailed;
        if (f.fmt.pix.pixelformat != FMT_YUYV) return error.NoYuyv;
        var self = Camera{ .fd = fd, .w = f.fmt.pix.width, .h = f.fmt.pix.height, .stride = @max(f.fmt.pix.bytesperline, f.fmt.pix.width * 2) };
        // 速さ(通らなくてもよい)
        var p = std.mem.zeroes(StreamParm);
        p.type = BUF_TYPE_CAPTURE;
        p.parm.capture.num = 1;
        p.parm.capture.den = fps;
        _ = io(fd, ioc(true, S_PARM, @sizeOf(StreamParm)), &p);

        var rb = ReqBufs{ .count = NBUF, .type = BUF_TYPE_CAPTURE, .memory = MEMORY_MMAP };
        if (!io(fd, ioc(true, REQBUFS, @sizeOf(ReqBufs)), &rb) or rb.count == 0) return error.NoBuffers;
        errdefer self.unmap();
        for (0..@min(rb.count, NBUF)) |i| {
            var b = Buffer{ .index = @intCast(i), .type = BUF_TYPE_CAPTURE, .memory = MEMORY_MMAP };
            if (!io(fd, ioc(true, QUERYBUF, @sizeOf(Buffer)), &b)) return error.QueryFailed;
            const m = std.posix.mmap(null, b.length, std.posix.PROT.READ, .{ .TYPE = .SHARED }, fd, b.m.offset) catch return error.MapFailed;
            self.maps[i] = m;
            self.n_maps += 1;
            if (!io(fd, ioc(true, QBUF, @sizeOf(Buffer)), &b)) return error.QueueFailed;
        }
        var t: c_int = BUF_TYPE_CAPTURE;
        if (!io(fd, ioc(false, STREAMON, @sizeOf(c_int)), &t)) return error.StreamFailed;
        return self;
    }

    fn unmap(self: *Camera) void {
        for (self.maps[0..self.n_maps]) |m| std.posix.munmap(m);
        self.n_maps = 0;
    }

    pub fn close(self: *Camera) void {
        var t: c_int = BUF_TYPE_CAPTURE;
        _ = io(self.fd, ioc(false, STREAMOFF, @sizeOf(c_int)), &t);
        self.unmap();
        _ = c.close(self.fd);
        self.fd = -1;
    }

    /// 届いている一番新しいコマを RGB(左右反転 = 鏡)にして out(w*h*3)へ。まだ無ければ false。
    /// out が null なら、溜まったコマを捨てるだけ(処理しないコマを変換しない)
    pub fn grab(self: *Camera, out: ?[]u8, mirror: bool) bool {
        // 溜まっているコマは捨てて、最後の 1 枚だけを使う(処理が遅れても遅延が積み上がらないように)
        var last: ?Buffer = null;
        while (true) {
            var b = Buffer{ .type = BUF_TYPE_CAPTURE, .memory = MEMORY_MMAP };
            if (!io(self.fd, ioc(true, DQBUF, @sizeOf(Buffer)), &b)) break;
            if (last) |*l| _ = io(self.fd, ioc(true, QBUF, @sizeOf(Buffer)), l);
            last = b;
        }
        var l = last orelse return false;
        defer _ = io(self.fd, ioc(true, QBUF, @sizeOf(Buffer)), &l);
        if (l.index >= self.n_maps or l.bytesused < self.stride * self.h) return false;
        if (out) |o| yuyvToRgb(self.maps[l.index], self.w, self.h, self.stride, o, mirror);
        return true;
    }
};

fn io(fd: c_int, req: u32, arg: anytype) bool {
    const Req = @typeInfo(@TypeOf(c.ioctl)).Fn.params[1].type.?;
    const r: Req = if (@typeInfo(Req).Int.signedness == .signed) @bitCast(req) else req;
    while (true) {
        if (c.ioctl(fd, r, arg) >= 0) return true;
        if (std.c._errno().* != @intFromEnum(std.posix.E.INTR)) return false;
    }
}

fn yuyvToRgb(src: []const u8, w: u32, h: u32, stride: u32, out: []u8, mirror: bool) void {
    // 整数で(BT.601、係数は 1/256 単位)
    for (0..h) |y| {
        const row = src[y * stride ..];
        for (0..w / 2) |k| {
            const p = row[k * 4 ..][0..4];
            const cb = @as(i32, p[1]) - 128;
            const cr = @as(i32, p[3]) - 128;
            const rr = (359 * cr) >> 8;
            const gg = (88 * cb + 183 * cr) >> 8;
            const bb = (454 * cb) >> 8;
            inline for (0..2) |j| {
                const yy: i32 = p[j * 2];
                const x = k * 2 + j;
                const ox = if (mirror) w - 1 - x else x;
                const d = out[(y * w + ox) * 3 ..][0..3];
                d[0] = clamp8(yy + rr);
                d[1] = clamp8(yy - gg);
                d[2] = clamp8(yy + bb);
            }
        }
    }
}

inline fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}
