// ame-ai: いろいろな会社の AI と API で話す。
//
//   echo 質問 | ame-ai [-p 会社] [-m モデル] [-s 指示] [-i 画像]…  返事の文章を標準出力へ(届いた分から)
//   ame-ai --json [-p …] [-m …] [-s …] [--mcp 名前,名前] < 会話.json  1 行 1 つの出来事(JSON)を標準出力へ
//   ame-ai models [-p 会社]                                          その会社のモデルの id を 1 行ずつ
//   ame-ai providers                                                 会社の id と名前
//
// 会社とモデルを省くと、ame-shell の AI チャットで最後に選んだもの($XDG_STATE_HOME/ame-shell/ai)。
// --json の会話の形は lib/ai.zig の parseConversation。出来事は:
//   {"type":"status","text":…}                       準備中など
//   {"type":"text","text":…} / {"type":"think",…}    返事の文章・考えている途中(少しずつ)
//   {"type":"tool_call","id","name","arguments","label"}  モデルが MCP のツールを呼んだ(このあと実行する)
//   {"type":"tool_result","id","content","error"}     ツールの結果。このあと、続きの返事が始まる
//   {"type":"error","message":…}                      失敗(終了コード 1)
//   {"type":"done"}
// --mcp で選んだ stdio の MCP サーバを起動し、ツールをモデルに渡す。モデルが呼んだら実行して結果を返し、
// 続きを答えさせる(12 往復まで)。API キーはコマンドラインに出さず curl の標準入力(-K -)で渡す。
// 止めるときはプロセスグループごと(curl・MCP サーバも)止める。
const std = @import("std");
const lib = @import("ame_lib");
const ai = lib.ai;
const mcpcfg = lib.mcp;

const HTTP_MARK = "__AME_HTTP__";
const MAX_ROUNDS = 12;

var out_json = false;
var stdout_buf: std.io.BufferedWriter(4096, std.fs.File.Writer) = undefined;

fn emit(v: anytype) void {
    const w = stdout_buf.writer();
    std.json.stringify(v, .{}, w) catch return;
    w.writeByte('\n') catch return;
    stdout_buf.flush() catch {};
}

fn emitText(kind: []const u8, s: []const u8) void {
    if (s.len == 0) return;
    if (out_json) return emit(.{ .type = kind, .text = s });
    if (!std.mem.eql(u8, kind, "text")) return; // 文章だけのときは、考えている途中は出さない
    stdout_buf.writer().writeAll(s) catch {};
    stdout_buf.flush() catch {};
}

fn fail(msg: []const u8) noreturn {
    if (out_json) emit(.{ .type = "error", .message = msg }) else std.io.getStdErr().writer().print("ame-ai: {s}\n", .{msg}) catch {};
    std.process.exit(1);
}

// ---------------------------------------------------------------------------
// 1 行ずつ読む(待ち時間の上限つき)
// ---------------------------------------------------------------------------

const LineReader = struct {
    fd: std.posix.fd_t,
    buf: std.ArrayList(u8),
    start: usize = 0,

    /// 次の 1 行(改行は除く)。終わり・時間切れは null
    fn next(self: *LineReader, timeout_ms: i32) ?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.buf.items, self.start, '\n')) |nl| {
                const line = self.buf.items[self.start..nl];
                self.start = nl + 1;
                return std.mem.trimRight(u8, line, "\r");
            }
            // 読み終えた分を詰める
            if (self.start > 0) {
                std.mem.copyForwards(u8, self.buf.items, self.buf.items[self.start..]);
                self.buf.shrinkRetainingCapacity(self.buf.items.len - self.start);
                self.start = 0;
            }
            var pfd = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&pfd, timeout_ms) catch return null;
            if (n == 0) return null;
            var tmp: [16384]u8 = undefined;
            const got = std.posix.read(self.fd, &tmp) catch return null;
            if (got == 0) {
                // 最後の改行の無い行
                if (self.buf.items.len > self.start) {
                    const line = self.buf.items[self.start..];
                    self.start = self.buf.items.len;
                    return line;
                }
                return null;
            }
            // 改行の来ないまま 8MB を超える応答は壊れているとみなす(メモリを食い尽くさない)
            if (self.buf.items.len + got > 8 << 20) return null;
            self.buf.appendSlice(tmp[0..got]) catch return null;
        }
    }
};

// ---------------------------------------------------------------------------
// MCP のサーバ(stdio。JSON-RPC、1 行 1 メッセージ)
// ---------------------------------------------------------------------------

const McpServer = struct {
    name: []const u8,
    child: std.process.Child,
    lines: LineReader,
    next_id: u32 = 3,

    fn send(self: *McpServer, msg: []const u8) void {
        const in = self.child.stdin orelse return;
        in.writeAll(msg) catch return;
        in.writeAll("\n") catch {};
    }

    /// id の返事を待つ(サーバからの問い合わせ ping / roots/list には空で答える)
    fn waitFor(self: *McpServer, a: std.mem.Allocator, id: u32, timeout_ms: i32) ?std.json.Value {
        while (self.lines.next(timeout_ms)) |line| {
            const t = std.mem.trim(u8, line, " ");
            if (t.len == 0 or t[0] != '{') continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, t, .{}) catch continue;
            if (v != .object) continue;
            if (v.object.get("method")) |m| {
                if (v.object.get("id")) |idv| if (m == .string) {
                    const res = if (std.mem.eql(u8, m.string, "roots/list")) "{\"roots\":[]}" else "{}";
                    const ids = std.json.stringifyAlloc(a, idv, .{}) catch continue;
                    self.send(std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ ids, res }) catch continue);
                };
                continue;
            }
            const idv = v.object.get("id") orelse continue;
            if (idv == .integer and idv.integer == id) return v;
        }
        return null;
    }
};

const ToolRef = struct { server: *McpServer, tool: []const u8 };

const Mcp = struct {
    a: std.mem.Allocator,
    servers: std.ArrayList(*McpServer),
    defs: std.ArrayList(ai.ToolDef),
    refs: std.ArrayList(ToolRef),

    fn start(a: std.mem.Allocator, names: []const u8) Mcp {
        var m = Mcp{ .a = a, .servers = std.ArrayList(*McpServer).init(a), .defs = std.ArrayList(ai.ToolDef).init(a), .refs = std.ArrayList(ToolRef).init(a) };
        if (names.len == 0) return m;
        var all = std.ArrayList(mcpcfg.Server).init(a);
        mcpcfg.loadAll(a, &all);
        var it = std.mem.tokenizeScalar(u8, names, ',');
        while (it.next()) |want| for (all.items) |s| {
            if (!std.mem.eql(u8, s.name, want) or s.kind != .stdio) continue;
            if (out_json) emit(.{ .type = "status", .text = std.fmt.allocPrint(a, "MCP サーバ {s} を準備しています…", .{s.name}) catch "" });
            m.open(s) catch |e| std.io.getStdErr().writer().print("ame-ai: MCP サーバ {s} を使えません: {s}\n", .{ s.name, @errorName(e) }) catch {};
        };
        return m;
    }

    fn open(self: *Mcp, s: mcpcfg.Server) !void {
        const a = self.a;
        var argv = std.ArrayList([]const u8).init(a);
        try argv.append(s.command);
        try argv.appendSlice(s.args);
        const env = try a.create(std.process.EnvMap);
        env.* = try std.process.getEnvMap(a);
        for (s.env) |kv| if (std.mem.indexOfScalar(u8, kv, '=')) |eq| try env.put(kv[0..eq], kv[eq + 1 ..]);
        const sv = try a.create(McpServer);
        sv.* = .{ .name = s.name, .child = std.process.Child.init(argv.items, a), .lines = undefined };
        sv.child.stdin_behavior = .Pipe;
        sv.child.stdout_behavior = .Pipe;
        sv.child.stderr_behavior = .Ignore;
        sv.child.env_map = env;
        try sv.child.spawn();
        sv.lines = .{ .fd = sv.child.stdout.?.handle, .buf = std.ArrayList(u8).init(a) };
        sv.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"ame-ai\",\"version\":\"1.0\"}}}");
        const init_r = sv.waitFor(a, 1, 20_000) orelse return error.NoResponse;
        if (init_r.object.get("result") == null) return error.InitFailed;
        sv.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
        sv.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}");
        const list_r = sv.waitFor(a, 2, 20_000) orelse return error.NoResponse;
        try self.servers.append(sv);
        const res = list_r.object.get("result") orelse return;
        if (res != .object) return;
        const tools = res.object.get("tools") orelse return;
        if (tools != .array) return;
        for (tools.array.items) |tv| {
            const nm = ai.getStr(tv, "name") orelse continue;
            const desc = ai.getStr(tv, "description") orelse "";
            const schema = if (tv.object.get("inputSchema")) |sc| try std.json.stringifyAlloc(a, sc, .{}) else "{\"type\":\"object\"}";
            try self.defs.append(.{ .name = try mcpcfg.toolName(a, s.name, nm), .description = desc[0..@min(desc.len, 1024)], .schema = schema });
            try self.refs.append(.{ .server = sv, .tool = nm });
        }
    }

    fn find(self: *Mcp, qname: []const u8) ?ToolRef {
        for (self.defs.items, 0..) |d, i| if (std.mem.eql(u8, d.name, qname)) return self.refs.items[i];
        return null;
    }

    /// ツールを呼んで、結果の文字とエラーかを返す
    fn call(self: *Mcp, qname: []const u8, args: []const u8) struct { text: []const u8, err: bool } {
        const a = self.a;
        const ref = self.find(qname) orelse return .{ .text = "そのツールはありません", .err = true };
        const sv = ref.server;
        const id = sv.next_id;
        sv.next_id += 1;
        const trimmed = std.mem.trim(u8, args, " \n");
        const req = std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":{s},\"arguments\":{s}}}}}", .{
            id,
            std.json.stringifyAlloc(a, ref.tool, .{}) catch "\"\"",
            if (trimmed.len > 0 and trimmed[0] == '{') trimmed else "{}",
        }) catch return .{ .text = "失敗", .err = true };
        sv.send(req);
        const r = sv.waitFor(a, id, 120_000) orelse return .{ .text = "MCP サーバから返事がありませんでした", .err = true };
        if (r.object.get("error")) |e| return .{ .text = ai.getStr(e, "message") orelse "エラー", .err = true };
        const res = r.object.get("result") orelse return .{ .text = "", .err = false };
        if (res != .object) return .{ .text = "", .err = false };
        var out = std.ArrayList(u8).init(a);
        const is_err = if (res.object.get("isError")) |ie| ie == .bool and ie.bool else false;
        if (res.object.get("content")) |cv| if (cv == .array) for (cv.array.items) |item| {
            const ty = ai.getStr(item, "type") orelse continue;
            if (out.items.len > 0) out.append('\n') catch {};
            if (std.mem.eql(u8, ty, "text")) out.appendSlice(ai.getStr(item, "text") orelse "") catch {} else out.writer().print("[{s}]", .{ty}) catch {};
        };
        if (out.items.len == 0) if (res.object.get("structuredContent")) |sc| std.json.stringify(sc, .{}, out.writer()) catch {};
        return .{ .text = out.items, .err = is_err };
    }

    fn stop(self: *Mcp) void {
        for (self.servers.items) |sv| {
            if (sv.child.stdin) |in| in.close();
            sv.child.stdin = null;
            _ = sv.child.kill() catch {};
        }
    }
};

// ---------------------------------------------------------------------------
// 1 回の問い合わせ(curl で送り、Server-Sent Events を読む)
// ---------------------------------------------------------------------------

const Reply = struct { text: []const u8, calls: []ai.Call, failed: ?[]const u8 };

fn request(a: std.mem.Allocator, p: usize, base: []const u8, mdl: []const u8, system: []const u8, turns: []const ai.Turn, tools: []const ai.ToolDef, round: u32) Reply {
    const prov = ai.providers[p];
    var body = std.ArrayList(u8).init(a);
    ai.buildBody(&body, prov.proto, mdl, system, turns, tools) catch return .{ .text = "", .calls = &.{}, .failed = "本文を作れませんでした" };
    const rd = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const path = std.fmt.allocPrint(a, "{s}/ame-ai-{d}-{d}.json", .{ rd, std.time.nanoTimestamp(), round }) catch "";
    {
        const f = std.fs.cwd().createFile(path, .{ .mode = 0o600, .truncate = true }) catch return .{ .text = "", .calls = &.{}, .failed = "一時ファイルを作れませんでした" };
        defer f.close();
        f.writeAll(body.items) catch return .{ .text = "", .calls = &.{}, .failed = "一時ファイルに書けませんでした" };
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    var kb: [512]u8 = undefined;
    const k = ai.key(p, &kb);
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ base, if (prov.proto == .anthropic) "/messages" else "/chat/completions" }) catch "";
    var cfg = std.ArrayList(u8).init(a);
    ai.buildCurlConfig(&cfg, p, url, k, path) catch return .{ .text = "", .calls = &.{}, .failed = "設定を作れませんでした" };
    @memset(&kb, 0);

    var ch = std.process.Child.init(&.{ "curl", "-sS", "-N", "--connect-timeout", "15", "--max-time", "900", "-w", "\n" ++ HTTP_MARK ++ "%{http_code}\n", "-K", "-" }, a);
    ch.stdin_behavior = .Pipe;
    ch.stdout_behavior = .Pipe;
    ch.stderr_behavior = .Pipe;
    ch.spawn() catch return .{ .text = "", .calls = &.{}, .failed = "curl を起動できませんでした(curl を入れてください)" };
    ch.stdin.?.writeAll(cfg.items) catch {};
    @memset(cfg.items, 0);
    ch.stdin.?.close();
    ch.stdin = null;

    var lines = LineReader{ .fd = ch.stdout.?.handle, .buf = std.ArrayList(u8).init(a) };
    var text = std.ArrayList(u8).init(a);
    var raw = std.ArrayList(u8).init(a);
    var calls = ai.CallBuilder.init(a);
    var http: u32 = 0;
    var stream_err: ?[]const u8 = null;
    while (lines.next(-1)) |l| {
        if (std.mem.startsWith(u8, l, HTTP_MARK)) {
            http = std.fmt.parseInt(u32, l[HTTP_MARK.len..], 10) catch 0;
            continue;
        }
        if (std.mem.startsWith(u8, l, "data:")) {
            const payload = std.mem.trim(u8, l[5..], " ");
            if (std.mem.eql(u8, payload, "[DONE]")) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, payload, .{}) catch continue;
            const d = ai.parseDelta(v, prov.proto);
            if (d.err.len > 0) stream_err = d.err;
            emitText("text", d.text);
            emitText("think", d.think);
            text.appendSlice(d.text) catch {};
            calls.feed(v, prov.proto);
            continue;
        }
        if (l.len == 0 or std.mem.startsWith(u8, l, "event:") or l[0] == ':') continue;
        // SSE ではない行: エラーの本文(JSON)
        if (raw.items.len < 65536) {
            raw.appendSlice(l) catch {};
            raw.append('\n') catch {};
        }
    }
    const errout = ch.stderr.?.reader().readAllAlloc(a, 65536) catch "";
    _ = ch.wait() catch {};
    raw.appendSlice(errout) catch {};
    const cs = calls.calls(round);
    if (stream_err) |e| return .{ .text = text.items, .calls = &.{}, .failed = e };
    if (text.items.len == 0 and cs.len == 0) return .{ .text = "", .calls = &.{}, .failed = ai.describeFailure(a, http, raw.items) };
    return .{ .text = text.items, .calls = cs, .failed = null };
}

// ---------------------------------------------------------------------------
// 引数・選んだ会社とモデル
// ---------------------------------------------------------------------------

const Opts = struct {
    cmd: enum { chat, models, providers } = .chat,
    /// -i で付けた画像(文字だけのときの頼みごとに付ける。8 枚まで)
    images: [8][]const u8 = undefined,
    n_images: usize = 0,
    provider: []const u8 = "",
    model: []const u8 = "",
    system: []const u8 = "",
    mcp: []const u8 = "",
    custom_url: []const u8 = "",
    json: bool = false,
};

pub fn parseArgs(args: []const []const u8) ?Opts {
    var o = Opts{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        const eq = std.mem.eql;
        const val = struct {
            fn f(xs: []const []const u8, j: *usize) ?[]const u8 {
                j.* += 1;
                return if (j.* < xs.len) xs[j.*] else null;
            }
        }.f;
        if (eq(u8, s, "-p")) {
            o.provider = val(args, &i) orelse return null;
        } else if (eq(u8, s, "-m")) {
            o.model = val(args, &i) orelse return null;
        } else if (eq(u8, s, "-s")) {
            o.system = val(args, &i) orelse return null;
        } else if (eq(u8, s, "--mcp")) {
            o.mcp = val(args, &i) orelse return null;
        } else if (eq(u8, s, "--custom-url")) {
            o.custom_url = std.mem.trimRight(u8, val(args, &i) orelse return null, "/");
        } else if (eq(u8, s, "-i")) {
            if (o.n_images >= o.images.len) return null;
            o.images[o.n_images] = val(args, &i) orelse return null;
            o.n_images += 1;
        } else if (eq(u8, s, "--json")) {
            o.json = true;
        } else if (i == 0 and eq(u8, s, "models")) {
            o.cmd = .models;
        } else if (i == 0 and eq(u8, s, "providers")) {
            o.cmd = .providers;
        } else return null;
    }
    return o;
}

/// ame-shell の AI チャットで最後に選んだ会社とモデル($XDG_STATE_HOME/ame-shell/ai)
fn lastChoice(a: std.mem.Allocator, o: *Opts) void {
    var db: [400]u8 = undefined;
    const dir = ai.stateDir(&db) orelse return;
    const txt = std.fs.cwd().readFileAlloc(a, std.fmt.allocPrint(a, "{s}/ai", .{dir}) catch return, 1 << 16) catch return;
    var prov: []const u8 = "";
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |l| if (std.mem.startsWith(u8, l, "provider ")) {
        prov = l["provider ".len..];
    };
    if (o.provider.len == 0) o.provider = if (prov.len > 0) prov else "openrouter";
    if (o.model.len > 0) return;
    it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |l| {
        var f = std.mem.tokenizeScalar(u8, l, ' ');
        if (!std.mem.eql(u8, f.next() orelse continue, "model")) continue;
        if (!std.mem.eql(u8, f.next() orelse continue, o.provider)) continue;
        const m = f.rest();
        if (m.len > 0) o.model = m;
    }
}

/// 会話の "images" のファイルを読んで base64 にする。読めない・画像でない・大きすぎる(20MB 超)ものは止める
fn loadImages(a: std.mem.Allocator, paths: []const []const u8) []const ai.Image {
    const out = a.alloc(ai.Image, paths.len) catch fail("メモリが足りません");
    for (paths, 0..) |p, i| {
        const bytes = std.fs.cwd().readFileAlloc(a, p, 20 << 20) catch {
            var b: [600]u8 = undefined;
            fail(std.fmt.bufPrint(&b, "画像を読めません: {s}", .{p}) catch "画像を読めません");
        };
        const mime = ai.mimeOf(bytes) orelse {
            var b: [600]u8 = undefined;
            fail(std.fmt.bufPrint(&b, "送れる画像ではありません(PNG・JPEG・GIF・WebP): {s}", .{p}) catch "送れる画像ではありません");
        };
        const enc = std.base64.standard.Encoder;
        const b64 = a.alloc(u8, enc.calcSize(bytes.len)) catch fail("メモリが足りません");
        out[i] = .{ .mime = mime, .b64 = enc.encode(b64, bytes) };
    }
    return out;
}

fn usage() noreturn {
    std.io.getStdErr().writeAll(
        \\使い方: echo 質問 | ame-ai [-p 会社] [-m モデル] [-s 指示]
        \\        ame-ai --json [-p 会社] [-m モデル] [-s 指示] [--mcp 名前,名前] < 会話.json
        \\        ame-ai models [-p 会社]      ame-ai providers
        \\
    ) catch {};
    std.process.exit(64);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    const argv = try std.process.argsAlloc(a);
    var o = parseArgs(argv[1..]) orelse usage();
    out_json = o.json;

    if (o.cmd == .providers) {
        const w = stdout_buf.writer();
        for (ai.providers) |p| try w.print("{s}\t{s}\t{s}\n", .{ p.id, p.name, if (!p.need_key) "キー不要" else if (ai.hasKey(ai.providerIndex(p.id).?)) "キーあり" else "キーなし" });
        try stdout_buf.flush();
        return;
    }
    lastChoice(a, &o);
    const p = ai.providerIndex(o.provider) orelse fail("その会社はありません(ame-ai providers で一覧)");
    const prov = ai.providers[p];
    const base = if (std.mem.eql(u8, prov.id, ai.CUSTOM)) o.custom_url else prov.base;
    if (base.len == 0) fail("カスタムの接続先が未設定です(--custom-url)");
    if (prov.need_key and !ai.hasKey(p)) fail("API キーが未設定です");

    if (o.cmd == .models) {
        var kb: [512]u8 = undefined;
        var cfg = std.ArrayList(u8).init(a);
        try ai.buildCurlConfig(&cfg, p, try std.fmt.allocPrint(a, "{s}/models", .{base}), ai.key(p, &kb), null);
        var ch = std.process.Child.init(&.{ "curl", "-sS", "--connect-timeout", "10", "--max-time", "30", "-K", "-" }, a);
        ch.stdin_behavior = .Pipe;
        ch.stdout_behavior = .Pipe;
        try ch.spawn();
        try ch.stdin.?.writeAll(cfg.items);
        ch.stdin.?.close();
        ch.stdin = null;
        const body = try ch.stdout.?.reader().readAllAlloc(a, 16 << 20);
        _ = try ch.wait();
        var list = std.ArrayList([]const u8).init(a);
        if (try ai.parseModels(a, body, &list) == 0) fail("一覧を取れませんでした(モデル名を入れても使えます)");
        for (list.items) |m| try stdout_buf.writer().print("{s}\n", .{m});
        try stdout_buf.flush();
        return;
    }

    const mdl = if (o.model.len > 0) o.model else prov.model;
    if (mdl.len == 0) fail("モデルが未設定です(-m)");
    const input = try std.io.getStdIn().reader().readAllAlloc(a, 64 << 20);
    var turns = std.ArrayList(ai.Turn).init(a);
    if (o.json) {
        try turns.appendSlice(ai.parseConversation(a, input) catch fail("会話の JSON を読めません"));
    } else {
        const q = std.mem.trim(u8, input, " \t\r\n");
        if (q.len == 0 and o.n_images == 0) usage();
        try turns.append(.{ .role = .user, .content = q, .image_paths = o.images[0..o.n_images] });
    }
    // 画像のファイルを読んで base64 に(会話の "images" と -i)
    for (turns.items) |*t| if (t.image_paths.len > 0) {
        t.images = loadImages(a, t.image_paths);
    };

    var mcp = Mcp.start(a, o.mcp);
    defer mcp.stop();
    var round: u32 = 0;
    while (round < MAX_ROUNDS) : (round += 1) {
        const r = request(a, p, base, mdl, o.system, turns.items, mcp.defs.items, round);
        if (r.failed) |why| fail(why);
        if (r.calls.len == 0) break;
        // ツールを呼んだ: 実行して結果を会話に足し、続きを頼む
        try turns.append(.{ .role = .assistant, .content = r.text, .calls = r.calls });
        for (r.calls) |cl| {
            const ref = mcp.find(cl.name);
            const label = try std.fmt.allocPrint(a, "{s}.{s}: {s}", .{ if (ref) |x| x.server.name else "MCP", if (ref) |x| x.tool else cl.name, cl.args[0..@min(cl.args.len, 200)] });
            if (out_json) emit(.{ .type = "tool_call", .id = cl.id, .name = cl.name, .arguments = cl.args, .label = label });
            const res = mcp.call(cl.name, cl.args);
            const text = res.text[0..@min(res.text.len, 60000)];
            if (out_json) emit(.{ .type = "tool_result", .id = cl.id, .content = text, .@"error" = res.err });
            try turns.append(.{ .role = .tool, .id = cl.id, .content = text, .err = res.err });
        }
    } else fail("ツールの呼び出しが多すぎるので止めました");
    if (out_json) emit(.{ .type = "done" }) else {
        try stdout_buf.writer().writeByte('\n');
        try stdout_buf.flush();
    }
}

test "args" {
    const o = parseArgs(&.{ "--json", "-p", "anthropic", "-m", "claude", "--mcp", "fs,web" }).?;
    try std.testing.expect(o.json and o.cmd == .chat);
    try std.testing.expectEqualStrings("fs,web", o.mcp);
    try std.testing.expect(parseArgs(&.{"models"}).?.cmd == .models);
    try std.testing.expect(parseArgs(&.{"-p"}) == null);
}
