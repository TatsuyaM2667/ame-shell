// 小さな推論エンジン: TFLite のモデル(tflite.zig で読んだもの)を CPU で計算する。外部のライブラリは使わない。
//
// 手の認識の 2 つのモデルに要る演算だけを、NHWC・バッチ 1・float32 で実装している。
//   畳み込み(普通・depthwise)・足し算・PReLU・パディング・双線形の拡大・max pool・連結・形の変更・
//   全結合・平均・シグモイド・(読み込み時に)f16 → f32
//
// 速さのために:
//   * 重みは読み込み時に「出力チャンネルが一番内側」の並びに直しておき、出力チャンネルを @Vector(8) でまとめて計算する
//   * 定数(f16 の重み → f32)の変換は読み込み時に 1 回だけ
//   * 畳み込みは出力の行ごとに、いくつかのスレッドに分ける(Pool)
const std = @import("std");
pub const tfl = @import("tflite.zig");

const V = 8;
const Vec = @Vector(V, f32);

pub const Error = tfl.Error || error{ShapeMismatch};

const Prep = struct {
    /// 並べ直した重み(畳み込み: [KH][KW][I][O]、depthwise: [KH][KW][C]、全結合: [O][I])
    w: []f32 = &.{},
    bias: []f32 = &.{},
    skip: bool = false,
};

pub const Net = struct {
    a: std.mem.Allocator,
    m: tfl.Model,
    /// テンソルごとの f32 の値(定数は変換済み、途中の値は計算で埋める)。int32 の定数は ints
    vals: [][]f32,
    ints: [][]const i32,
    prep: []Prep,
    /// 自分で確保したもの(deinit で返す)
    owned: std.ArrayListUnmanaged([]f32) = .{},
    owned_i: std.ArrayListUnmanaged([]i32) = .{},
    pool: ?*Pool = null,
    /// 計測(試験用): 演算の種類ごとの合計時間(ns)。null なら測らない
    prof: ?*[128]u64 = null,

    pub fn init(a: std.mem.Allocator, bytes: []const u8, threads: usize) Error!Net {
        return initModel(a, try tfl.load(a, bytes), threads);
    }

    /// 読み込み済みのモデルから(顔の見分けの ONNX は face/onnx.zig がこの形に直す)。m は Net が持つ
    pub fn initModel(a: std.mem.Allocator, m_in: tfl.Model, threads: usize) Error!Net {
        var m = m_in;
        errdefer m.deinit(a);
        const n = m.tensors.len;
        const vals = try a.alloc([]f32, n);
        @memset(vals, &.{});
        const ints = try a.alloc([]const i32, n);
        @memset(ints, &.{});
        const prep = try a.alloc(Prep, m.ops.len);
        @memset(prep, .{});
        var self = Net{ .a = a, .m = m, .vals = vals, .ints = ints, .prep = prep };
        errdefer self.deinit();

        // 定数を f32 に(int32 はそのまま読む)
        for (m.tensors, 0..) |t, i| {
            if (t.data.len == 0) continue;
            switch (t.dtype) {
                .f32 => {
                    const v = try self.newF(t.data.len / 4);
                    for (v, 0..) |*x, k| x.* = @bitCast(std.mem.readInt(u32, t.data[k * 4 ..][0..4], .little));
                    vals[i] = v;
                },
                .f16 => {
                    const v = try self.newF(t.data.len / 2);
                    for (v, 0..) |*x, k| x.* = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, t.data[k * 2 ..][0..2], .little))));
                    vals[i] = v;
                },
                .i32 => {
                    const v = try a.alloc(i32, t.data.len / 4);
                    try self.owned_i.append(a, v);
                    for (v, 0..) |*x, k| x.* = std.mem.readInt(i32, t.data[k * 4 ..][0..4], .little);
                    ints[i] = v;
                },
                else => return error.Unsupported,
            }
        }
        // f16 → f32 の演算は、ここで済ませる(出力のテンソルに変換済みの値を渡す)
        for (m.ops, 0..) |op, k| if (op.op == .dequantize) {
            const src: usize = @intCast(op.inputs[0]);
            const dst: usize = @intCast(op.output);
            if (vals[src].len == 0) return error.Unsupported;
            vals[dst] = vals[src];
            vals[src] = &.{};
            prep[k].skip = true;
        };
        const is_const = try a.alloc(bool, n);
        defer a.free(is_const);
        for (0..n) |i| is_const[i] = vals[i].len > 0 or ints[i].len > 0;

        // 重みの並べ直し(普通の畳み込みは並べ直した写しだけを残し、元は返す)
        for (m.ops, 0..) |op, k| switch (op.op) {
            .conv_2d => {
                const wi: usize = @intCast(op.inputs[1]);
                const wt = m.tensors[wi];
                const O: usize = @intCast(wt.shape[0]);
                const KH: usize = @intCast(wt.shape[1]);
                const KW: usize = @intCast(wt.shape[2]);
                const I: usize = @intCast(wt.shape[3]);
                const src = vals[wi];
                const w = try self.newF(O * KH * KW * I);
                for (0..O) |o| for (0..KH) |ky| for (0..KW) |kx| for (0..I) |ii| {
                    w[((ky * KW + kx) * I + ii) * O + o] = src[((o * KH + ky) * KW + kx) * I + ii];
                };
                prep[k].w = w;
                prep[k].bias = try biasOf(&self, op, O);
                if (useCount(m, op.inputs[1]) == 1) {
                    self.freeF(src);
                    vals[wi] = &.{};
                }
            },
            .depthwise_conv_2d => {
                const wt = m.tensors[@intCast(op.inputs[1])];
                if (op.opt.depth_mul != 1) return error.Unsupported;
                const C: usize = @intCast(wt.shape[3]);
                prep[k].w = vals[@intCast(op.inputs[1])];
                prep[k].bias = try biasOf(&self, op, C);
            },
            .fully_connected => {
                const wt = m.tensors[@intCast(op.inputs[1])];
                prep[k].w = vals[@intCast(op.inputs[1])];
                prep[k].bias = try biasOf(&self, op, @intCast(wt.shape[0]));
            },
            else => {},
        };

        // 途中の値の置き場: 使い終わった置き場を次の演算で使い回す(最後に読む演算の後で空ける)
        const last = try a.alloc(i64, n);
        defer a.free(last);
        @memset(last, -1);
        for (m.ops, 0..) |op, k| {
            if (prep[k].skip) continue;
            for (op.inputs[0..op.n_in]) |ii| if (ii >= 0) {
                last[@intCast(ii)] = @intCast(k);
            };
        }
        for (m.outputs[0..m.n_out]) |o| last[@intCast(o)] = std.math.maxInt(i64);
        var free_list = std.ArrayListUnmanaged([]f32){};
        defer free_list.deinit(a);
        const take = struct {
            fn f(s: *Net, fl: *std.ArrayListUnmanaged([]f32), size: usize) Error![]f32 {
                // 足りる中でいちばん小さいもの
                var best: ?usize = null;
                for (fl.items, 0..) |b, bi| if (b.len >= size and (best == null or b.len < fl.items[best.?].len)) {
                    best = bi;
                };
                if (best) |bi| return fl.swapRemove(bi)[0..size];
                return s.newF(size);
            }
        }.f;
        // 置き場の元の大きさ(使い回すときに全体を返すため)
        var full = std.AutoHashMapUnmanaged(usize, []f32){};
        defer full.deinit(a);
        const in_i: usize = @intCast(m.input);
        vals[in_i] = try take(&self, &free_list, m.tensors[in_i].count());
        try full.put(a, @intFromPtr(vals[in_i].ptr), vals[in_i]);
        for (m.ops, 0..) |op, k| {
            if (prep[k].skip) continue;
            const oi: usize = @intCast(op.output);
            if (!is_const[oi] and vals[oi].len == 0) {
                const buf = try take(&self, &free_list, m.tensors[oi].count());
                vals[oi] = buf;
                if (!full.contains(@intFromPtr(buf.ptr))) try full.put(a, @intFromPtr(buf.ptr), buf);
            }
            for (op.inputs[0..op.n_in]) |ii| if (ii >= 0) {
                const u: usize = @intCast(ii);
                if (is_const[u] or last[u] != @as(i64, @intCast(k)) or vals[u].len == 0) continue;
                // 同じ置き場を 2 回返さないように
                const whole = full.get(@intFromPtr(vals[u].ptr)) orelse continue;
                var dup = false;
                for (free_list.items) |b| if (b.ptr == whole.ptr) {
                    dup = true;
                };
                if (!dup) try free_list.append(a, whole);
            };
        }
        if (threads > 1) {
            self.pool = Pool.create(a, threads) catch null;
        }
        return self;
    }

    fn useCount(m: tfl.Model, t: i32) usize {
        var c: usize = 0;
        for (m.ops) |op| for (op.inputs[0..op.n_in]) |ii| {
            if (ii == t) c += 1;
        };
        return c;
    }

    fn newF(self: *Net, len: usize) Error![]f32 {
        const v = try self.a.alloc(f32, len);
        errdefer self.a.free(v);
        try self.owned.append(self.a, v);
        return v;
    }

    fn freeF(self: *Net, v: []f32) void {
        for (self.owned.items, 0..) |o, i| if (o.ptr == v.ptr) {
            self.a.free(o);
            _ = self.owned.swapRemove(i);
            return;
        };
    }

    fn biasOf(self: *Net, op: tfl.Operator, n: usize) Error![]f32 {
        if (op.n_in >= 3 and op.inputs[2] >= 0) {
            const b = self.vals[@intCast(op.inputs[2])];
            if (b.len == n) return b;
        }
        const z = try self.newF(n);
        @memset(z, 0);
        return z;
    }

    pub fn deinit(self: *Net) void {
        if (self.pool) |p| p.destroy();
        for (self.owned.items) |v| self.a.free(v);
        self.owned.deinit(self.a);
        for (self.owned_i.items) |v| self.a.free(v);
        self.owned_i.deinit(self.a);
        self.a.free(self.vals);
        self.a.free(self.ints);
        self.a.free(self.prep);
        self.m.deinit(self.a);
    }

    pub fn inputShape(self: *const Net) [4]i32 {
        return self.m.tensors[@intCast(self.m.input)].shape;
    }
    pub fn input(self: *Net) []f32 {
        return self.vals[@intCast(self.m.input)];
    }
    pub fn output(self: *Net, k: usize) []f32 {
        return self.vals[@intCast(self.m.outputs[k])];
    }

    pub fn run(self: *Net) Error!void {
        for (self.m.ops, 0..) |op, k| {
            if (self.prep[k].skip) continue;
            if (self.prof) |pf| {
                const t0 = std.time.nanoTimestamp();
                try self.exec(op, &self.prep[k]);
                const i: usize = @intCast(@max(0, @min(127, @intFromEnum(op.op))));
                pf[i] += @intCast(std.time.nanoTimestamp() - t0);
            } else try self.exec(op, &self.prep[k]);
        }
    }

    fn ten(self: *Net, i: i32) tfl.Tensor {
        return self.m.tensors[@intCast(i)];
    }
    fn val(self: *Net, i: i32) []f32 {
        return self.vals[@intCast(i)];
    }

    fn exec(self: *Net, op: tfl.Operator, p: *Prep) Error!void {
        const out = self.val(op.output);
        const ot = self.ten(op.output);
        switch (op.op) {
            .conv_2d => self.conv(op, p, false),
            .depthwise_conv_2d => self.conv(op, p, true),
            .add => binary(self.val(op.inputs[0]), self.val(op.inputs[1]), out, op.opt.act, .add),
            .mul => binary(self.val(op.inputs[0]), self.val(op.inputs[1]), out, op.opt.act, .mul),
            .sub => binary(self.val(op.inputs[0]), self.val(op.inputs[1]), out, op.opt.act, .sub),
            .prelu => {
                const x = self.val(op.inputs[0]);
                const al = self.val(op.inputs[1]);
                const C = al.len;
                var base: usize = 0;
                while (base < out.len) : (base += C) {
                    var i: usize = 0;
                    while (i + V <= C) : (i += V) {
                        const s: Vec = x[base + i ..][0..V].*;
                        const neg = s * @as(Vec, al[i..][0..V].*);
                        out[base + i ..][0..V].* = @select(f32, s >= @as(Vec, @splat(0)), s, neg);
                    }
                    while (i < C) : (i += 1) {
                        const s = x[base + i];
                        out[base + i] = if (s >= 0) s else s * al[i];
                    }
                }
            },
            .relu => for (out, self.val(op.inputs[0])) |*o, x| {
                o.* = @max(x, 0);
            },
            .relu6 => for (out, self.val(op.inputs[0])) |*o, x| {
                o.* = std.math.clamp(x, 0, 6);
            },
            .logistic => for (out, self.val(op.inputs[0])) |*o, x| {
                o.* = 1 / (1 + @exp(-x));
            },
            .reshape => {
                const x = self.val(op.inputs[0]);
                if (x.len != out.len) return error.ShapeMismatch;
                @memcpy(out, x);
            },
            .pad => {
                const it = self.ten(op.inputs[0]);
                const pads = self.ints[@intCast(op.inputs[1])];
                padOp(self.val(op.inputs[0]), it, pads, out, ot);
            },
            .max_pool_2d => poolMax(self.val(op.inputs[0]), self.ten(op.inputs[0]), out, ot, op.opt),
            .resize_bilinear => resize(self.val(op.inputs[0]), self.ten(op.inputs[0]), out, ot, op.opt),
            .concatenation => {
                var ins: [4][]f32 = undefined;
                var its: [4]tfl.Tensor = undefined;
                for (0..op.n_in) |k| {
                    ins[k] = self.val(op.inputs[k]);
                    its[k] = self.ten(op.inputs[k]);
                }
                concat(ins[0..op.n_in], its[0..op.n_in], out, ot, op.opt.axis);
            },
            .fully_connected => {
                const x = self.val(op.inputs[0]);
                const O = p.bias.len;
                const I = p.w.len / O;
                for (0..O) |o| {
                    var acc: Vec = @splat(0);
                    const wr = p.w[o * I ..][0..I];
                    var i: usize = 0;
                    while (i + V <= I) : (i += V) acc += @as(Vec, x[i..][0..V].*) * @as(Vec, wr[i..][0..V].*);
                    var s = @reduce(.Add, acc);
                    while (i < I) : (i += 1) s += x[i] * wr[i];
                    out[o] = act(s + p.bias[o], op.opt.act);
                }
            },
            .mean => {
                // 空間方向(H, W)の平均 = global average pool
                const it = self.ten(op.inputs[0]);
                const H: usize = @intCast(it.shape[1]);
                const W: usize = @intCast(it.shape[2]);
                const C: usize = @intCast(it.shape[3]);
                const x = self.val(op.inputs[0]);
                @memset(out, 0);
                for (0..H * W) |px| for (0..C) |cc| {
                    out[cc] += x[px * C + cc];
                };
                const inv = 1 / @as(f32, @floatFromInt(H * W));
                for (out) |*o| o.* *= inv;
            },
            .dequantize => {},
            else => return error.Unsupported,
        }
    }

    // ---- 畳み込み ----
    const ConvJob = struct {
        net: *Net,
        op: tfl.Operator,
        p: *Prep,
        dw: bool,
        y0: usize,
        y1: usize,
    };

    fn conv(self: *Net, op: tfl.Operator, p: *Prep, dw: bool) void {
        const ot = self.ten(op.output);
        const OH: usize = @intCast(ot.shape[1]);
        if (self.pool) |pool| {
            const n = pool.n;
            var jobs: [16]ConvJob = undefined;
            const per = (OH + n - 1) / n;
            var k: usize = 0;
            var y: usize = 0;
            while (y < OH and k < jobs.len) : (k += 1) {
                jobs[k] = .{ .net = self, .op = op, .p = p, .dw = dw, .y0 = y, .y1 = @min(OH, y + per) };
                y += per;
            }
            pool.run(ConvJob, jobs[0..k], convRows);
        } else {
            var j = ConvJob{ .net = self, .op = op, .p = p, .dw = dw, .y0 = 0, .y1 = OH };
            convRows(&j);
        }
    }

    fn convRows(j: *ConvJob) void {
        const self = j.net;
        const op = j.op;
        const it = self.ten(op.inputs[0]);
        const ot = self.ten(op.output);
        const wt = self.ten(op.inputs[1]);
        const x = self.val(op.inputs[0]);
        const out = self.val(op.output);
        const H: i32 = it.shape[1];
        const W: i32 = it.shape[2];
        const I: usize = @intCast(it.shape[3]);
        const OW: usize = @intCast(ot.shape[2]);
        const O: usize = @intCast(ot.shape[3]);
        const KH: i32 = wt.shape[1];
        const KW: i32 = wt.shape[2];
        const o = op.opt;
        const pad_t = padBefore(H, @intCast(ot.shape[1]), KH, o.stride_h, o.dil_h, o.padding_same);
        const pad_l = padBefore(W, @intCast(OW), KW, o.stride_w, o.dil_w, o.padding_same);
        const w = j.p.w;
        const bias = j.p.bias;
        if (!j.dw and O % 8 == 0) {
            // 普通の畳み込み: 4 画素 × 16(または 8)チャンネルをレジスタに置いて計算する。
            // 重み 1 行を読むたびに 4 画素分に使うので、重みを読む回数が 1/4 になる
            for (j.y0..j.y1) |oy| {
                var ox: usize = 0;
                while (ox < OW) : (ox += PX) {
                    const np = @min(PX, OW - ox);
                    // 各画素の、カーネル位置ごとの入力の先頭(範囲外は null)
                    var ob: usize = 0;
                    while (ob < O) : (ob += if (O - ob >= 16) 16 else 8) {
                        const two = O - ob >= 16;
                        var acc0: [PX]Vec = undefined;
                        var acc1: [PX]Vec = undefined;
                        for (0..PX) |p| {
                            acc0[p] = bias[ob..][0..V].*;
                            acc1[p] = if (two) bias[ob + V ..][0..V].* else @splat(0);
                        }
                        var ky: i32 = 0;
                        while (ky < KH) : (ky += 1) {
                            const iy = @as(i32, @intCast(oy)) * o.stride_h - pad_t + ky * o.dil_h;
                            if (iy < 0 or iy >= H) continue;
                            var kx: i32 = 0;
                            while (kx < KW) : (kx += 1) {
                                const kk: usize = @intCast(ky * KW + kx);
                                const wk = w[kk * I * O ..];
                                var src: [PX]?[*]const f32 = .{null} ** PX;
                                var all = np == PX;
                                for (0..np) |p| {
                                    const ix = @as(i32, @intCast(ox + p)) * o.stride_w - pad_l + kx * o.dil_w;
                                    if (ix >= 0 and ix < W) src[p] = x[@as(usize, @intCast(iy * W + ix)) * I ..].ptr else all = false;
                                }
                                if (all) {
                                    // 4 画素とも中にある(ほとんどの場合): 確かめずに回す
                                    var sp: [PX][*]const f32 = undefined;
                                    inline for (0..PX) |p| sp[p] = src[p].?;
                                    if (two) {
                                        for (0..I) |ii| {
                                            const wr = wk[ii * O + ob ..];
                                            const w0: Vec = wr[0..V].*;
                                            const w1: Vec = wr[V..][0..V].*;
                                            inline for (0..PX) |p| {
                                                const s: Vec = @splat(sp[p][ii]);
                                                acc0[p] = @mulAdd(Vec, s, w0, acc0[p]);
                                                acc1[p] = @mulAdd(Vec, s, w1, acc1[p]);
                                            }
                                        }
                                    } else {
                                        for (0..I) |ii| {
                                            const w0: Vec = wk[ii * O + ob ..][0..V].*;
                                            inline for (0..PX) |p| acc0[p] = @mulAdd(Vec, @as(Vec, @splat(sp[p][ii])), w0, acc0[p]);
                                        }
                                    }
                                    continue;
                                }
                                for (0..I) |ii| {
                                    const wr = wk[ii * O + ob ..];
                                    const w0: Vec = wr[0..V].*;
                                    const w1: Vec = if (two) wr[V..][0..V].* else @splat(0);
                                    inline for (0..PX) |p| if (src[p]) |sp| {
                                        const s: Vec = @splat(sp[ii]);
                                        acc0[p] = @mulAdd(Vec, s, w0, acc0[p]);
                                        if (two) acc1[p] = @mulAdd(Vec, s, w1, acc1[p]);
                                    };
                                }
                            }
                        }
                        for (0..np) |p| {
                            const d = out[((oy * OW + ox + p) * O) + ob ..];
                            d[0..V].* = actV(acc0[p], o.act);
                            if (two) d[V..][0..V].* = actV(acc1[p], o.act);
                        }
                    }
                }
            }
            return;
        }
        if (j.dw and O % 8 == 0) {
            // depthwise: チャンネル 8 個ずつをレジスタに置き、カーネルの各位置を足してから 1 回だけ書く
            for (j.y0..j.y1) |oy| for (0..OW) |ox| {
                const d = out[(oy * OW + ox) * O ..][0..O];
                // この画素で使うカーネルの位置(入力と重みの先頭)を先に数えておく
                var xs_off: [49]usize = undefined;
                var ws_off: [49]usize = undefined;
                var nt: usize = 0;
                var ky: i32 = 0;
                while (ky < KH) : (ky += 1) {
                    const iy = @as(i32, @intCast(oy)) * o.stride_h - pad_t + ky * o.dil_h;
                    if (iy < 0 or iy >= H) continue;
                    var kx: i32 = 0;
                    while (kx < KW) : (kx += 1) {
                        const ix = @as(i32, @intCast(ox)) * o.stride_w - pad_l + kx * o.dil_w;
                        if (ix < 0 or ix >= W or nt >= xs_off.len) continue;
                        xs_off[nt] = @as(usize, @intCast(iy * W + ix)) * I;
                        ws_off[nt] = @as(usize, @intCast(ky * KW + kx)) * O;
                        nt += 1;
                    }
                }
                var cb: usize = 0;
                while (cb < O) : (cb += V) {
                    var acc: Vec = bias[cb..][0..V].*;
                    for (xs_off[0..nt], ws_off[0..nt]) |xo, wo| {
                        acc = @mulAdd(Vec, @as(Vec, x[xo + cb ..][0..V].*), @as(Vec, w[wo + cb ..][0..V].*), acc);
                    }
                    d[cb..][0..V].* = actV(acc, o.act);
                }
            };
            return;
        }
        for (j.y0..j.y1) |oy| for (0..OW) |ox| {
            const acc = out[(oy * OW + ox) * O ..][0..O];
            @memcpy(acc, bias);
            var ky: i32 = 0;
            while (ky < KH) : (ky += 1) {
                const iy = @as(i32, @intCast(oy)) * o.stride_h - pad_t + ky * o.dil_h;
                if (iy < 0 or iy >= H) continue;
                var kx: i32 = 0;
                while (kx < KW) : (kx += 1) {
                    const ix = @as(i32, @intCast(ox)) * o.stride_w - pad_l + kx * o.dil_w;
                    if (ix < 0 or ix >= W) continue;
                    const src = x[@as(usize, @intCast(iy * W + ix)) * I ..][0..I];
                    const kk: usize = @intCast(ky * KW + kx);
                    if (j.dw) {
                        // depthwise: チャンネルごとに掛ける(I == O)
                        axpyMul(acc, src, w[kk * O ..][0..O]);
                    } else {
                        const wk = w[kk * I * O ..][0 .. I * O];
                        for (0..I) |ii| axpy(acc, src[ii], wk[ii * O ..][0..O]);
                    }
                }
            }
            applyAct(acc, o.act);
        };
    }
};

const PX = 4;

inline fn actV(x: Vec, a: tfl.Act) Vec {
    return switch (a) {
        .relu => @max(x, @as(Vec, @splat(0))),
        .relu6 => @min(@max(x, @as(Vec, @splat(0))), @as(Vec, @splat(6))),
        .relu_n1_1 => @min(@max(x, @as(Vec, @splat(-1))), @as(Vec, @splat(1))),
        .tanh => blk: {
            var r: Vec = undefined;
            inline for (0..V) |k| r[k] = std.math.tanh(x[k]);
            break :blk r;
        },
        else => x,
    };
}

fn padBefore(in: i32, out: i32, k: i32, stride: i32, dil: i32, same: bool) i32 {
    if (!same) return 0;
    const eff = (k - 1) * dil + 1;
    const total = @max((out - 1) * stride + eff - in, 0);
    return @divFloor(total, 2);
}

/// acc += s * w(出力チャンネル方向にまとめて)
inline fn axpy(acc: []f32, s: f32, w: []const f32) void {
    const sv: Vec = @splat(s);
    var i: usize = 0;
    while (i + V <= acc.len) : (i += V) {
        const a: Vec = acc[i..][0..V].*;
        acc[i..][0..V].* = a + sv * @as(Vec, w[i..][0..V].*);
    }
    while (i < acc.len) : (i += 1) acc[i] += s * w[i];
}

/// acc += x * w(要素ごと)
inline fn axpyMul(acc: []f32, x: []const f32, w: []const f32) void {
    var i: usize = 0;
    while (i + V <= acc.len) : (i += V) {
        const a: Vec = acc[i..][0..V].*;
        acc[i..][0..V].* = a + @as(Vec, x[i..][0..V].*) * @as(Vec, w[i..][0..V].*);
    }
    while (i < acc.len) : (i += 1) acc[i] += x[i] * w[i];
}

fn act(x: f32, a: tfl.Act) f32 {
    return switch (a) {
        .relu => @max(x, 0),
        .relu6 => std.math.clamp(x, 0, 6),
        .relu_n1_1 => std.math.clamp(x, -1, 1),
        .tanh => std.math.tanh(x),
        else => x,
    };
}

fn applyAct(xs: []f32, a: tfl.Act) void {
    if (a == .none) return;
    for (xs) |*x| x.* = act(x.*, a);
}

const BinOp = enum { add, mul, sub };

fn binary(a: []const f32, b: []const f32, out: []f32, ac: tfl.Act, comptime k: BinOp) void {
    // 同じ形、または片方が末尾の次元だけ(チャンネルごとの値)・1 つだけ
    const swapped = a.len < b.len;
    const big = if (swapped) b else a;
    const small = if (swapped) a else b;
    const C = small.len;
    var base: usize = 0;
    while (base < out.len) : (base += C) {
        const xs = big[base..][0..C];
        const ds = out[base..][0..C];
        var i: usize = 0;
        while (i + V <= C) : (i += V) {
            const x: Vec = xs[i..][0..V].*;
            const y: Vec = small[i..][0..V].*;
            const l = if (swapped) y else x;
            const r = if (swapped) x else y;
            ds[i..][0..V].* = actV(switch (k) {
                .add => l + r,
                .mul => l * r,
                .sub => l - r,
            }, ac);
        }
        while (i < C) : (i += 1) {
            const l = if (swapped) small[i] else xs[i];
            const r = if (swapped) xs[i] else small[i];
            ds[i] = act(switch (k) {
                .add => l + r,
                .mul => l * r,
                .sub => l - r,
            }, ac);
        }
    }
}

fn padOp(x: []const f32, it: tfl.Tensor, pads: []const i32, out: []f32, ot: tfl.Tensor) void {
    @memset(out, 0);
    if (it.rank != 4 or pads.len < 8) return;
    const H: usize = @intCast(it.shape[1]);
    const W: usize = @intCast(it.shape[2]);
    const C: usize = @intCast(it.shape[3]);
    const OW: usize = @intCast(ot.shape[2]);
    const OC: usize = @intCast(ot.shape[3]);
    const pt: usize = @intCast(pads[2]);
    const pl: usize = @intCast(pads[4]);
    const pc: usize = @intCast(pads[6]);
    for (0..H) |y| for (0..W) |xx| {
        const s = x[(y * W + xx) * C ..][0..C];
        @memcpy(out[((y + pt) * OW + xx + pl) * OC + pc ..][0..C], s);
    };
}

fn poolMax(x: []const f32, it: tfl.Tensor, out: []f32, ot: tfl.Tensor, o: tfl.Options) void {
    const H: i32 = it.shape[1];
    const W: i32 = it.shape[2];
    const C: usize = @intCast(it.shape[3]);
    const OH: usize = @intCast(ot.shape[1]);
    const OW: usize = @intCast(ot.shape[2]);
    const pt = padBefore(H, @intCast(OH), o.filter_h, o.stride_h, 1, o.padding_same);
    const pl = padBefore(W, @intCast(OW), o.filter_w, o.stride_w, 1, o.padding_same);
    for (0..OH) |oy| for (0..OW) |ox| {
        const d = out[(oy * OW + ox) * C ..][0..C];
        @memset(d, -std.math.inf(f32));
        var ky: i32 = 0;
        while (ky < o.filter_h) : (ky += 1) {
            const iy = @as(i32, @intCast(oy)) * o.stride_h - pt + ky;
            if (iy < 0 or iy >= H) continue;
            var kx: i32 = 0;
            while (kx < o.filter_w) : (kx += 1) {
                const ix = @as(i32, @intCast(ox)) * o.stride_w - pl + kx;
                if (ix < 0 or ix >= W) continue;
                const s = x[@as(usize, @intCast(iy * W + ix)) * C ..][0..C];
                for (d, s) |*dd, ss| dd.* = @max(dd.*, ss);
            }
        }
        applyAct(d, o.act);
    };
}

fn resize(x: []const f32, it: tfl.Tensor, out: []f32, ot: tfl.Tensor, o: tfl.Options) void {
    const H: usize = @intCast(it.shape[1]);
    const W: usize = @intCast(it.shape[2]);
    const C: usize = @intCast(it.shape[3]);
    const OH: usize = @intCast(ot.shape[1]);
    const OW: usize = @intCast(ot.shape[2]);
    const sy: f32 = if (o.align_corners and OH > 1) @as(f32, @floatFromInt(H - 1)) / @as(f32, @floatFromInt(OH - 1)) else @as(f32, @floatFromInt(H)) / @as(f32, @floatFromInt(OH));
    const sx: f32 = if (o.align_corners and OW > 1) @as(f32, @floatFromInt(W - 1)) / @as(f32, @floatFromInt(OW - 1)) else @as(f32, @floatFromInt(W)) / @as(f32, @floatFromInt(OW));
    for (0..OH) |oy| {
        var fy = if (o.half_pixel) (@as(f32, @floatFromInt(oy)) + 0.5) * sy - 0.5 else @as(f32, @floatFromInt(oy)) * sy;
        fy = @max(fy, 0);
        const y0: usize = @min(@as(usize, @intFromFloat(@floor(fy))), H - 1);
        const y1 = @min(y0 + 1, H - 1);
        const wy = fy - @as(f32, @floatFromInt(y0));
        for (0..OW) |ox| {
            var fx = if (o.half_pixel) (@as(f32, @floatFromInt(ox)) + 0.5) * sx - 0.5 else @as(f32, @floatFromInt(ox)) * sx;
            fx = @max(fx, 0);
            const x0: usize = @min(@as(usize, @intFromFloat(@floor(fx))), W - 1);
            const x1 = @min(x0 + 1, W - 1);
            const wx = fx - @as(f32, @floatFromInt(x0));
            const d = out[(oy * OW + ox) * C ..][0..C];
            const a = x[(y0 * W + x0) * C ..][0..C];
            const b = x[(y0 * W + x1) * C ..][0..C];
            const cc = x[(y1 * W + x0) * C ..][0..C];
            const dd = x[(y1 * W + x1) * C ..][0..C];
            for (0..C) |k| {
                const top = a[k] + (b[k] - a[k]) * wx;
                const bot = cc[k] + (dd[k] - cc[k]) * wx;
                d[k] = top + (bot - top) * wy;
            }
        }
    }
}

fn concat(ins: []const []f32, its: []const tfl.Tensor, out: []f32, ot: tfl.Tensor, axis_in: i32) void {
    const rank: i32 = ot.rank;
    const axis: usize = @intCast(if (axis_in < 0) axis_in + rank else axis_in);
    // outer = 軸より前の要素数、各入力は「軸以降の大きさ」ずつ並べる
    var outer: usize = 1;
    for (0..axis) |k| outer *= @intCast(ot.shape[k]);
    var off: usize = 0;
    var inner_out: usize = 1;
    for (axis..ot.rank) |k| inner_out *= @intCast(ot.shape[k]);
    for (ins, its) |x, t| {
        var inner: usize = 1;
        for (axis..t.rank) |k| inner *= @intCast(t.shape[k]);
        for (0..outer) |o| @memcpy(out[o * inner_out + off ..][0..inner], x[o * inner ..][0..inner]);
        off += inner;
    }
}

// ---------------------------------------------------------------------------
// 小さなスレッドの組: 仕事を n 個に分けて同時に走らせ、全部終わるまで待つ
// ---------------------------------------------------------------------------

pub const Pool = struct {
    a: std.mem.Allocator,
    n: usize,
    threads: []std.Thread,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done_cond: std.Thread.Condition = .{},
    gen: u64 = 0,
    pending: usize = 0,
    quit: bool = false,
    // 今の仕事
    ctx: ?*anyopaque = null,
    fnp: ?*const fn (*anyopaque, usize) void = null,
    next: usize = 0,
    total: usize = 0,

    fn create(a: std.mem.Allocator, n: usize) !*Pool {
        const p = try a.create(Pool);
        p.* = .{ .a = a, .n = n, .threads = try a.alloc(std.Thread, n - 1) };
        for (p.threads, 0..) |*t, i| {
            t.* = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, worker, .{p}) catch |e| {
                for (p.threads[0..i]) |tt| tt.detach();
                return e;
            };
        }
        return p;
    }

    fn destroy(self: *Pool) void {
        self.mutex.lock();
        self.quit = true;
        self.cond.broadcast();
        self.mutex.unlock();
        for (self.threads) |t| t.join();
        self.a.free(self.threads);
        self.a.destroy(self);
    }

    fn worker(self: *Pool) void {
        var seen: u64 = 0;
        while (true) {
            self.mutex.lock();
            while (self.gen == seen and !self.quit) self.cond.wait(&self.mutex);
            if (self.quit) {
                self.mutex.unlock();
                return;
            }
            seen = self.gen;
            self.mutex.unlock();
            self.drain();
        }
    }

    /// 残っている仕事を取って片付ける(呼んだスレッドも手伝う)
    fn drain(self: *Pool) void {
        while (true) {
            self.mutex.lock();
            if (self.next >= self.total) {
                self.mutex.unlock();
                return;
            }
            const i = self.next;
            self.next += 1;
            const f = self.fnp.?;
            const ctx = self.ctx.?;
            self.mutex.unlock();
            f(ctx, i);
            self.mutex.lock();
            self.pending -= 1;
            if (self.pending == 0) self.done_cond.broadcast();
            self.mutex.unlock();
        }
    }

    fn run(self: *Pool, comptime J: type, jobs: []J, comptime f: fn (*J) void) void {
        const S = struct {
            fn call(ctx: *anyopaque, i: usize) void {
                const js: [*]J = @ptrCast(@alignCast(ctx));
                f(&js[i]);
            }
        };
        self.mutex.lock();
        self.ctx = @ptrCast(jobs.ptr);
        self.fnp = S.call;
        self.next = 0;
        self.total = jobs.len;
        self.pending = jobs.len;
        self.gen += 1;
        self.cond.broadcast();
        self.mutex.unlock();
        self.drain();
        self.mutex.lock();
        while (self.pending > 0) self.done_cond.wait(&self.mutex);
        self.mutex.unlock();
    }
};
