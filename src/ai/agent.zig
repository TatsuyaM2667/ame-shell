// コーディング CLI(Claude Code・OpenCode・Gemini CLI・Codex など)を AI チャットのパネルで使う。
//
// CLI を「頼みごと 1 回 = 1 回の起動」で動かし(claude -p など)、出力をチャットに映す:
//   ・機械向けの出力(JSON の行)がある CLI は、それを読んで「返事」「ツールの実行(見出し + 出力)」に分けて表示
//   ・無い CLI は、端末に出る文字をそのまま等幅の帯で表示
// 2 回目からは前の会話の続き(claude は --resume <セッション id>、ほかは --continue など)。
// Claude Code は ~/.claude/projects/<フォルダ>/<id>.jsonl の会話の記録を読み込んで、途中から再開できる。
//
// 作業フォルダはパネルで選ぶ。CLI は新しいプロセスグループで動かし、止めるときは子プロセスごと止める。
// 自分で足す CLI: ~/.config/ame-shell/agents(「名前 | 形式 | コマンド」、{prompt} が頼みごとに置き換わる)。
const std = @import("std");
const c = @import("../c.zig");
const App = @import("../core/app.zig").App;
const ai = @import("ai.zig");
const sys = @import("../platform/sys.zig");
const Msg = ai.Msg;
const af = @import("ame_lib").agentfmt;

fn redraw() void {
    if (st.redraw_fn) |f| f();
}

fn getApp() ?*App {
    return @ptrCast(@alignCast(st.app orelse return null));
}

fn nowMs() u64 {
    return @intCast(@max(0, std.time.milliTimestamp()));
}

pub const Fmt = af.Fmt;
/// ツールの実行の許可
pub const Perm = enum { edits, all, plan, ask };
pub const perm_labels = [_][]const u8{ "編集は自動で許可", "全部を自動で許可", "計画だけ(変更しない)", "毎回確認(許可の要るものは止まる)" };
pub const perm_short = [_][]const u8{ "編集を許可", "全部許可", "計画だけ", "確認する" };

pub const Agent = struct {
    id: []const u8,
    name: []const u8,
    bin: []const u8,
    fmt: Fmt,
    /// セッション id を指定して再開できる(出力から id を拾う)
    resume_id: bool = false,
    /// 「前回の続き」(--continue など)ができる
    cont: bool = true,
};

pub const builtin = [_]Agent{
    .{ .id = "claude", .name = "Claude Code", .bin = "claude", .fmt = .claude, .resume_id = true },
    .{ .id = "opencode", .name = "OpenCode", .bin = "opencode", .fmt = .opencode, .resume_id = true },
    .{ .id = "antigravity", .name = "Antigravity CLI", .bin = "agy", .fmt = .antigravity, .resume_id = true },
    .{ .id = "gemini", .name = "Gemini CLI", .bin = "gemini", .fmt = .gemini },
    .{ .id = "codex", .name = "Codex CLI", .bin = "codex", .fmt = .codex, .resume_id = true },
    .{ .id = "kimi", .name = "Kimi CLI", .bin = "kimi", .fmt = .kimi },
    .{ .id = "qwen", .name = "Qwen Code", .bin = "qwen", .fmt = .claude },
    .{ .id = "cursor", .name = "Cursor Agent", .bin = "cursor-agent", .fmt = .claude, .resume_id = true },
    .{ .id = "amp", .name = "Amp", .bin = "amp", .fmt = .claude, .cont = false },
    .{ .id = "copilot", .name = "GitHub Copilot CLI", .bin = "copilot", .fmt = .raw },
    .{ .id = "crush", .name = "Crush", .bin = "crush", .fmt = .raw, .cont = false },
    .{ .id = "goose", .name = "Goose", .bin = "goose", .fmt = .raw },
    .{ .id = "aider", .name = "Aider", .bin = "aider", .fmt = .raw, .cont = false },
};

const Custom = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    cmd: [512]u8 = undefined,
    cmd_len: usize = 0,
    fmt: Fmt = .raw,
};

const MAX_CUSTOM = 8;
const MAX_MSGS = 400;

const State = struct {
    /// App(テストで画面まわりを読み込まないよう、型を消して持つ)
    app: ?*anyopaque = null,
    redraw_fn: ?*const fn () void = null,
    alloc: std.mem.Allocator = std.heap.c_allocator,
    loaded: bool = false,
    active: bool = false,
    idx: usize = 0,
    cwd: [1024]u8 = undefined,
    cwd_len: usize = 0,
    session: [160]u8 = undefined,
    session_len: usize = 0,
    /// これまでに送った回数(2 回目からは続き)
    turns: u32 = 0,
    /// 次の送信は「前回の続き」で始める(会話を選ぶ画面で「前回の続き」を選んだ)
    cont_next: bool = false,
    perm: Perm = .edits,
    msgs: std.ArrayList(*Msg) = undefined,
    customs: [MAX_CUSTOM]Custom = undefined,
    n_custom: usize = 0,
    inst: [builtin.len + MAX_CUSTOM]i8 = [_]i8{-1} ** (builtin.len + MAX_CUSTOM),

    fd: c_int = -1,
    pid: c_int = 0,
    line: std.ArrayList(u8) = undefined,
    parser: af.Parser = .{ .fmt = .raw, .ctx = undefined, .emit = onEvent },
    cur: ?*Msg = null,
    raw_msg: ?*Msg = null,
    got_any: bool = false,
    t0: u64 = 0,
    status: [200]u8 = undefined,
    status_len: usize = 0,
};

var st: State = .{};

pub fn ensure(app: *App) void {
    st.app = app;
    st.redraw_fn = ai.redraw;
    if (st.loaded) return;
    st.loaded = true;
    st.alloc = app.alloc;
    st.msgs = std.ArrayList(*Msg).init(st.alloc);
    st.line = std.ArrayList(u8).init(st.alloc);
    loadCustoms();
    loadState();
    ai.readChat(&st.msgs, "ai-agent-chat");
}

// ---------------------------------------------------------------------------
// 一覧
// ---------------------------------------------------------------------------

pub fn count() usize {
    return builtin.len + st.n_custom;
}

pub fn name(i: usize) []const u8 {
    if (i < builtin.len) return builtin[i].name;
    const cu = &st.customs[i - builtin.len];
    return cu.name[0..cu.name_len];
}

fn fmtOf(i: usize) Fmt {
    return if (i < builtin.len) builtin[i].fmt else st.customs[i - builtin.len].fmt;
}

fn binOf(i: usize, buf: []u8) []const u8 {
    if (i < builtin.len) return builtin[i].bin;
    const cu = &st.customs[i - builtin.len];
    var it = std.mem.tokenizeScalar(u8, cu.cmd[0..cu.cmd_len], ' ');
    const b = it.next() orelse return "";
    const n = @min(b.len, buf.len);
    @memcpy(buf[0..n], b[0..n]);
    return buf[0..n];
}

/// 入っているか(PATH にあるか。1 回調べたら覚える)
pub fn installed(i: usize) bool {
    if (i >= count()) return false;
    if (st.inst[i] < 0) {
        var bb: [128]u8 = undefined;
        st.inst[i] = @intFromBool(hasBin(binOf(i, &bb)));
    }
    return st.inst[i] == 1;
}

fn hasBin(bin: []const u8) bool {
    if (bin.len == 0) return false;
    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        std.fs.cwd().access(bin, .{}) catch return false;
        return true;
    }
    const path = std.posix.getenv("PATH") orelse "/usr/bin:/bin";
    var it = std.mem.tokenizeScalar(u8, path, ':');
    var pb: [1024]u8 = undefined;
    while (it.next()) |dir| {
        const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, bin }) catch continue;
        std.fs.cwd().access(p, .{}) catch continue;
        return true;
    }
    // ~/.local/bin など、セッションの PATH に無い置き場
    const home = std.posix.getenv("HOME") orelse return false;
    for ([_][]const u8{ ".local/bin", ".npm-global/bin", ".bun/bin", ".cargo/bin", "go/bin", ".opencode/bin" }) |d| {
        const p = std.fmt.bufPrint(&pb, "{s}/{s}/{s}", .{ home, d, bin }) catch continue;
        std.fs.cwd().access(p, .{}) catch continue;
        return true;
    }
    return false;
}

pub fn indexOf(id: []const u8) ?usize {
    for (builtin, 0..) |b, i| if (std.mem.eql(u8, b.id, id)) return i;
    for (0..st.n_custom) |k| if (std.mem.eql(u8, name(builtin.len + k), id)) return builtin.len + k;
    return null;
}

pub fn isActive() bool {
    return st.active;
}

pub fn current() usize {
    return st.idx;
}

pub fn cwd() []const u8 {
    return st.cwd[0..st.cwd_len];
}

pub fn sessionId() []const u8 {
    return st.session[0..st.session_len];
}

pub fn perm() Perm {
    return st.perm;
}

pub fn cyclePerm() void {
    st.perm = @enumFromInt((@as(u8, @intFromEnum(st.perm)) + 1) % 4);
    saveState();
}

pub fn canResumeList(i: usize) bool {
    return i < builtin.len and std.mem.eql(u8, builtin[i].id, "claude");
}

pub fn canContinue(i: usize) bool {
    return i < builtin.len and builtin[i].cont;
}

pub fn messages() []*Msg {
    return st.msgs.items;
}

pub fn busy() bool {
    return st.fd >= 0;
}

pub fn status() []const u8 {
    return st.status[0..st.status_len];
}

/// 表示用のパス: ~ で短くし、長ければ最後の 2 つの名前だけ(…/親/フォルダ)
pub fn displayPath(p: []const u8, buf: []u8) []const u8 {
    const s = shortPath(p, buf);
    if (s.len <= 44) return s;
    var k: usize = 0;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] == '/') {
            k += 1;
            if (k == 2) return std.fmt.bufPrint(buf[buf.len / 2 ..], "…{s}", .{s[i..]}) catch s;
        }
    }
    return s;
}

/// ~ で短くした表示用のパス
pub fn shortPath(p: []const u8, buf: []u8) []const u8 {
    const home = std.posix.getenv("HOME") orelse return p;
    if (std.mem.startsWith(u8, p, home) and (p.len == home.len or p[home.len] == '/'))
        return std.fmt.bufPrint(buf, "~{s}", .{p[home.len..]}) catch p;
    return p;
}

// ---------------------------------------------------------------------------
// 選ぶ・始める
// ---------------------------------------------------------------------------

pub const Start = union(enum) { new, last, id: []const u8 };

/// CLI と作業フォルダを選んで始める(id なら Claude Code の会話の記録を読み込む)
pub fn start(i: usize, dir: []const u8, how: Start) void {
    stop();
    st.idx = i;
    const n = @min(dir.len, st.cwd.len);
    @memcpy(st.cwd[0..n], dir[0..n]);
    st.cwd_len = n;
    clearMsgs();
    st.session_len = 0;
    st.turns = 0;
    st.cont_next = false;
    st.status_len = 0;
    switch (how) {
        .new => {},
        .last => st.cont_next = true,
        .id => |id| {
            setSession(id);
            loadClaudeHistory(dir, id);
        },
    }
    st.active = true;
    addRecent(dir);
    saveState();
    saveChat();
    redraw();
}

pub fn deactivate() void {
    if (!st.active) return;
    st.active = false;
    saveState();
}

/// 新しい会話(同じ CLI・同じフォルダで)
pub fn newConversation() void {
    stop();
    clearMsgs();
    st.session_len = 0;
    st.turns = 0;
    st.cont_next = false;
    st.status_len = 0;
    saveState();
    saveChat();
    redraw();
}

fn clearMsgs() void {
    for (st.msgs.items) |m| m.destroy(st.alloc);
    st.msgs.clearRetainingCapacity();
    st.cur = null;
    st.raw_msg = null;
}

fn setSession(id: []const u8) void {
    const n = @min(id.len, st.session.len);
    @memcpy(st.session[0..n], id[0..n]);
    st.session_len = n;
}

fn setStatus(comptime f: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&st.status, f, args) catch "";
    st.status_len = s.len;
}

// ---------------------------------------------------------------------------
// 送る
// ---------------------------------------------------------------------------

const Argv = struct {
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(?[*:0]const u8),

    fn add(self: *Argv, s: []const u8) void {
        const z = self.arena.allocator().dupeZ(u8, s) catch return;
        self.list.append(z.ptr) catch {};
    }
};

pub fn send(text: []const u8) void {
    const text_t = std.mem.trim(u8, text, " \t\r\n");
    if ((text_t.len == 0 and ai.nPending() == 0) or busy() or !st.active) return;
    const app = getApp() orelse return;
    const um = Msg.create(st.alloc, .user) catch return;
    um.text.appendSlice(text_t) catch {};
    // 付けた画像: 吹き出しに小さな絵を出し、CLI には画像のファイルの場所を頼みごとに書く(Claude Code・Antigravity などは自分で読める)
    ai.takePending(um);
    var prompt = std.ArrayList(u8).init(st.alloc);
    defer prompt.deinit();
    prompt.appendSlice(text_t) catch {};
    if (um.images.items.len > 0) {
        prompt.appendSlice(if (text_t.len > 0) "\n\n添付した画像(このファイルを読んで見てください):\n" else "添付した画像(このファイルを読んで見てください):\n") catch {};
        prompt.appendSlice(um.images.items) catch {};
    }
    const t = prompt.items;
    st.msgs.append(um) catch return;
    if (!installed(st.idx)) return addError("この CLI は入っていません(PATH に見つかりません)");

    var av = Argv{ .arena = std.heap.ArenaAllocator.init(st.alloc), .list = std.ArrayList(?[*:0]const u8).init(st.alloc) };
    defer av.arena.deinit();
    defer av.list.deinit();
    var input: []const u8 = "";
    buildArgv(&av, t, &input);
    if (av.list.items.len == 0) return addError("コマンドを作れませんでした");
    var cb: [1100]u8 = undefined;
    const cwdz = std.fmt.bufPrintZ(&cb, "{s}", .{cwd()}) catch return addError("フォルダの名前が長すぎます");
    st.line.clearRetainingCapacity();
    st.parser = .{ .fmt = fmtOf(st.idx), .cwd = cwd(), .ctx = &st, .emit = onEvent, .alloc = st.alloc };
    st.cur = null;
    st.raw_msg = null;
    st.got_any = false;
    st.t0 = nowMs();
    setStatus("{s} が作業しています…", .{name(st.idx)});
    st.fd = sys.spawnAgent(av.list.items, input, cwdz.ptr, &st.pid) orelse return addError("CLI を起動できませんでした");
    app.loop.add(st.fd, c.EPOLLIN | c.EPOLLHUP, &st, onRead) catch {};
    st.turns += 1;
    saveChat();
    redraw();
}

/// 続きから始めるか: セッション id があればそれ、無ければ「前回の続き」
fn wantResume() enum { none, id, last } {
    const i = st.idx;
    if (i < builtin.len and builtin[i].resume_id and st.session_len > 0) return .id;
    if ((st.cont_next or st.turns > 0) and canContinue(i)) return .last;
    return .none;
}

fn buildArgv(av: *Argv, prompt: []const u8, input: *[]const u8) void {
    const i = st.idx;
    const res = wantResume();
    const sid = sessionId();
    if (i >= builtin.len) {
        // 自分で足した CLI: {prompt} を頼みごとに置き換える(引数 1 つとして渡すので、どんな文字でも安全)
        const cu = &st.customs[i - builtin.len];
        var it = std.mem.tokenizeScalar(u8, cu.cmd[0..cu.cmd_len], ' ');
        var has_prompt = false;
        while (it.next()) |w| {
            if (std.mem.eql(u8, w, "{prompt}")) {
                av.add(prompt);
                has_prompt = true;
            } else av.add(w);
        }
        if (!has_prompt) input.* = prompt;
        return;
    }
    const id = builtin[i].id;
    const p = st.perm;
    const eq = std.mem.eql;
    if (eq(u8, id, "claude")) {
        for ([_][]const u8{ "claude", "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-mode" }) |w| av.add(w);
        av.add(switch (p) {
            .edits => "acceptEdits",
            .all => "bypassPermissions",
            .plan => "plan",
            .ask => "default",
        });
        switch (res) {
            .id => {
                av.add("--resume");
                av.add(sid);
            },
            .last => av.add("--continue"),
            .none => {},
        }
        if (@import("mcp.zig").claudeConfigPath()) |mp| {
            av.add("--mcp-config");
            av.add(mp);
        }
        // 頼みごとは標準入力から(- で始まる文でも引数と間違えられない)
        input.* = prompt;
    } else if (eq(u8, id, "qwen")) {
        for ([_][]const u8{ "qwen", "--output-format", "stream-json", "--include-partial-messages", "--approval-mode" }) |w| av.add(w);
        av.add(switch (p) {
            .edits => "auto-edit",
            .all => "yolo",
            .plan => "plan",
            .ask => "default",
        });
        if (res != .none) av.add("--continue");
        av.add("-p");
        av.add(prompt);
    } else if (eq(u8, id, "cursor")) {
        for ([_][]const u8{ "cursor-agent", "-p", "--output-format", "stream-json", "--stream-partial-output" }) |w| av.add(w);
        if (p == .all) av.add("--force");
        if (res == .id) {
            av.add("--resume");
            av.add(sid);
        }
        av.add(prompt);
    } else if (eq(u8, id, "amp")) {
        av.add("amp");
        if (p == .all) av.add("--dangerously-allow-all");
        av.add("--stream-json");
        av.add("-x");
        av.add(prompt);
    } else if (eq(u8, id, "antigravity")) {
        // Antigravity CLI(agy): -p で 1 回だけ動かす。続きは --conversation <id>(出力の conversation_id)か -c
        for ([_][]const u8{ "agy", "--output-format", "stream-json" }) |w| av.add(w);
        switch (p) {
            .edits => {
                av.add("--mode");
                av.add("accept-edits");
            },
            .all => av.add("--dangerously-skip-permissions"),
            .plan => {
                av.add("--mode");
                av.add("plan");
            },
            .ask => {}, // 許可の要るものは聞けないので止まる(断ったことになる)
        }
        switch (res) {
            .id => {
                av.add("--conversation");
                av.add(sid);
            },
            .last => av.add("--continue"),
            .none => {},
        }
        // -p の値は次の引数をそのまま取る(- で始まる文でも)
        av.add("-p");
        av.add(prompt);
    } else if (eq(u8, id, "gemini")) {
        for ([_][]const u8{ "gemini", "--output-format", "stream-json" }) |w| av.add(w);
        switch (p) {
            .edits => {
                av.add("--approval-mode");
                av.add("auto_edit");
            },
            .all => av.add("--yolo"),
            .plan, .ask => {},
        }
        if (res != .none) {
            av.add("--resume");
            av.add("latest");
        }
        av.add("-p");
        av.add(prompt);
    } else if (eq(u8, id, "codex")) {
        for ([_][]const u8{ "codex", "exec", "--json", "--skip-git-repo-check" }) |w| av.add(w);
        switch (p) {
            .edits => av.add("--full-auto"),
            .all => av.add("--dangerously-bypass-approvals-and-sandbox"),
            .plan => {
                av.add("--sandbox");
                av.add("read-only");
            },
            .ask => {},
        }
        switch (res) {
            .id => {
                av.add("resume");
                av.add(sid);
            },
            .last => {
                av.add("resume");
                av.add("--last");
            },
            .none => {},
        }
        av.add(prompt);
    } else if (eq(u8, id, "opencode")) {
        for ([_][]const u8{ "opencode", "run", "--format", "json" }) |w| av.add(w);
        switch (res) {
            .id => {
                av.add("--session");
                av.add(sid);
            },
            .last => av.add("--continue"),
            .none => {},
        }
        av.add(prompt);
    } else if (eq(u8, id, "kimi")) {
        for ([_][]const u8{ "kimi", "--print", "--output-format", "stream-json" }) |w| av.add(w);
        if (p == .all) av.add("--yolo");
        if (res != .none) av.add("--continue");
        av.add("--command");
        av.add(prompt);
    } else if (eq(u8, id, "copilot")) {
        av.add("copilot");
        if (p == .edits or p == .all) av.add("--allow-all-tools");
        if (res != .none) av.add("--continue");
        av.add("-p");
        av.add(prompt);
    } else if (eq(u8, id, "crush")) {
        for ([_][]const u8{ "crush", "run", "-q" }) |w| av.add(w);
        av.add(prompt);
    } else if (eq(u8, id, "goose")) {
        for ([_][]const u8{ "goose", "run" }) |w| av.add(w);
        if (res != .none) av.add("--resume");
        av.add("-t");
        av.add(prompt);
    } else if (eq(u8, id, "aider")) {
        for ([_][]const u8{ "aider", "--no-pretty", "--no-stream", "--no-check-update" }) |w| av.add(w);
        if (p == .edits or p == .all) av.add("--yes-always");
        av.add("--message");
        av.add(prompt);
    }
}

/// 止める(子プロセスごと)
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
        st.parser.line(l);
    }
    finish(false);
}

fn feed(bytes: []const u8) void {
    var rest = bytes;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        if (st.line.items.len > 0) {
            st.line.appendSlice(rest[0..nl]) catch {};
            const l = st.alloc.dupe(u8, st.line.items) catch return;
            defer st.alloc.free(l);
            st.line.clearRetainingCapacity();
            st.parser.line(l);
        } else st.parser.line(rest[0..nl]);
        rest = rest[nl + 1 ..];
    }
    if (st.line.items.len < 8 << 20) st.line.appendSlice(rest) catch {};
}

fn finish(stopped: bool) void {
    if (st.fd >= 0) {
        if (getApp()) |a| a.loop.remove(st.fd);
        _ = c.close(st.fd);
        st.fd = -1;
    }
    const secs = (nowMs() -| st.t0) / 1000;
    if (stopped) {
        setStatus("止めました", .{});
    } else if (!st.got_any) {
        addError("出力がありませんでした(ログインや設定が要るかもしれません。端末で一度起動して確かめてください)");
        st.status_len = 0;
    } else if (st.status_len == 0 or std.mem.endsWith(u8, status(), "…")) {
        setStatus("終わりました({d} 秒)", .{secs});
    }
    st.cur = null;
    st.raw_msg = null;
    saveState();
    saveChat();
    redraw();
}

// ---------------------------------------------------------------------------
// 出力を読む
// ---------------------------------------------------------------------------

fn lastMsg() ?*Msg {
    return if (st.msgs.items.len > 0) st.msgs.items[st.msgs.items.len - 1] else null;
}

fn push(m: *Msg) void {
    if (st.msgs.items.len >= MAX_MSGS) {
        st.msgs.items[0].destroy(st.alloc);
        _ = st.msgs.orderedRemove(0);
    }
    st.msgs.append(m) catch m.destroy(st.alloc);
}

fn newMsg(role: ai.Role) ?*Msg {
    const m = Msg.create(st.alloc, role) catch return null;
    push(m);
    st.raw_msg = null;
    return m;
}

fn addUser(t: []const u8) void {
    const m = newMsg(.user) orelse return;
    m.text.appendSlice(t) catch {};
    st.cur = null;
}

fn addAssistant(t: []const u8) void {
    const tt = std.mem.trim(u8, t, "\n");
    if (tt.len == 0) return;
    st.got_any = true;
    const m = newMsg(.assistant) orelse return;
    m.text.appendSlice(tt) catch {};
    st.cur = null;
}

/// 少しずつ届く返事
fn appendLive(t: []const u8) void {
    if (t.len == 0) return;
    st.got_any = true;
    const m = blk: {
        if (st.cur) |cm| if (lastMsg() == cm) break :blk cm;
        const nm = newMsg(.assistant) orelse return;
        st.cur = nm;
        break :blk nm;
    };
    m.text.appendSlice(t) catch {};
}

fn addError(t: []const u8) void {
    const m = newMsg(.assistant) orelse return;
    m.text.appendSlice(t) catch {};
    m.err = true;
    st.got_any = true;
    st.cur = null;
    redraw();
}

fn addTool(title: []const u8) void {
    st.got_any = true;
    const m = newMsg(.tool) orelse return;
    m.text.appendSlice(title) catch {};
    st.cur = null;
}

/// ツールの結果を、いちばん新しいツールの表示に付ける(長いものは切る)
fn attachResult(out: []const u8, is_err: bool) void {
    var i = st.msgs.items.len;
    const m = while (i > 0) {
        i -= 1;
        if (st.msgs.items[i].role == .tool) break st.msgs.items[i];
    } else return;
    if (is_err) m.err = true;
    const t = std.mem.trim(u8, out, " \n\r\t");
    if (t.len == 0) return;
    if (std.mem.indexOfScalar(u8, m.text.items, '\n') != null) return; // もう付いている
    m.text.append('\n') catch {};
    var lines: usize = 0;
    var j: usize = 0;
    while (j < t.len and j < 4000 and lines < 40) : (j += 1) {
        if (t[j] == '\n') lines += 1;
    }
    // UTF-8 の途中で切らない
    while (j < t.len and j > 0 and (t[j] & 0xC0) == 0x80) j -= 1;
    m.text.appendSlice(stripAnsiInPlace(t[0..j])) catch {};
    if (j < t.len) m.text.appendSlice("\n…") catch {};
}

var ansi_buf: [4096]u8 = undefined;

fn stripAnsiInPlace(s: []const u8) []const u8 {
    return af.stripAnsi(s, &ansi_buf);
}

/// 端末の出力の 1 行
fn rawLine(t: []const u8) void {
    st.got_any = true;
    const m = blk: {
        if (st.raw_msg) |rm| if (lastMsg() == rm) break :blk rm;
        const nm = Msg.create(st.alloc, .assistant) catch return;
        nm.mono = true;
        push(nm);
        st.raw_msg = nm;
        break :blk nm;
    };
    if (m.text.items.len > 200_000) return;
    if (m.text.items.len > 0) m.text.append('\n') catch {};
    m.text.appendSlice(t) catch {};
    st.cur = null;
}

/// CLI の出力から読み取った出来事を、チャットの表示にする(読み方は lib/agentfmt.zig)
fn onEvent(_: *anyopaque, e: af.Event) void {
    switch (e) {
        .session => |id| setSession(id),
        .delta => |t| appendLive(t),
        .text => |t| addAssistant(t),
        .user => |t| addUser(t),
        .tool => |t| addTool(t),
        .result => |r| attachResult(r.text, r.err),
        .@"error" => |t| addError(t),
        .split => st.cur = null,
        .done => |d| {
            const secs = (nowMs() -| st.t0) / 1000;
            if (d.cost > 0) setStatus("終わりました({d} 秒・${d:.3})", .{ secs, d.cost }) else setStatus("終わりました({d} 秒)", .{secs});
        },
        .raw => |t| rawLine(t),
    }
}

pub const SessionInfo = af.SessionInfo;
pub const listSessions = af.listSessions;

/// Claude Code の会話の記録を読み込んで表示する
fn loadClaudeHistory(dir: []const u8, id: []const u8) void {
    var p = af.Parser{ .fmt = .claude, .live = false, .cwd = dir, .ctx = &st, .emit = onEvent, .alloc = st.alloc };
    _ = af.loadHistory(st.alloc, dir, id, &p);
    st.cur = null;
    st.got_any = false;
    setStatus("記録を読み込みました(続きから話せます)", .{});
}

pub const Folder = struct { path: []const u8, mtime: i128 };

/// 最近使ったフォルダ(Claude Code の記録の置き場 + ame-shell で選んだもの、新しい順)
pub fn recentFolders(arena: std.mem.Allocator, out: *std.ArrayList(Folder)) void {
    // ame-shell で選んだもの
    var rb: [16384]u8 = undefined;
    var pp: [512]u8 = undefined;
    if (ai.statePath(&pp, "agent-recent")) |rp| if (ai.readSmall(rp, &rb)) |txt| {
        var it = std.mem.splitScalar(u8, txt, '\n');
        var k: i128 = std.math.maxInt(i64);
        while (it.next()) |l| {
            if (l.len == 0) continue;
            addFolder(arena, out, l, k);
            k -= 1;
        }
    };
    // Claude Code の記録の置き場: 一番新しい記録の cwd
    var db: [512]u8 = undefined;
    if (af.claudeDir(&db)) |base| {
        var d = std.fs.cwd().openDir(base, .{ .iterate = true }) catch return finishFolders(out);
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .directory) continue;
            var sd = d.openDir(e.name, .{ .iterate = true }) catch continue;
            defer sd.close();
            var newest: i128 = 0;
            var newest_name: [256]u8 = undefined;
            var nn: usize = 0;
            var it2 = sd.iterate();
            while (it2.next() catch null) |f| {
                if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".jsonl")) continue;
                const s = sd.statFile(f.name) catch continue;
                if (s.mtime > newest and f.name.len <= newest_name.len) {
                    newest = s.mtime;
                    @memcpy(newest_name[0..f.name.len], f.name);
                    nn = f.name.len;
                }
            }
            if (nn == 0) continue;
            const f = sd.openFile(newest_name[0..nn], .{}) catch continue;
            defer f.close();
            var head: [16384]u8 = undefined;
            const n = f.readAll(&head) catch continue;
            const key = "\"cwd\":\"";
            const k = std.mem.indexOf(u8, head[0..n], key) orelse continue;
            const s0 = k + key.len;
            const e2 = std.mem.indexOfScalarPos(u8, head[0..n], s0, '"') orelse continue;
            addFolder(arena, out, head[s0..e2], newest);
        }
    }
    finishFolders(out);
}

fn addFolder(arena: std.mem.Allocator, out: *std.ArrayList(Folder), p: []const u8, mtime: i128) void {
    for (out.items) |*x| if (std.mem.eql(u8, x.path, p)) {
        x.mtime = @max(x.mtime, mtime);
        return;
    };
    var d = std.fs.cwd().openDir(p, .{}) catch return;
    d.close();
    out.append(.{ .path = arena.dupe(u8, p) catch return, .mtime = mtime }) catch {};
}

fn finishFolders(out: *std.ArrayList(Folder)) void {
    std.mem.sort(Folder, out.items, {}, struct {
        fn lt(_: void, a: Folder, b: Folder) bool {
            return a.mtime > b.mtime;
        }
    }.lt);
    if (out.items.len > 30) out.shrinkRetainingCapacity(30);
}

fn addRecent(dir: []const u8) void {
    var rb: [16384]u8 = undefined;
    var pp: [512]u8 = undefined;
    const rp = ai.statePath(&pp, "agent-recent") orelse return;
    const old = ai.readSmall(rp, &rb) orelse "";
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    out.appendSlice(dir) catch return;
    out.append('\n') catch return;
    var it = std.mem.splitScalar(u8, old, '\n');
    var n: usize = 1;
    while (it.next()) |l| {
        if (l.len == 0 or std.mem.eql(u8, l, dir) or n >= 20) continue;
        out.appendSlice(l) catch return;
        out.append('\n') catch return;
        n += 1;
    }
    ai.writeState("agent-recent", out.items);
}

// ---------------------------------------------------------------------------
// 状態の保存
// ---------------------------------------------------------------------------

fn idOf(i: usize, buf: []u8) []const u8 {
    if (i < builtin.len) return builtin[i].id;
    return std.fmt.bufPrint(buf, "custom:{s}", .{name(i)}) catch "";
}

fn saveState() void {
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    const w = out.writer();
    var ib: [96]u8 = undefined;
    w.print("active {d}\nagent {s}\nperm {d}\nturns {d}\ncont {d}\n", .{ @intFromBool(st.active), idOf(st.idx, &ib), @intFromEnum(st.perm), st.turns, @intFromBool(st.cont_next) }) catch return;
    if (st.cwd_len > 0) w.print("cwd {s}\n", .{cwd()}) catch return;
    if (st.session_len > 0) w.print("session {s}\n", .{sessionId()}) catch return;
    ai.writeState("agent", out.items);
}

fn loadState() void {
    var pb: [512]u8 = undefined;
    const p = ai.statePath(&pb, "agent") orelse return;
    var fb: [4096]u8 = undefined;
    const txt = ai.readSmall(p, &fb) orelse return;
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |l| {
        const sp = std.mem.indexOfScalar(u8, l, ' ') orelse continue;
        const k = l[0..sp];
        const v = l[sp + 1 ..];
        const eq = std.mem.eql;
        if (eq(u8, k, "active")) {
            st.active = eq(u8, v, "1");
        } else if (eq(u8, k, "agent")) {
            for (0..count()) |i| {
                var ib: [96]u8 = undefined;
                if (eq(u8, idOf(i, &ib), v)) st.idx = i;
            }
        } else if (eq(u8, k, "perm")) {
            const n = std.fmt.parseInt(u8, v, 10) catch 0;
            st.perm = @enumFromInt(@min(n, 3));
        } else if (eq(u8, k, "turns")) {
            st.turns = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (eq(u8, k, "cont")) {
            st.cont_next = eq(u8, v, "1");
        } else if (eq(u8, k, "cwd")) {
            const n = @min(v.len, st.cwd.len);
            @memcpy(st.cwd[0..n], v[0..n]);
            st.cwd_len = n;
        } else if (eq(u8, k, "session")) setSession(v);
    }
}

fn saveChat() void {
    ai.writeChat(st.msgs.items, "ai-agent-chat");
}

/// ~/.config/ame-shell/agents: 「名前 | 形式 | コマンド」(形式: claude gemini codex opencode kimi raw)
fn loadCustoms() void {
    var pb: [512]u8 = undefined;
    var db: [400]u8 = undefined;
    const dir = ai.configDir(&db) orelse return;
    const p = std.fmt.bufPrint(&pb, "{s}/agents", .{dir}) catch return;
    var fb: [8192]u8 = undefined;
    const txt = ai.readSmall(p, &fb) orelse return;
    parseCustoms(txt);
}

fn parseCustoms(txt: []const u8) void {
    st.n_custom = 0;
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |raw_line| {
        const l = std.mem.trim(u8, raw_line, " \t\r");
        if (l.len == 0 or l[0] == '#' or st.n_custom >= MAX_CUSTOM) continue;
        var f = std.mem.splitScalar(u8, l, '|');
        const nm = std.mem.trim(u8, f.next() orelse continue, " ");
        const fm = std.mem.trim(u8, f.next() orelse continue, " ");
        const cmd = std.mem.trim(u8, f.rest(), " ");
        if (nm.len == 0 or cmd.len == 0) continue;
        var cu = &st.customs[st.n_custom];
        cu.* = .{};
        cu.name_len = @min(nm.len, cu.name.len);
        @memcpy(cu.name[0..cu.name_len], nm[0..cu.name_len]);
        cu.cmd_len = @min(cmd.len, cu.cmd.len);
        @memcpy(cu.cmd[0..cu.cmd_len], cmd[0..cu.cmd_len]);
        cu.fmt = Fmt.parse(fm) orelse .raw;
        st.n_custom += 1;
    }
}

// ---------------------------------------------------------------------------

test "custom agents and ansi" {
    parseCustoms("# comment\nAntigravity | raw | agy chat {prompt}\nbad line\n");
    try std.testing.expectEqual(@as(usize, 1), st.n_custom);
    try std.testing.expectEqualStrings("Antigravity", name(builtin.len));
    try std.testing.expectEqualStrings("ok", stripAnsiInPlace("\x1b[1;32mok\x1b[0m\r"));
}

test "claude output into chat" {
    const a = std.testing.allocator;
    st.alloc = a;
    st.msgs = std.ArrayList(*Msg).init(a);
    defer {
        for (st.msgs.items) |m| m.destroy(a);
        st.msgs.deinit();
    }
    st.cwd_len = 0;
    st.parser = .{ .fmt = .claude, .ctx = &st, .emit = onEvent, .alloc = a };
    for ([_][]const u8{
        "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"abc-123\"}",
        "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
        "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"text\":\"見て\"}}}",
        "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"text\":\"みます\"}}}",
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"見てみます\"}]}}",
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls -la\"}}]}}",
        "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"a\\nb\"}]}}",
    }) |l| st.parser.line(l);
    try std.testing.expectEqualStrings("abc-123", sessionId());
    try std.testing.expectEqual(@as(usize, 2), st.msgs.items.len);
    try std.testing.expectEqualStrings("見てみます", st.msgs.items[0].text.items);
    try std.testing.expectEqualStrings("Bash: ls -la\na\nb", st.msgs.items[1].text.items);
}

// ---------------------------------------------------------------------------
// 新しいプロジェクト
// ---------------------------------------------------------------------------

/// 名前だけで作るときの置き場: 設定の ai { projects-dir } → ~/projects(あれば)→ ホーム
pub fn projectsBase(buf: []u8) []const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    if (getApp()) |app| {
        const d = app.cfg.ai_projects_dir.get();
        if (d.len > 0) {
            if (std.mem.eql(u8, d, "~")) return home;
            if (std.mem.startsWith(u8, d, "~/")) return std.fmt.bufPrint(buf, "{s}{s}", .{ home, d[1..] }) catch d;
            return d;
        }
    }
    const p = std.fmt.bufPrint(buf, "{s}/projects", .{home}) catch return home;
    var dir = std.fs.cwd().openDir(p, .{}) catch return home;
    dir.close();
    return p;
}

/// プロジェクトの名前として使えるか(フォルダの名前 1 つ分)
pub fn validProjectName(n: []const u8) bool {
    if (n.len == 0 or n.len > 120 or n[0] == '.' or n[0] == '-') return false;
    for (n) |ch| if (ch == '/' or ch < 0x20) return false;
    return true;
}

/// フォルダを作り(親も)、git があれば git init する。作ったフォルダの絶対パスを buf に返す
pub fn createProject(path: []const u8, buf: []u8) ?[]const u8 {
    std.fs.cwd().makePath(path) catch return null;
    const real = std.fs.cwd().realpath(path, buf) catch return null;
    var gb: [std.fs.max_path_bytes + 8]u8 = undefined;
    const gpath = std.fmt.bufPrint(&gb, "{s}/.git", .{real}) catch return real;
    const has_git = if (std.fs.cwd().access(gpath, .{})) |_| true else |_| false;
    if (!has_git and hasBin("git")) {
        var zb: [std.fs.max_path_bytes + 1]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zb, "{s}", .{real}) catch return real;
        var out: [256]u8 = undefined;
        _ = sys.run(&.{ "git", "-C", z.ptr, "init", "-q" }, &out);
    }
    return real;
}

test "project names" {
    try std.testing.expect(validProjectName("my-app"));
    try std.testing.expect(validProjectName("日本語のアプリ"));
    try std.testing.expect(!validProjectName(".hidden"));
    try std.testing.expect(!validProjectName("a/b"));
    try std.testing.expect(!validProjectName(""));
}

/// パネルの下に出す一言(「新しいプロジェクトを作りました」など)
pub fn setNote(prefix: []const u8, s: []const u8) void {
    setStatus("{s}{s}", .{ prefix, s });
}
