// 開いているアプリの一覧(River 0.3 用。wlr-foreign-toplevel-management)。
//
// River 0.3 は「どの窓がどのタグにいるか」を外部に出さない(river-status はタグの集合しか送らない)ので推測する:
//   - 新しい窓は、開いた時点の出力のフォーカス中タグにいる(River の既定動作)
//   - フォーカスされた窓は必ず見えている → 記録が見えていないタグなら今のタグへ直す
//   - river-status のタグごとの窓の数が「1 つ減ったタグ」と「1 つ増えたタグ」で食い違ったら、
//     最後にフォーカスされた窓が移された(Super+Shift+数字)とみなす
// River 0.5 では内蔵 WM が正確な情報を持っているので、こちらは使わない。
const std = @import("std");
const c = @import("c.zig");
const appmod = @import("app.zig");
const App = appmod.App;
const Output = appmod.Output;

pub const Toplevel = struct {
    list: *Toplevels,
    handle: *c.struct_zwlr_foreign_toplevel_handle_v1,
    app_id: [96]u8 = undefined,
    app_id_len: usize = 0,
    title: [160]u8 = undefined,
    title_len: usize = 0,
    out: ?*Output = null,
    tags: u32 = 0,
    activated: bool = false,
    seen_done: bool = false,

    pub fn appId(self: *const Toplevel) []const u8 {
        return self.app_id[0..self.app_id_len];
    }
    pub fn titleStr(self: *const Toplevel) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const Toplevels = struct {
    app: *App,
    mgr: *c.struct_zwlr_foreign_toplevel_manager_v1,
    items: std.ArrayList(*Toplevel),
    last_active: ?*Toplevel = null,

    pub fn create(app: *App, mgr: *c.struct_zwlr_foreign_toplevel_manager_v1) !*Toplevels {
        const self = try app.alloc.create(Toplevels);
        self.* = .{ .app = app, .mgr = mgr, .items = std.ArrayList(*Toplevel).init(app.alloc) };
        _ = c.zwlr_foreign_toplevel_manager_v1_add_listener(mgr, &mgr_listener, self);
        return self;
    }

    fn outOf(self: *Toplevels, t: *Toplevel) ?*Output {
        return t.out orelse self.app.focused_output orelse if (self.app.outputs.items.len > 0) self.app.outputs.items[0] else null;
    }

    /// river-status の view_tags が更新されたとき(app.zig から)。移動された窓を推測する
    pub fn viewTagsChanged(self: *Toplevels, o: *Output) void {
        var real = [_]i32{0} ** 32;
        for (o.view_list[0..o.n_views]) |tg| for (0..32) |b| {
            if ((tg >> @intCast(b)) & 1 == 1) real[b] += 1;
        };
        var model = [_]i32{0} ** 32;
        for (self.items.items) |t| if (self.outOf(t) == o) for (0..32) |b| {
            if ((t.tags >> @intCast(b)) & 1 == 1) model[b] += 1;
        };
        var lost: ?usize = null;
        var gained: ?usize = null;
        for (0..32) |b| {
            const d = real[b] - model[b];
            if (d < 0) lost = b;
            if (d > 0) gained = b;
        }
        const t = self.last_active orelse return;
        if (lost) |l| if (gained) |g| if ((t.tags >> @intCast(l)) & 1 == 1) {
            t.tags = @as(u32, 1) << @intCast(g);
        };
    }

    /// 出力の各タグ(ワークスペース)にいる窓の一覧
    pub fn onTag(self: *Toplevels, o: *Output, tag: u5, buf: []*Toplevel) usize {
        var n: usize = 0;
        for (self.items.items) |t| {
            if (n >= buf.len) break;
            if (self.outOf(t) != o or (t.tags >> tag) & 1 == 0) continue;
            buf[n] = t;
            n += 1;
        }
        return n;
    }
};

fn mgrToplevel(data: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_manager_v1, h: ?*c.struct_zwlr_foreign_toplevel_handle_v1) callconv(.C) void {
    const self: *Toplevels = @ptrCast(@alignCast(data.?));
    const t = self.app.alloc.create(Toplevel) catch return;
    t.* = .{ .list = self, .handle = h.? };
    _ = c.zwlr_foreign_toplevel_handle_v1_add_listener(h, &handle_listener, t);
    self.items.append(t) catch {};
}
fn mgrFinished(_: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_manager_v1) callconv(.C) void {}
const mgr_listener = c.struct_zwlr_foreign_toplevel_manager_v1_listener{ .toplevel = mgrToplevel, .finished = mgrFinished };

fn copyStr(dst: []u8, len: *usize, s: [*c]const u8) void {
    const v = if (s != null) std.mem.sliceTo(s, 0) else "";
    var n = @min(v.len, dst.len);
    while (n > 0 and n < v.len and (v[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(dst[0..n], v[0..n]);
    len.* = n;
}
fn hTitle(data: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, s: [*c]const u8) callconv(.C) void {
    const t: *Toplevel = @ptrCast(@alignCast(data.?));
    copyStr(&t.title, &t.title_len, s);
}
fn hAppId(data: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, s: [*c]const u8) callconv(.C) void {
    const t: *Toplevel = @ptrCast(@alignCast(data.?));
    copyStr(&t.app_id, &t.app_id_len, s);
}
fn hOutEnter(data: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, wl: ?*c.struct_wl_output) callconv(.C) void {
    const t: *Toplevel = @ptrCast(@alignCast(data.?));
    for (t.list.app.outputs.items) |o| if (o.wl == wl) {
        t.out = o;
    };
}
fn hOutLeave(_: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, _: ?*c.struct_wl_output) callconv(.C) void {}
fn hState(data: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, arr: [*c]c.struct_wl_array) callconv(.C) void {
    const t: *Toplevel = @ptrCast(@alignCast(data.?));
    t.activated = false;
    if (arr == null) return;
    const n = arr.*.size / @sizeOf(u32);
    if (n == 0) return;
    const states: [*]const u32 = @ptrCast(@alignCast(arr.*.data));
    for (states[0..n]) |st| if (st == c.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) {
        t.activated = true;
    };
}
fn hDone(data: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1) callconv(.C) void {
    const t: *Toplevel = @ptrCast(@alignCast(data.?));
    const self = t.list;
    const o = self.outOf(t);
    if (!t.seen_done) {
        t.seen_done = true;
        if (o) |oo| t.tags = oo.focused_tags;
    }
    if (t.activated) {
        self.last_active = t;
        // フォーカスされている窓は見えている → 見えていないタグとして記録していたら今のタグへ
        if (o) |oo| if (t.tags & oo.focused_tags == 0) {
            t.tags = oo.focused_tags;
        };
    }
    if (self.app.activeFrame()) |f| f.schedule();
}
fn hClosed(data: ?*anyopaque, h: ?*c.struct_zwlr_foreign_toplevel_handle_v1) callconv(.C) void {
    const t: *Toplevel = @ptrCast(@alignCast(data.?));
    const self = t.list;
    if (self.last_active == t) self.last_active = null;
    if (std.mem.indexOfScalar(*Toplevel, self.items.items, t)) |i| _ = self.items.orderedRemove(i);
    c.zwlr_foreign_toplevel_handle_v1_destroy(h);
    self.app.alloc.destroy(t);
    if (self.app.activeFrame()) |f| f.schedule();
}
fn hParent(_: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1) callconv(.C) void {}
const handle_listener = c.struct_zwlr_foreign_toplevel_handle_v1_listener{
    .title = hTitle,
    .app_id = hAppId,
    .output_enter = hOutEnter,
    .output_leave = hOutLeave,
    .state = hState,
    .done = hDone,
    .closed = hClosed,
    .parent = hParent,
};
