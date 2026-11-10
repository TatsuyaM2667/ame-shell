// 日本語入力(text-input-v3): fcitx5 などの入力メソッドで変換した文字を、ame-shell の入力欄(AI チャット)に入れる。
// 入力欄にキーボードが向いている間だけ有効にする(enable)。変換中の文字(preedit)は下線つきで、確定した文字は
// そのまま入力欄へ。入力メソッドが無い・直接入力のときは、今までどおり wl_keyboard のキーで入る。
const std = @import("std");
const c = @import("../c.zig");
const App = @import("../core/app.zig").App;
const aipanel = @import("../frame/aipanel.zig");

const log = std.log.scoped(.ime);

/// AME_DEBUG のときだけ、入力メソッドとのやりとりをログに出す(日本語が入らないときの切り分け用)
fn dbg(comptime f: []const u8, args: anytype) void {
    if (std.posix.getenv("AME_DEBUG") != null) log.info(f, args);
}

const State = struct {
    ti: ?*c.struct_zwp_text_input_v3 = null,
    app: ?*App = null,
    focus: ?*c.struct_wl_surface = null,
    enabled: bool = false,
    commit: [4096]u8 = undefined,
    commit_len: usize = 0,
    pre: [512]u8 = undefined,
    pre_len: usize = 0,
    composing: bool = false,
};

var st: State = .{};

fn ensure(app: *App) ?*c.struct_zwp_text_input_v3 {
    st.app = app;
    if (st.ti) |t| return t;
    const mgr = app.ti_mgr orelse return null;
    const seat = app.seat orelse return null;
    st.ti = c.zwp_text_input_manager_v3_get_text_input(mgr, seat);
    if (st.ti) |t| _ = c.zwp_text_input_v3_add_listener(t, &listener, null);
    return st.ti;
}

/// 入力欄を使う場面か(AI チャットを開いていて、文字を入れる画面)
fn wanted(app: *App) bool {
    const f = app.activeFrame() orelse return false;
    return f.aiOpen() and aipanel.wantsText() and st.focus != null and st.focus == f.surf.wl;
}

/// 状態が変わったとき(パネルの開閉・画面の切り替え・キーボードの行き先)に呼ぶ
pub fn update(app: *App) void {
    const t = ensure(app) orelse return;
    const want = wanted(app);
    if (want == st.enabled) return;
    st.enabled = want;
    dbg("{s}(入力欄にキーボード: {})", .{ if (want) "enable" else "disable", st.focus != null });
    if (want) {
        c.zwp_text_input_v3_enable(t);
        c.zwp_text_input_v3_set_content_type(t, c.ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE, c.ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
        sendRect(app, t);
    } else {
        c.zwp_text_input_v3_disable(t);
        aipanel.setPreedit("");
    }
    c.zwp_text_input_v3_commit(t);
    _ = c.wl_display_flush(app.display);
}

/// 変換候補の窓を入力位置に出してもらう(開き切った位置で計算する)
fn sendRect(app: *App, t: *c.struct_zwp_text_input_v3) void {
    const f = app.activeFrame() orelse return;
    const r = aipanel.caretRect(f);
    c.zwp_text_input_v3_set_cursor_rectangle(t, r[0], r[1], r[2], r[3]);
}

fn tiEnter(_: ?*anyopaque, _: ?*c.struct_zwp_text_input_v3, surf: ?*c.struct_wl_surface) callconv(.C) void {
    dbg("enter", .{});
    st.focus = surf;
    st.enabled = false; // 入り直したら、もう一度 enable を送る
    if (st.app) |a| update(a);
}

fn tiLeave(_: ?*anyopaque, t: ?*c.struct_zwp_text_input_v3, _: ?*c.struct_wl_surface) callconv(.C) void {
    dbg("leave", .{});
    st.focus = null;
    if (st.enabled) {
        c.zwp_text_input_v3_disable(t);
        c.zwp_text_input_v3_commit(t);
        st.enabled = false;
    }
    aipanel.setPreedit("");
}

/// max バイトに収まる s の先頭の長さ(UTF-8 の文字の途中で切らない)
fn fit(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return n;
}

test "fit は文字の途中で切らない" {
    try std.testing.expectEqual(@as(usize, 3), fit("あい", 5));
    try std.testing.expectEqual(@as(usize, 6), fit("あい", 6));
    try std.testing.expectEqual(@as(usize, 2), fit("ab", 8));
}

fn tiPreedit(_: ?*anyopaque, _: ?*c.struct_zwp_text_input_v3, text: [*c]const u8, _: i32, _: i32) callconv(.C) void {
    const s: []const u8 = if (text != null) std.mem.span(text) else "";
    const n = fit(s, st.pre.len);
    @memcpy(st.pre[0..n], s[0..n]);
    st.pre_len = n;
}

fn tiCommit(_: ?*anyopaque, _: ?*c.struct_zwp_text_input_v3, text: [*c]const u8) callconv(.C) void {
    const s: []const u8 = if (text != null) std.mem.span(text) else "";
    const n = fit(s, st.commit.len - st.commit_len);
    @memcpy(st.commit[st.commit_len .. st.commit_len + n], s[0..n]);
    st.commit_len += n;
}

fn tiDelete(_: ?*anyopaque, _: ?*c.struct_zwp_text_input_v3, _: u32, _: u32) callconv(.C) void {}

fn tiDone(_: ?*anyopaque, _: ?*c.struct_zwp_text_input_v3, _: u32) callconv(.C) void {
    dbg("done: 確定 \"{s}\" 変換中 \"{s}\"", .{ st.commit[0..st.commit_len], st.pre[0..st.pre_len] });
    if (st.commit_len > 0) {
        aipanel.insert(st.commit[0..st.commit_len]);
        st.commit_len = 0;
    }
    // 変換を始めたとき: 今の入力位置を伝え直す(文字が増えて位置が動くため)
    if (st.pre_len > 0 and !st.composing) {
        if (st.ti) |t| if (st.app) |a| {
            sendRect(a, t);
            c.zwp_text_input_v3_commit(t);
        };
    }
    st.composing = st.pre_len > 0;
    aipanel.setPreedit(st.pre[0..st.pre_len]);
    st.pre_len = 0;
}

const listener = c.struct_zwp_text_input_v3_listener{
    .enter = tiEnter,
    .leave = tiLeave,
    .preedit_string = tiPreedit,
    .commit_string = tiCommit,
    .delete_surrounding_text = tiDelete,
    .done = tiDone,
};
