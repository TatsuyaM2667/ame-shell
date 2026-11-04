// AI チャットのパネル(枠の右辺、通知センターと同じ場所から生えるドロワー)。送受信は ../ai.zig。
//   チャット … 会話(届いた分から表示)・入力欄(Enter で送信 / Shift+Enter で改行 / Ctrl+V で貼り付け)
//   会社     … 一覧から選ぶ(キーの有無を表示)
//   モデル   … その会社の /models から取った一覧(入力で絞り込み。一覧に無い名前も Enter で使える)
//   キー     … API キーを貼り付けて保存(~/.config/ame-shell/ai-keys、0600)
const std = @import("std");
const c = @import("../c.zig");
const anim = @import("../anim.zig");
const Color = anim.Color;
const gfx = @import("../gfx.zig");
const textmod = @import("../text.zig");
const theme = @import("../theme.zig");
const surface = @import("../surface.zig");
const loop = @import("../platform/loop.zig");
const ai = @import("../ai.zig");
const agent = @import("../agent.zig");
const mcp = @import("../mcp.zig");
const Frame = @import("frame.zig").Frame;

pub const W: f32 = 440;

const SIZE: f32 = 13.5;
const LH: f32 = 21;
const PAD: f32 = 20;
/// 会話の欄の上端(見出し・会社の名前・MCP と許可の行の下)
const TOP: f32 = 128;
const MAX_INPUT_LINES = 6;
/// ツールの実行の表示: 見出し + 出力の最初の数行 / 端末の出力: 最後の数行
const TOOL_LINES = 8;
const MONO_LINES = 40;
const TLH: f32 = 18;

const Mode = enum { chat, providers, models, key, folder, sessions, mcp };

const HitId = enum { pick, new_chat, close, send, stop, copy, prov, back, model, use_typed, key_edit, key_save, key_delete, refresh, agent, folder, use_folder, session, mcp_open, mcp_toggle, mcp_reload, perm };
const Hit = struct { x: f32, y: f32, w: f32, h: f32, id: HitId, arg: usize = 0 };

const State = struct {
    mode: Mode = .chat,
    input: [16384]u8 = undefined,
    input_len: usize = 0,
    filter: [160]u8 = undefined,
    filter_len: usize = 0,
    keybuf: [512]u8 = undefined,
    key_len: usize = 0,
    /// 下からのスクロール量(0 = いちばん下に付いていく)
    scroll: f32 = 0,
    list_scroll: f32 = 0,
    sel: usize = 0,
    /// キーで選んだ行が見えるようにスクロールする(ホイールで動かしたら止める)
    follow: bool = true,
    pick: usize = 0,
    hover: i32 = -1,
    hits: [96]Hit = undefined,
    n_hits: usize = 0,
    copied: usize = std.math.maxInt(usize),
    copied_ms: u64 = 0,
    status: [200]u8 = undefined,
    status_len: usize = 0,
    /// 日本語入力の変換中の文字(text-input-v3)
    preedit: [512]u8 = undefined,
    preedit_len: usize = 0,
    frame: ?*Frame = null,
    input_lines: std.ArrayList(ai.Line) = undefined,
    input_lines_ok: bool = false,
    /// 入力位置(パネルの中の座標。変換候補の窓を出す位置)
    caret: [2]f32 = .{ 30, 600 },
    /// フォルダ・会話の一覧(選ぶ画面を開いたとき・入力が変わったときに作り直す)
    list_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.c_allocator),
    folders: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(std.heap.c_allocator),
    sessions: std.ArrayList(agent.SessionInfo) = std.ArrayList(agent.SessionInfo).init(std.heap.c_allocator),
    /// フォルダの入力欄(filter とは別に持つ)
    path: [1024]u8 = undefined,
    path_len: usize = 0,
    /// 選んでいる途中のフォルダ
    folder: [1024]u8 = undefined,
    folder_len: usize = 0,
};

var st: State = .{};

pub fn onOpen(f: *Frame) void {
    ai.ensure(f.app);
    @import("../clipboard.zig").prepare(f.app);
    @import("../ime.zig").update(f.app);
    st.frame = f;
    st.mode = .chat;
    st.scroll = 0;
    st.preedit_len = 0;
}

fn addHit(x: f32, y: f32, w: f32, h: f32, id: HitId, arg: usize) void {
    if (st.n_hits >= st.hits.len) return;
    st.hits[st.n_hits] = .{ .x = x, .y = y, .w = w, .h = h, .id = id, .arg = arg };
    st.n_hits += 1;
}

fn hitAt(x: f32, y: f32) ?Hit {
    var i = st.n_hits;
    while (i > 0) {
        i -= 1;
        const h = st.hits[i];
        if (x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h) return h;
    }
    return null;
}

fn hovered(id: HitId, arg: usize) bool {
    if (st.hover < 0) return false;
    const h = st.hits[@intCast(st.hover)];
    return h.id == id and h.arg == arg;
}

// ---------------------------------------------------------------------------
// 折り返し(簡単な Markdown: ``` のコード・# 見出し・- 箇条書き・> 引用・**太字** の記号は消す)
// ---------------------------------------------------------------------------

fn wrapInto(cv: *gfx.Canvas, txt: []const u8, a: usize, b: usize, max_w: f32, bold: bool, kind: ai.Line.Kind, cont: ai.Line.Kind, out: *std.ArrayList(ai.Line), max_seen: *f32) void {
    const k = SIZE / textmod.BASE_PX;
    if (a >= b) {
        out.append(.{ .a = @intCast(a), .b = @intCast(a), .kind = kind }) catch {};
        return;
    }
    const s = txt[a..b];
    const shaped = cv.fonts.shape(s, bold);
    var ls: usize = 0;
    var lx: f32 = 0;
    var brk: ?usize = null;
    var bx: f32 = 0;
    var first = true;
    const code = kind == .code;
    for (shaped.glyphs) |g| {
        const cl: usize = g.cluster;
        if (cl > ls and cl < s.len) {
            const prev = s[cl - 1];
            if (!code and (prev == ' ' or (s[cl] >= 0xE3 and s[cl] <= 0xE9))) {
                brk = cl;
                bx = g.x;
            }
        }
        if ((g.x + g.glyph.left + g.glyph.w - lx) * k > max_w and cl > ls) {
            const bb = brk orelse cl;
            const nx = if (brk != null) bx else g.x;
            out.append(.{ .a = @intCast(a + ls), .b = @intCast(a + bb), .kind = if (first) kind else cont }) catch {};
            max_seen.* = @max(max_seen.*, (nx - lx) * k);
            first = false;
            ls = bb;
            lx = nx;
            brk = null;
        }
    }
    out.append(.{ .a = @intCast(a + ls), .b = @intCast(b), .kind = if (first) kind else cont }) catch {};
    max_seen.* = @max(max_seen.*, (shaped.width - lx) * k);
}

fn layoutPara(cv: *gfx.Canvas, txt: []const u8, a: usize, b: usize, w: f32, code: *bool, md: bool, out: *std.ArrayList(ai.Line), max_seen: *f32) void {
    const para = txt[a..b];
    if (!md) return wrapInto(cv, txt, a, b, w, false, .plain, .plain, out, max_seen);
    const lead = para.len - std.mem.trimLeft(u8, para, " ").len;
    const t = para[lead..];
    if (std.mem.startsWith(u8, t, "```")) {
        code.* = !code.*;
        return;
    }
    if (code.*) return wrapInto(cv, txt, a, b, w - 16, false, .code, .code, out, max_seen);
    var hashes: usize = 0;
    while (hashes < t.len and t[hashes] == '#') hashes += 1;
    if (hashes > 0 and hashes <= 6 and hashes < t.len and t[hashes] == ' ')
        return wrapInto(cv, txt, a + lead + hashes + 1, b, w, true, .head, .head, out, max_seen);
    if (std.mem.startsWith(u8, t, "- ") or std.mem.startsWith(u8, t, "* ") or std.mem.startsWith(u8, t, "+ "))
        return wrapInto(cv, txt, a + lead + 2, b, w - 16 - @as(f32, @floatFromInt(@min(lead, 8))) * 4, false, .bullet, .bullet_cont, out, max_seen);
    if (std.mem.startsWith(u8, t, "> "))
        return wrapInto(cv, txt, a + lead + 2, b, w - 14, false, .quote, .quote, out, max_seen);
    if (std.mem.eql(u8, std.mem.trim(u8, t, " "), "---")) {
        out.append(.{ .a = @intCast(a), .b = @intCast(a), .kind = .plain }) catch {};
        return;
    }
    wrapInto(cv, txt, a, b, w, false, .plain, .plain, out, max_seen);
}

/// 文章のレイアウトを作る(文字が増えただけなら、最後の段落から作り直す)
fn layout(cv: *gfx.Canvas, m: *ai.Msg, w: f32) void {
    const txt = m.text.items;
    const md = m.role == .assistant and !m.err and !m.mono;
    if (m.lay_w != w) {
        m.lines.clearRetainingCapacity();
        m.lay_w = w;
        m.lay_para = 0;
        m.lay_code = false;
        m.lay_max = 0;
        m.lay_lines_before = 0;
        m.lay_max_before = 0;
    } else if (m.lay_len == txt.len) {
        return;
    } else {
        m.lines.shrinkRetainingCapacity(m.lay_lines_before);
        m.lay_max = m.lay_max_before;
    }
    var code = m.lay_code;
    var i = @min(m.lay_para, txt.len);
    while (true) {
        const e = std.mem.indexOfScalarPos(u8, txt, i, '\n') orelse txt.len;
        if (e == txt.len) {
            m.lay_para = i;
            m.lay_code = code;
            m.lay_lines_before = m.lines.items.len;
            m.lay_max_before = m.lay_max;
        }
        layoutPara(cv, txt, i, e, w, &code, md, &m.lines, &m.lay_max);
        if (e >= txt.len) break;
        i = e + 1;
    }
    m.lay_len = txt.len;
}

/// **太字** の記号を除いて描く
fn drawLine(cv: *gfx.Canvas, x: f32, y: f32, col: Color, s: []const u8, bold: bool) void {
    var buf: [2048]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    const t = std.mem.trim(u8, s, " ");
    while (i < t.len and n < buf.len) {
        if (i + 1 < t.len and t[i] == '*' and t[i + 1] == '*') {
            i += 2;
            continue;
        }
        buf[n] = t[i];
        n += 1;
        i += 1;
    }
    _ = cv.text(x, y, SIZE, col, buf[0..n], .{ .bold = bold });
}

fn msgHeight(m: *const ai.Msg, last: bool) f32 {
    const n: f32 = @floatFromInt(@max(m.lines.items.len, 1));
    if (m.role == .user) return n * LH + 20;
    if (m.role == .tool) return @as(f32, @floatFromInt(@min(@max(m.lines.items.len, 1), TOOL_LINES))) * TLH + 12;
    if (m.mono) return @as(f32, @floatFromInt(@min(@max(m.lines.items.len, 1), MONO_LINES))) * TLH + 12;
    var h = n * LH;
    if (m.text.items.len == 0) h = LH; // 考え中の表示
    if (m.text.items.len == 0 and m.think.items.len > 0) h += 3 * 18;
    if (!(last and busy()) and m.text.items.len > 0 and !m.err) h += 24; // コピー
    return h;
}

// ---------------------------------------------------------------------------
// 描画
// ---------------------------------------------------------------------------

pub fn draw(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, dt: f32) bool {
    _ = dt;
    ai.ensure(f.app);
    st.frame = f;
    st.n_hits = 0;
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const base_clip = cv.clip;
    agent.ensure(app);
    mcp.ensure(app);
    var animating = busy() or ai.modelsBusy();

    // ---- 見出し ----
    // ame-ctl から CLI を切り替えたときなど: 会話の画面にいれば、そのまま
    if (st.mode == .chat) {
        _ = cv.text(PAD + 2, 38, 18, acc.lighten(0.25), if (usingAgent()) "\u{F018D}" else "\u{F0674}", .{});
        _ = cv.text(PAD + 30, 37, 16, txt, if (usingAgent()) "コーディング" else "AI チャット", .{ .bold = true });
        // 新しい会話・閉じる
        iconButton(cv, w - PAD - 72, 16, "\u{F0415}", .new_chat, acc, txt);
        iconButton(cv, w - PAD - 32, 16, "\u{F0156}", .close, acc, txt);
        // 会社・モデル / CLI・フォルダ(押すと選び直す)
        const hv: f32 = if (hovered(.pick, 0)) 1 else 0;
        cv.rect(PAD - 4, 54, w - 2 * PAD + 8, 32, 16, Color.hex(0xffffff).alpha(0.06 + 0.06 * hv));
        var nb: [1400]u8 = undefined;
        var label: []const u8 = "";
        if (usingAgent()) {
            const ai_i = agent.current();
            cv.rect(PAD + 8, 66, 8, 8, 4, if (agent.installed(ai_i)) acc.lighten(0.2) else theme.danger(app));
            var pb: [1100]u8 = undefined;
            label = std.fmt.bufPrint(&nb, "{s} · {s}", .{ agent.name(ai_i), agent.displayPath(agent.cwd(), &pb) }) catch "";
        } else {
            const i = ai.current();
            const has = !ai.providers[i].need_key or ai.hasKey(i);
            cv.rect(PAD + 8, 66, 8, 8, 4, if (has) acc.lighten(0.2) else theme.danger(app));
            label = std.fmt.bufPrint(&nb, "{s} · {s}", .{ ai.providers[i].name, ai.model(i) }) catch "";
        }
        _ = cv.text(PAD + 24, 75, 13, txt, label, .{ .max_w = w - 2 * PAD - 54 });
        _ = cv.text(w - PAD - 12, 76, 14, sub, "\u{F0140}", .{ .alignment = .center });
        addHit(PAD - 4, 54, w - 2 * PAD + 8, 32, .pick, 0);
        // MCP と、CLI の許可
        var x: f32 = PAD - 4;
        {
            var mb: [64]u8 = undefined;
            const n = mcp.enabledCount();
            const ml = if (n > 0) std.fmt.bufPrint(&mb, "\u{F06A5} MCP {d}", .{n}) catch "MCP" else "\u{F06A5} MCP";
            x += chip(cv, x, 94, ml, .mcp_open, n > 0, acc, txt, sub) + 6;
        }
        if (usingAgent()) {
            var pb2: [64]u8 = undefined;
            const pl = std.fmt.bufPrint(&pb2, "\u{F0565} {s}", .{agent.perm_short[@intFromEnum(agent.perm())]}) catch "";
            x += chip(cv, x, 94, pl, .perm, agent.perm() == .all, if (agent.perm() == .all) theme.danger(app) else acc, txt, sub) + 6;
        }
        if (drawChat(f, cv, w, h, acc, txt, sub)) animating = true;
    } else {
        const title = switch (st.mode) {
            .providers => "会社・コーディング CLI を選ぶ",
            .models => ai.providers[st.pick].name,
            .key => "API キー",
            .folder => "作業フォルダを選ぶ",
            .sessions => agent.name(st.pick),
            .mcp => "MCP サーバ",
            .chat => unreachable,
        };
        iconButton(cv, PAD - 6, 16, "\u{F0141}", .back, acc, txt);
        _ = cv.text(PAD + 38, 37, 16, txt, title, .{ .bold = true, .max_w = w - PAD * 2 - 40 });
        switch (st.mode) {
            .providers => drawProviders(f, cv, w, h, acc, txt, sub),
            .models => drawModels(f, cv, w, h, acc, txt, sub),
            .key => drawKey(f, cv, w, h, acc, txt, sub),
            .folder => drawFolder(f, cv, w, h, acc, txt, sub),
            .sessions => drawSessions(f, cv, w, h, acc, txt, sub),
            .mcp => drawMcp(f, cv, w, h, acc, txt, sub),
            .chat => unreachable,
        }
    }
    cv.clip = base_clip;
    if (st.copied != std.math.maxInt(usize)) {
        if (loop.nowMs() -| st.copied_ms < 1500) animating = true else st.copied = std.math.maxInt(usize);
    }
    return animating;
}

fn iconButton(cv: *gfx.Canvas, x: f32, y: f32, icon: []const u8, id: HitId, acc: Color, txt: Color) void {
    const hv: f32 = if (hovered(id, 0)) 1 else 0;
    cv.rect(x, y, 30, 30, 15, acc.alpha(0.08 + 0.18 * hv));
    _ = cv.text(x + 15, y + 21, 16, txt, icon, .{ .alignment = .center });
    addHit(x, y, 30, 30, id, 0);
}

fn drawChat(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, acc: Color, txt: Color, sub: Color) bool {
    const app = f.app;
    var animating = false;
    // ---- 入力欄(下) ----
    if (!st.input_lines_ok) {
        st.input_lines = std.ArrayList(ai.Line).init(app.alloc);
        st.input_lines_ok = true;
    }
    st.input_lines.clearRetainingCapacity();
    const in_w = w - 2 * PAD - 54;
    var code = false;
    var mx: f32 = 0;
    {
        const s = st.input[0..st.input_len];
        var i: usize = 0;
        while (true) {
            const e = std.mem.indexOfScalarPos(u8, s, i, '\n') orelse s.len;
            layoutPara(cv, s, i, e, in_w, &code, false, &st.input_lines, &mx);
            if (e >= s.len) break;
            i = e + 1;
        }
    }
    const nl = st.input_lines.items.len;
    const shown = @min(nl, MAX_INPUT_LINES);
    const ih = @as(f32, @floatFromInt(shown)) * LH + 22;
    const iy = h - 18 - ih;
    cv.rect(PAD - 4, iy, w - 2 * PAD + 8, ih, 18, Color.hex(0x000000).alpha(0.28));
    cv.rectBorder(PAD - 4, iy, w - 2 * PAD + 8, ih, 18, .{ .a = 0 }, acc.alpha(0.45), 1);
    const tx = PAD + 10;
    var ly = iy + 11 + 15;
    if (st.input_len == 0 and st.preedit_len == 0) {
        _ = cv.text(tx + 5, ly, SIZE, sub.alpha(0.75), if (usingAgent()) "頼みごと(Enter で送信・Shift+Enter で改行)" else "メッセージ(Enter で送信・Shift+Enter で改行)", .{ .max_w = in_w });
    }
    const first = nl - shown;
    var end_x: f32 = tx;
    for (st.input_lines.items[first..], 0..) |l, j| {
        const s = st.input[l.a..l.b];
        const wdt = cv.text(tx, ly, SIZE, txt, s, .{});
        if (first + j + 1 == nl) end_x = tx + wdt;
        if (first + j + 1 < nl) ly += LH;
    }
    // 変換中の文字(下線)と、入力の位置
    if (st.preedit_len > 0) {
        const pw = cv.text(end_x, ly, SIZE, acc.lighten(0.3), st.preedit[0..st.preedit_len], .{});
        cv.rect(end_x, ly + 4, pw, 1.5, 0.75, acc.lighten(0.3));
        end_x += pw;
    }
    cv.rect(end_x + 1, ly - 13, 1.5, 17, 0.75, acc.lighten(0.2));
    st.caret = .{ end_x, ly };
    // 送信 / 止める
    const bx = w - PAD - 38;
    const by = iy + ih - 39;
    if (busy()) {
        const hv: f32 = if (hovered(.stop, 0)) 1 else 0;
        cv.rect(bx, by, 34, 34, 17, theme.danger(app).alpha(0.55 + 0.3 * hv));
        _ = cv.text(bx + 17, by + 23, 15, Color.hex(0xffffff), "\u{F04DB}", .{ .alignment = .center });
        addHit(bx, by, 34, 34, .stop, 0);
    } else {
        const can = st.input_len > 0;
        const hv: f32 = if (hovered(.send, 0)) 1 else 0;
        if (can) cv.rectGrad(bx, by, 34, 34, 17, acc.lighten(0.3 + 0.1 * hv), acc) else cv.rect(bx, by, 34, 34, 17, Color.hex(0xffffff).alpha(0.08));
        _ = cv.text(bx + 18, by + 23, 15, if (can) Color.hex(0x08101e) else sub, "\u{F048A}", .{ .alignment = .center });
        addHit(bx, by, 34, 34, .send, 0);
    }

    // ---- 状態(作業中・終わった・費用)----
    const stt = statusText();
    if (stt.len > 0) _ = cv.text(PAD, iy - 10, 11.5, sub, stt, .{ .max_w = w - 2 * PAD });
    // ---- 会話 ----
    const top = TOP;
    const bottom = iy - (if (stt.len > 0) @as(f32, 26) else 10);
    const area_h = bottom - top;
    const msgs = messages();
    // 最後が返事の欄でない(CLI の作業中)ときは、最後に「…」を出す
    const tail_dots = busy() and (msgs.len == 0 or msgs[msgs.len - 1].role != .assistant or msgs[msgs.len - 1].text.items.len > 0);
    const aw = w - 2 * PAD;
    const uw = aw * 0.82 - 24;
    var total: f32 = 0;
    for (msgs, 0..) |m, i| {
        layout(cv, m, if (m.role == .user) uw else if (m.role == .tool or m.mono) aw - 20 else aw);
        total += msgHeight(m, i + 1 == msgs.len) + 14;
    }
    if (tail_dots) total += LH;
    if (msgs.len == 0 and usingAgent()) {
        const cy = top + area_h * 0.34;
        _ = cv.text(w / 2, cy, 40, acc.lighten(0.25).alpha(0.8), "\u{F018D}", .{ .alignment = .center });
        var pb: [1100]u8 = undefined;
        var hb: [1300]u8 = undefined;
        _ = cv.text(w / 2, cy + 44, 15, txt, std.fmt.bufPrint(&hb, "{s} に頼む", .{agent.name(agent.current())}) catch "", .{ .bold = true, .alignment = .center, .max_w = w - 40 });
        _ = cv.text(w / 2, cy + 68, 12.5, sub, agent.displayPath(agent.cwd(), &pb), .{ .alignment = .center, .max_w = w - 40 });
        if (!agent.installed(agent.current())) {
            _ = cv.text(w / 2, cy + 94, 12.5, theme.danger(app).lighten(0.25), "この CLI は入っていません(PATH に見つかりません)", .{ .alignment = .center, .max_w = w - 40 });
        } else _ = cv.text(w / 2, cy + 94, 12, sub, "作業の様子(ツールの実行・結果)もここに出ます", .{ .alignment = .center, .max_w = w - 40 });
        if (tail_dots) animating = true;
        return animating;
    }
    if (msgs.len == 0) {
        const cy = top + area_h * 0.38;
        _ = cv.text(w / 2, cy, 40, acc.lighten(0.25).alpha(0.8), "\u{F0674}", .{ .alignment = .center });
        _ = cv.text(w / 2, cy + 44, 15, txt, "何でも聞いてください", .{ .bold = true, .alignment = .center });
        const i = ai.current();
        if (ai.providers[i].need_key and !ai.hasKey(i)) {
            _ = cv.text(w / 2, cy + 70, 12.5, theme.danger(app).lighten(0.25), "API キーが未設定です。上の名前を押して設定してください", .{ .alignment = .center, .max_w = w - 40 });
        } else _ = cv.text(w / 2, cy + 70, 12.5, sub, "会社とモデルは上の名前から選べます", .{ .alignment = .center });
        return animating;
    }
    const max_scroll = @max(0, total - area_h);
    st.scroll = std.math.clamp(st.scroll, 0, max_scroll);
    var y = if (total <= area_h) top else bottom - total + st.scroll;
    cv.setClip(0, top - 6, w, area_h + 6);
    for (msgs, 0..) |m, mi| {
        const last = mi + 1 == msgs.len;
        const mh = msgHeight(m, last);
        defer y += mh + 14;
        if (y + mh < top - 10 or y > bottom + 10) continue;
        if (m.role == .user) {
            const bw = @min(m.lay_max + 24, aw * 0.82);
            const x0 = w - PAD - bw;
            cv.rectGrad(x0, y, bw, mh, 16, acc.alpha(0.42), acc.alpha(0.3));
            for (m.lines.items, 0..) |l, li| {
                const ty = y + 10 + 15 + @as(f32, @floatFromInt(li)) * LH;
                if (ty < top - LH or ty > bottom + LH) continue;
                _ = cv.text(x0 + 12, ty, SIZE, txt, std.mem.trim(u8, m.text.items[l.a..l.b], " "), .{});
            }
            continue;
        }
        // ツールの実行(見出し + 出力の最初の数行)/ 端末の出力(最後の数行)
        if (m.role == .tool or m.mono) {
            const is_tool = m.role == .tool;
            const failed = m.err or m.call_failed;
            cv.rect(PAD - 4, y, aw + 8, mh, 12, Color.hex(0x000000).alpha(if (is_tool) 0.22 else 0.32));
            if (is_tool) cv.rect(PAD - 4, y + 6, 3, mh - 12, 1.5, if (failed) theme.danger(app) else acc.alpha(0.7));
            const n = m.lines.items.len;
            const lim: usize = if (is_tool) TOOL_LINES else MONO_LINES;
            const from: usize = if (is_tool or n <= lim) 0 else n - lim;
            const to: usize = @min(n, from + lim);
            const running = is_tool and m.call_id.items.len > 0 and !m.call_done;
            for (m.lines.items[from..to], 0..) |l, li| {
                const ty = y + 6 + 13 + @as(f32, @floatFromInt(li)) * TLH;
                if (ty < top - TLH or ty > bottom + TLH) continue;
                const s = std.mem.trimRight(u8, m.text.items[l.a..l.b], " ");
                const head = is_tool and l.a == 0;
                const col = if (head) (if (failed) theme.danger(app).lighten(0.3) else acc.lighten(0.35)) else Color.mix(sub, txt, 0.35);
                _ = cv.text(PAD + 8, ty, if (head) 12.5 else 12, col, s, .{ .bold = head, .max_w = aw - 12 });
            }
            if (running) {
                animating = true;
                const t = @as(f32, @floatFromInt(loop.nowMs() % 1000)) / 1000.0;
                cv.rect(w - PAD - 14, y + 10, 8, 8, 4, acc.lighten(0.3).alpha(0.3 + 0.7 * @abs(@sin(t * std.math.pi))));
            }
            if (n > to) _ = cv.text(w - PAD - 2, y + mh - 6, 10.5, sub, "…", .{ .alignment = .right });
            continue;
        }
        // 返事
        if (m.text.items.len == 0 and !m.err) {
            // 届くまでの「…」と、考えている途中の文章(最後の 3 行)
            const t = @as(f32, @floatFromInt(loop.nowMs() % 1200)) / 1200.0;
            for (0..3) |k| {
                const ph = @mod(t - @as(f32, @floatFromInt(k)) * 0.18, 1.0);
                const a = 0.35 + 0.65 * @max(0, 1 - @abs(ph - 0.3) * 3);
                cv.rect(PAD + 2 + @as(f32, @floatFromInt(k)) * 14, y + 8, 8, 8, 4, acc.lighten(0.3).alpha(a));
            }
            if (busy()) animating = true;
            if (m.think.items.len > 0) {
                _ = cv.text(PAD + 52, y + 16, 12, sub, "考えています…", .{});
                drawThinkTail(cv, m.think.items, PAD, y + LH + 12, aw, sub);
            }
            continue;
        }
        const col = if (m.err) theme.danger(app).lighten(0.3) else txt;
        var in_code_start: ?f32 = null;
        for (m.lines.items, 0..) |l, li| {
            const ly0 = y + @as(f32, @floatFromInt(li)) * LH;
            const ty = ly0 + 15;
            if (l.kind == .code) {
                if (in_code_start == null) in_code_start = ly0;
                cv.rect(PAD, ly0, aw, LH, 0, Color.hex(0x000000).alpha(0.3));
            } else in_code_start = null;
            if (ty < top - LH or ty > bottom + LH) continue;
            const s = m.text.items[l.a..l.b];
            switch (l.kind) {
                .plain => drawLine(cv, PAD, ty, col, s, false),
                .head => drawLine(cv, PAD, ty, acc.lighten(0.35), s, true),
                .bullet => {
                    _ = cv.text(PAD + 3, ty, SIZE, acc.lighten(0.3), "•", .{});
                    drawLine(cv, PAD + 16, ty, col, s, false);
                },
                .bullet_cont => drawLine(cv, PAD + 16, ty, col, s, false),
                .quote => {
                    cv.rect(PAD + 2, ly0 + 2, 3, LH - 4, 1.5, acc.alpha(0.6));
                    drawLine(cv, PAD + 14, ty, sub, s, false);
                },
                .code => _ = cv.text(PAD + 8, ty, SIZE - 1, Color.mix(txt, acc.lighten(0.5), 0.25), s, .{}),
            }
        }
        if (!(last and busy()) and m.text.items.len > 0 and !m.err) {
            const cy = y + mh - 20;
            const done = st.copied == mi;
            const hv = hovered(.copy, mi);
            const lbl = if (done) "\u{F012C} コピーしました" else "\u{F018F} コピー";
            const cw = cv.measure(lbl, 11.5, false) + 16;
            cv.rect(PAD - 4, cy, cw, 20, 10, Color.hex(0xffffff).alpha(if (hv) 0.12 else 0.04));
            _ = cv.text(PAD + 4, cy + 14, 11.5, if (done) acc.lighten(0.3) else sub, lbl, .{});
            addHit(PAD - 4, cy, cw, 20, .copy, mi);
        }
    }
    if (tail_dots) {
        animating = true;
        const t = @as(f32, @floatFromInt(loop.nowMs() % 1200)) / 1200.0;
        for (0..3) |k| {
            const ph = @mod(t - @as(f32, @floatFromInt(k)) * 0.18, 1.0);
            const a = 0.35 + 0.65 * @max(0, 1 - @abs(ph - 0.3) * 3);
            cv.rect(PAD + 2 + @as(f32, @floatFromInt(k)) * 14, y + 6, 8, 8, 4, acc.lighten(0.3).alpha(a));
        }
    }
    cv.setClip(0, 0, w, h);
    if (st.scroll > 1) {
        // 下に続きがある印
        cv.rectGrad(0, bottom - 18, w, 18, 0, Color.hex(0x000000).alpha(0), Color.hex(0x000000).alpha(0.25));
    }
    return animating;
}

fn drawThinkTail(cv: *gfx.Canvas, think: []const u8, x: f32, y: f32, w: f32, sub: Color) void {
    // 最後の 3 行ぶん(おおよそ)を薄く
    const tail = if (think.len > 400) think[think.len - 400 ..] else think;
    var start: usize = 0;
    while (start < tail.len and (tail[start] & 0xC0) == 0x80) start += 1;
    var flat: [420]u8 = undefined;
    var n: usize = 0;
    for (tail[start..]) |ch| {
        if (n >= flat.len) break;
        flat[n] = if (ch == '\n') ' ' else ch;
        n += 1;
    }
    var ranges: [8][2]usize = undefined;
    const s = flat[0..n];
    const lines = gfx.wrapRanges(cv, s, 12, w, 8, &ranges);
    const from = if (lines > 3) lines - 3 else 0;
    for (ranges[from..lines], 0..) |r, i| {
        _ = cv.text(x, y + @as(f32, @floatFromInt(i)) * 18, 12, sub.alpha(0.7), std.mem.trim(u8, s[r[0]..r[1]], " "), .{ .max_w = w + 12 });
    }
}

fn drawField(cv: *gfx.Canvas, x: f32, y: f32, w: f32, s: []const u8, placeholder: []const u8, acc: Color, txt: Color, sub: Color) void {
    cv.rect(x, y, w, 36, 12, Color.hex(0x000000).alpha(0.3));
    cv.rectBorder(x, y, w, 36, 12, .{ .a = 0 }, acc.alpha(0.55), 1);
    if (s.len == 0 and st.preedit_len == 0) {
        _ = cv.text(x + 12, y + 23, 12.5, sub.alpha(0.75), placeholder, .{ .max_w = w - 24 });
        cv.rect(x + 11, y + 10, 1.5, 17, 0.75, acc.lighten(0.2));
        return;
    }
    // 長いときは末尾が見えるように
    var start: usize = 0;
    while (start < s.len and cv.measure(s[start..], 13, false) > w - 30) {
        start += 1;
        while (start < s.len and (s[start] & 0xC0) == 0x80) start += 1;
    }
    var ex = x + 12 + cv.text(x + 12, y + 23, 13, txt, s[start..], .{});
    if (st.preedit_len > 0) {
        const pw = cv.text(ex, y + 23, 13, acc.lighten(0.3), st.preedit[0..st.preedit_len], .{});
        cv.rect(ex, y + 27, pw, 1.5, 0.75, acc.lighten(0.3));
        ex += pw;
    }
    st.caret = .{ ex, y + 23 };
    cv.rect(ex + 1, y + 10, 1.5, 17, 0.75, acc.lighten(0.2));
}

/// 会社の一覧 + コーディング CLI の一覧の、行の位置(見出しの分だけ CLI をずらす)
const PROV_ROW: f32 = 52;
const SECTION_H: f32 = 40;

fn pickRows() usize {
    return ai.providers.len + agent.count();
}

fn pickRowY(k: usize) f32 {
    if (k < ai.providers.len) return @as(f32, @floatFromInt(k)) * PROV_ROW;
    return @as(f32, @floatFromInt(k)) * PROV_ROW + SECTION_H;
}

fn drawProviders(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, acc: Color, txt: Color, sub: Color) void {
    const app = f.app;
    const row = PROV_ROW;
    const top: f32 = 64;
    const list_h = h - top - 16;
    const total = pickRowY(pickRows() - 1) + row;
    // 選択中の行が見えるように
    const sel_y = pickRowY(@min(st.sel, pickRows() - 1));
    if (st.follow) {
        if (sel_y < st.list_scroll) st.list_scroll = sel_y;
        if (sel_y + row > st.list_scroll + list_h) st.list_scroll = sel_y + row - list_h;
    }
    st.list_scroll = std.math.clamp(st.list_scroll, 0, @max(0, total - list_h));
    cv.setClip(0, top, w, list_h);
    const api_cur = !usingAgent();
    for (ai.providers, 0..) |p, i| {
        const y = top + pickRowY(i) - st.list_scroll;
        if (y + row < top or y > top + list_h) continue;
        const cur = api_cur and i == ai.current();
        const hv = hovered(.prov, i) or st.sel == i;
        cv.rect(PAD - 8, y + 3, w - 2 * PAD + 16, row - 6, 14, Color.hex(0xffffff).alpha(if (hv) 0.1 else 0.035));
        if (cur) cv.rect(PAD - 8, y + 3, 4, row - 6, 2, acc);
        _ = cv.text(PAD + 4, y + 23, 14, if (cur) acc.lighten(0.3) else txt, p.name, .{ .bold = cur, .max_w = w - 2 * PAD - 110 });
        _ = cv.text(PAD + 4, y + 41, 11.5, sub, ai.model(i), .{ .max_w = w - 2 * PAD - 110 });
        const has = ai.hasKey(i);
        const tag = if (!p.need_key and !has) "キー不要" else if (has) "\u{F0306} 設定済み" else "キーが必要";
        _ = cv.text(w - PAD - 4, y + 32, 11.5, if (has) acc.lighten(0.25) else if (p.need_key) theme.danger(app).lighten(0.25) else sub, tag, .{ .alignment = .right });
        addHit(PAD - 8, y + 3, w - 2 * PAD + 16, row - 6, .prov, i);
    }
    // ---- コーディング CLI ----
    {
        const y = top + pickRowY(ai.providers.len) - SECTION_H - st.list_scroll;
        _ = cv.text(PAD, y + 28, 12.5, sub, "コーディング CLI(端末の作業をここに映す)", .{ .bold = true, .max_w = w - 2 * PAD });
    }
    for (0..agent.count()) |k| {
        const r = ai.providers.len + k;
        const y = top + pickRowY(r) - st.list_scroll;
        if (y + row < top or y > top + list_h) continue;
        const inst = agent.installed(k);
        const cur = usingAgent() and agent.current() == k;
        const hv = hovered(.agent, k) or st.sel == r;
        cv.rect(PAD - 8, y + 3, w - 2 * PAD + 16, row - 6, 14, Color.hex(0xffffff).alpha(if (hv and inst) 0.1 else 0.035));
        if (cur) cv.rect(PAD - 8, y + 3, 4, row - 6, 2, acc);
        const col = if (!inst) sub.alpha(0.6) else if (cur) acc.lighten(0.3) else txt;
        _ = cv.text(PAD + 4, y + 23, 14, col, agent.name(k), .{ .bold = cur, .max_w = w - 2 * PAD - 110 });
        var pb: [1100]u8 = undefined;
        const sub_l = if (cur) agent.displayPath(agent.cwd(), &pb) else if (inst) "押して作業フォルダを選ぶ" else "入っていません";
        _ = cv.text(PAD + 4, y + 41, 11.5, sub.alpha(if (inst) 1 else 0.6), sub_l, .{ .max_w = w - 2 * PAD - 110 });
        _ = cv.text(w - PAD - 4, y + 32, 11.5, if (inst) acc.lighten(0.25) else sub.alpha(0.6), if (inst) "\u{F012C} 使える" else "未インストール", .{ .alignment = .right });
        addHit(PAD - 8, y + 3, w - 2 * PAD + 16, row - 6, .agent, k);
    }
    cv.setClip(0, 0, w, h);
}

/// 小さなボタン(MCP・許可)。戻り値は幅
fn chip(cv: *gfx.Canvas, x: f32, y: f32, label: []const u8, id: HitId, on: bool, col: Color, txt: Color, sub: Color) f32 {
    const cw = cv.measure(label, 11.5, false) + 20;
    const hv = hovered(id, 0);
    cv.rect(x, y, cw, 24, 12, if (on) col.alpha(if (hv) 0.4 else 0.28) else Color.hex(0xffffff).alpha(if (hv) 0.12 else 0.05));
    _ = cv.text(x + 10, y + 16.5, 11.5, if (on) txt else sub, label, .{});
    addHit(x, y, cw, 24, id, 0);
    return cw;
}

// ---- 作業フォルダ ----

fn pathText() []const u8 {
    return st.path[0..st.path_len];
}

/// ~ を広げる
fn expandPath(p: []const u8, buf: []u8) []const u8 {
    const home = std.posix.getenv("HOME") orelse return p;
    if (std.mem.eql(u8, p, "~")) return home;
    if (std.mem.startsWith(u8, p, "~/")) return std.fmt.bufPrint(buf, "{s}{s}", .{ home, p[1..] }) catch p;
    return p;
}

/// 入力に合わせてフォルダの候補を作り直す: / を含めばその中のフォルダ、そうでなければ最近のフォルダを絞り込み
fn rebuildFolders() void {
    _ = st.list_arena.reset(.retain_capacity);
    st.folders = std.ArrayList([]const u8).init(st.list_arena.allocator());
    const a = st.list_arena.allocator();
    var eb: [1100]u8 = undefined;
    const typed = expandPath(std.mem.trim(u8, pathText(), " "), &eb);
    if (std.mem.indexOfScalar(u8, typed, '/') != null) {
        // 親フォルダの中で、名前が前方一致するフォルダ
        const slash = std.mem.lastIndexOfScalar(u8, typed, '/').?;
        const parent = if (slash == 0) "/" else typed[0..slash];
        const prefix = typed[slash + 1 ..];
        var d = std.fs.cwd().openDir(parent, .{ .iterate = true }) catch return;
        defer d.close();
        var it = d.iterate();
        var names = std.ArrayList([]const u8).init(a);
        while (it.next() catch null) |e| {
            if (e.kind != .directory) continue;
            if (e.name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
            if (!std.mem.startsWith(u8, e.name, prefix)) continue;
            names.append(std.fmt.allocPrint(a, "{s}/{s}", .{ if (slash == 0) "" else parent, e.name }) catch continue) catch {};
            if (names.items.len >= 200) break;
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        st.folders.appendSlice(names.items) catch {};
        return;
    }
    var recent = std.ArrayList(agent.Folder).init(a);
    agent.recentFolders(a, &recent);
    for (recent.items) |r| if (filterMatch(r.path, typed)) st.folders.append(r.path) catch {};
    // 何も無ければホームのフォルダ
    if (st.folders.items.len == 0 and typed.len == 0) if (std.posix.getenv("HOME")) |home| {
        st.folders.append(a.dupe(u8, home) catch return) catch {};
    };
}

fn drawFolder(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, acc: Color, txt: Color, sub: Color) void {
    _ = f;
    _ = cv.text(PAD, 76, 12, sub, "フォルダのパスを入れる(~/ と Tab で補完)か、下から選ぶ", .{ .max_w = w - 2 * PAD });
    drawField(cv, PAD - 4, 88, w - 2 * PAD + 8, pathText(), "~/projects/…", acc, txt, sub);
    const top: f32 = 136;
    const row: f32 = 36;
    const list_h = h - top - 16;
    const n = st.folders.items.len;
    const total = row * @as(f32, @floatFromInt(n));
    const sel_y = @as(f32, @floatFromInt(st.sel)) * row;
    if (st.follow) {
        if (sel_y < st.list_scroll) st.list_scroll = sel_y;
        if (sel_y + row > st.list_scroll + list_h) st.list_scroll = sel_y + row - list_h;
    }
    st.list_scroll = std.math.clamp(st.list_scroll, 0, @max(0, total - list_h));
    cv.setClip(0, top, w, list_h);
    if (n == 0) _ = cv.text(w / 2, top + 30, 12.5, sub, "見つかりません(Enter で入力したフォルダを使う)", .{ .alignment = .center, .max_w = w - 40 });
    for (st.folders.items, 0..) |p, i| {
        const y = top + @as(f32, @floatFromInt(i)) * row - st.list_scroll;
        if (y + row < top or y > top + list_h) continue;
        const hv = hovered(.folder, i) or st.sel == i;
        cv.rect(PAD - 8, y + 2, w - 2 * PAD + 16, row - 4, 12, Color.hex(0xffffff).alpha(if (hv) 0.1 else 0.03));
        var pb: [1100]u8 = undefined;
        _ = cv.text(PAD + 4, y + 23, 13, txt, "\u{F024B}", .{});
        _ = cv.text(PAD + 28, y + 23, 13, txt, agent.shortPath(p, &pb), .{ .max_w = w - 2 * PAD - 36 });
        addHit(PAD - 8, y + 2, w - 2 * PAD + 16, row - 4, .folder, i);
    }
    cv.setClip(0, 0, w, h);
}

// ---- 会話を選ぶ(新しく / 前回の続き / Claude Code の記録から)----

fn sessionRows() usize {
    return 1 + @as(usize, @intFromBool(agent.canContinue(st.pick) and !agent.canResumeList(st.pick))) + st.sessions.items.len;
}

fn rebuildSessions() void {
    _ = st.list_arena.reset(.retain_capacity);
    st.sessions = std.ArrayList(agent.SessionInfo).init(st.list_arena.allocator());
    st.folders = std.ArrayList([]const u8).init(st.list_arena.allocator());
    if (agent.canResumeList(st.pick)) agent.listSessions(st.list_arena.allocator(), st.folder[0..st.folder_len], &st.sessions);
}

fn ago(mtime: i128, buf: []u8) []const u8 {
    const now = std.time.nanoTimestamp();
    const s: i64 = @intCast(@divTrunc(@max(0, now - mtime), std.time.ns_per_s));
    if (s < 60) return "いま";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d} 分前", .{@divTrunc(s, 60)}) catch "";
    if (s < 86400) return std.fmt.bufPrint(buf, "{d} 時間前", .{@divTrunc(s, 3600)}) catch "";
    return std.fmt.bufPrint(buf, "{d} 日前", .{@divTrunc(s, 86400)}) catch "";
}

fn drawSessions(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, acc: Color, txt: Color, sub: Color) void {
    _ = f;
    var pb: [1100]u8 = undefined;
    _ = cv.text(PAD, 76, 12, sub, agent.displayPath(st.folder[0..st.folder_len], &pb), .{ .max_w = w - 2 * PAD });
    const top: f32 = 90;
    const row: f32 = 50;
    const list_h = h - top - 16;
    const n = sessionRows();
    const total = row * @as(f32, @floatFromInt(n));
    const sel_y = @as(f32, @floatFromInt(st.sel)) * row;
    if (st.follow) {
        if (sel_y < st.list_scroll) st.list_scroll = sel_y;
        if (sel_y + row > st.list_scroll + list_h) st.list_scroll = sel_y + row - list_h;
    }
    st.list_scroll = std.math.clamp(st.list_scroll, 0, @max(0, total - list_h));
    cv.setClip(0, top, w, list_h);
    const has_cont = agent.canContinue(st.pick) and !agent.canResumeList(st.pick);
    for (0..n) |i| {
        const y = top + @as(f32, @floatFromInt(i)) * row - st.list_scroll;
        if (y + row < top or y > top + list_h) continue;
        const hv = hovered(.session, i) or st.sel == i;
        cv.rect(PAD - 8, y + 3, w - 2 * PAD + 16, row - 6, 14, if (i == 0) acc.alpha(if (hv) 0.3 else 0.16) else Color.hex(0xffffff).alpha(if (hv) 0.1 else 0.035));
        if (i == 0) {
            _ = cv.text(PAD + 4, y + 30, 14, txt, "\u{F0415}  新しい会話", .{ .bold = true });
        } else if (has_cont and i == 1) {
            _ = cv.text(PAD + 4, y + 23, 14, txt, "\u{F0450}  前回の続き", .{});
            _ = cv.text(PAD + 4, y + 41, 11.5, sub, "このフォルダで最後にした会話を続ける", .{});
        } else {
            const s = st.sessions.items[i - 1 - @intFromBool(has_cont)];
            var tb: [32]u8 = undefined;
            _ = cv.text(PAD + 4, y + 23, 13.5, txt, s.title, .{ .max_w = w - 2 * PAD - 8 });
            var ib: [96]u8 = undefined;
            _ = cv.text(PAD + 4, y + 41, 11, sub, std.fmt.bufPrint(&ib, "{s} · {s}", .{ ago(s.mtime, &tb), s.id[0..@min(8, s.id.len)] }) catch "", .{});
        }
        addHit(PAD - 8, y + 3, w - 2 * PAD + 16, row - 6, .session, i);
    }
    if (agent.canResumeList(st.pick) and st.sessions.items.len == 0)
        _ = cv.text(w / 2, top + row + 34, 12, sub, "このフォルダの会話の記録はありません", .{ .alignment = .center });
    cv.setClip(0, 0, w, h);
}

// ---- MCP サーバ ----

fn drawMcp(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, acc: Color, txt: Color, sub: Color) void {
    const app = f.app;
    const list = mcp.servers();
    _ = cv.text(PAD, 76, 12, sub, if (usingAgent()) "選んだサーバだけを Claude Code に渡します" else "選んだ stdio のサーバのツールを、モデルが使えます", .{ .max_w = w - 2 * PAD - 40 });
    {
        const bx = w - PAD - 36;
        const hv: f32 = if (hovered(.mcp_reload, 0)) 1 else 0;
        cv.rect(bx, 56, 34, 34, 17, acc.alpha(0.1 + 0.2 * hv));
        _ = cv.text(bx + 17, 79, 15, txt, "\u{F0450}", .{ .alignment = .center });
        addHit(bx, 56, 34, 34, .mcp_reload, 0);
    }
    const top: f32 = 100;
    const row: f32 = 56;
    if (list.len == 0) {
        _ = cv.text(PAD, top + 24, 13, txt, "MCP サーバが登録されていません", .{ .bold = true });
        const lines = [_][]const u8{
            "~/.config/ame-shell/mcp.json に書くと出てきます:",
            "{\"mcpServers\": {",
            "  \"fs\": {\"command\": \"npx\", \"args\": [\"-y\",",
            "     \"@modelcontextprotocol/server-filesystem\", \"/home\"]}",
            "}}",
            "Claude Code に登録したサーバ(~/.claude.json)も出ます。",
        };
        for (lines, 0..) |l, i| _ = cv.text(PAD, top + 52 + @as(f32, @floatFromInt(i)) * 20, 12, sub, l, .{ .max_w = w - 2 * PAD });
        return;
    }
    const list_h = h - top - 16;
    const total = row * @as(f32, @floatFromInt(list.len));
    st.list_scroll = std.math.clamp(st.list_scroll, 0, @max(0, total - list_h));
    cv.setClip(0, top, w, list_h);
    for (list, 0..) |s, i| {
        const y = top + @as(f32, @floatFromInt(i)) * row - st.list_scroll;
        if (y + row < top or y > top + list_h) continue;
        const hv = hovered(.mcp_toggle, i) or st.sel == i;
        cv.rect(PAD - 8, y + 3, w - 2 * PAD + 16, row - 6, 14, Color.hex(0xffffff).alpha(if (hv) 0.1 else 0.035));
        _ = cv.text(PAD + 4, y + 24, 14, txt, s.name, .{ .bold = s.enabled, .max_w = w - 2 * PAD - 80 });
        var ib: [200]u8 = undefined;
        const kind = switch (s.kind) {
            .stdio => "stdio",
            .http => "HTTP",
            .sse => "SSE",
        };
        const from = if (s.source == .ame) "ame-shell" else "Claude Code";
        const state_s: []const u8 = switch (s.phase) {
            .ready => " · 動いています",
            .starting, .listing => " · 起動中…",
            .failed => " · 失敗",
            .off => "",
        };
        const note = if (s.kind != .stdio and !usingAgent()) " · API のチャットでは使えません(Claude Code 用)" else "";
        const info = std.fmt.bufPrint(&ib, "{s} · {s}{s}{s}", .{ kind, from, state_s, note }) catch "";
        _ = cv.text(PAD + 4, y + 42, 11, if (s.phase == .failed) theme.danger(app).lighten(0.3) else sub, if (s.phase == .failed and s.err.len > 0) s.err else info, .{ .max_w = w - 2 * PAD - 80 });
        // スイッチ
        const sx = w - PAD - 50;
        const on: f32 = if (s.enabled) 1 else 0;
        cv.rect(sx, y + 16, 46, 24, 12, Color.mix(Color.hex(0xffffff).alpha(0.15), acc, on));
        cv.rect(sx + 3 + on * 22, y + 19, 18, 18, 9, Color.hex(0xffffff));
        addHit(PAD - 8, y + 3, w - 2 * PAD + 16, row - 6, .mcp_toggle, i);
    }
    cv.setClip(0, 0, w, h);
}

fn filterMatch(name: []const u8, q: []const u8) bool {
    if (q.len == 0) return true;
    if (q.len > name.len) return false;
    var i: usize = 0;
    while (i + q.len <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i .. i + q.len], q)) return true;
    }
    return false;
}

/// 絞り込んだモデルの一覧(index の配列)
fn filtered(buf: []usize) usize {
    const list = ai.modelList(st.pick);
    const q = st.filter[0..st.filter_len];
    var n: usize = 0;
    for (list, 0..) |m, i| {
        if (n >= buf.len) break;
        if (filterMatch(m, q)) {
            buf[n] = i;
            n += 1;
        }
    }
    return n;
}

fn typedRow() bool {
    const q = std.mem.trim(u8, st.filter[0..st.filter_len], " ");
    if (q.len == 0) return false;
    for (ai.modelList(st.pick)) |m| if (std.mem.eql(u8, m, q)) return false;
    return true;
}

fn drawModels(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, acc: Color, txt: Color, sub: Color) void {
    const app = f.app;
    const i = st.pick;
    const p = &ai.providers[i];
    // ---- キー ----
    var kb: [512]u8 = undefined;
    const k = ai.key(i, &kb);
    {
        const y: f32 = 60;
        const hv = hovered(.key_edit, 0);
        cv.rect(PAD - 4, y, w - 2 * PAD + 8, 34, 14, Color.hex(0xffffff).alpha(if (hv) 0.1 else 0.05));
        var lb: [96]u8 = undefined;
        const label = if (k) |kk| std.fmt.bufPrint(&lb, "\u{F0306}  API キー: 設定済み(…{s})", .{kk[kk.len -| 4..]}) catch "" else if (p.need_key) "\u{F0306}  API キーを入れる(押して貼り付け)" else "\u{F0306}  API キー(不要。使うなら押して入れる)";
        _ = cv.text(PAD + 8, y + 22, 13, if (k != null) acc.lighten(0.3) else if (p.need_key) theme.danger(app).lighten(0.3) else sub, label, .{ .max_w = w - 2 * PAD - 16 });
        addHit(PAD - 4, y, w - 2 * PAD + 8, 34, .key_edit, 0);
    }
    @memset(&kb, 0);
    // ---- 絞り込み ----
    const fy: f32 = 104;
    drawField(cv, PAD - 4, fy, w - 2 * PAD - 40, st.filter[0..st.filter_len], "モデルを絞り込む / 名前を入れて Enter", acc, txt, sub);
    {
        const bx = w - PAD - 36;
        const hv: f32 = if (hovered(.refresh, 0)) 1 else 0;
        cv.rect(bx, fy + 1, 34, 34, 17, acc.alpha(0.1 + 0.2 * hv));
        _ = cv.text(bx + 17, fy + 24, 15, txt, "\u{F0450}", .{ .alignment = .center });
        addHit(bx, fy + 1, 34, 34, .refresh, 0);
    }
    // ---- 一覧 ----
    const top: f32 = 152;
    const row: f32 = 34;
    const list_h = h - top - 30;
    var idx: [600]usize = undefined;
    const n = filtered(&idx);
    const typed = typedRow();
    const rows = n + @intFromBool(typed);
    const total = row * @as(f32, @floatFromInt(rows));
    const sel_y = @as(f32, @floatFromInt(st.sel)) * row;
    if (st.follow) {
        if (sel_y < st.list_scroll) st.list_scroll = sel_y;
        if (sel_y + row > st.list_scroll + list_h) st.list_scroll = sel_y + row - list_h;
    }
    st.list_scroll = std.math.clamp(st.list_scroll, 0, @max(0, total - list_h));
    cv.setClip(0, top, w, list_h);
    const cur_model = ai.model(i);
    var r: usize = 0;
    if (typed) {
        const y = top - st.list_scroll;
        const hv = hovered(.use_typed, 0) or st.sel == 0;
        cv.rect(PAD - 8, y + 2, w - 2 * PAD + 16, row - 4, 12, acc.alpha(if (hv) 0.25 else 0.12));
        var tb: [220]u8 = undefined;
        _ = cv.text(PAD + 4, y + 22, 13, txt, std.fmt.bufPrint(&tb, "「{s}」を使う", .{std.mem.trim(u8, st.filter[0..st.filter_len], " ")}) catch "", .{ .max_w = w - 2 * PAD - 8 });
        addHit(PAD - 8, y + 2, w - 2 * PAD + 16, row - 4, .use_typed, 0);
        r = 1;
    }
    const list = ai.modelList(i);
    for (idx[0..n], 0..) |mi, j| {
        const y = top + @as(f32, @floatFromInt(r + j)) * row - st.list_scroll;
        if (y + row < top or y > top + list_h) continue;
        const name = list[mi];
        const cur = std.mem.eql(u8, name, cur_model);
        const hv = hovered(.model, mi) or st.sel == r + j;
        cv.rect(PAD - 8, y + 2, w - 2 * PAD + 16, row - 4, 12, Color.hex(0xffffff).alpha(if (hv) 0.1 else 0.03));
        if (cur) _ = cv.text(w - PAD - 4, y + 22, 13, acc.lighten(0.3), "\u{F012C}", .{ .alignment = .right });
        _ = cv.text(PAD + 4, y + 22, 13, if (cur) acc.lighten(0.3) else txt, name, .{ .max_w = w - 2 * PAD - 30 });
        addHit(PAD - 8, y + 2, w - 2 * PAD + 16, row - 4, .model, mi);
    }
    cv.setClip(0, 0, w, h);
    // ---- 状態 ----
    var sb: [200]u8 = undefined;
    const status: []const u8 = if (ai.modelsBusy()) "一覧を取ってきています…" else if (ai.modelError().len > 0) ai.modelError() else if (list.len > 0) (std.fmt.bufPrint(&sb, "{d} 個のモデル(今: {s})", .{ list.len, cur_model }) catch "") else (std.fmt.bufPrint(&sb, "今のモデル: {s}", .{cur_model}) catch "");
    _ = cv.text(PAD, h - 12, 11.5, if (ai.modelError().len > 0 and !ai.modelsBusy()) theme.danger(app).lighten(0.3) else sub, status, .{ .max_w = w - 2 * PAD });
}

fn drawKey(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32, acc: Color, txt: Color, sub: Color) void {
    _ = h;
    const app = f.app;
    const i = st.pick;
    const p = &ai.providers[i];
    var hb: [200]u8 = undefined;
    _ = cv.text(PAD, 80, 13, txt, std.fmt.bufPrint(&hb, "{s} の API キー", .{p.name}) catch "", .{ .bold = true, .max_w = w - 2 * PAD });
    if (p.hint.len > 0) _ = cv.text(PAD, 102, 12, sub, std.fmt.bufPrint(&hb, "キーを作る場所: {s}", .{p.hint}) catch "", .{ .max_w = w - 2 * PAD });
    // 伏せ字(最後の 4 文字だけ見せる)
    var dots: [600]u8 = undefined;
    var n: usize = 0;
    const kl = st.key_len;
    for (st.keybuf[0..kl], 0..) |ch, j| {
        if (j + 4 >= kl) {
            if (n < dots.len) {
                dots[n] = ch;
                n += 1;
            }
        } else if (n + 3 <= dots.len) {
            @memcpy(dots[n .. n + 3], "•");
            n += 3;
        }
    }
    drawField(cv, PAD - 4, 118, w - 2 * PAD + 8, dots[0..n], "Ctrl+V で貼り付け → Enter で保存", acc, txt, sub);
    // 保存・消す
    const by: f32 = 168;
    {
        const hv: f32 = if (hovered(.key_save, 0)) 1 else 0;
        cv.rectGrad(PAD - 4, by, 110, 34, 17, acc.lighten(0.3 + 0.1 * hv), acc);
        _ = cv.text(PAD + 51, by + 22, 13, Color.hex(0x08101e), "保存", .{ .bold = true, .alignment = .center });
        addHit(PAD - 4, by, 110, 34, .key_save, 0);
    }
    var kb: [512]u8 = undefined;
    if (ai.key(i, &kb) != null) {
        const hv: f32 = if (hovered(.key_delete, 0)) 1 else 0;
        cv.rect(PAD + 118, by, 110, 34, 17, theme.danger(app).alpha(0.2 + 0.25 * hv));
        _ = cv.text(PAD + 173, by + 22, 13, txt, "消す", .{ .alignment = .center });
        addHit(PAD + 118, by, 110, 34, .key_delete, 0);
    }
    @memset(&kb, 0);
    _ = cv.text(PAD, by + 62, 11.5, sub, "保存先: ~/.config/ame-shell/ai-keys(自分だけが読めます)", .{ .max_w = w - 2 * PAD });
    _ = cv.text(PAD, by + 82, 11.5, sub, "環境変数でも渡せます(例: OPENAI_API_KEY)", .{ .max_w = w - 2 * PAD });
    if (st.status_len > 0) _ = cv.text(PAD, by + 112, 12, theme.danger(app).lighten(0.3), st.status[0..st.status_len], .{ .max_w = w - 2 * PAD });
}

// ---------------------------------------------------------------------------
// 入力
// ---------------------------------------------------------------------------

fn redraw() void {
    if (st.frame) |f| f.schedule();
}

fn setStatus(s: []const u8) void {
    const n = @min(s.len, st.status.len);
    @memcpy(st.status[0..n], s[0..n]);
    st.status_len = n;
}

fn goMode(m: Mode) void {
    st.mode = m;
    st.sel = 0;
    st.list_scroll = 0;
    st.preedit_len = 0;
    st.status_len = 0;
    if (m == .models) {
        st.filter_len = 0;
        if (ai.modelList(st.pick).len == 0 and !ai.modelsBusy()) ai.fetchModels(st.pick);
    }
    if (m == .key) {
        @memset(&st.keybuf, 0);
        st.key_len = 0;
    }
    if (m == .providers) st.sel = if (usingAgent()) ai.providers.len + agent.current() else ai.current();
    if (m == .folder) {
        // 最初は今のフォルダ(無ければ空 = 最近のフォルダの一覧)
        st.path_len = 0;
        rebuildFolders();
    }
    if (m == .sessions) rebuildSessions();
    if (m == .mcp) mcp.ensure(st.frame.?.app);
    if (st.frame) |f| @import("../ime.zig").update(f.app);
}

fn submit() void {
    if (busy() or st.input_len == 0) return;
    if (usingAgent()) agent.send(st.input[0..st.input_len]) else ai.send(st.input[0..st.input_len]);
    st.input_len = 0;
    st.scroll = 0;
}

fn saveKey() void {
    const k = std.mem.trim(u8, st.keybuf[0..st.key_len], " \t\r\n");
    if (!ai.validKey(k)) {
        setStatus("キーの形が正しくありません(空白や引用符は使えません)");
        return;
    }
    if (!ai.saveKey(st.pick, k)) {
        setStatus("保存できませんでした");
        return;
    }
    @memset(&st.keybuf, 0);
    st.key_len = 0;
    goMode(.models);
    ai.fetchModels(st.pick);
}

fn chooseModel(name: []const u8) void {
    agent.deactivate();
    ai.setProvider(st.pick);
    ai.setModel(st.pick, name);
    goMode(.chat);
}

/// 文字を入れる(キー入力・日本語入力の確定・貼り付け)
pub fn insert(s: []const u8) void {
    switch (st.mode) {
        .chat => appendTo(&st.input, &st.input_len, s, true),
        .models => {
            appendTo(&st.filter, &st.filter_len, s, false);
            st.sel = 0;
            st.list_scroll = 0;
        },
        .key => appendTo(&st.keybuf, &st.key_len, std.mem.trim(u8, s, " \t\r\n"), false),
        .folder => {
            appendTo(&st.path, &st.path_len, s, false);
            st.sel = 0;
            st.list_scroll = 0;
            rebuildFolders();
        },
        .providers, .sessions, .mcp => {},
    }
    redraw();
}

fn appendTo(buf: []u8, len: *usize, s: []const u8, multiline: bool) void {
    for (s) |ch| {
        if (len.* >= buf.len) break;
        if (ch == '\r') continue;
        if (ch == '\n' and !multiline) continue;
        if (ch == '\t') {
            buf[len.*] = ' ';
        } else if (ch < 0x20 and ch != '\n') continue else buf[len.*] = ch;
        len.* += 1;
    }
    // 途中で切れた UTF-8 を残さない
    var i = len.*;
    while (i > 0 and (buf[i - 1] & 0xC0) == 0x80) i -= 1;
    if (i > 0 and buf[i - 1] >= 0xC0) {
        const need = std.unicode.utf8ByteSequenceLength(buf[i - 1]) catch 1;
        if (len.* - (i - 1) < need) len.* = i - 1;
    }
}

fn backspace(buf: []u8, len: *usize, word: bool) void {
    if (len.* == 0) return;
    if (word) {
        while (len.* > 0 and (buf[len.* - 1] == ' ' or buf[len.* - 1] == '\n')) len.* -= 1;
        while (len.* > 0 and buf[len.* - 1] != ' ' and buf[len.* - 1] != '\n') len.* -= 1;
        return;
    }
    var i = len.* - 1;
    while (i > 0 and (buf[i] & 0xC0) == 0x80) i -= 1;
    len.* = i;
}

fn onPasted(s: []const u8) void {
    insert(s);
}

/// 日本語入力の変換中の文字
pub fn setPreedit(s: []const u8) void {
    const n = @min(s.len, st.preedit.len);
    @memcpy(st.preedit[0..n], s[0..n]);
    st.preedit_len = n;
    redraw();
}

/// 入力位置(サーフェスの物理 px: x, y, w, h)。変換候補の窓をここに出してもらう
pub fn caretRect(f: *const Frame) [4]i32 {
    const S = f.S;
    const x = (f.W - f.T() - f.ai.w.target + st.caret[0]) * S;
    const y = (f.ai.oy + st.caret[1] - 15) * S;
    return .{ @intFromFloat(@max(0, x)), @intFromFloat(@max(0, y)), 2, @intFromFloat(20 * S) };
}

/// 日本語入力を使う場面か(会社の一覧では使わない)
/// 会社の選択を開く(ame-ctl ai pick)
/// 会話の画面に戻す
pub fn showChat() void {
    goMode(.chat);
    redraw();
}

/// MCP サーバの選択を開く(ame-ctl ai mcp)
pub fn openMcp() void {
    goMode(.mcp);
    redraw();
}

pub fn openPicker() void {
    goMode(.providers);
    redraw();
}

pub fn wantsText() bool {
    return switch (st.mode) {
        .chat, .models, .key, .folder => true,
        .providers, .sessions, .mcp => false,
    };
}

pub fn key(f: *Frame, ev: surface.KeyEvent) void {
    st.frame = f;
    st.follow = true;
    ai.ensure(f.app);
    const sym = ev.sym;
    if (sym == c.XKB_KEY_Escape) {
        switch (st.mode) {
            .chat => f.toggleAi(),
            .key => goMode(.models),
            .folder => goMode(.providers),
            .sessions => goMode(.folder),
            else => goMode(.chat),
        }
        return;
    }
    if (ev.ctrl and (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V)) {
        ai.paste(onPasted);
        return;
    }
    switch (st.mode) {
        .chat => {
            if (ev.ctrl and sym == c.XKB_KEY_l) {
                if (usingAgent()) agent.newConversation() else ai.clear();
                return;
            }
            if (ev.ctrl and sym == c.XKB_KEY_p) {
                goMode(.providers);
                return;
            }
            if (ev.ctrl and sym == c.XKB_KEY_c and busy()) {
                if (usingAgent()) agent.stop() else ai.stop();
                return;
            }
            switch (sym) {
                c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => if (ev.shift) appendTo(&st.input, &st.input_len, "\n", true) else submit(),
                c.XKB_KEY_BackSpace => backspace(&st.input, &st.input_len, ev.ctrl),
                c.XKB_KEY_Page_Up => st.scroll += 300,
                c.XKB_KEY_Page_Down => st.scroll = @max(0, st.scroll - 300),
                c.XKB_KEY_Up => if (st.input_len == 0) {
                    st.scroll += 60;
                },
                c.XKB_KEY_Down => if (st.input_len == 0) {
                    st.scroll = @max(0, st.scroll - 60);
                },
                else => if (!ev.ctrl and ev.utf8.len > 0 and ev.utf8[0] >= 0x20 and ev.utf8[0] != 0x7f) insert(ev.utf8),
            }
        },
        .providers => switch (sym) {
            c.XKB_KEY_Down, c.XKB_KEY_Tab => st.sel = @min(st.sel + 1, pickRows() - 1),
            c.XKB_KEY_Up, c.XKB_KEY_ISO_Left_Tab => st.sel -|= 1,
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => if (st.sel < ai.providers.len) pickProvider(st.sel) else pickAgent(st.sel - ai.providers.len),
            else => {},
        },
        .folder => switch (sym) {
            c.XKB_KEY_Down => if (st.folders.items.len > 0) {
                st.sel = @min(st.sel + 1, st.folders.items.len - 1);
            },
            c.XKB_KEY_Up => st.sel -|= 1,
            c.XKB_KEY_Tab => if (st.sel < st.folders.items.len) {
                // 補完: 選んでいるフォルダを入力欄へ(続けて中を選べるよう / を付ける)
                var pb: [1100]u8 = undefined;
                const p = agent.shortPath(st.folders.items[st.sel], &pb);
                st.path_len = 0;
                appendTo(&st.path, &st.path_len, p, false);
                appendTo(&st.path, &st.path_len, "/", false);
                st.sel = 0;
                rebuildFolders();
            },
            c.XKB_KEY_BackSpace => {
                backspace(&st.path, &st.path_len, ev.ctrl);
                st.sel = 0;
                rebuildFolders();
            },
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => useFolderInput(),
            else => if (!ev.ctrl and ev.utf8.len > 0 and ev.utf8[0] >= 0x20 and ev.utf8[0] != 0x7f) insert(ev.utf8),
        },
        .sessions => switch (sym) {
            c.XKB_KEY_Down, c.XKB_KEY_Tab => st.sel = @min(st.sel + 1, sessionRows() - 1),
            c.XKB_KEY_Up, c.XKB_KEY_ISO_Left_Tab => st.sel -|= 1,
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => pickSession(st.sel),
            else => {},
        },
        .mcp => switch (sym) {
            c.XKB_KEY_Down, c.XKB_KEY_Tab => if (mcp.servers().len > 0) {
                st.sel = @min(st.sel + 1, mcp.servers().len - 1);
            },
            c.XKB_KEY_Up, c.XKB_KEY_ISO_Left_Tab => st.sel -|= 1,
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_space => mcp.toggle(st.sel),
            else => {},
        },
        .models => {
            var idx: [600]usize = undefined;
            const n = filtered(&idx);
            const typed = typedRow();
            const rows = n + @intFromBool(typed);
            switch (sym) {
                c.XKB_KEY_Down, c.XKB_KEY_Tab => if (rows > 0) {
                    st.sel = @min(st.sel + 1, rows - 1);
                },
                c.XKB_KEY_Up, c.XKB_KEY_ISO_Left_Tab => st.sel -|= 1,
                c.XKB_KEY_BackSpace => {
                    backspace(&st.filter, &st.filter_len, ev.ctrl);
                    st.sel = 0;
                },
                c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                    const q = std.mem.trim(u8, st.filter[0..st.filter_len], " ");
                    if (typed and st.sel == 0) {
                        chooseModel(q);
                    } else if (rows > 0) {
                        const j = st.sel - @intFromBool(typed);
                        if (j < n) chooseModel(ai.modelList(st.pick)[idx[j]]);
                    } else if (q.len == 0) goMode(.chat); // 一覧が無い: 今のモデルのまま
                },
                else => if (!ev.ctrl and ev.utf8.len > 0 and ev.utf8[0] > 0x20 and ev.utf8[0] != 0x7f) insert(ev.utf8),
            }
        },
        .key => switch (sym) {
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => saveKey(),
            c.XKB_KEY_BackSpace => backspace(&st.keybuf, &st.key_len, ev.ctrl),
            else => if (!ev.ctrl and ev.utf8.len > 0 and ev.utf8[0] > 0x20 and ev.utf8[0] != 0x7f) insert(ev.utf8),
        },
    }
}

fn pickProvider(i: usize) void {
    st.pick = i;
    agent.deactivate();
    ai.setProvider(i);
    const p = &ai.providers[i];
    if (p.need_key and !ai.hasKey(i)) goMode(.key) else goMode(.models);
}

/// コーディング CLI を選んだ: 作業フォルダを選ぶ画面へ
fn pickAgent(k: usize) void {
    if (!agent.installed(k)) return;
    st.pick = k;
    goMode(.folder);
}

/// 入力欄のフォルダ(あれば)か、選んでいる行のフォルダを使う
fn useFolderInput() void {
    var eb: [1100]u8 = undefined;
    const typed = std.mem.trimRight(u8, expandPath(std.mem.trim(u8, pathText(), " "), &eb), "/");
    if (typed.len > 0) {
        if (std.fs.cwd().openDir(typed, .{})) |d| {
            var dd = d;
            dd.close();
            var rb: [std.fs.max_path_bytes]u8 = undefined;
            return chooseFolder(std.fs.cwd().realpath(typed, &rb) catch typed);
        } else |_| {}
    }
    if (st.sel < st.folders.items.len) chooseFolder(st.folders.items[st.sel]);
}

fn chooseFolder(p: []const u8) void {
    const n = @min(p.len, st.folder.len);
    @memcpy(st.folder[0..n], p[0..n]);
    st.folder_len = n;
    goMode(.sessions);
}

/// 会話を選んだ: 0 = 新しい会話、(前回の続き)、Claude Code の記録
fn pickSession(i: usize) void {
    const dir = st.folder[0..st.folder_len];
    const has_cont = agent.canContinue(st.pick) and !agent.canResumeList(st.pick);
    if (i == 0) {
        agent.start(st.pick, dir, .new);
    } else if (has_cont and i == 1) {
        agent.start(st.pick, dir, .last);
    } else {
        const k = i - 1 - @intFromBool(has_cont);
        if (k >= st.sessions.items.len) return;
        agent.start(st.pick, dir, .{ .id = st.sessions.items[k].id });
    }
    st.scroll = 0;
    goMode(.chat);
}

pub fn pointer(f: *Frame, ev: surface.PointerEvent, lx: f32, ly: f32) bool {
    st.frame = f;
    ai.ensure(f.app);
    var hov: i32 = -1;
    if (ev.kind != .leave) {
        var i = st.n_hits;
        while (i > 0) {
            i -= 1;
            const h = st.hits[i];
            if (lx >= h.x and lx < h.x + h.w and ly >= h.y and ly < h.y + h.h) {
                hov = @intCast(i);
                break;
            }
        }
    }
    const changed = hov != st.hover;
    st.hover = hov;
    if (ev.kind == .scroll) {
        if (st.mode == .chat) {
            st.scroll = @max(0, st.scroll - ev.scroll * 4);
        } else st.list_scroll = @max(0, st.list_scroll + ev.scroll * 4);
        st.follow = false;
        return true;
    }
    if (ev.kind != .press) return changed;
    const h = hitAt(lx, ly) orelse return changed;
    switch (h.id) {
        .pick => goMode(.providers),
        .new_chat => if (usingAgent()) agent.newConversation() else ai.clear(),
        .close => f.toggleAi(),
        .send => submit(),
        .stop => if (usingAgent()) agent.stop() else ai.stop(),
        .copy => {
            const msgs = messages();
            if (h.arg < msgs.len) {
                ai.copy(msgs[h.arg].text.items);
                st.copied = h.arg;
                st.copied_ms = loop.nowMs();
            }
        },
        .prov => pickProvider(h.arg),
        .back => switch (st.mode) {
            .key => goMode(.models),
            .models, .folder => goMode(.providers),
            .sessions => goMode(.folder),
            else => goMode(.chat),
        },
        .model => {
            const list = ai.modelList(st.pick);
            if (h.arg < list.len) chooseModel(list[h.arg]);
        },
        .use_typed => chooseModel(std.mem.trim(u8, st.filter[0..st.filter_len], " ")),
        .key_edit => goMode(.key),
        .key_save => saveKey(),
        .key_delete => {
            _ = ai.saveKey(st.pick, "");
            goMode(.models);
        },
        .refresh => ai.fetchModels(st.pick),
        .agent => pickAgent(h.arg),
        .folder => if (h.arg < st.folders.items.len) chooseFolder(st.folders.items[h.arg]),
        .use_folder => useFolderInput(),
        .session => pickSession(h.arg),
        .mcp_open => goMode(.mcp),
        .mcp_toggle => mcp.toggle(h.arg),
        .mcp_reload => mcp.reload(),
        .perm => agent.cyclePerm(),
    }
    return true;
}

// ---------------------------------------------------------------------------
// API のチャットとコーディング CLI の切り替え
// ---------------------------------------------------------------------------

fn usingAgent() bool {
    return agent.isActive();
}

fn messages() []*ai.Msg {
    return if (usingAgent()) agent.messages() else ai.messages();
}

fn busy() bool {
    return if (usingAgent()) agent.busy() else ai.busy();
}

fn statusText() []const u8 {
    return if (usingAgent()) agent.status() else ai.status();
}
