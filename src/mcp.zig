// MCP サーバの一覧と、使うものの選択(画面の側)。設定の読み方は lib/mcp.zig、サーバを起動して話すのは ame-ai。
// Claude Code には、選んだサーバを書いた設定ファイルを --mcp-config で足す(agent.zig)。
const std = @import("std");
const App = @import("app.zig").App;
const cfg = @import("ame_lib").mcp;

pub const Server = cfg.Server;
pub const Kind = cfg.Kind;
pub const Source = cfg.Source;

const State = struct {
    loaded: bool = false,
    arena: std.heap.ArenaAllocator = undefined,
    list: std.ArrayList(Server) = undefined,
    path: [512]u8 = undefined,
};

var st: State = .{};

pub fn ensure(app: *App) void {
    if (st.loaded) return;
    st.loaded = true;
    st.arena = std.heap.ArenaAllocator.init(app.alloc);
    reload();
}

/// 設定を読み直す
pub fn reload() void {
    _ = st.arena.reset(.retain_capacity);
    st.list = std.ArrayList(Server).init(st.arena.allocator());
    cfg.loadAll(st.arena.allocator(), &st.list);
}

pub fn servers() []Server {
    return if (st.loaded) st.list.items else &.{};
}

pub fn enabledCount() usize {
    var n: usize = 0;
    for (servers()) |s| n += @intFromBool(s.enabled);
    return n;
}

pub fn toggle(i: usize) void {
    if (i >= servers().len) return;
    st.list.items[i].enabled = !st.list.items[i].enabled;
    cfg.saveSelected(std.heap.c_allocator, st.list.items);
}

/// ame-ai の --mcp に渡す、選んだ stdio のサーバの名前(カンマ区切り)。無ければ空
pub fn enabledNames(buf: []u8) []const u8 {
    var n: usize = 0;
    for (servers()) |s| if (s.enabled and s.kind == .stdio) {
        const sep: usize = @intFromBool(n > 0);
        if (n + sep + s.name.len > buf.len) break;
        if (sep == 1) buf[n] = ',';
        @memcpy(buf[n + sep .. n + sep + s.name.len], s.name);
        n += sep + s.name.len;
    };
    return buf[0..n];
}

/// Claude Code に渡す設定ファイル(選んだサーバだけ。$XDG_RUNTIME_DIR に 0600 で書く)。選んでいなければ null
pub fn claudeConfigPath() ?[]const u8 {
    if (enabledCount() == 0) return null;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const json = cfg.claudeConfig(arena.allocator(), st.list.items) catch return null;
    const rd = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const p = std.fmt.bufPrint(&st.path, "{s}/ame-mcp-{d}.json", .{ rd, @import("c.zig").getpid() }) catch return null;
    const f = std.fs.cwd().createFile(p, .{ .mode = 0o600, .truncate = true }) catch return null;
    defer f.close();
    f.writeAll(json) catch return null;
    return p;
}
