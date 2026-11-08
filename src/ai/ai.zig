// AI チャット(画面の側): 会話・選んだ会社とモデル・会話の保存。AI と話すのはコマンド ame-ai(src/cmd/ame-ai.zig)。
// 送るときは、会話を JSON にして ame-ai --json の標準入力へ渡し、1 行ずつ届く出来事(返事の文章・考え中・
// MCP のツールの呼び出しと結果・エラー)を会話に足していく。止めるときは ame-ai をプロセスグループごと止める。
// 会社の一覧・API キーは lib/ai.zig。
// 選んだ会社・モデル: $XDG_STATE_HOME/ame-shell/ai(ame-ai も読む)。会話: $XDG_STATE_HOME/ame-shell/ai-chat
const std = @import("std");
const c = @import("../c.zig");
const App = @import("../core/app.zig").App;
const sys = @import("../platform/sys.zig");
const lib = @import("ame_lib").ai;
const Mcp = @import("mcp.zig");

pub const Proto = lib.Proto;
pub const Provider = lib.Provider;
pub const CUSTOM = lib.CUSTOM;
pub const providers = lib.providers;
pub const providerIndex = lib.providerIndex;
pub const configDir = lib.configDir;
pub const stateDir = lib.stateDir;
pub const readSmall = lib.readSmall;
pub const key = lib.key;
pub const hasKey = lib.hasKey;
pub const validKey = lib.validKey;

pub fn saveKey(i: usize, k: []const u8) bool {
    return lib.saveKey(st.alloc, i, k);
}

pub const Role = enum { user, assistant, tool };

pub const Line = struct {
    a: u32,
    b: u32,
    kind: Kind = .plain,
    pub const Kind = enum { plain, code, head, bullet, bullet_cont, quote };
};

pub const Msg = struct {
    role: Role,
    text: std.ArrayList(u8),
    /// 考えている途中の文章(DeepSeek R1・OpenRouter の reasoning、Claude の thinking)
    think: std.ArrayList(u8),
    err: bool = false,
    /// 端末の出力をそのまま(等幅の帯で表示。コーディング CLI の生の出力)
    mono: bool = false,
    /// 表示のレイアウト(aipanel が作る。文字が増えたら最後の段落から作り直す)
    lines: std.ArrayList(Line),
    lay_w: f32 = 0,
    lay_len: usize = 0,
    lay_para: usize = 0,
    lay_code: bool = false,
    lay_max: f32 = 0,
    lay_lines_before: usize = 0,
    lay_max_before: f32 = 0,
    /// MCP のツールの呼び出し(role = tool。API に送り返すための id・名前・引数・結果)
    call_id: std.ArrayList(u8),
    call_name: std.ArrayList(u8),
    call_args: std.ArrayList(u8),
    result: std.ArrayList(u8),
    /// 結果が届いた(届くまでは「実行中」)
    call_done: bool = false,
    call_failed: bool = false,
    /// この返事のあとにツールの呼び出しが続く(文が空でも送り返す)
    has_calls: bool = false,

    pub fn create(alloc: std.mem.Allocator, role: Role) !*Msg {
        const m = try alloc.create(Msg);
        const B = std.ArrayList(u8);
        m.* = .{ .role = role, .text = B.init(alloc), .think = B.init(alloc), .lines = std.ArrayList(Line).init(alloc), .call_id = B.init(alloc), .call_name = B.init(alloc), .call_args = B.init(alloc), .result = B.init(alloc) };
        return m;
    }
    pub fn destroy(self: *Msg, alloc: std.mem.Allocator) void {
        self.text.deinit();
        self.think.deinit();
        self.lines.deinit();
        self.call_id.deinit();
        self.call_name.deinit();
        self.call_args.deinit();
        self.result.deinit();
        alloc.destroy(self);
    }
};

/// 返事の途中で組み立てるツールの呼び出し
const State = struct {
    app: ?*App = null,
    alloc: std.mem.Allocator = std.heap.c_allocator,
    loaded: bool = false,
    msgs: std.ArrayList(*Msg) = undefined,
    prov: usize = 6, // OpenRouter
    models: [providers.len][128]u8 = undefined,
    model_len: [providers.len]usize = [_]usize{0} ** providers.len,
    // ---- ame-ai とのやりとり ----
    fd: c_int = -1,
    pid: c_int = 0,
    line: std.ArrayList(u8) = undefined,
    /// 今書いている返事(ツールの呼び出しのあとは、新しい返事)
    cur: ?*Msg = null,
    /// JSON でない出力(ame-ai が起動できなかったときの理由など)
    raw: std.ArrayList(u8) = undefined,
    got_event: bool = false,
    status: [160]u8 = undefined,
    status_len: usize = 0,
    // ---- モデルの一覧(ame-ai models)----
    mfd: c_int = -1,
    mpid: c_int = 0,
    mbuf: std.ArrayList(u8) = undefined,
    model_arena: std.heap.ArenaAllocator = undefined,
    model_list: std.ArrayList([]const u8) = undefined,
    model_prov: usize = std.math.maxInt(usize),
    model_err: [200]u8 = undefined,
    model_err_len: usize = 0,
};

var st: State = .{};

pub fn ensure(app: *App) void {
    st.app = app;
    if (st.loaded) return;
    st.loaded = true;
    st.alloc = app.alloc;
    st.msgs = std.ArrayList(*Msg).init(st.alloc);
    st.line = std.ArrayList(u8).init(st.alloc);
    st.raw = std.ArrayList(u8).init(st.alloc);
    st.mbuf = std.ArrayList(u8).init(st.alloc);
    st.model_arena = std.heap.ArenaAllocator.init(st.alloc);
    st.model_list = std.ArrayList([]const u8).init(st.alloc);
    loadState();
    if (app.cfg.ai_provider.len > 0) if (providerIndex(app.cfg.ai_provider.get())) |i| {
        // 設定ファイルの指定は「初めて使うとき」の既定。パネルで選び直したものが優先
        if (!stateFileExists()) st.prov = i;
    };
    loadChat();
}

pub fn messages() []*Msg {
    return st.msgs.items;
}

pub fn current() usize {
    return st.prov;
}

pub fn baseUrl(i: usize) []const u8 {
    if (std.mem.eql(u8, providers[i].id, CUSTOM)) if (st.app) |a| return a.cfg.ai_custom_url.get();
    return providers[i].base;
}

pub fn model(i: usize) []const u8 {
    if (st.model_len[i] > 0) return st.models[i][0..st.model_len[i]];
    if (std.mem.eql(u8, providers[i].id, CUSTOM)) if (st.app) |a| return a.cfg.ai_custom_model.get();
    return providers[i].model;
}

pub fn setProvider(i: usize) void {
    if (i >= providers.len or i == st.prov) return;
    st.prov = i;
    saveState();
}

pub fn setModel(i: usize, name: []const u8) void {
    const n = @min(name.len, st.models[i].len);
    @memcpy(st.models[i][0..n], name[0..n]);
    st.model_len[i] = n;
    saveState();
}

pub fn busy() bool {
    return st.fd >= 0;
}

/// 今していること(MCP の準備など)
pub fn status() []const u8 {
    return st.status[0..st.status_len];
}

pub fn modelsBusy() bool {
    return st.mfd >= 0;
}

/// 取ってきたモデルの一覧(その会社の分だけ)
pub fn modelList(i: usize) []const []const u8 {
    return if (st.model_prov == i) st.model_list.items else &.{};
}

pub fn modelError() []const u8 {
    return st.model_err[0..st.model_err_len];
}

pub fn redraw() void {
    if (st.app) |a| for (a.outputs.items) |o| if (o.frame) |f| f.schedule();
}

// ---------------------------------------------------------------------------
// 選んだ会社・モデル / 会話の保存
// ---------------------------------------------------------------------------

pub fn statePath(buf: []u8, name: []const u8) ?[]const u8 {
    var d: [400]u8 = undefined;
    const dir = stateDir(&d) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch null;
}

fn stateFileExists() bool {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb, "ai") orelse return false;
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

fn loadState() void {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb, "ai") orelse return;
    var fb: [16384]u8 = undefined;
    const txt = readSmall(p, &fb) orelse return;
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |l| {
        var f = std.mem.tokenizeScalar(u8, l, ' ');
        const k = f.next() orelse continue;
        if (std.mem.eql(u8, k, "provider")) {
            if (providerIndex(f.next() orelse continue)) |i| st.prov = i;
        } else if (std.mem.eql(u8, k, "model")) {
            const i = providerIndex(f.next() orelse continue) orelse continue;
            const m = f.rest();
            if (m.len == 0) continue;
            const n = @min(m.len, st.models[i].len);
            @memcpy(st.models[i][0..n], m[0..n]);
            st.model_len[i] = n;
        }
    }
}

fn saveState() void {
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    const w = out.writer();
    w.print("provider {s}\n", .{providers[st.prov].id}) catch return;
    for (providers, 0..) |p, i| if (st.model_len[i] > 0) w.print("model {s} {s}\n", .{ p.id, st.models[i][0..st.model_len[i]] }) catch return;
    writeState("ai", out.items);
}

pub fn writeState(name: []const u8, bytes: []const u8) void {
    var d: [400]u8 = undefined;
    const dir = stateDir(&d) orelse return;
    std.fs.cwd().makePath(dir) catch {};
    var pb: [512]u8 = undefined;
    const p = statePath(&pb, name) orelse return;
    var tb: [520]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.new", .{p}) catch return;
    const f = std.fs.cwd().createFile(tmp, .{ .mode = 0o600, .truncate = true }) catch return;
    f.writeAll(bytes) catch {
        f.close();
        return;
    };
    f.close();
    std.fs.cwd().rename(tmp, p) catch {};
}

/// 会話の保存形式: 「U <バイト数>\n<本文>\n」/「A …」(本文に何が入っていても読み戻せる)
fn saveChat() void {
    writeChat(st.msgs.items, "ai-chat");
}

/// 会話を状態の置き場に保存する(コーディング CLI の会話も同じ形式。M = 等幅の出力)
pub fn writeChat(msgs: []const *Msg, name: []const u8) void {
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    for (msgs) |m| {
        if (m.err or m.text.items.len == 0) continue;
        out.writer().print("{c} {d}\n", .{ @as(u8, switch (m.role) {
            .user => 'U',
            .assistant => if (m.mono) 'M' else 'A',
            .tool => 'T',
        }), m.text.items.len }) catch return;
        out.appendSlice(m.text.items) catch return;
        out.append('\n') catch return;
    }
    writeState(name, out.items);
}

fn loadChat() void {
    readChat(&st.msgs, "ai-chat");
}

pub fn readChat(list: *std.ArrayList(*Msg), name: []const u8) void {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb, name) orelse return;
    const f = std.fs.cwd().openFile(p, .{}) catch return;
    defer f.close();
    const txt = f.readToEndAlloc(st.alloc, 8 << 20) catch return;
    defer st.alloc.free(txt);
    parseChat(st.alloc, list, txt) catch {};
}

fn parseChat(alloc: std.mem.Allocator, list: *std.ArrayList(*Msg), txt: []const u8) !void {
    var i: usize = 0;
    while (i < txt.len) {
        const nl = std.mem.indexOfScalarPos(u8, txt, i, '\n') orelse return;
        const head = txt[i..nl];
        if (head.len < 3 or head[1] != ' ') return;
        const role: Role = switch (head[0]) {
            'U' => .user,
            'A', 'M' => .assistant,
            'T' => .tool,
            else => return,
        };
        const n = std.fmt.parseInt(usize, head[2..], 10) catch return;
        if (nl + 1 + n > txt.len) return;
        const m = try Msg.create(alloc, role);
        try m.text.appendSlice(txt[nl + 1 .. nl + 1 + n]);
        m.mono = head[0] == 'M';
        try list.append(m);
        i = nl + 1 + n + 1;
    }
}

pub fn clear() void {
    stop();
    for (st.msgs.items) |m| m.destroy(st.alloc);
    st.msgs.clearRetainingCapacity();
    saveChat();
    redraw();
}

// ---------------------------------------------------------------------------
// 送る(ame-ai --json に会話を渡し、出来事を読む)
// ---------------------------------------------------------------------------

/// 会話を ame-ai に渡す JSON にする(失敗した返事・等幅の出力は送らない。ツールの呼び出しは直前の返事に付ける)
fn conversationJson(out: *std.ArrayList(u8), msgs: []const *Msg) !void {
    var ws = std.json.writeStream(out.writer(), .{});
    try ws.beginArray();
    var i: usize = 0;
    while (i < msgs.len) : (i += 1) {
        const m = msgs[i];
        if (m.err or m.mono or m.role == .tool) continue;
        if (m.role == .user) {
            try ws.beginObject();
            try ws.objectField("role");
            try ws.write("user");
            try ws.objectField("content");
            try ws.write(m.text.items);
            try ws.endObject();
            continue;
        }
        // 返事 + 続くツールの呼び出し(結果の届いたものだけ)
        var j = i + 1;
        while (j < msgs.len and msgs[j].role == .tool) j += 1;
        const calls = msgs[i + 1 .. j];
        try ws.beginObject();
        try ws.objectField("role");
        try ws.write("assistant");
        try ws.objectField("content");
        try ws.write(m.text.items);
        try ws.objectField("tool_calls");
        try ws.beginArray();
        for (calls) |t| if (t.call_id.items.len > 0 and t.call_done) {
            try ws.beginObject();
            try ws.objectField("id");
            try ws.write(t.call_id.items);
            try ws.objectField("name");
            try ws.write(t.call_name.items);
            try ws.objectField("arguments");
            try ws.write(t.call_args.items);
            try ws.endObject();
        };
        try ws.endArray();
        try ws.endObject();
        for (calls) |t| if (t.call_id.items.len > 0 and t.call_done) {
            try ws.beginObject();
            try ws.objectField("role");
            try ws.write("tool");
            try ws.objectField("id");
            try ws.write(t.call_id.items);
            try ws.objectField("content");
            try ws.write(t.result.items);
            try ws.objectField("error");
            try ws.write(t.call_failed);
            try ws.endObject();
        };
    }
    try ws.endArray();
}

/// 送る。失敗の理由は返事の欄に出す
pub fn send(text: []const u8) void {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0 or busy()) return;
    const app = st.app orelse return;
    const um = Msg.create(st.alloc, .user) catch return;
    um.text.appendSlice(t) catch {};
    st.msgs.append(um) catch return;
    const am = Msg.create(st.alloc, .assistant) catch return;
    st.msgs.append(am) catch return;
    st.cur = am;
    saveChat();
    redraw();

    const i = st.prov;
    var conv = std.ArrayList(u8).init(st.alloc);
    defer conv.deinit();
    conversationJson(&conv, st.msgs.items) catch return fail(am, "会話を JSON にできませんでした");
    // ame-ai --json -p 会社 -m モデル [-s 指示] [--custom-url URL] [--mcp 名前,…]
    var mb: [256]u8 = undefined;
    var nb: [1024]u8 = undefined;
    var sb: [300]u8 = undefined;
    var ub: [300]u8 = undefined;
    var pb: [64]u8 = undefined;
    var argv: [16]?[*:0]const u8 = undefined;
    var n: usize = 0;
    for ([_][*:0]const u8{ "ame-ai", "--json", "-p", (std.fmt.bufPrintZ(&pb, "{s}", .{providers[i].id}) catch return).ptr, "-m", (std.fmt.bufPrintZ(&mb, "{s}", .{model(i)}) catch return).ptr }) |x| {
        argv[n] = x;
        n += 1;
    }
    const system = app.cfg.ai_system.get();
    if (system.len > 0) {
        argv[n] = "-s";
        argv[n + 1] = (std.fmt.bufPrintZ(&sb, "{s}", .{system}) catch return).ptr;
        n += 2;
    }
    if (app.cfg.ai_custom_url.len > 0) {
        argv[n] = "--custom-url";
        argv[n + 1] = (std.fmt.bufPrintZ(&ub, "{s}", .{app.cfg.ai_custom_url.get()}) catch return).ptr;
        n += 2;
    }
    Mcp.ensure(app);
    var names_buf: [1000]u8 = undefined;
    const names = Mcp.enabledNames(&names_buf);
    if (names.len > 0) {
        argv[n] = "--mcp";
        argv[n + 1] = (std.fmt.bufPrintZ(&nb, "{s}", .{names}) catch return).ptr;
        n += 2;
    }
    st.line.clearRetainingCapacity();
    st.raw.clearRetainingCapacity();
    st.got_event = false;
    st.status_len = 0;
    // 新しいプロセスグループで動かす(止めるときに curl・MCP サーバもまとめて止める)
    st.fd = sys.spawnAgent(argv[0..n], conv.items, "/", &st.pid) orelse return fail(am, "ame-ai を起動できませんでした");
    app.loop.add(st.fd, c.EPOLLIN | c.EPOLLHUP, &st, onRead) catch {};
}

fn fail(m: *Msg, why: []const u8) void {
    m.text.clearRetainingCapacity();
    m.text.appendSlice(why) catch {};
    m.err = true;
    redraw();
}

/// 返事を止める(届いた分は残す)
pub fn stop() void {
    if (st.fd < 0) return;
    _ = c.kill(-st.pid, c.SIGTERM);
    finish(true);
}

fn onRead(_: *anyopaque, fd: c_int, _: u32) void {
    var tmp: [16384]u8 = undefined;
    while (true) {
        const n = c.read(fd, &tmp, tmp.len);
        if (n > 0) {
            feed(tmp[0..@intCast(n)]);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) {
            redraw();
            return;
        }
        break;
    }
    if (st.line.items.len > 0) {
        const l = st.alloc.dupe(u8, st.line.items) catch "";
        defer if (l.len > 0) st.alloc.free(l);
        st.line.clearRetainingCapacity();
        handleEvent(l);
    }
    finish(false);
}

fn feed(bytes: []const u8) void {
    var rest = bytes;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        st.line.appendSlice(rest[0..nl]) catch {};
        const l = st.alloc.dupe(u8, st.line.items) catch return;
        defer st.alloc.free(l);
        st.line.clearRetainingCapacity();
        handleEvent(l);
        rest = rest[nl + 1 ..];
    }
    st.line.appendSlice(rest) catch {};
}

/// 今の返事(無ければ、ツールの結果のあとの新しい返事を作る)
fn reply() ?*Msg {
    if (st.cur) |m| return m;
    const m = Msg.create(st.alloc, .assistant) catch return null;
    st.msgs.append(m) catch {
        m.destroy(st.alloc);
        return null;
    };
    st.cur = m;
    return m;
}

fn findTool(id: []const u8) ?*Msg {
    var i = st.msgs.items.len;
    while (i > 0) {
        i -= 1;
        const m = st.msgs.items[i];
        if (m.role == .tool and std.mem.eql(u8, m.call_id.items, id)) return m;
    }
    return null;
}

/// ame-ai の出来事 1 行
fn handleEvent(line: []const u8) void {
    const t = std.mem.trim(u8, line, " \r");
    if (t.len == 0) return;
    const parsed = std.json.parseFromSlice(std.json.Value, st.alloc, t, .{}) catch {
        // JSON でない行(標準エラーの知らせ)
        if (st.raw.items.len < 4096) {
            st.raw.appendSlice(t) catch {};
            st.raw.append('\n') catch {};
        }
        return;
    };
    defer parsed.deinit();
    const v = parsed.value;
    const gs = lib.getStr;
    const ty = gs(v, "type") orelse return;
    st.got_event = true;
    const eq = std.mem.eql;
    if (eq(u8, ty, "text")) {
        if (reply()) |m| m.text.appendSlice(gs(v, "text") orelse "") catch {};
    } else if (eq(u8, ty, "think")) {
        if (reply()) |m| m.think.appendSlice(gs(v, "text") orelse "") catch {};
    } else if (eq(u8, ty, "status")) {
        const s = gs(v, "text") orelse "";
        const n = @min(s.len, st.status.len);
        @memcpy(st.status[0..n], s[0..n]);
        st.status_len = n;
    } else if (eq(u8, ty, "tool_call")) {
        if (reply()) |m| m.has_calls = true;
        const tm = Msg.create(st.alloc, .tool) catch return;
        tm.call_id.appendSlice(gs(v, "id") orelse "") catch {};
        tm.call_name.appendSlice(gs(v, "name") orelse "") catch {};
        tm.call_args.appendSlice(gs(v, "arguments") orelse "{}") catch {};
        tm.text.appendSlice(gs(v, "label") orelse "MCP") catch {};
        st.msgs.append(tm) catch return tm.destroy(st.alloc);
        st.cur = null; // 結果のあとの返事は、新しい欄に
        st.status_len = 0;
    } else if (eq(u8, ty, "tool_result")) {
        const tm = findTool(gs(v, "id") orelse "") orelse return;
        const res = gs(v, "content") orelse "";
        tm.call_done = true;
        tm.call_failed = if (v.object.get("error")) |e| e == .bool and e.bool else false;
        tm.result.appendSlice(res) catch {};
        tm.text.append('\n') catch {};
        tm.text.appendSlice(res[0..@min(res.len, 3000)]) catch {};
        if (res.len > 3000) tm.text.appendSlice("\n…") catch {};
    } else if (eq(u8, ty, "error")) {
        const msg = gs(v, "message") orelse "エラー";
        const m = reply() orelse return;
        if (m.text.items.len == 0) return fail(m, msg);
        m.text.writer().print("\n\n(エラー: {s})", .{msg}) catch {};
    }
}

fn finish(stopped: bool) void {
    if (st.fd >= 0) {
        if (st.app) |a| a.loop.remove(st.fd);
        _ = c.close(st.fd);
        st.fd = -1;
    }
    st.status_len = 0;
    if (st.cur) |m| {
        if (m.text.items.len == 0 and !m.err) {
            if (stopped) fail(m, "止めました") else if (!st.got_event) {
                fail(m, if (st.raw.items.len > 0) std.mem.trim(u8, st.raw.items, " \n") else "ame-ai から返事がありませんでした(ame-ai が入っているか確かめてください)");
            } else fail(m, "返事が空でした");
        }
    }
    // 空のまま終わった、ツールのあとの返事の欄は消す
    if (st.cur == null) if (st.msgs.items.len > 0) {
        const last = st.msgs.items[st.msgs.items.len - 1];
        if (last.role == .assistant and last.text.items.len == 0 and !last.err) {
            _ = st.msgs.pop();
            last.destroy(st.alloc);
        }
    };
    st.cur = null;
    saveChat();
    redraw();
}

// ---------------------------------------------------------------------------
// モデルの一覧(ame-ai models)
// ---------------------------------------------------------------------------

pub fn fetchModels(i: usize) void {
    const app = st.app orelse return;
    if (st.mfd >= 0) return;
    st.model_err_len = 0;
    var pb: [64]u8 = undefined;
    var ub: [300]u8 = undefined;
    const argv = [_]?[*:0]const u8{ "ame-ai", "models", "-p", (std.fmt.bufPrintZ(&pb, "{s}", .{providers[i].id}) catch return).ptr, "--custom-url", (std.fmt.bufPrintZ(&ub, "{s}", .{baseUrl(i)}) catch return).ptr };
    const n: usize = if (std.mem.eql(u8, providers[i].id, CUSTOM)) 6 else 4;
    st.mbuf.clearRetainingCapacity();
    st.mfd = sys.spawnReaderAll(argv[0..n], &st.mpid) orelse return setModelErr("ame-ai を起動できませんでした");
    st.model_prov = i;
    _ = st.model_arena.reset(.retain_capacity);
    st.model_list.clearRetainingCapacity();
    app.loop.add(st.mfd, c.EPOLLIN | c.EPOLLHUP, &st, onModels) catch {};
}

fn setModelErr(s: []const u8) void {
    const n = @min(s.len, st.model_err.len);
    @memcpy(st.model_err[0..n], s[0..n]);
    st.model_err_len = n;
    redraw();
}

fn onModels(_: *anyopaque, fd: c_int, _: u32) void {
    var tmp: [16384]u8 = undefined;
    while (true) {
        const n = c.read(fd, &tmp, tmp.len);
        if (n > 0) {
            if (st.mbuf.items.len < 4 << 20) st.mbuf.appendSlice(tmp[0..@intCast(n)]) catch {};
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) return;
        break;
    }
    if (st.app) |a| a.loop.remove(fd);
    _ = c.close(fd);
    st.mfd = -1;
    // 1 行 1 モデル。失敗は「ame-ai: 理由」の 1 行
    const a = st.model_arena.allocator();
    var it = std.mem.splitScalar(u8, st.mbuf.items, '\n');
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \r");
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "ame-ai: ")) {
            setModelErr(t["ame-ai: ".len..]);
            continue;
        }
        st.model_list.append(a.dupe(u8, t) catch continue) catch {};
    }
    redraw();
}

// ---------------------------------------------------------------------------
// クリップボード(clipboard.zig。ext-data-control を直接使う)
// ---------------------------------------------------------------------------

pub fn copy(text: []const u8) void {
    const app = st.app orelse return;
    _ = @import("../desktop/clipboard.zig").copy(app, text);
}

/// 貼り付け: 読み終わったら cb に渡す
pub fn paste(cb: *const fn ([]const u8) void) void {
    const app = st.app orelse return;
    _ = @import("../desktop/clipboard.zig").paste(app, cb);
}

// ---------------------------------------------------------------------------

test "chat round trip" {
    const a = std.testing.allocator;
    var list = std.ArrayList(*Msg).init(a);
    defer {
        for (list.items) |m| m.destroy(a);
        list.deinit();
    }
    try parseChat(a, &list, "U 5\nhello\nA 7\nline1\nx\n");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("line1\nx", list.items[1].text.items);
}

test "conversation json" {
    const a = std.testing.allocator;
    var list = std.ArrayList(*Msg).init(a);
    defer {
        for (list.items) |m| m.destroy(a);
        list.deinit();
    }
    const u = try Msg.create(a, .user);
    try u.text.appendSlice("天気は?");
    const m = try Msg.create(a, .assistant);
    const t = try Msg.create(a, .tool);
    try t.call_id.appendSlice("c1");
    try t.call_name.appendSlice("w__get");
    try t.call_args.appendSlice("{}");
    try t.result.appendSlice("晴れ");
    t.call_done = true;
    try list.appendSlice(&.{ u, m, t });
    var out = std.ArrayList(u8).init(a);
    defer out.deinit();
    try conversationJson(&out, list.items);
    try std.testing.expectEqualStrings("[{\"role\":\"user\",\"content\":\"天気は?\"},{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"w__get\",\"arguments\":\"{}\"}]},{\"role\":\"tool\",\"id\":\"c1\",\"content\":\"晴れ\",\"error\":false}]", out.items);
}
