// MCP サーバ(Model Context Protocol)を AI チャットで使う。
//
// サーバの一覧: ~/.config/ame-shell/mcp.json と、Claude Code の ~/.claude.json(どちらも {"mcpServers": {名前: {...}}})。
//   stdio のサーバ: {"command": "npx", "args": [...], "env": {...}}
//   HTTP のサーバ:  {"type": "http" | "sse", "url": "...", "headers": {...}}
// パネルの「MCP」で使うものを選ぶ(選んだ名前は $XDG_STATE_HOME/ame-shell/mcp に覚える)。
//
// ・AI チャット(API): ame-shell が MCP のクライアントになり、選んだ stdio のサーバを起動して
//   ツールの一覧をモデルに渡し、モデルが呼んだツールを実行して結果を返す(ai.zig)。
// ・Claude Code: 選んだサーバを書いた設定ファイルを --mcp-config で足す(Claude Code に登録済みのサーバ・プラグインはそのまま)。
const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig").App;
const ai = @import("ai.zig");
const sys = @import("platform/sys.zig");

pub const Kind = enum { stdio, http, sse };
pub const Source = enum { ame, claude };

pub const Tool = struct {
    server: usize,
    /// モデルに渡す名前(<サーバ>__<ツール>、英数字と _ - だけ・64 文字まで)
    qname: []const u8,
    name: []const u8,
    description: []const u8,
    /// inputSchema の JSON
    schema: []const u8,
};

pub const Server = struct {
    name: []const u8,
    source: Source,
    kind: Kind,
    /// 設定の元の JSON(Claude Code に渡す設定ファイルにそのまま書く)
    json: []const u8,
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    env: []const [*:0]const u8 = &.{},
    enabled: bool = false,

    // ---- 動いている間 ----
    pid: c_int = 0,
    in_w: c_int = -1,
    out_r: c_int = -1,
    phase: Phase = .off,
    buf: std.ArrayList(u8) = undefined,
    err: []const u8 = "",
};

pub const Phase = enum { off, starting, listing, ready, failed };

const Pending = struct {
    id: u32,
    server: usize,
    cb: *const fn (ctx: usize, result: []const u8, is_error: bool) void,
    ctx: usize,
};

const State = struct {
    app: ?*App = null,
    alloc: std.mem.Allocator = std.heap.c_allocator,
    loaded: bool = false,
    arena: std.heap.ArenaAllocator = undefined,
    servers: std.ArrayList(Server) = undefined,
    tools: std.ArrayList(Tool) = undefined,
    tool_arena: std.heap.ArenaAllocator = undefined,
    next_id: u32 = 100,
    pending: std.ArrayList(Pending) = undefined,
    ready_cb: ?*const fn () void = null,
    timer: ?@import("platform/loop.zig").Timer = null,
    cfg_path: [512]u8 = undefined,
    cfg_len: usize = 0,
};

var st: State = .{};

pub fn ensure(app: *App) void {
    st.app = app;
    if (st.loaded) return;
    st.loaded = true;
    st.alloc = app.alloc;
    st.arena = std.heap.ArenaAllocator.init(st.alloc);
    st.tool_arena = std.heap.ArenaAllocator.init(st.alloc);
    st.servers = std.ArrayList(Server).init(st.alloc);
    st.tools = std.ArrayList(Tool).init(st.alloc);
    st.pending = std.ArrayList(Pending).init(st.alloc);
    reload();
}

/// 設定を読み直す(動いているサーバは止める)
pub fn reload() void {
    stopAll();
    st.servers.clearRetainingCapacity();
    _ = st.arena.reset(.retain_capacity);
    const a = st.arena.allocator();
    var db: [400]u8 = undefined;
    var pb: [512]u8 = undefined;
    if (ai.configDir(&db)) |dir| if (std.fmt.bufPrint(&pb, "{s}/mcp.json", .{dir}) catch null) |p| loadFile(a, p, .ame);
    if (std.posix.getenv("HOME")) |home| if (std.fmt.bufPrint(&pb, "{s}/.claude.json", .{home}) catch null) |p| loadFile(a, p, .claude);
    // 選んだもの
    var sb: [4096]u8 = undefined;
    if (ai.statePath(&pb, "mcp")) |p| if (ai.readSmall(p, &sb)) |txt| {
        var it = std.mem.splitScalar(u8, txt, '\n');
        while (it.next()) |l| for (st.servers.items) |*s| if (l.len > 0 and std.mem.eql(u8, s.name, l)) {
            s.enabled = true;
        };
    };
}

fn loadFile(a: std.mem.Allocator, path: []const u8, src: Source) void {
    const f = std.fs.cwd().openFile(path, .{}) catch return;
    defer f.close();
    const txt = f.readToEndAlloc(a, 32 << 20) catch return;
    parseConfig(a, txt, src, &st.servers);
}

/// {"mcpServers": {...}} を読む(Claude Code の ~/.claude.json は一番外側の mcpServers だけ)
pub fn parseConfig(a: std.mem.Allocator, txt: []const u8, src: Source, out: *std.ArrayList(Server)) void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, txt, .{}) catch return;
    if (parsed != .object) return;
    const ms = parsed.object.get("mcpServers") orelse return;
    if (ms != .object) return;
    var it = ms.object.iterator();
    while (it.next()) |e| {
        const v = e.value_ptr.*;
        if (v != .object) continue;
        // 同じ名前は先に読んだもの(ame-shell の設定)を使う
        var dup = false;
        for (out.items) |s| if (std.mem.eql(u8, s.name, e.key_ptr.*)) {
            dup = true;
        };
        if (dup) continue;
        var s = Server{ .name = e.key_ptr.*, .source = src, .kind = .stdio, .json = std.json.stringifyAlloc(a, v, .{}) catch continue };
        if (v.object.get("type")) |t| if (t == .string) {
            if (std.mem.eql(u8, t.string, "http") or std.mem.eql(u8, t.string, "streamable-http")) s.kind = .http;
            if (std.mem.eql(u8, t.string, "sse")) s.kind = .sse;
        };
        if (s.kind == .stdio and v.object.get("url") != null and v.object.get("command") == null) s.kind = .http;
        if (s.kind == .stdio) {
            const cmd = v.object.get("command") orelse continue;
            if (cmd != .string) continue;
            s.command = cmd.string;
            if (v.object.get("args")) |av| if (av == .array) {
                var list = std.ArrayList([]const u8).init(a);
                for (av.array.items) |x| if (x == .string) list.append(x.string) catch {};
                s.args = list.items;
            };
            if (v.object.get("env")) |ev| if (ev == .object) {
                var list = std.ArrayList([*:0]const u8).init(a);
                var ei = ev.object.iterator();
                while (ei.next()) |kv| if (kv.value_ptr.* == .string) {
                    const z = std.fmt.allocPrintZ(a, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.string }) catch continue;
                    list.append(z.ptr) catch {};
                };
                s.env = list.items;
            };
        }
        out.append(s) catch {};
    }
}

pub fn servers() []Server {
    return st.servers.items;
}

pub fn enabledCount() usize {
    var n: usize = 0;
    for (st.servers.items) |s| if (s.enabled) {
        n += 1;
    };
    return n;
}

pub fn toggle(i: usize) void {
    if (i >= st.servers.items.len) return;
    const s = &st.servers.items[i];
    s.enabled = !s.enabled;
    if (!s.enabled) stopServer(i);
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    for (st.servers.items) |x| if (x.enabled) {
        out.appendSlice(x.name) catch return;
        out.append('\n') catch return;
    };
    ai.writeState("mcp", out.items);
}

/// Claude Code に渡す設定ファイル(選んだサーバだけ)。選んでいなければ null
pub fn claudeConfigPath() ?[]const u8 {
    if (!st.loaded or enabledCount() == 0) return null;
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    const w = out.writer();
    w.writeAll("{\"mcpServers\":{") catch return null;
    var first = true;
    for (st.servers.items) |s| if (s.enabled) {
        if (!first) w.writeByte(',') catch return null;
        first = false;
        std.json.stringify(s.name, .{}, w) catch return null;
        w.writeByte(':') catch return null;
        w.writeAll(s.json) catch return null;
    };
    w.writeAll("}}") catch return null;
    const rd = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const p = std.fmt.bufPrint(&st.cfg_path, "{s}/ame-mcp-{d}.json", .{ rd, c.getpid() }) catch return null;
    const f = std.fs.cwd().createFile(p, .{ .mode = 0o600, .truncate = true }) catch return null;
    defer f.close();
    f.writeAll(out.items) catch return null;
    st.cfg_len = p.len;
    return p;
}

// ---------------------------------------------------------------------------
// stdio のサーバと話す(JSON-RPC、1 行 1 メッセージ)
// ---------------------------------------------------------------------------

pub fn tools() []const Tool {
    return st.tools.items;
}

/// 選んだ stdio のサーバを起動してツールの一覧を集め、全部そろったら(または 20 秒で)cb を呼ぶ
pub fn prepare(cb: *const fn () void) void {
    const app = st.app orelse return cb();
    st.ready_cb = cb;
    var waiting = false;
    for (st.servers.items, 0..) |*s, i| {
        if (!s.enabled or s.kind != .stdio) continue;
        if (s.phase == .ready) continue;
        if (s.phase == .off or s.phase == .failed) startServer(i);
        if (s.phase == .starting or s.phase == .listing) waiting = true;
    }
    if (!waiting) return fireReady();
    if (st.timer == null) {
        st.timer = @import("platform/loop.zig").Timer.init() catch null;
        if (st.timer) |t| app.loop.add(t.fd, c.EPOLLIN, &st, onTimeout) catch {};
    }
    if (st.timer) |t| t.arm(20000, 0);
}

fn onTimeout(_: *anyopaque, _: c_int, _: u32) void {
    if (st.timer) |t| t.ack();
    for (st.servers.items, 0..) |*s, i| if (s.phase == .starting or s.phase == .listing) {
        s.err = "20 秒以内に応答がありませんでした";
        stopServer(i);
        s.phase = .failed;
    };
    fireReady();
}

fn fireReady() void {
    if (st.timer) |t| t.disarm();
    rebuildTools();
    if (st.ready_cb) |cb| {
        st.ready_cb = null;
        cb();
    }
}

fn checkReady() void {
    if (st.ready_cb == null) return;
    for (st.servers.items) |s| if (s.enabled and s.kind == .stdio and (s.phase == .starting or s.phase == .listing)) return;
    fireReady();
}

fn startServer(i: usize) void {
    const app = st.app orelse return;
    const s = &st.servers.items[i];
    var arena = std.heap.ArenaAllocator.init(st.alloc);
    defer arena.deinit();
    var argv = std.ArrayList(?[*:0]const u8).init(arena.allocator());
    argv.append((arena.allocator().dupeZ(u8, s.command) catch return).ptr) catch return;
    for (s.args) |x| argv.append((arena.allocator().dupeZ(u8, x) catch return).ptr) catch return;
    s.buf = std.ArrayList(u8).init(st.alloc);
    s.out_r = sys.spawnDuplex(argv.items, s.env, &s.in_w, &s.pid) orelse {
        s.phase = .failed;
        s.err = "起動できませんでした";
        return;
    };
    s.phase = .starting;
    s.err = "";
    app.loop.add(s.out_r, c.EPOLLIN | c.EPOLLHUP, @ptrFromInt(i + 1), onRead) catch {};
    writeMsg(i, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"ame-shell\",\"version\":\"1.0\"}}}");
}

fn stopServer(i: usize) void {
    const s = &st.servers.items[i];
    if (s.out_r >= 0) {
        if (st.app) |a| a.loop.remove(s.out_r);
        _ = c.close(s.out_r);
        s.out_r = -1;
        s.buf.deinit();
    }
    if (s.in_w >= 0) {
        _ = c.close(s.in_w);
        s.in_w = -1;
    }
    if (s.pid > 0) {
        _ = c.kill(-s.pid, c.SIGTERM);
        s.pid = 0;
    }
    if (s.phase != .failed) s.phase = .off;
    // 待っている呼び出しには失敗を返す
    var k: usize = 0;
    while (k < st.pending.items.len) {
        const p = st.pending.items[k];
        if (p.server == i) {
            _ = st.pending.orderedRemove(k);
            p.cb(p.ctx, "MCP サーバが止まりました", true);
        } else k += 1;
    }
}

pub fn stopAll() void {
    if (!st.loaded) return;
    for (st.servers.items, 0..) |_, i| stopServer(i);
}

fn writeMsg(i: usize, msg: []const u8) void {
    const s = &st.servers.items[i];
    if (s.in_w < 0) return;
    var off: usize = 0;
    while (off < msg.len) {
        const n = c.write(s.in_w, msg.ptr + off, msg.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
    _ = c.write(s.in_w, "\n", 1);
}

fn onRead(ctx: *anyopaque, fd: c_int, _: u32) void {
    const i = @intFromPtr(ctx) - 1;
    if (i >= st.servers.items.len) return;
    var tmp: [16384]u8 = undefined;
    while (true) {
        const n = c.read(fd, &tmp, tmp.len);
        if (n > 0) {
            const s = &st.servers.items[i];
            s.buf.appendSlice(tmp[0..@intCast(n)]) catch {};
            while (std.mem.indexOfScalar(u8, s.buf.items, '\n')) |nl| {
                const line = st.alloc.dupe(u8, s.buf.items[0..nl]) catch break;
                defer st.alloc.free(line);
                std.mem.copyForwards(u8, s.buf.items, s.buf.items[nl + 1 ..]);
                s.buf.shrinkRetainingCapacity(s.buf.items.len - nl - 1);
                handleMsg(i, line);
                if (st.servers.items[i].out_r < 0) return; // 処理の途中で止めた
            }
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) return;
        break;
    }
    const s = &st.servers.items[i];
    if (s.phase == .starting or s.phase == .listing) s.err = "起動してすぐ終わりました(コマンドや引数を確かめてください)";
    stopServer(i);
    s.phase = .failed;
    checkReady();
    ai.redraw();
}

fn handleMsg(i: usize, line: []const u8) void {
    const t = std.mem.trim(u8, line, " \r");
    if (t.len == 0 or t[0] != '{') return;
    const parsed = std.json.parseFromSlice(std.json.Value, st.alloc, t, .{}) catch return;
    defer parsed.deinit();
    const v = parsed.value;
    if (v != .object) return;
    const s = &st.servers.items[i];
    // サーバからの問い合わせ(ping・roots/list)には空で答える
    if (v.object.get("method")) |m| if (m == .string) {
        if (v.object.get("id")) |idv| {
            var b: [256]u8 = undefined;
            var ib: [64]u8 = undefined;
            const idstr = blk: {
                var fbs = std.io.fixedBufferStream(&ib);
                std.json.stringify(idv, .{}, fbs.writer()) catch break :blk "0";
                break :blk fbs.getWritten();
            };
            const res = if (std.mem.eql(u8, m.string, "roots/list")) "{\"roots\":[]}" else "{}";
            writeMsg(i, std.fmt.bufPrint(&b, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ idstr, res }) catch return);
        }
        return;
    };
    const idv = v.object.get("id") orelse return;
    const id: u32 = if (idv == .integer) @intCast(@max(0, idv.integer)) else return;
    const err_v = v.object.get("error");
    const res_v = v.object.get("result");
    if (id == 1 and s.phase == .starting) {
        if (err_v != null or res_v == null) {
            s.err = "初期化に失敗しました";
            stopServer(i);
            s.phase = .failed;
            return checkReady();
        }
        writeMsg(i, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
        writeMsg(i, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}");
        s.phase = .listing;
        return;
    }
    if (id == 2 and s.phase == .listing) {
        s.phase = .ready;
        if (res_v) |r| storeTools(i, r);
        return checkReady();
    }
    // tools/call の結果
    for (st.pending.items, 0..) |p, k| if (p.id == id and p.server == i) {
        _ = st.pending.orderedRemove(k);
        var out = std.ArrayList(u8).init(st.alloc);
        defer out.deinit();
        var is_err = false;
        if (err_v) |e| {
            is_err = true;
            if (e == .object) if (e.object.get("message")) |mm| if (mm == .string) out.appendSlice(mm.string) catch {};
            if (out.items.len == 0) out.appendSlice("エラー") catch {};
        } else if (res_v) |r| {
            if (r == .object) {
                if (r.object.get("isError")) |ie| is_err = ie == .bool and ie.bool;
                if (r.object.get("content")) |cv| if (cv == .array) for (cv.array.items) |item| {
                    if (item != .object) continue;
                    const ty = item.object.get("type") orelse continue;
                    if (ty != .string) continue;
                    if (std.mem.eql(u8, ty.string, "text")) {
                        if (item.object.get("text")) |tx| if (tx == .string) {
                            if (out.items.len > 0) out.append('\n') catch {};
                            out.appendSlice(tx.string) catch {};
                        };
                    } else {
                        if (out.items.len > 0) out.append('\n') catch {};
                        out.writer().print("[{s}]", .{ty.string}) catch {};
                    }
                };
                if (out.items.len == 0) if (r.object.get("structuredContent")) |sc| {
                    std.json.stringify(sc, .{}, out.writer()) catch {};
                };
            }
        }
        p.cb(p.ctx, out.items, is_err);
        return;
    };
}

/// ツールの名前に使える文字だけにする
fn sanitize(a: std.mem.Allocator, server: []const u8, tool: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (server) |ch| try out.append(if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else '_');
    try out.appendSlice("__");
    for (tool) |ch| try out.append(if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else '_');
    if (out.items.len > 64) out.shrinkRetainingCapacity(64);
    return out.items;
}

fn storeTools(i: usize, r: std.json.Value) void {
    if (r != .object) return;
    const list = r.object.get("tools") orelse return;
    if (list != .array) return;
    const a = st.tool_arena.allocator();
    const s = &st.servers.items[i];
    // 前の一覧(このサーバの分)は rebuildTools で並べ直す
    for (list.array.items) |tv| {
        if (tv != .object) continue;
        const nm = tv.object.get("name") orelse continue;
        if (nm != .string) continue;
        const desc: []const u8 = if (tv.object.get("description")) |d| (if (d == .string) d.string else "") else "";
        const schema = if (tv.object.get("inputSchema")) |sc| std.json.stringifyAlloc(a, sc, .{}) catch "{\"type\":\"object\"}" else "{\"type\":\"object\"}";
        st.tools.append(.{
            .server = i,
            .qname = sanitize(a, s.name, nm.string) catch continue,
            .name = a.dupe(u8, nm.string) catch continue,
            .description = a.dupe(u8, desc[0..@min(desc.len, 1024)]) catch "",
            .schema = schema,
        }) catch {};
    }
}

/// 選んでいない・止まったサーバのツールを一覧から外す
fn rebuildTools() void {
    var k: usize = 0;
    while (k < st.tools.items.len) {
        const t = st.tools.items[k];
        const s = st.servers.items[t.server];
        if (!s.enabled or s.phase != .ready) {
            _ = st.tools.orderedRemove(k);
        } else k += 1;
    }
    // 同じサーバの重複(起動し直したとき)を除く
    var i: usize = 0;
    while (i < st.tools.items.len) : (i += 1) {
        var j = i + 1;
        while (j < st.tools.items.len) {
            if (std.mem.eql(u8, st.tools.items[i].qname, st.tools.items[j].qname)) {
                _ = st.tools.orderedRemove(i);
                j = i + 1;
            } else j += 1;
        }
    }
}

pub fn findTool(qname: []const u8) ?Tool {
    for (st.tools.items) |t| if (std.mem.eql(u8, t.qname, qname)) return t;
    return null;
}

/// ツールを呼ぶ(args は JSON のオブジェクトの文字列)。結果は cb(ctx, 文字, エラーか)
pub fn call(qname: []const u8, args: []const u8, ctx: usize, cb: *const fn (ctx: usize, result: []const u8, is_error: bool) void) void {
    const t = findTool(qname) orelse return cb(ctx, "そのツールはありません", true);
    const s = &st.servers.items[t.server];
    if (s.phase != .ready) return cb(ctx, "MCP サーバが動いていません", true);
    const id = st.next_id;
    st.next_id += 1;
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    const w = out.writer();
    const a = std.mem.trim(u8, args, " \n");
    w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":", .{id}) catch return cb(ctx, "失敗", true);
    std.json.stringify(t.name, .{}, w) catch return cb(ctx, "失敗", true);
    w.writeAll(",\"arguments\":") catch return cb(ctx, "失敗", true);
    w.writeAll(if (a.len > 0 and a[0] == '{') a else "{}") catch return cb(ctx, "失敗", true);
    w.writeAll("}}") catch return cb(ctx, "失敗", true);
    st.pending.append(.{ .id = id, .server = t.server, .cb = cb, .ctx = ctx }) catch return cb(ctx, "失敗", true);
    writeMsg(t.server, out.items);
}

// ---------------------------------------------------------------------------

test "mcp config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = std.ArrayList(Server).init(arena.allocator());
    parseConfig(arena.allocator(), "{\"mcpServers\":{\"fs\":{\"command\":\"npx\",\"args\":[\"-y\",\"pkg\"],\"env\":{\"K\":\"v\"}},\"web\":{\"type\":\"http\",\"url\":\"https://x\"}},\"projects\":{}}", .ame, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    var fs_i: usize = 0;
    if (!std.mem.eql(u8, list.items[0].name, "fs")) fs_i = 1;
    try std.testing.expectEqual(Kind.stdio, list.items[fs_i].kind);
    try std.testing.expectEqualStrings("-y", list.items[fs_i].args[0]);
    try std.testing.expectEqualStrings("K=v", std.mem.span(list.items[fs_i].env[0]));
    try std.testing.expectEqual(Kind.http, list.items[1 - fs_i].kind);
    try std.testing.expectEqualStrings("my_srv__read-file", try sanitize(arena.allocator(), "my.srv", "read-file"));
}
