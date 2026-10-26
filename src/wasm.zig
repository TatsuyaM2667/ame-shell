// WASM ウィジェットの実行(wasm3)。
//
// wasm3 を選んだ理由(docs/decisions.md に詳細): 純 C で依存なし、musl でもそのままビルドでき、
// インタプリタでも十分速い(ウィジェットは1フレーム数十命令〜数千命令程度)。WAMR は JIT/AOT
// を使うと速いが、ビルド構成が大きく CMake 前提なので「zig build 一発」の方針に合わない。
//
// サンドボックス: ウィジェットに与える import は "ame.action" だけ。WASI は有効にしないので
// ファイル・ネットワーク・時計にも触れられない(時刻はホストがストアに書き込む)。
// メモリは 1MiB 固定(ビルド時に max_memory で制限)。
const std = @import("std");
const c = @import("c.zig");
const abi = @import("widget_abi.zig");

pub const ActionFn = *const fn (ctx: *anyopaque, action: abi.Action, value: f32) void;

pub const Widget = struct {
    alloc: std.mem.Allocator,
    name: [32]u8 = undefined,
    name_len: usize = 0,
    path: [512]u8 = undefined,
    path_len: usize = 0,
    bytes: []u8 = &.{},
    env: c.IM3Environment = null,
    rt: c.IM3Runtime = null,
    f_frame: c.IM3Function = null,
    f_height: c.IM3Function = null,
    f_pointer: c.IM3Function = null,
    f_state: c.IM3Function = null,
    f_state_size: c.IM3Function = null,
    store_off: u32 = 0,
    cmds_off: u32 = 0,
    host_ctx: *anyopaque,
    host_action: ActionFn,
    failed: bool = false,

    pub fn nameStr(self: *const Widget) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn load(alloc: std.mem.Allocator, path: []const u8, name: []const u8, ctx: *anyopaque, action: ActionFn) !*Widget {
        const self = try alloc.create(Widget);
        self.* = .{ .alloc = alloc, .host_ctx = ctx, .host_action = action };
        self.name_len = @min(name.len, self.name.len);
        @memcpy(self.name[0..self.name_len], name[0..self.name_len]);
        self.path_len = @min(path.len, self.path.len);
        @memcpy(self.path[0..self.path_len], path[0..self.path_len]);
        self.instantiate() catch |e| {
            alloc.destroy(self);
            return e;
        };
        return self;
    }

    fn check(r: c.M3Result, what: []const u8) !void {
        if (r != null) {
            std.log.err("wasm: {s}: {s}", .{ what, std.mem.sliceTo(r, 0) });
            return error.Wasm;
        }
    }

    fn instantiate(self: *Widget) !void {
        self.bytes = try std.fs.cwd().readFileAlloc(self.alloc, self.path[0..self.path_len], 4 << 20);
        errdefer self.alloc.free(self.bytes);
        self.env = c.m3_NewEnvironment() orelse return error.Wasm;
        errdefer c.m3_FreeEnvironment(self.env);
        // スタック 64KiB。userdata に自分を入れて import 関数から引けるようにする。
        self.rt = c.m3_NewRuntime(self.env, 64 * 1024, self) orelse return error.Wasm;
        errdefer c.m3_FreeRuntime(self.rt);
        var module: c.IM3Module = null;
        try check(c.m3_ParseModule(self.env, &module, self.bytes.ptr, @intCast(self.bytes.len)), "parse");
        try check(c.m3_LoadModule(self.rt, module), "load");
        // import が無いウィジェットもあるので「見つからない」は無視する
        const r = c.m3_LinkRawFunction(module, "ame", "action", "v(if)", hostAction);
        if (r != null and r != c.m3Err_functionLookupFailed) try check(r, "link action");

        try check(c.m3_FindFunction(&self.f_frame, self.rt, "ame_frame"), "ame_frame");
        try check(c.m3_FindFunction(&self.f_height, self.rt, "ame_height"), "ame_height");
        try check(c.m3_FindFunction(&self.f_pointer, self.rt, "ame_pointer"), "ame_pointer");
        try check(c.m3_FindFunction(&self.f_state, self.rt, "ame_state"), "ame_state");
        try check(c.m3_FindFunction(&self.f_state_size, self.rt, "ame_state_size"), "ame_state_size");
        var f: c.IM3Function = null;
        try check(c.m3_FindFunction(&f, self.rt, "ame_store"), "ame_store");
        self.store_off = try call0(f);
        try check(c.m3_FindFunction(&f, self.rt, "ame_cmds"), "ame_cmds");
        self.cmds_off = try call0(f);
        const mem = self.memory();
        if (self.store_off + @sizeOf(abi.Store) > mem.len or self.cmds_off >= mem.len) return error.WasmBadLayout;
        self.failed = false;
    }

    fn release(self: *Widget) void {
        if (self.rt != null) c.m3_FreeRuntime(self.rt);
        if (self.env != null) c.m3_FreeEnvironment(self.env);
        if (self.bytes.len > 0) self.alloc.free(self.bytes);
        self.rt = null;
        self.env = null;
        self.bytes = &.{};
    }

    pub fn destroy(self: *Widget) void {
        self.release();
        self.alloc.destroy(self);
    }

    /// ホットリロード: state を退避 → 作り直し → サイズが同じなら state を戻す。
    pub fn reload(self: *Widget) void {
        var saved: [4096]u8 = undefined;
        var saved_len: usize = 0;
        if (!self.failed) {
            if (self.stateSlice()) |st| if (st.len <= saved.len) {
                @memcpy(saved[0..st.len], st);
                saved_len = st.len;
            };
        }
        self.release();
        self.instantiate() catch {
            std.log.err("wasm: {s} の再読込に失敗(前の版は破棄済み。修正して保存し直せば再試行します)", .{self.nameStr()});
            self.failed = true;
            return;
        };
        if (self.stateSlice()) |st| {
            if (st.len == saved_len) {
                @memcpy(st, saved[0..saved_len]);
                std.log.info("wasm: {s} を再読込(状態を引き継ぎ)", .{self.nameStr()});
            } else std.log.info("wasm: {s} を再読込(状態の形が変わったので初期化)", .{self.nameStr()});
        }
    }

    fn stateSlice(self: *Widget) ?[]u8 {
        const off = call0(self.f_state) catch return null;
        const size = call0(self.f_state_size) catch return null;
        const mem = self.memory();
        if (@as(usize, off) + size > mem.len) return null;
        return mem[off .. off + size];
    }

    pub fn memory(self: *Widget) []u8 {
        var size: u32 = 0;
        const p = c.m3_GetMemory(self.rt, &size, 0) orelse return &.{};
        return p[0..size];
    }

    /// ホストのデータをウィジェットのメモリへ直接書く(コピー1回、シリアライズ無し)
    pub fn writeStore(self: *Widget, s: *const abi.Store) void {
        if (self.failed) return;
        const mem = self.memory();
        const dst = mem[self.store_off .. self.store_off + @sizeOf(abi.Store)];
        @memcpy(dst, std.mem.asBytes(s));
    }

    pub fn height(self: *Widget, w: f32) f32 {
        if (self.failed) return 40;
        var arg = w;
        const args = [_]?*const anyopaque{&arg};
        if (c.m3_Call(self.f_height, 1, @ptrCast(@constCast(&args))) != null) return 40;
        var out: f32 = 40;
        const rets = [_]?*const anyopaque{&out};
        _ = c.m3_GetResults(self.f_height, 1, @ptrCast(@constCast(&rets)));
        return out;
    }

    pub const FrameResult = struct { cmds: []align(1) const abi.Cmd, animating: bool };

    pub fn frame(self: *Widget, dt: f32, w: f32, h: f32) FrameResult {
        if (self.failed) return .{ .cmds = &.{}, .animating = false };
        var a0 = dt;
        var a1 = w;
        var a2 = h;
        const args = [_]?*const anyopaque{ &a0, &a1, &a2 };
        if (c.m3_Call(self.f_frame, 3, @ptrCast(@constCast(&args)))) |err| {
            std.log.err("wasm: {s}.frame がトラップ: {s}(このウィジェットを停止)", .{ self.nameStr(), std.mem.sliceTo(err, 0) });
            self.failed = true;
            return .{ .cmds = &.{}, .animating = false };
        }
        var ret: u32 = 0;
        const rets = [_]?*const anyopaque{&ret};
        _ = c.m3_GetResults(self.f_frame, 1, @ptrCast(@constCast(&rets)));
        const n = ret >> 1;
        const mem = self.memory();
        const bytes = @as(usize, n) * @sizeOf(abi.Cmd);
        if (@as(usize, self.cmds_off) + bytes > mem.len) return .{ .cmds = &.{}, .animating = false };
        // ウィジェットのメモリ上のコマンド配列をそのまま参照する(ゼロコピー)
        const ptr: [*]align(1) const abi.Cmd = @ptrCast(mem.ptr + self.cmds_off);
        return .{ .cmds = ptr[0..n], .animating = (ret & 1) != 0 };
    }

    /// コマンドが指す文字列を、ウィジェットのメモリから境界チェック付きで取り出す
    pub fn str(self: *Widget, ptr: u32, len: u32) []const u8 {
        const mem = self.memory();
        if (@as(usize, ptr) + len > mem.len) return "";
        return mem[ptr .. ptr + len];
    }

    pub fn pointer(self: *Widget, kind: abi.PointerKind, x: f32, y: f32) bool {
        if (self.failed) return false;
        var k: u32 = @intFromEnum(kind);
        var a1 = x;
        var a2 = y;
        const args = [_]?*const anyopaque{ &k, &a1, &a2 };
        if (c.m3_Call(self.f_pointer, 3, @ptrCast(@constCast(&args))) != null) return false;
        var ret: u32 = 0;
        const rets = [_]?*const anyopaque{&ret};
        _ = c.m3_GetResults(self.f_pointer, 1, @ptrCast(@constCast(&rets)));
        return ret != 0;
    }
};

fn call0(f: c.IM3Function) !u32 {
    if (c.m3_Call(f, 0, null) != null) return error.Wasm;
    var ret: u32 = 0;
    const rets = [_]?*const anyopaque{&ret};
    if (c.m3_GetResults(f, 1, @ptrCast(@constCast(&rets))) != null) return error.Wasm;
    return ret;
}

/// import "ame.action"(i32, f32) -> void
fn hostAction(rt: c.IM3Runtime, _: c.IM3ImportContext, sp: [*c]u64, _: ?*anyopaque) callconv(.C) ?*const anyopaque {
    const w: *Widget = @ptrCast(@alignCast(c.m3_GetUserData(rt) orelse return null));
    const id: u32 = @truncate(sp[0]);
    const v: f32 = @bitCast(@as(u32, @truncate(sp[1])));
    w.host_action(w.host_ctx, @enumFromInt(id), v);
    return null;
}
