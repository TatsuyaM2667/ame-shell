// ONNX のモデルを読み、手の認識と同じ推論エンジン(hand/nn.zig)が扱う形(tflite.Model)に直す。外部のライブラリは使わない。
//
// 顔の見分け(SFace、OpenCV Zoo、Apache-2.0)に要る演算だけ:
//   Conv(普通・depthwise)・BatchNormalization・PRelu・Add・Sub・Mul・Pad・Flatten・Gemm・Dropout / Identity
// 並びの違い:
//   ONNX は NCHW、エンジンは NHWC。重みを読み込み時に並べ直す(Conv: OIHW → OHWI、depthwise: → [1, KH, KW, C])。
//   Flatten の後の Gemm は、NCHW の順に並んだ重みの列を NHWC の順に並べ替える。
//   BatchNormalization は直前の Conv / Gemm の重みに畳み込む(畳めないときは掛け算と足し算にする)。
//   Conv の左右非対称になりうる詰め物(pads)は、stride 1 で対称なら SAME、それ以外は前に Pad を置いて VALID にする。
//
// プロトコルバッファ(ONNX のファイル形式)の読み取りも自前(必要なフィールドだけ)。
const std = @import("std");
const tfl = @import("../hand/tflite.zig");

pub const Error = error{ BadModel, Unsupported, OutOfMemory };

// ---------------------------------------------------------------------------
// プロトコルバッファ
// ---------------------------------------------------------------------------

const Field = struct {
    num: u32,
    wire: u3,
    /// wire 0 / 1 / 5 の値
    int: u64 = 0,
    /// wire 2 の中身
    bytes: []const u8 = &.{},
};

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn varint(self: *Reader) Error!u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.i >= self.b.len) return error.BadModel;
            const c = self.b[self.i];
            self.i += 1;
            v |= @as(u64, c & 0x7f) << shift;
            if (c & 0x80 == 0) return v;
            if (shift >= 63) return error.BadModel;
            shift += 7;
        }
    }

    fn next(self: *Reader) Error!?Field {
        if (self.i >= self.b.len) return null;
        const key = try self.varint();
        const wire: u3 = @intCast(key & 7);
        var f = Field{ .num = @intCast(key >> 3), .wire = wire };
        switch (wire) {
            0 => f.int = try self.varint(),
            1 => {
                if (self.i + 8 > self.b.len) return error.BadModel;
                f.int = std.mem.readInt(u64, self.b[self.i..][0..8], .little);
                self.i += 8;
            },
            2 => {
                const n: usize = @intCast(try self.varint());
                if (self.i + n > self.b.len) return error.BadModel;
                f.bytes = self.b[self.i .. self.i + n];
                self.i += n;
            },
            5 => {
                if (self.i + 4 > self.b.len) return error.BadModel;
                f.int = std.mem.readInt(u32, self.b[self.i..][0..4], .little);
                self.i += 4;
            },
            else => return error.BadModel,
        }
        return f;
    }
};

/// 繰り返しの int64(詰めた形・1 つずつの形のどちらでも)を out に足す
fn appendInts(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(i64), f: Field) Error!void {
    if (f.wire == 2) {
        var r = Reader{ .b = f.bytes };
        while (r.i < r.b.len) try out.append(a, @bitCast(try r.varint()));
    } else try out.append(a, @bitCast(f.int));
}

// ---------------------------------------------------------------------------
// ONNX の中身(必要なものだけ)
// ---------------------------------------------------------------------------

const Init = struct {
    name: []const u8,
    dims: []const i64,
    /// float32(raw_data か float_data から)・int64(pads など)
    f: []const f32 = &.{},
    i: []const i64 = &.{},
};

const Attr = struct {
    name: []const u8,
    int: i64 = 0,
    float: f32 = 0,
    ints: []const i64 = &.{},
};

pub const Node = struct {
    op: []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
    attrs: []const Attr,

    fn attr(self: Node, name: []const u8) ?Attr {
        for (self.attrs) |at| if (std.mem.eql(u8, at.name, name)) return at;
        return null;
    }
    fn attrInt(self: Node, name: []const u8, def: i64) i64 {
        return if (self.attr(name)) |at| at.int else def;
    }
    fn attrFloat(self: Node, name: []const u8, def: f32) f32 {
        return if (self.attr(name)) |at| at.float else def;
    }
    fn attrInts(self: Node, name: []const u8) []const i64 {
        return if (self.attr(name)) |at| at.ints else &.{};
    }
};

pub const Graph = struct {
    nodes: []Node,
    inits: []Init,
    input: []const u8 = "",
    input_dims: [4]i64 = .{ 1, 3, 112, 112 },
    output: []const u8 = "",

    fn init_(self: *const Graph, name: []const u8) ?*const Init {
        for (self.inits) |*it| if (std.mem.eql(u8, it.name, name)) return it;
        return null;
    }
};

fn parseTensor(a: std.mem.Allocator, b: []const u8) Error!Init {
    var r = Reader{ .b = b };
    var dims = std.ArrayListUnmanaged(i64){};
    var fl = std.ArrayListUnmanaged(f32){};
    var il = std.ArrayListUnmanaged(i64){};
    var dtype: u64 = 1;
    var raw: []const u8 = &.{};
    var name: []const u8 = "";
    while (try r.next()) |f| switch (f.num) {
        1 => try appendInts(a, &dims, f),
        2 => dtype = f.int,
        4 => if (f.wire == 2) {
            var k: usize = 0;
            while (k + 4 <= f.bytes.len) : (k += 4) try fl.append(a, @bitCast(std.mem.readInt(u32, f.bytes[k..][0..4], .little)));
        } else try fl.append(a, @bitCast(@as(u32, @truncate(f.int)))),
        7 => try appendInts(a, &il, f),
        8 => name = f.bytes,
        9 => raw = f.bytes,
        else => {},
    };
    if (raw.len > 0) switch (dtype) {
        1 => {
            const n = raw.len / 4;
            const v = try a.alloc(f32, n);
            for (v, 0..) |*x, k| x.* = @bitCast(std.mem.readInt(u32, raw[k * 4 ..][0..4], .little));
            return .{ .name = name, .dims = dims.items, .f = v };
        },
        7 => {
            const n = raw.len / 8;
            const v = try a.alloc(i64, n);
            for (v, 0..) |*x, k| x.* = std.mem.readInt(i64, raw[k * 8 ..][0..8], .little);
            return .{ .name = name, .dims = dims.items, .i = v };
        },
        else => return error.Unsupported,
    };
    return .{ .name = name, .dims = dims.items, .f = fl.items, .i = il.items };
}

fn parseAttr(a: std.mem.Allocator, b: []const u8) Error!Attr {
    var r = Reader{ .b = b };
    var at = Attr{ .name = "" };
    var ints = std.ArrayListUnmanaged(i64){};
    while (try r.next()) |f| switch (f.num) {
        1 => at.name = f.bytes,
        2 => at.float = @bitCast(@as(u32, @truncate(f.int))),
        3 => at.int = @bitCast(f.int),
        8 => try appendInts(a, &ints, f),
        else => {},
    };
    at.ints = ints.items;
    return at;
}

fn parseNode(a: std.mem.Allocator, b: []const u8) Error!Node {
    var r = Reader{ .b = b };
    var ins = std.ArrayListUnmanaged([]const u8){};
    var outs = std.ArrayListUnmanaged([]const u8){};
    var attrs = std.ArrayListUnmanaged(Attr){};
    var op: []const u8 = "";
    while (try r.next()) |f| switch (f.num) {
        1 => try ins.append(a, f.bytes),
        2 => try outs.append(a, f.bytes),
        4 => op = f.bytes,
        5 => try attrs.append(a, try parseAttr(a, f.bytes)),
        else => {},
    };
    return .{ .op = op, .inputs = ins.items, .outputs = outs.items, .attrs = attrs.items };
}

/// ValueInfoProto: 名前と(あれば)形
fn parseValueInfo(b: []const u8, dims: ?*[4]i64) Error![]const u8 {
    var r = Reader{ .b = b };
    var name: []const u8 = "";
    while (try r.next()) |f| switch (f.num) {
        1 => name = f.bytes,
        2 => if (dims) |d| {
            // TypeProto.tensor_type(1) → TypeProto.Tensor.shape(2) → dim(1) → dim_value(1)
            var tr = Reader{ .b = f.bytes };
            while (try tr.next()) |tf| if (tf.num == 1) {
                var tt = Reader{ .b = tf.bytes };
                while (try tt.next()) |sf| if (sf.num == 2) {
                    var sr = Reader{ .b = sf.bytes };
                    var k: usize = 0;
                    while (try sr.next()) |df| if (df.num == 1 and k < 4) {
                        var dr = Reader{ .b = df.bytes };
                        while (try dr.next()) |vf| if (vf.num == 1) {
                            d[k] = @bitCast(vf.int);
                        };
                        k += 1;
                    };
                };
            };
        },
        else => {},
    };
    return name;
}

/// ファイルの中身から計算の流れを読む。名前・重みは bytes の中を指すか a で確保する
pub fn parse(a: std.mem.Allocator, bytes: []const u8) Error!Graph {
    var r = Reader{ .b = bytes };
    var graph: []const u8 = &.{};
    while (try r.next()) |f| if (f.num == 7) {
        graph = f.bytes;
    };
    if (graph.len == 0) return error.BadModel;
    var nodes = std.ArrayListUnmanaged(Node){};
    var inits = std.ArrayListUnmanaged(Init){};
    var g = Graph{ .nodes = &.{}, .inits = &.{} };
    var inputs = std.ArrayListUnmanaged([]const u8){};
    var input_dims = std.ArrayListUnmanaged([4]i64){};
    var gr = Reader{ .b = graph };
    while (try gr.next()) |f| switch (f.num) {
        1 => try nodes.append(a, try parseNode(a, f.bytes)),
        5 => try inits.append(a, try parseTensor(a, f.bytes)),
        11 => {
            var d = [4]i64{ 1, 3, 112, 112 };
            try inputs.append(a, try parseValueInfo(f.bytes, &d));
            try input_dims.append(a, d);
        },
        12 => if (g.output.len == 0) {
            g.output = try parseValueInfo(f.bytes, null);
        },
        else => {},
    };
    g.nodes = nodes.items;
    g.inits = inits.items;
    // 入力の一覧には重みも並ぶことがある(古い形式)。重みでない最初のもの
    for (inputs.items, input_dims.items) |n, d| {
        if (g.init_(n) != null) continue;
        g.input = n;
        g.input_dims = d;
        break;
    }
    if (g.input.len == 0 or g.output.len == 0) return error.BadModel;
    return g;
}

// ---------------------------------------------------------------------------
// エンジンの形(tflite.Model)へ
// ---------------------------------------------------------------------------

const Conv = struct {
    /// 並べ直した重み(エンジンの並び)と足す値。BatchNormalization を畳むときに書き換える
    w: []f32,
    b: []f32,
    /// 重みの 1 出力チャンネルあたりの数(普通の畳み込み・全結合)。depthwise は 0(チャンネルが一番内側)
    per_out: usize,
};

const Builder = struct {
    a: std.mem.Allocator,
    tensors: std.ArrayListUnmanaged(tfl.Tensor) = .{},
    ops: std.ArrayListUnmanaged(tfl.Operator) = .{},
    /// ONNX の値の名前 → テンソルの番号
    names: std.StringHashMapUnmanaged(i32) = .{},
    /// 値の名前 → それを作った Conv / Gemm(BatchNormalization を畳むため)
    convs: std.StringHashMapUnmanaged(Conv) = .{},
    /// Flatten の前の形(NHWC の H, W, C)。Gemm の重みの列を並べ替えるため
    flat_from: std.StringHashMapUnmanaged([3]usize) = .{},

    fn tensor(self: *Builder, dims: []const i32, data: []const u8, dtype: tfl.DType) Error!i32 {
        var t = tfl.Tensor{ .rank = @intCast(dims.len), .data = data, .dtype = dtype };
        for (dims, 0..) |d, k| t.shape[k] = d;
        try self.tensors.append(self.a, t);
        return @intCast(self.tensors.items.len - 1);
    }
    fn constF(self: *Builder, dims: []const i32, v: []f32) Error!i32 {
        return self.tensor(dims, std.mem.sliceAsBytes(v), .f32);
    }
    fn op(self: *Builder, kind: tfl.Op, ins: []const i32, out: i32, opt: tfl.Options) Error!void {
        var o = tfl.Operator{ .op = kind, .output = out, .opt = opt, .n_in = @intCast(ins.len) };
        for (ins, 0..) |x, k| o.inputs[k] = x;
        try self.ops.append(self.a, o);
    }
    fn get(self: *Builder, name: []const u8) Error!i32 {
        return self.names.get(name) orelse error.BadModel;
    }
    fn shape(self: *Builder, t: i32) [4]i32 {
        return self.tensors.items[@intCast(t)].shape;
    }
    fn rank(self: *Builder, t: i32) u8 {
        return self.tensors.items[@intCast(t)].rank;
    }
};

/// その値を入力に使う演算の数
fn consumers(g: *const Graph, name: []const u8) usize {
    var n: usize = 0;
    for (g.nodes) |nd| for (nd.inputs) |i| {
        if (std.mem.eql(u8, i, name)) n += 1;
    };
    return n;
}

/// ONNX の計算の流れを、エンジンが扱う形に直す。重みはすべて a で確保した f32(NHWC の並び)
pub fn toModel(a: std.mem.Allocator, g: *const Graph) Error!tfl.Model {
    var b = Builder{ .a = a };
    const d = g.input_dims;
    if (d[0] != 1) return error.Unsupported;
    const in_t = try b.tensor(&.{ 1, @intCast(d[2]), @intCast(d[3]), @intCast(d[1]) }, &.{}, .f32);
    try b.names.put(a, g.input, in_t);

    for (g.nodes) |nd| {
        const op = nd.op;
        if (nd.outputs.len == 0) return error.BadModel;
        const out_name = nd.outputs[0];
        if (std.mem.eql(u8, op, "Dropout") or std.mem.eql(u8, op, "Identity")) {
            try b.names.put(a, out_name, try b.get(nd.inputs[0]));
        } else if (std.mem.eql(u8, op, "Sub") or std.mem.eql(u8, op, "Mul") or std.mem.eql(u8, op, "Add")) {
            const kind: tfl.Op = if (op[0] == 'S') .sub else if (op[0] == 'M') .mul else .add;
            var ins: [2]i32 = undefined;
            for (nd.inputs[0..2], 0..) |name, k| {
                if (g.init_(name)) |it| {
                    // 定数: スカラーかチャンネルごと([C] / [1, C, 1, 1])
                    const v = try a.dupe(f32, it.f);
                    ins[k] = try b.constF(&.{@intCast(v.len)}, v);
                } else ins[k] = try b.get(name);
            }
            const big = if (b.tensors.items[@intCast(ins[0])].data.len == 0) ins[0] else ins[1];
            const sh = b.shape(big);
            const out = try b.tensor(sh[0..b.rank(big)], &.{}, .f32);
            try b.op(kind, &ins, out, .{});
            try b.names.put(a, out_name, out);
        } else if (std.mem.eql(u8, op, "Conv")) {
            try convNode(&b, g, nd);
        } else if (std.mem.eql(u8, op, "BatchNormalization")) {
            try bnNode(&b, g, nd);
        } else if (std.mem.eql(u8, op, "PRelu")) {
            const x = try b.get(nd.inputs[0]);
            const it = g.init_(nd.inputs[1]) orelse return error.Unsupported;
            const v = try a.dupe(f32, it.f);
            const al = try b.constF(&.{@intCast(v.len)}, v);
            const sh = b.shape(x);
            const out = try b.tensor(sh[0..b.rank(x)], &.{}, .f32);
            try b.op(.prelu, &.{ x, al }, out, .{});
            try b.names.put(a, out_name, out);
        } else if (std.mem.eql(u8, op, "Pad")) {
            const x = try b.get(nd.inputs[0]);
            // pads: opset 11 からは 2 番目の入力、それより前は属性。NCHW の [始まり×4, 終わり×4]
            const p: []const i64 = if (nd.inputs.len > 1) (g.init_(nd.inputs[1]) orelse return error.Unsupported).i else nd.attrInts("pads");
            if (p.len != 8 or p[0] != 0 or p[4] != 0 or p[1] != 0 or p[5] != 0) return error.Unsupported;
            const out = try padTensor(&b, x, @intCast(p[2]), @intCast(p[6]), @intCast(p[3]), @intCast(p[7]));
            try b.names.put(a, out_name, out);
        } else if (std.mem.eql(u8, op, "Flatten")) {
            const x = try b.get(nd.inputs[0]);
            const sh = b.shape(x);
            const n: i32 = sh[1] * sh[2] * sh[3];
            const out = try b.tensor(&.{ 1, n }, &.{}, .f32);
            try b.op(.reshape, &.{x}, out, .{});
            try b.names.put(a, out_name, out);
            if (b.rank(x) == 4 and sh[1] * sh[2] > 1) try b.flat_from.put(a, out_name, .{ @intCast(sh[1]), @intCast(sh[2]), @intCast(sh[3]) });
        } else if (std.mem.eql(u8, op, "Gemm")) {
            try gemmNode(&b, g, nd);
        } else {
            std.log.warn("onnx: 扱えない演算 {s}", .{op});
            return error.Unsupported;
        }
    }
    const out = try b.get(g.output);
    var m = tfl.Model{ .bytes = &.{}, .tensors = try b.tensors.toOwnedSlice(a), .ops = try b.ops.toOwnedSlice(a), .input = in_t };
    m.outputs[0] = out;
    m.n_out = 1;
    return m;
}

/// 上下左右に 0 を詰める(PAD)
fn padTensor(b: *Builder, x: i32, top: i32, bottom: i32, left: i32, right: i32) Error!i32 {
    const sh = b.shape(x);
    const pads = try b.a.alloc(i32, 8);
    @memcpy(pads, &[8]i32{ 0, 0, top, bottom, left, right, 0, 0 });
    const pt = try b.tensor(&.{ 4, 2 }, std.mem.sliceAsBytes(pads), .i32);
    const out = try b.tensor(&.{ 1, sh[1] + top + bottom, sh[2] + left + right, sh[3] }, &.{}, .f32);
    try b.op(.pad, &.{ x, pt }, out, .{});
    return out;
}

fn convNode(b: *Builder, g: *const Graph, nd: Node) Error!void {
    const a = b.a;
    var x = try b.get(nd.inputs[0]);
    const wi = g.init_(nd.inputs[1]) orelse return error.Unsupported;
    if (wi.dims.len != 4) return error.Unsupported;
    const O: usize = @intCast(wi.dims[0]);
    const Ig: usize = @intCast(wi.dims[1]);
    const KH: usize = @intCast(wi.dims[2]);
    const KW: usize = @intCast(wi.dims[3]);
    const group: usize = @intCast(nd.attrInt("group", 1));
    const strides = nd.attrInts("strides");
    const sh_: i32 = if (strides.len == 2) @intCast(strides[0]) else 1;
    const sw: i32 = if (strides.len == 2) @intCast(strides[1]) else 1;
    const dil = nd.attrInts("dilations");
    if (dil.len == 2 and (dil[0] != 1 or dil[1] != 1)) return error.Unsupported;
    const pads = nd.attrInts("pads");
    var pt: i32 = 0;
    var pl: i32 = 0;
    var pb: i32 = 0;
    var pr: i32 = 0;
    if (pads.len == 4) {
        pt = @intCast(pads[0]);
        pl = @intCast(pads[1]);
        pb = @intCast(pads[2]);
        pr = @intCast(pads[3]);
    }
    const xs = b.shape(x);
    const C: usize = @intCast(xs[3]);
    const dw = group > 1;
    if (dw and !(group == C and group == O and Ig == 1)) return error.Unsupported;
    if (!dw and Ig != C) return error.BadModel;

    // 詰め物: stride 1 で対称なら SAME(エンジンの SAME と同じ位置)、無ければ VALID、それ以外は先に PAD
    var same = false;
    if (pt == 0 and pb == 0 and pl == 0 and pr == 0) {
        same = false;
    } else if (sh_ == 1 and sw == 1 and pt == pb and pl == pr and pt == @as(i32, @intCast(KH / 2)) and pl == @as(i32, @intCast(KW / 2)) and KH % 2 == 1 and KW % 2 == 1) {
        same = true;
    } else {
        x = try padTensor(b, x, pt, pb, pl, pr);
    }
    const ps = b.shape(x);
    const OH: i32 = if (same) @divFloor(ps[1] + sh_ - 1, sh_) else @divFloor(ps[1] - @as(i32, @intCast(KH)), sh_) + 1;
    const OW: i32 = if (same) @divFloor(ps[2] + sw - 1, sw) else @divFloor(ps[2] - @as(i32, @intCast(KW)), sw) + 1;

    const src = wi.f;
    if (src.len != O * Ig * KH * KW) return error.BadModel;
    const w = try a.alloc(f32, src.len);
    if (dw) {
        // [C, 1, KH, KW] → [1, KH, KW, C]
        for (0..O) |c| for (0..KH) |ky| for (0..KW) |kx| {
            w[(ky * KW + kx) * O + c] = src[(c * KH + ky) * KW + kx];
        };
    } else {
        // [O, I, KH, KW] → [O, KH, KW, I]
        for (0..O) |o| for (0..Ig) |i| for (0..KH) |ky| for (0..KW) |kx| {
            w[((o * KH + ky) * KW + kx) * Ig + i] = src[((o * Ig + i) * KH + ky) * KW + kx];
        };
    }
    const bias = try a.alloc(f32, O);
    if (nd.inputs.len > 2) {
        const bi = g.init_(nd.inputs[2]) orelse return error.Unsupported;
        if (bi.f.len != O) return error.BadModel;
        @memcpy(bias, bi.f);
    } else @memset(bias, 0);
    const wt = if (dw)
        try b.constF(&.{ 1, @intCast(KH), @intCast(KW), @intCast(O) }, w)
    else
        try b.constF(&.{ @intCast(O), @intCast(KH), @intCast(KW), @intCast(Ig) }, w);
    const bt = try b.constF(&.{@intCast(O)}, bias);
    const out = try b.tensor(&.{ 1, OH, OW, @intCast(O) }, &.{}, .f32);
    try b.op(if (dw) .depthwise_conv_2d else .conv_2d, &.{ x, wt, bt }, out, .{
        .padding_same = same,
        .stride_h = sh_,
        .stride_w = sw,
        .filter_h = @intCast(KH),
        .filter_w = @intCast(KW),
        .depth_mul = 1,
    });
    try b.names.put(a, nd.outputs[0], out);
    try b.convs.put(a, nd.outputs[0], .{ .w = w, .b = bias, .per_out = if (dw) 0 else KH * KW * Ig });
}

fn gemmNode(b: *Builder, g: *const Graph, nd: Node) Error!void {
    const a = b.a;
    const x = try b.get(nd.inputs[0]);
    const wi = g.init_(nd.inputs[1]) orelse return error.Unsupported;
    if (wi.dims.len != 2 or nd.attrInt("transA", 0) != 0) return error.Unsupported;
    if (nd.attrFloat("alpha", 1) != 1 or nd.attrFloat("beta", 1) != 1) return error.Unsupported;
    const transB = nd.attrInt("transB", 0) != 0;
    const O: usize = @intCast(if (transB) wi.dims[0] else wi.dims[1]);
    const I: usize = @intCast(if (transB) wi.dims[1] else wi.dims[0]);
    const xs = b.shape(x);
    if (b.rank(x) != 2 or @as(usize, @intCast(xs[1])) != I) return error.BadModel;
    // エンジンの全結合の重みは [O][I]。Flatten の前が NHWC なら、列(I)を NCHW の順から NHWC の順へ
    const ff = b.flat_from.get(nd.inputs[0]);
    const w = try a.alloc(f32, O * I);
    for (0..O) |o| for (0..I) |j| {
        // j = エンジンでの位置。ONNX での位置 jj を求める
        const jj = if (ff) |f| blk: {
            const H = f[0];
            const W = f[1];
            const C = f[2];
            const c = j % C;
            const hw = j / C;
            break :blk c * H * W + hw; // hw = h * W + w
        } else j;
        w[o * I + j] = if (transB) wi.f[o * I + jj] else wi.f[jj * O + o];
    };
    const bias = try a.alloc(f32, O);
    if (nd.inputs.len > 2) {
        const bi = g.init_(nd.inputs[2]) orelse return error.Unsupported;
        if (bi.f.len != O) return error.BadModel;
        @memcpy(bias, bi.f);
    } else @memset(bias, 0);
    const wt = try b.constF(&.{ @intCast(O), @intCast(I) }, w);
    const bt = try b.constF(&.{@intCast(O)}, bias);
    const out = try b.tensor(&.{ 1, @intCast(O) }, &.{}, .f32);
    try b.op(.fully_connected, &.{ x, wt, bt }, out, .{});
    try b.names.put(a, nd.outputs[0], out);
    try b.convs.put(a, nd.outputs[0], .{ .w = w, .b = bias, .per_out = I });
}

fn bnNode(b: *Builder, g: *const Graph, nd: Node) Error!void {
    const a = b.a;
    if (nd.inputs.len < 5) return error.BadModel;
    const gm = (g.init_(nd.inputs[1]) orelse return error.Unsupported).f;
    const bt = (g.init_(nd.inputs[2]) orelse return error.Unsupported).f;
    const mean = (g.init_(nd.inputs[3]) orelse return error.Unsupported).f;
    const vr = (g.init_(nd.inputs[4]) orelse return error.Unsupported).f;
    const eps = nd.attrFloat("epsilon", 1e-5);
    const C = gm.len;
    if (bt.len != C or mean.len != C or vr.len != C) return error.BadModel;
    // y = x * scale + shift
    const scale = try a.alloc(f32, C);
    const shift = try a.alloc(f32, C);
    for (0..C) |c| {
        scale[c] = gm[c] / @sqrt(vr[c] + eps);
        shift[c] = bt[c] - mean[c] * scale[c];
    }
    const x = try b.get(nd.inputs[0]);
    // 直前の Conv / Gemm の結果をこれだけが使うなら、その重みに畳む(計算が 1 つ減る)
    if (b.convs.get(nd.inputs[0])) |cv| if (consumers(g, nd.inputs[0]) == 1 and cv.b.len == C) {
        if (cv.per_out == 0) {
            // depthwise: チャンネルが一番内側
            for (cv.w, 0..) |*w, k| w.* *= scale[k % C];
        } else {
            for (0..C) |o| for (cv.w[o * cv.per_out ..][0..cv.per_out]) |*w| {
                w.* *= scale[o];
            };
        }
        for (cv.b, 0..) |*bb, o| bb.* = bb.* * scale[o] + shift[o];
        try b.names.put(a, nd.outputs[0], x);
        return;
    };
    // 畳めない: 掛けてから足す(チャンネルが一番内側なので、そのまま並べた値で計算できる)
    const sh = b.shape(x);
    const r = b.rank(x);
    if (sh[r - 1] != @as(i32, @intCast(C))) return error.BadModel;
    const st = try b.constF(&.{@intCast(C)}, scale);
    const ft = try b.constF(&.{@intCast(C)}, shift);
    const mid = try b.tensor(sh[0..r], &.{}, .f32);
    try b.op(.mul, &.{ x, st }, mid, .{});
    const out = try b.tensor(sh[0..r], &.{}, .f32);
    try b.op(.add, &.{ mid, ft }, out, .{});
    try b.names.put(a, nd.outputs[0], out);
}
