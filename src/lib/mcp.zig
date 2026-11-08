// MCP サーバ(Model Context Protocol)の設定の部品(画面にも OS の作りにも依存しない)。
//
// サーバの一覧: ~/.config/ame-shell/mcp.json と、Claude Code の ~/.claude.json(どちらも {"mcpServers": {名前: {...}}})。
//   stdio のサーバ: {"command": "npx", "args": [...], "env": {...}}
//   HTTP のサーバ:  {"type": "http" | "sse", "url": "...", "headers": {...}}
// 選んだサーバの名前は $XDG_STATE_HOME/ame-shell/mcp に 1 行ずつ覚える(ame-shell の AI チャットの「MCP」)。
// サーバを起動して話すのは ame-ai(src/cmd/ame-ai.zig)。Claude Code には設定ファイル(claudeConfig)で渡す。
const std = @import("std");
const ai = @import("ai.zig");

pub const Kind = enum { stdio, http, sse };
pub const Source = enum { ame, claude };

pub const Server = struct {
    name: []const u8,
    source: Source,
    kind: Kind,
    /// 設定の元の JSON(Claude Code に渡す設定ファイルにそのまま書く)
    json: []const u8,
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    /// 「名前=値」の並び(親の環境に足す)
    env: []const []const u8 = &.{},
    enabled: bool = false,
};

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
                var list = std.ArrayList([]const u8).init(a);
                var ei = ev.object.iterator();
                while (ei.next()) |kv| if (kv.value_ptr.* == .string) {
                    list.append(std.fmt.allocPrint(a, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.string }) catch continue) catch {};
                };
                s.env = list.items;
            };
        }
        out.append(s) catch {};
    }
}

fn loadFile(a: std.mem.Allocator, path: []const u8, src: Source, out: *std.ArrayList(Server)) void {
    const txt = std.fs.cwd().readFileAlloc(a, path, 32 << 20) catch return;
    parseConfig(a, txt, src, out);
}

fn selectedPath(buf: []u8) ?[]const u8 {
    var d: [400]u8 = undefined;
    const dir = ai.stateDir(&d) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/mcp", .{dir}) catch null;
}

/// 登録されているサーバを全部読む(ame-shell の設定 → Claude Code の登録)。選んだものは enabled
pub fn loadAll(a: std.mem.Allocator, out: *std.ArrayList(Server)) void {
    var db: [400]u8 = undefined;
    var pb: [512]u8 = undefined;
    if (ai.configDir(&db)) |dir| if (std.fmt.bufPrint(&pb, "{s}/mcp.json", .{dir}) catch null) |p| loadFile(a, p, .ame, out);
    if (std.posix.getenv("HOME")) |home| if (std.fmt.bufPrint(&pb, "{s}/.claude.json", .{home}) catch null) |p| loadFile(a, p, .claude, out);
    var sb: [4096]u8 = undefined;
    if (selectedPath(&pb)) |p| if (ai.readSmall(p, &sb)) |txt| {
        var it = std.mem.splitScalar(u8, txt, '\n');
        while (it.next()) |l| for (out.items) |*s| if (l.len > 0 and std.mem.eql(u8, s.name, l)) {
            s.enabled = true;
        };
    };
}

/// 選んだサーバの名前を覚える
pub fn saveSelected(a: std.mem.Allocator, list: []const Server) void {
    var out = std.ArrayList(u8).init(a);
    defer out.deinit();
    for (list) |x| if (x.enabled) {
        out.appendSlice(x.name) catch return;
        out.append('\n') catch return;
    };
    var db: [400]u8 = undefined;
    const dir = ai.stateDir(&db) orelse return;
    std.fs.cwd().makePath(dir) catch {};
    var pb: [512]u8 = undefined;
    const p = selectedPath(&pb) orelse return;
    const f = std.fs.cwd().createFile(p, .{ .mode = 0o600, .truncate = true }) catch return;
    defer f.close();
    f.writeAll(out.items) catch {};
}

/// Claude Code の --mcp-config に渡す JSON(選んだサーバだけ。HTTP のサーバも)
pub fn claudeConfig(a: std.mem.Allocator, list: []const Server) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("{\"mcpServers\":{");
    var first = true;
    for (list) |s| if (s.enabled) {
        if (!first) try w.writeByte(',');
        first = false;
        try std.json.stringify(s.name, .{}, w);
        try w.writeByte(':');
        try w.writeAll(s.json);
    };
    try w.writeAll("}}");
    return out.items;
}

/// モデルに渡すツールの名前(<サーバ>__<ツール>、英数字と _ - だけ・64 文字まで)
pub fn toolName(a: std.mem.Allocator, server: []const u8, tool: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (server) |ch| try out.append(if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else '_');
    try out.appendSlice("__");
    for (tool) |ch| try out.append(if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else '_');
    if (out.items.len > 64) out.shrinkRetainingCapacity(64);
    return out.items;
}

test "mcp config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list = std.ArrayList(Server).init(a);
    parseConfig(a, "{\"mcpServers\":{\"fs\":{\"command\":\"npx\",\"args\":[\"-y\",\"pkg\"],\"env\":{\"K\":\"v\"}},\"web\":{\"type\":\"http\",\"url\":\"https://x\"}},\"projects\":{}}", .ame, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    var fs_i: usize = 0;
    if (!std.mem.eql(u8, list.items[0].name, "fs")) fs_i = 1;
    try std.testing.expectEqual(Kind.stdio, list.items[fs_i].kind);
    try std.testing.expectEqualStrings("-y", list.items[fs_i].args[0]);
    try std.testing.expectEqualStrings("K=v", list.items[fs_i].env[0]);
    try std.testing.expectEqual(Kind.http, list.items[1 - fs_i].kind);
    try std.testing.expectEqualStrings("my_srv__read-file", try toolName(a, "my.srv", "read-file"));
    list.items[fs_i].enabled = true;
    const cfg = try claudeConfig(a, list.items);
    try std.testing.expect(std.mem.startsWith(u8, cfg, "{\"mcpServers\":{\"fs\":{"));
}
