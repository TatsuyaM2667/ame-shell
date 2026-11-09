// コーディング CLI(Claude Code・Gemini CLI・Codex・OpenCode・Kimi など)の出力を、共通の出来事に直す。
// 画面(agent.zig)と ame-agent コマンドの両方が使う。どちらも 1 行ずつ Parser.line に渡すだけ。
// Claude Code の会話の記録(~/.claude/projects/<フォルダ>/<id>.jsonl)の一覧と読み込みもここ。
const std = @import("std");

pub const Fmt = enum {
    /// Claude Code の stream-json(Qwen Code・Cursor Agent・Amp も同じ形)
    claude,
    gemini,
    codex,
    opencode,
    /// 役割ごとのメッセージ({"role":"assistant","content":…,"tool_calls":…})
    kimi,
    /// Antigravity CLI(agy)の stream-json(event: init / step_update / result)
    antigravity,
    /// 端末の出力をそのまま
    raw,

    pub fn parse(s: []const u8) ?Fmt {
        inline for (std.meta.fields(Fmt)) |f| if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        return null;
    }
};

/// 出力から読み取れた出来事。文字列は emit の呼び出しの間だけ有効
pub const Event = union(enum) {
    /// 会話(セッション)の id
    session: []const u8,
    /// 少しずつ届く返事の続き
    delta: []const u8,
    /// まとまった返事
    text: []const u8,
    /// 人が打った文(記録を読むときだけ)
    user: []const u8,
    /// ツールの実行の見出し(「Bash: ls -la」など)
    tool: []const u8,
    /// いちばん新しいツールの結果
    result: struct { text: []const u8, err: bool },
    @"error": []const u8,
    /// 返事の区切り(次の delta は新しい吹き出しにする)
    split,
    /// 終わり(Claude の result。分かれば料金)
    done: struct { cost: f64 },
    /// JSON でない行(色の指定などは取り除いてある)
    raw: []const u8,
};

pub const Parser = struct {
    fmt: Fmt,
    /// 作業フォルダ(ツールの見出しから省く)
    cwd: []const u8 = "",
    /// false なら会話の記録を読んでいる(人の発言も出す・session は出さない)
    live: bool = true,
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, ev: Event) void,
    /// 今の返事の区切りが、すでに delta で届いた
    seg_streamed: bool = false,
    /// Antigravity: 見出しを出した最後のツールの手順の番号
    last_step: i64 = -1,
    /// Antigravity: 会話の id はもう出した(行ごとに同じものが来るので 1 回だけ)
    got_session: bool = false,
    alloc: std.mem.Allocator = std.heap.c_allocator,
    ansi: [4096]u8 = undefined,

    fn ev(p: *Parser, e: Event) void {
        p.emit(p.ctx, e);
    }

    /// 出力の 1 行(改行は除いて渡す)
    pub fn line(p: *Parser, raw_line: []const u8) void {
        const l = std.mem.trimRight(u8, raw_line, "\r");
        if (p.fmt == .raw) return p.rawLine(l);
        const t = std.mem.trim(u8, l, " ");
        if (t.len == 0) return;
        if (t[0] != '{') return p.rawLine(l);
        const parsed = std.json.parseFromSlice(std.json.Value, p.alloc, t, .{}) catch return p.rawLine(l);
        defer parsed.deinit();
        const v = parsed.value;
        if (v != .object) return p.rawLine(l);
        switch (p.fmt) {
            .claude => p.claude(v),
            .gemini => p.gemini(v),
            .codex => p.codex(v),
            .opencode => p.opencode(v),
            .kimi => p.kimi(v),
            .antigravity => p.antigravity(v),
            .raw => unreachable,
        }
    }

    fn rawLine(p: *Parser, l: []const u8) void {
        p.ev(.{ .raw = stripAnsi(l, &p.ansi) });
    }

    fn title(p: *Parser, tool: []const u8, input: ?std.json.Value) void {
        var tb: [256]u8 = undefined;
        p.ev(.{ .tool = toolTitle(tool, input, p.cwd, &tb) });
    }

    fn result(p: *Parser, v: ?std.json.Value, err: bool) void {
        var out = std.ArrayList(u8).init(p.alloc);
        defer out.deinit();
        if (v) |x| resultText(x, &out);
        p.ev(.{ .result = .{ .text = out.items, .err = err } });
    }

    /// Claude Code の stream-json / 会話の記録(.jsonl)の 1 行
    fn claude(p: *Parser, v: std.json.Value) void {
        const ty = getStr(v, "type") orelse return;
        const eq = std.mem.eql;
        if (getBool(v, "isSidechain") or getBool(v, "isMeta") or getBool(v, "isCompactSummary")) return;
        if (p.live) if (getStr(v, "session_id")) |sid| p.ev(.{ .session = sid });
        if (eq(u8, ty, "system")) return;
        if (eq(u8, ty, "stream_event")) {
            const e = getVal(v, "event") orelse return;
            const et = getStr(e, "type") orelse return;
            if (eq(u8, et, "content_block_start")) {
                p.seg_streamed = false;
                p.ev(.split);
            } else if (eq(u8, et, "content_block_delta")) {
                const d = getVal(e, "delta") orelse return;
                if (getStr(d, "text")) |t| {
                    p.ev(.{ .delta = t });
                    p.seg_streamed = true;
                }
            }
            return;
        }
        if (eq(u8, ty, "assistant") or eq(u8, ty, "user")) {
            const msg = getVal(v, "message") orelse return;
            const content = getVal(msg, "content") orelse return;
            const is_user = eq(u8, ty, "user");
            const streamed = p.live and p.seg_streamed;
            if (content == .string) {
                if (is_user and !p.live) p.human(content.string);
                if (!is_user and !streamed) p.ev(.{ .text = content.string });
                return;
            }
            if (content != .array) return;
            for (content.array.items) |b| {
                const bt = getStr(b, "type") orelse continue;
                if (eq(u8, bt, "text")) {
                    const t = getStr(b, "text") orelse continue;
                    if (is_user) {
                        if (!p.live) p.human(t);
                    } else if (!streamed) p.ev(.{ .text = t });
                } else if (eq(u8, bt, "tool_use")) {
                    p.title(getStr(b, "name") orelse "ツール", getVal(b, "input"));
                } else if (eq(u8, bt, "tool_result")) {
                    p.result(getVal(b, "content"), getBool(b, "is_error"));
                }
            }
            if (!is_user and p.live) p.ev(.split);
            return;
        }
        if (eq(u8, ty, "result")) {
            if (getBool(v, "is_error")) p.ev(.{ .@"error" = getStr(v, "result") orelse getStr(v, "subtype") orelse "エラーで止まりました" });
            const cost: f64 = if (getVal(v, "total_cost_usd")) |cv| switch (cv) {
                .float => cv.float,
                .integer => @floatFromInt(cv.integer),
                else => 0,
            } else 0;
            p.ev(.{ .done = .{ .cost = cost } });
        }
    }

    /// 人が打った文だけを会話として出す(<command-name> などの内部の文は出さない)
    fn human(p: *Parser, t: []const u8) void {
        const tt = std.mem.trim(u8, t, " \n");
        if (tt.len == 0 or tt[0] == '<') return;
        if (std.mem.startsWith(u8, tt, "[Request interrupted")) return;
        p.ev(.{ .user = tt });
    }

    fn gemini(p: *Parser, v: std.json.Value) void {
        const ty = getStr(v, "type") orelse return;
        const eq = std.mem.eql;
        if (getStr(v, "session_id")) |sid| p.ev(.{ .session = sid });
        if (eq(u8, ty, "message")) {
            const role = getStr(v, "role") orelse "assistant";
            if (!eq(u8, role, "assistant")) return;
            const t = getStr(v, "content") orelse return;
            p.ev(if (getBool(v, "delta")) .{ .delta = t } else .{ .text = t });
        } else if (eq(u8, ty, "tool_use")) {
            p.title(getStr(v, "tool_name") orelse "ツール", getVal(v, "parameters"));
        } else if (eq(u8, ty, "tool_result")) {
            p.result(getVal(v, "output"), if (getStr(v, "status")) |s| eq(u8, s, "error") else false);
        } else if (eq(u8, ty, "error")) {
            p.ev(.{ .@"error" = getStr(v, "message") orelse "エラー" });
        }
    }

    fn codex(p: *Parser, v: std.json.Value) void {
        const ty = getStr(v, "type") orelse return;
        const eq = std.mem.eql;
        if (eq(u8, ty, "thread.started")) {
            if (getStr(v, "thread_id")) |id| p.ev(.{ .session = id });
        } else if (eq(u8, ty, "item.completed")) {
            const item = getVal(v, "item") orelse return;
            const it = getStr(item, "type") orelse getStr(item, "item_type") orelse return;
            if (eq(u8, it, "agent_message") or eq(u8, it, "assistant_message")) {
                p.ev(.{ .text = getStr(item, "text") orelse "" });
            } else if (eq(u8, it, "command_execution")) {
                p.title("$", getVal(item, "command"));
                const code = getVal(item, "exit_code");
                const bad = if (code) |cv| cv == .integer and cv.integer != 0 else false;
                p.ev(.{ .result = .{ .text = getStr(item, "aggregated_output") orelse "", .err = bad } });
            } else if (eq(u8, it, "file_change")) {
                var list = std.ArrayList(u8).init(p.alloc);
                defer list.deinit();
                list.appendSlice("ファイルの変更:") catch {};
                if (getVal(item, "changes")) |ch| if (ch == .array) for (ch.array.items) |e| {
                    list.append(' ') catch {};
                    list.appendSlice(getStr(e, "path") orelse "?") catch {};
                };
                p.ev(.{ .tool = list.items });
            } else if (eq(u8, it, "mcp_tool_call")) {
                var tb: [256]u8 = undefined;
                p.ev(.{ .tool = std.fmt.bufPrint(&tb, "MCP: {s}.{s}", .{ getStr(item, "server") orelse "?", getStr(item, "tool") orelse "?" }) catch "MCP" });
            } else if (eq(u8, it, "web_search")) {
                p.title("検索", getVal(item, "query"));
            } else if (eq(u8, it, "error")) {
                p.ev(.{ .@"error" = getStr(item, "message") orelse "エラー" });
            }
        } else if (eq(u8, ty, "turn.failed")) {
            const e = getVal(v, "error");
            p.ev(.{ .@"error" = if (e) |x| getStr(x, "message") orelse "失敗しました" else "失敗しました" });
        } else if (eq(u8, ty, "error")) {
            p.ev(.{ .@"error" = getStr(v, "message") orelse "エラー" });
        }
    }

    fn opencode(p: *Parser, v: std.json.Value) void {
        const ty = getStr(v, "type") orelse return;
        const eq = std.mem.eql;
        if (getStr(v, "sessionID")) |sid| p.ev(.{ .session = sid });
        const part = getVal(v, "part");
        if (eq(u8, ty, "text")) {
            if (part) |x| p.ev(.{ .text = getStr(x, "text") orelse "" });
        } else if (eq(u8, ty, "tool_use") or eq(u8, ty, "tool")) {
            const x = part orelse return;
            const state = getVal(x, "state");
            const t = if (state) |s| getStr(s, "title") else null;
            if (t) |tt| {
                var tb: [256]u8 = undefined;
                p.ev(.{ .tool = std.fmt.bufPrint(&tb, "{s}: {s}", .{ getStr(x, "tool") orelse "ツール", tt }) catch tt });
            } else p.title(getStr(x, "tool") orelse "ツール", if (state) |s| getVal(s, "input") else null);
            if (state) |s| p.ev(.{ .result = .{
                .text = getStr(s, "output") orelse getStr(s, "error") orelse "",
                .err = if (getStr(s, "status")) |st| eq(u8, st, "error") else false,
            } });
        } else if (eq(u8, ty, "error")) {
            var msg: []const u8 = "エラー";
            if (getVal(v, "error")) |e| {
                if (getStr(e, "message")) |m| msg = m;
                if (getVal(e, "data")) |d| if (getStr(d, "message")) |m| {
                    msg = m;
                };
            }
            p.ev(.{ .@"error" = msg });
        }
    }

    /// Antigravity CLI(agy -p --output-format stream-json)の 1 行。
    /// {"event":"init"|"step_update"|"result", "conversation_id"…}。step_update の step_type が
    /// agent_response(text_delta で少しずつ)・tool(ACTIVE で始まり DONE / ERROR で output / error)
    fn antigravity(p: *Parser, v: std.json.Value) void {
        const kind = getStr(v, "event") orelse return;
        const eq = std.mem.eql;
        // 会話の id は init では一番外、step_update・result では中にある
        if (p.live and !p.got_session) {
            const inner = getVal(v, "step_update") orelse getVal(v, "result");
            if (getStr(v, "conversation_id") orelse (if (inner) |x| getStr(x, "conversation_id") else null)) |sid| {
                p.ev(.{ .session = sid });
                p.got_session = true;
            }
        }
        if (eq(u8, kind, "result")) {
            const r = getVal(v, "result") orelse return;
            const status = getStr(r, "status") orelse "";
            if (status.len > 0 and !eq(u8, status, "SUCCESS")) {
                const msg = getStr(r, "response") orelse "";
                p.ev(.{ .@"error" = if (msg.len > 0) msg else status });
            }
            p.ev(.{ .done = .{ .cost = 0 } });
            return;
        }
        if (!eq(u8, kind, "step_update")) return;
        const s = getVal(v, "step_update") orelse return;
        const ty = getStr(s, "step_type") orelse return;
        const state = getStr(s, "state") orelse "";
        const step: i64 = if (getVal(s, "step_index")) |x| (if (x == .integer) x.integer else -1) else -1;
        if (eq(u8, ty, "agent_response")) {
            if (getStr(s, "text_delta")) |t| p.ev(.{ .delta = t });
            if (eq(u8, state, "DONE")) p.ev(.split);
        } else if (eq(u8, ty, "tool")) {
            const info = getVal(s, "tool_info");
            const name = getStr(s, "tool_name") orelse (if (info) |i| getStr(i, "name") else null) orelse "ツール";
            // 見出しは 1 つの手順につき 1 回(ACTIVE と DONE の両方に同じものが来る)
            if (step != p.last_step) {
                p.last_step = step;
                p.title(name, if (info) |i| getVal(i, "parameters") else null);
            }
            if (eq(u8, state, "DONE")) {
                p.result(if (info) |i| getVal(i, "output") else null, false);
            } else if (eq(u8, state, "ERROR")) {
                const e = if (info) |i| getVal(i, "error") else null;
                p.ev(.{ .result = .{ .text = if (e) |x| getStr(x, "message") orelse "失敗しました" else "失敗しました", .err = true } });
            }
        }
    }

    fn kimi(p: *Parser, v: std.json.Value) void {
        const role = getStr(v, "role") orelse return p.claude(v);
        const eq = std.mem.eql;
        if (eq(u8, role, "assistant")) {
            if (getVal(v, "content")) |cv| {
                var out = std.ArrayList(u8).init(p.alloc);
                defer out.deinit();
                resultText(cv, &out);
                p.ev(.{ .text = out.items });
            }
            if (getVal(v, "tool_calls")) |tc| if (tc == .array) for (tc.array.items) |call| {
                const f = getVal(call, "function") orelse continue;
                // arguments は JSON の文字列
                var parsed: ?std.json.Parsed(std.json.Value) = null;
                defer if (parsed) |x| x.deinit();
                if (getStr(f, "arguments")) |a| parsed = std.json.parseFromSlice(std.json.Value, p.alloc, a, .{}) catch null;
                p.title(getStr(f, "name") orelse "ツール", if (parsed) |x| x.value else null);
            };
        } else if (eq(u8, role, "tool")) {
            p.result(getVal(v, "content"), false);
        }
    }
};

pub fn getStr(v: std.json.Value, k: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(k) orelse return null;
    return if (x == .string) x.string else null;
}

fn getVal(v: std.json.Value, k: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(k);
}

fn getBool(v: std.json.Value, k: []const u8) bool {
    const x = getVal(v, k) orelse return false;
    return x == .bool and x.bool;
}

/// ツールの見出し(「Bash: ls -la」「Edit: src/main.zig」など)
pub fn toolTitle(tool: []const u8, input: ?std.json.Value, dir: []const u8, buf: []u8) []const u8 {
    var arg: []const u8 = "";
    if (input) |in| {
        if (in == .object) {
            for ([_][]const u8{ "command", "cmd", "CommandLine", "file_path", "filePath", "AbsolutePath", "TargetFile", "path", "absolute_path", "DirectoryPath", "SearchPath", "pattern", "Pattern", "url", "Url", "query", "Query", "description", "prompt", "title" }) |k| {
                if (getStr(in, k)) |s| {
                    arg = s;
                    break;
                }
            }
        } else if (in == .string) arg = in.string;
    }
    // 1 行目だけ・作業フォルダは省く
    if (std.mem.indexOfScalar(u8, arg, '\n')) |nl| arg = arg[0..nl];
    if (dir.len > 0 and std.mem.startsWith(u8, arg, dir) and arg.len > dir.len and arg[dir.len] == '/') arg = arg[dir.len + 1 ..];
    if (arg.len > 160) arg = arg[0..160];
    if (arg.len == 0) return std.fmt.bufPrint(buf, "{s}", .{tool}) catch tool;
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ tool, arg }) catch tool;
}

/// ツールの結果(文字列 / [{type:text,text}] / その他は JSON のまま)の文字
fn resultText(v: std.json.Value, buf: *std.ArrayList(u8)) void {
    switch (v) {
        .string => |s| buf.appendSlice(s) catch {},
        .array => |a| for (a.items) |e| {
            if (getStr(e, "text")) |t| {
                if (buf.items.len > 0) buf.append('\n') catch {};
                buf.appendSlice(t) catch {};
            } else if (e == .string) buf.appendSlice(e.string) catch {};
        },
        .object => if (getStr(v, "text") orelse getStr(v, "output") orelse getStr(v, "content")) |t| buf.appendSlice(t) catch {},
        else => {},
    }
}

/// 端末の色の指定(ESC [ … / ESC ] …)と CR を取り除く。out に入りきらない分は捨てる
pub fn stripAnsi(s: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) {
        const ch = s[i];
        if (ch == 0x1b) {
            i += 1;
            if (i < s.len and s[i] == '[') {
                i += 1;
                while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) i += 1;
                i += 1;
            } else if (i < s.len and s[i] == ']') {
                while (i < s.len and s[i] != 0x07 and s[i] != 0x1b) i += 1;
                i += 1;
            } else i += 1;
            continue;
        }
        if (ch == '\r') {
            i += 1;
            continue;
        }
        // タブは字形が無く □ になるので、空白 2 つに(ls の出力などの区切り)
        if (ch == '\t') {
            out[n] = ' ';
            n += 1;
            if (n < out.len) {
                out[n] = ' ';
                n += 1;
            }
            i += 1;
            continue;
        }
        out[n] = ch;
        n += 1;
        i += 1;
    }
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Claude Code の会話の記録
// ---------------------------------------------------------------------------

pub fn claudeDir(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("CLAUDE_CONFIG_DIR")) |d| if (d.len > 0) return std.fmt.bufPrint(buf, "{s}/projects", .{d}) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.claude/projects", .{home}) catch null;
}

/// フォルダの記録の置き場(英数字以外を - にした名前)
fn claudeProjectDir(dir: []const u8, buf: []u8) ?[]const u8 {
    var db: [512]u8 = undefined;
    const base = claudeDir(&db) orelse return null;
    var nb: [1100]u8 = undefined;
    const n = @min(dir.len, nb.len);
    for (dir[0..n], 0..) |ch, i| nb[i] = if (std.ascii.isAlphanumeric(ch)) ch else '-';
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, nb[0..n] }) catch null;
}

pub const SessionInfo = struct { id: []const u8, title: []const u8, mtime: i128 };

/// そのフォルダの Claude Code の会話(新しい順・最大 60)。文字列は arena に置く
pub fn listSessions(arena: std.mem.Allocator, dir: []const u8, out: *std.ArrayList(SessionInfo)) void {
    var pb: [1700]u8 = undefined;
    const pdir = claudeProjectDir(dir, &pb) orelse return;
    var d = std.fs.cwd().openDir(pdir, .{ .iterate = true }) catch return;
    defer d.close();
    var it = d.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".jsonl")) continue;
        const f = d.openFile(e.name, .{}) catch continue;
        defer f.close();
        const stt = f.stat() catch continue;
        const t = scanFirstPrompt(arena, f) orelse continue;
        out.append(.{ .id = arena.dupe(u8, e.name[0 .. e.name.len - 6]) catch continue, .title = t, .mtime = stt.mtime }) catch {};
    }
    std.mem.sort(SessionInfo, out.items, {}, struct {
        fn lt(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.mtime > b.mtime;
        }
    }.lt);
    if (out.items.len > 60) out.shrinkRetainingCapacity(60);
}

/// 記録を少しずつ読み、最初の人の発言を探す(長いツールの結果の行が先に来ることがあるので、最大 8MB まで)
fn scanFirstPrompt(arena: std.mem.Allocator, f: std.fs.File) ?[]const u8 {
    var buf = std.ArrayList(u8).init(std.heap.c_allocator);
    defer buf.deinit();
    var chunk: [262144]u8 = undefined;
    var from: usize = 0; // まだ調べていない行の先頭
    while (buf.items.len < 8 << 20) {
        const n = f.read(&chunk) catch return null;
        if (n == 0) break;
        buf.appendSlice(chunk[0..n]) catch return null;
        const last_nl = std.mem.lastIndexOfScalar(u8, buf.items, '\n') orelse continue;
        if (last_nl + 1 <= from) continue;
        if (firstPrompt(arena, buf.items[from .. last_nl + 1])) |t| return t;
        from = last_nl + 1;
    }
    if (from < buf.items.len) return firstPrompt(arena, buf.items[from..]);
    return null;
}

/// 記録の最初の、人が打った文(160 バイトまで・改行は空白に)
fn firstPrompt(arena: std.mem.Allocator, head: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, "\"type\":\"user\"") == null) continue;
        const p = std.json.parseFromSlice(std.json.Value, arena, l, .{}) catch continue;
        const v = p.value;
        if (getBool(v, "isMeta") or getBool(v, "isSidechain") or getBool(v, "isCompactSummary")) continue;
        const msg = getVal(v, "message") orelse continue;
        const content = getVal(msg, "content") orelse continue;
        var t: []const u8 = "";
        if (content == .string) t = content.string else if (content == .array) {
            for (content.array.items) |b| if (getStr(b, "text")) |x| {
                t = x;
                break;
            };
        }
        t = std.mem.trim(u8, t, " \n");
        if (t.len == 0 or t[0] == '<') continue;
        var out = arena.alloc(u8, @min(t.len, 160)) catch return null;
        for (t[0..out.len], 0..) |ch, i| out[i] = if (ch == '\n') ' ' else ch;
        // UTF-8 の途中で切らない
        var n = out.len;
        if (n < t.len) while (n > 0 and (out[n - 1] & 0xC0) == 0x80) {
            n -= 1;
        };
        if (n < t.len and n > 0 and out[n - 1] >= 0xC0) n -= 1;
        return out[0..n];
    }
    return null;
}

/// 会話の記録を p に流す(大きい記録は最後の 8MB だけ)。p.fmt は .claude、p.live は false にしておく
pub fn loadHistory(alloc: std.mem.Allocator, dir: []const u8, id: []const u8, p: *Parser) bool {
    var pb: [1700]u8 = undefined;
    const pdir = claudeProjectDir(dir, &pb) orelse return false;
    var fb: [1900]u8 = undefined;
    const path = std.fmt.bufPrint(&fb, "{s}/{s}.jsonl", .{ pdir, id }) catch return false;
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    const size = (f.stat() catch return false).size;
    const cap: u64 = 8 << 20;
    if (size > cap) f.seekTo(size - cap) catch return false;
    const data = f.readToEndAlloc(alloc, cap + 1) catch return false;
    defer alloc.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    if (size > cap) _ = it.next(); // 途中から読んだ最初の行は捨てる
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \r");
        if (t.len > 0 and t[0] == '{') p.line(t);
    }
    return true;
}

// ---------------------------------------------------------------------------

/// 試験用: 出来事を「種類:文字」の行にして貯める
const Collect = struct {
    out: std.ArrayList(u8),
    fn emit(ctx: *anyopaque, e: Event) void {
        const self: *Collect = @ptrCast(@alignCast(ctx));
        const w = self.out.writer();
        switch (e) {
            .split => w.writeAll("split\n") catch {},
            .done => |d| w.print("done:{d}\n", .{d.cost}) catch {},
            .result => |r| w.print("result{s}:{s}\n", .{ if (r.err) "!" else "", r.text }) catch {},
            inline else => |s, tag| w.print("{s}:{s}\n", .{ @tagName(tag), s }) catch {},
        }
    }
};

fn collect(fmt: Fmt, live: bool, lines: []const []const u8) ![]u8 {
    var c = Collect{ .out = std.ArrayList(u8).init(std.testing.allocator) };
    var p = Parser{ .fmt = fmt, .live = live, .cwd = "/w", .ctx = &c, .emit = Collect.emit, .alloc = std.testing.allocator };
    for (lines) |l| p.line(l);
    return c.out.toOwnedSlice();
}

test "claude stream-json" {
    const got = try collect(.claude, true, &.{
        "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"abc-123\"}",
        "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}",
        "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"見て\"}}}",
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"見て\"}]}}",
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls /w/src\\nsecond\"}}]}}",
        "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":[{\"type\":\"text\",\"text\":\"a\"}],\"is_error\":true}]}}",
        "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.5}",
        "not json \x1b[1mbold\x1b[0m",
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "session:abc-123\nsplit\ndelta:見て\nsplit\ntool:Bash: ls /w/src\nsplit\nresult!:a\ndone:0.5\nraw:not json bold\n",
        got,
    );
}

test "claude history" {
    const got = try collect(.claude, false, &.{
        "{\"type\":\"user\",\"session_id\":\"x\",\"message\":{\"role\":\"user\",\"content\":\"<command-name>/clear</command-name>\"}}",
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"直して\"}}",
        "{\"type\":\"assistant\",\"isSidechain\":true,\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"sub\"}]}}",
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"はい\"}]}}",
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("user:直して\ntext:はい\n", got);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("最初の頼みごと", firstPrompt(arena.allocator(), "{\"type\":\"user\",\"message\":{\"content\":\"<x>\"}}\n{\"type\":\"user\",\"message\":{\"content\":\"最初の頼みごと\"}}\n").?);
}

test "other formats" {
    const got = try collect(.codex, true, &.{
        "{\"type\":\"thread.started\",\"thread_id\":\"t9\"}",
        "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"command\":\"make\",\"aggregated_output\":\"ok\",\"exit_code\":2}}",
        "{\"type\":\"turn.failed\",\"error\":{\"message\":\"ダメ\"}}",
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("session:t9\ntool:$: make\nresult!:ok\nerror:ダメ\n", got);
    const k = try collect(.kimi, true, &.{
        "{\"role\":\"assistant\",\"content\":\"やります\",\"tool_calls\":[{\"function\":{\"name\":\"Shell\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}",
        "{\"role\":\"tool\",\"content\":\"x\"}",
    });
    defer std.testing.allocator.free(k);
    try std.testing.expectEqualStrings("text:やります\ntool:Shell: ls\nresult:x\n", k);
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ok", stripAnsi("\x1b[1;32mok\x1b[0m\r", &b));
}

test "antigravity stream-json" {
    // agy -p … --output-format stream-json が実際に出したもの(短くしたもの)
    const got = try collect(.antigravity, true, &.{
        "{\"event\":\"init\",\"conversation_id\":\"c1\",\"init\":{\"cwd\":\"/w\"}}",
        "{\"event\":\"step_update\",\"step_update\":{\"conversation_id\":\"c1\",\"step_index\":0,\"state\":\"DONE\",\"step_type\":\"user_input\"}}",
        "{\"event\":\"step_update\",\"step_update\":{\"step_index\":1,\"state\":\"ACTIVE\",\"step_type\":\"agent_response\",\"text_delta\":\"見て\"}}",
        "{\"event\":\"step_update\",\"step_update\":{\"step_index\":1,\"state\":\"DONE\",\"step_type\":\"agent_response\",\"text_delta\":\"みます\"}}",
        "{\"event\":\"step_update\",\"step_update\":{\"step_index\":2,\"state\":\"ACTIVE\",\"step_type\":\"tool\",\"tool_name\":\"run_command\",\"tool_info\":{\"name\":\"run_command\",\"parameters\":{\"CommandLine\":\"ls -a\"}}}}",
        "{\"event\":\"step_update\",\"step_update\":{\"step_index\":2,\"state\":\"DONE\",\"step_type\":\"tool\",\"tool_name\":\"run_command\",\"tool_info\":{\"name\":\"run_command\",\"parameters\":{\"CommandLine\":\"ls -a\"},\"output\":\"a.txt\"}}}",
        "{\"event\":\"step_update\",\"step_update\":{\"step_index\":3,\"state\":\"ERROR\",\"step_type\":\"tool\",\"tool_name\":\"run_command\",\"tool_info\":{\"parameters\":{\"CommandLine\":\"ps\"},\"error\":{\"type\":\"TOOL_ERROR\",\"message\":\"denied\"}}}}",
        "{\"event\":\"result\",\"result\":{\"conversation_id\":\"c1\",\"status\":\"SUCCESS\",\"response\":\"ok\"}}",
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "session:c1\ndelta:見て\ndelta:みます\nsplit\ntool:run_command: ls -a\nresult:a.txt\ntool:run_command: ps\nresult!:denied\ndone:0\n",
        got,
    );
}

test "tabs become spaces" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings(".  ..  a", stripAnsi(".\t..\ta\r", &b));
}
