// TFLite のモデルファイル(FlatBuffers)を読む。外部のライブラリは使わない。
//
// 手の認識(hand/)が使う 2 つのモデル(MediaPipe の hand_detector / hand_landmarks_detector)を読むのに
// 必要な分だけを実装している: テンソル(形・型・中身)と演算子(種類・入出力・オプション)。
//
// FlatBuffers の読み方:
//   ルート: 先頭の u32 がルートのテーブルの位置
//   テーブル: 先頭の i32(soffset)を引いた所に vtable。vtable は u16 の並び
//             [vtable の大きさ, テーブルの大きさ, フィールド 0 の位置, フィールド 1 の位置, …](0 = 無い)
//   テーブル・ベクタ・文字列への参照: その場所の u32 + その場所
//   ベクタ: u32 の長さのあとに要素
const std = @import("std");

pub const Error = error{ BadModel, Unsupported, OutOfMemory };

/// TFLite の BuiltinOperator のうち、使うもの
pub const Op = enum(i32) {
    add = 0,
    average_pool_2d = 1,
    concatenation = 2,
    conv_2d = 3,
    depthwise_conv_2d = 4,
    dequantize = 6,
    fully_connected = 9,
    logistic = 14,
    max_pool_2d = 17,
    mul = 18,
    relu = 19,
    relu6 = 21,
    reshape = 22,
    resize_bilinear = 23,
    pad = 34,
    transpose = 39,
    mean = 40,
    sub = 41,
    prelu = 54,
    resize_nearest_neighbor = 97,
    hard_swish = 117,
    _,
};

pub const DType = enum(u8) { f32 = 0, f16 = 1, i32 = 2, u8 = 3, i64 = 4, i8 = 9, _ };

pub const Act = enum(u8) { none = 0, relu = 1, relu_n1_1 = 2, relu6 = 3, tanh = 4, _ };

pub const Tensor = struct {
    shape: [4]i32 = .{ 1, 1, 1, 1 },
    rank: u8 = 0,
    dtype: DType = .f32,
    /// モデルの中の定数(重みなど)。無ければ空(計算の途中の値)
    data: []const u8 = &.{},
    name: []const u8 = "",

    pub fn count(self: Tensor) usize {
        var n: usize = 1;
        for (self.shape[0..self.rank]) |d| n *= @intCast(@max(d, 1));
        return n;
    }
};

pub const Options = struct {
    padding_same: bool = true,
    stride_w: i32 = 1,
    stride_h: i32 = 1,
    dil_w: i32 = 1,
    dil_h: i32 = 1,
    filter_w: i32 = 1,
    filter_h: i32 = 1,
    depth_mul: i32 = 1,
    act: Act = .none,
    axis: i32 = 0,
    align_corners: bool = false,
    half_pixel: bool = false,
    keep_dims: bool = false,
};

pub const Operator = struct {
    op: Op,
    inputs: [4]i32 = .{ -1, -1, -1, -1 },
    n_in: u8 = 0,
    output: i32 = -1,
    opt: Options = .{},
};

pub const Model = struct {
    bytes: []const u8,
    tensors: []Tensor,
    ops: []Operator,
    input: i32,
    outputs: [4]i32 = .{ -1, -1, -1, -1 },
    n_out: u8 = 0,

    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        a.free(self.tensors);
        a.free(self.ops);
    }
};

// ---------------------------------------------------------------------------
// FlatBuffers の最小の読み手
// ---------------------------------------------------------------------------

const Buf = struct {
    b: []const u8,

    fn u32At(self: Buf, pos: usize) Error!u32 {
        if (pos + 4 > self.b.len) return error.BadModel;
        return std.mem.readInt(u32, self.b[pos..][0..4], .little);
    }
    fn i32At(self: Buf, pos: usize) Error!i32 {
        return @bitCast(try self.u32At(pos));
    }
    fn u16At(self: Buf, pos: usize) Error!u16 {
        if (pos + 2 > self.b.len) return error.BadModel;
        return std.mem.readInt(u16, self.b[pos..][0..2], .little);
    }
    /// pos にある u32 の参照先
    fn deref(self: Buf, pos: usize) Error!usize {
        const off = try self.u32At(pos);
        const t = pos + off;
        if (t >= self.b.len) return error.BadModel;
        return t;
    }
};

const Table = struct {
    buf: Buf,
    pos: usize,
    vt: usize,
    vt_len: u16,

    fn at(buf: Buf, pos: usize) Error!Table {
        const so = try buf.i32At(pos);
        const vt_i: i64 = @as(i64, @intCast(pos)) - so;
        if (vt_i < 0 or vt_i >= buf.b.len) return error.BadModel;
        const vt: usize = @intCast(vt_i);
        return .{ .buf = buf, .pos = pos, .vt = vt, .vt_len = try buf.u16At(vt) };
    }
    /// フィールド i の場所(無ければ null)
    fn field(self: Table, i: usize) Error!?usize {
        const o = 4 + i * 2;
        if (o + 2 > self.vt_len) return null;
        const off = try self.buf.u16At(self.vt + o);
        if (off == 0) return null;
        return self.pos + off;
    }
    fn int(self: Table, comptime T: type, i: usize, default: T) Error!T {
        const p = (try self.field(i)) orelse return default;
        const n = @sizeOf(T);
        if (p + n > self.buf.b.len) return error.BadModel;
        return std.mem.readInt(T, self.buf.b[p..][0..n], .little);
    }
    fn table(self: Table, i: usize) Error!?Table {
        const p = (try self.field(i)) orelse return null;
        return try Table.at(self.buf, try self.buf.deref(p));
    }
    fn vector(self: Table, i: usize) Error!?Vec {
        const p = (try self.field(i)) orelse return null;
        const v = try self.buf.deref(p);
        return .{ .buf = self.buf, .len = try self.buf.u32At(v), .start = v + 4 };
    }
    fn string(self: Table, i: usize) Error![]const u8 {
        const v = (try self.vector(i)) orelse return "";
        if (v.start + v.len > self.buf.b.len) return error.BadModel;
        return self.buf.b[v.start .. v.start + v.len];
    }
};

const Vec = struct {
    buf: Buf,
    len: u32,
    start: usize,

    fn table(self: Vec, i: usize) Error!Table {
        const p = self.start + i * 4;
        return Table.at(self.buf, try self.buf.deref(p));
    }
    fn int32(self: Vec, i: usize) Error!i32 {
        return self.buf.i32At(self.start + i * 4);
    }
};

// ---------------------------------------------------------------------------
// モデルを読む
// ---------------------------------------------------------------------------

/// bytes は呼んだ側が持ち続ける(テンソルの中身はそこを直接指す)
pub fn load(a: std.mem.Allocator, bytes: []const u8) Error!Model {
    const buf = Buf{ .b = bytes };
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[4..8], "TFL3")) return error.BadModel;
    const root = try Table.at(buf, try buf.deref(0));

    const codes_v = (try root.vector(1)) orelse return error.BadModel;
    const subs = (try root.vector(2)) orelse return error.BadModel;
    const buffers = (try root.vector(4)) orelse return error.BadModel;
    if (subs.len < 1) return error.BadModel;
    const sg = try subs.table(0);

    // 演算子の種類(古い 1 バイトの番号と新しい 4 バイトの番号の大きい方)
    var codes = try a.alloc(i32, codes_v.len);
    defer a.free(codes);
    for (0..codes_v.len) |i| {
        const t = try codes_v.table(i);
        const old: i32 = try t.int(i8, 0, 0);
        const new = try t.int(i32, 3, 0);
        codes[i] = @max(old, new);
    }

    // テンソル
    const tv = (try sg.vector(0)) orelse return error.BadModel;
    const tensors = try a.alloc(Tensor, tv.len);
    errdefer a.free(tensors);
    for (0..tv.len) |i| {
        const t = try tv.table(i);
        var ten = Tensor{};
        if (try t.vector(0)) |sh| {
            if (sh.len > 4) return error.Unsupported;
            ten.rank = @intCast(sh.len);
            for (0..sh.len) |k| ten.shape[k] = try sh.int32(k);
        }
        ten.dtype = @enumFromInt(try t.int(u8, 1, 0));
        ten.name = try t.string(3);
        const bi = try t.int(u32, 2, 0);
        if (bi > 0 and bi < buffers.len) {
            const bt = try buffers.table(bi);
            if (try bt.vector(0)) |d| {
                if (d.start + d.len > bytes.len) return error.BadModel;
                ten.data = bytes[d.start .. d.start + d.len];
            } else {
                // 2GB を超えるモデル向けの「ファイルの中の位置」形式
                const off = try bt.int(u64, 1, 0);
                const size = try bt.int(u64, 2, 0);
                if (off > 1 and off + size <= bytes.len) ten.data = bytes[@intCast(off)..@intCast(off + size)];
            }
        }
        tensors[i] = ten;
    }

    // 入出力
    const ins = (try sg.vector(1)) orelse return error.BadModel;
    const outs = (try sg.vector(2)) orelse return error.BadModel;
    if (ins.len != 1) return error.Unsupported;
    var model = Model{ .bytes = bytes, .tensors = tensors, .ops = &.{}, .input = try ins.int32(0) };
    for (0..@min(outs.len, 4)) |k| {
        model.outputs[k] = try outs.int32(k);
        model.n_out += 1;
    }

    // 演算子
    const ov = (try sg.vector(3)) orelse return error.BadModel;
    const ops = try a.alloc(Operator, ov.len);
    errdefer a.free(ops);
    for (0..ov.len) |i| {
        const t = try ov.table(i);
        const ci = try t.int(u32, 0, 0);
        if (ci >= codes.len) return error.BadModel;
        var o = Operator{ .op = @enumFromInt(codes[ci]) };
        if (try t.vector(1)) |iv| {
            if (iv.len > 4) return error.Unsupported;
            for (0..iv.len) |k| o.inputs[k] = try iv.int32(k);
            o.n_in = @intCast(iv.len);
        }
        if (try t.vector(2)) |outv| {
            if (outv.len != 1) return error.Unsupported;
            o.output = try outv.int32(0);
        }
        if (try t.table(4)) |opt| o.opt = try readOptions(o.op, opt);
        ops[i] = o;
    }
    model.ops = ops;
    return model;
}

fn readOptions(op: Op, t: Table) Error!Options {
    var o = Options{};
    switch (op) {
        .conv_2d => {
            o.padding_same = try t.int(u8, 0, 0) == 0;
            o.stride_w = try t.int(i32, 1, 1);
            o.stride_h = try t.int(i32, 2, 1);
            o.act = @enumFromInt(try t.int(u8, 3, 0));
            o.dil_w = try t.int(i32, 4, 1);
            o.dil_h = try t.int(i32, 5, 1);
        },
        .depthwise_conv_2d => {
            o.padding_same = try t.int(u8, 0, 0) == 0;
            o.stride_w = try t.int(i32, 1, 1);
            o.stride_h = try t.int(i32, 2, 1);
            o.depth_mul = try t.int(i32, 3, 1);
            o.act = @enumFromInt(try t.int(u8, 4, 0));
            o.dil_w = try t.int(i32, 5, 1);
            o.dil_h = try t.int(i32, 6, 1);
        },
        .max_pool_2d, .average_pool_2d => {
            o.padding_same = try t.int(u8, 0, 0) == 0;
            o.stride_w = try t.int(i32, 1, 1);
            o.stride_h = try t.int(i32, 2, 1);
            o.filter_w = try t.int(i32, 3, 1);
            o.filter_h = try t.int(i32, 4, 1);
            o.act = @enumFromInt(try t.int(u8, 5, 0));
        },
        .add, .mul, .sub, .fully_connected => o.act = @enumFromInt(try t.int(u8, 0, 0)),
        .concatenation => {
            o.axis = try t.int(i32, 0, 0);
            o.act = @enumFromInt(try t.int(u8, 1, 0));
        },
        .resize_bilinear => {
            o.align_corners = try t.int(u8, 2, 0) != 0;
            o.half_pixel = try t.int(u8, 3, 0) != 0;
        },
        .resize_nearest_neighbor => {
            o.align_corners = try t.int(u8, 0, 0) != 0;
            o.half_pixel = try t.int(u8, 1, 0) != 0;
        },
        .mean => o.keep_dims = try t.int(u8, 0, 0) != 0,
        else => {},
    }
    return o;
}
