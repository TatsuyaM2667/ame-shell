// ユーザーの写真(ダッシュボードの丸いアイコン)。
//
// 探す順: ~/.config/ame-shell/avatar(ピッカーで選んだ画像のパスを 1 行)→ ~/.face → ~/.face.icon
//        → /var/lib/AccountsService/icons/$USER。無ければ名前の頭文字を表示する。
// 写真は大きいことが多いので、別スレッドで中央を正方形に切り抜いて 256px に縮めてから GPU へ送る。
const std = @import("std");

const App = @import("app.zig").App;
const c = @import("c.zig");
const gfx = @import("gfx.zig");
const icons = @import("icons.zig");

const SIZE = 256;

pub const Avatar = struct {
    app: *App,
    tex: c.GLuint = 0,
    pipe_r: c_int,
    pipe_w: c_int,
    mutex: std.Thread.Mutex = .{},
    pending: ?[*]u8 = null,
    /// 読み終えて GPU へ送るのを待っている画素(描画中に送る: そのとき GL コンテキストが current)
    ready: ?[*]u8 = null,
    loading: bool = false,

    pub fn create(app: *App) !*Avatar {
        const self = try app.alloc.create(Avatar);
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.Pipe;
        self.* = .{ .app = app, .pipe_r = fds[0], .pipe_w = fds[1] };
        try app.loop.add(fds[0], c.EPOLLIN, self, onReady);
        self.reload();
        return self;
    }

    /// ピッカーで選んだ画像を保存して読み直す
    pub fn set(self: *Avatar, path: []const u8) void {
        var pb: [512]u8 = undefined;
        const p = configPath(&pb) orelse return;
        if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
        const f = std.fs.cwd().createFile(p, .{}) catch return;
        defer f.close();
        f.writer().print("{s}\n", .{path}) catch {};
        self.reload();
    }

    pub fn reload(self: *Avatar) void {
        if (self.loading) return;
        var buf: [600]u8 = undefined;
        const path = resolve(&buf) orelse return;
        const owned = std.heap.c_allocator.dupeZ(u8, path) catch return;
        self.loading = true;
        const t = std.Thread.spawn(.{}, work, .{ self, owned }) catch {
            std.heap.c_allocator.free(owned);
            self.loading = false;
            return;
        };
        t.detach();
    }

    fn work(self: *Avatar, path: [:0]u8) void {
        const px = icons.decode(path, SIZE, SIZE, true);
        std.heap.c_allocator.free(path);
        self.mutex.lock();
        if (self.pending) |old| std.c.free(old);
        self.pending = px;
        self.mutex.unlock();
        _ = c.write(self.pipe_w, "a", 1);
    }

    fn onReady(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Avatar = @ptrCast(@alignCast(ctx));
        var drain: [16]u8 = undefined;
        while (c.read(fd, &drain, drain.len) > 0) {}
        self.mutex.lock();
        const px = self.pending;
        self.pending = null;
        self.mutex.unlock();
        self.loading = false;
        const p = px orelse return;
        if (self.ready) |old| std.c.free(old);
        self.ready = p;
        self.app.redrawAll();
    }

    /// 描画中に呼ぶ。写真が無ければ 0
    pub fn texture(self: *Avatar) c.GLuint {
        if (self.ready) |p| {
            if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
            self.tex = gfx.uploadImage(p, SIZE, SIZE);
            std.c.free(p);
            self.ready = null;
        }
        return self.tex;
    }
};

fn configPath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| return std.fmt.bufPrint(buf, "{s}/ame-shell/avatar", .{x}) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/ame-shell/avatar", .{home}) catch null;
}

fn exists(p: []const u8) bool {
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

/// 使う画像のパスを決める(無ければ null)
pub fn resolve(buf: []u8) ?[]const u8 {
    var pb: [512]u8 = undefined;
    if (configPath(&pb)) |cp| {
        if (std.fs.cwd().openFile(cp, .{})) |f| {
            defer f.close();
            const n = f.readAll(buf) catch 0;
            const line = std.mem.trim(u8, std.mem.sliceTo(buf[0..n], '\n'), " \t\r");
            if (line.len > 0 and exists(line)) return line;
        } else |_| {}
    }
    const home = std.posix.getenv("HOME") orelse return null;
    const user = std.posix.getenv("USER") orelse "";
    const cands = [_][]const u8{ "{s}/.face", "{s}/.face.icon" };
    inline for (cands) |fmt| {
        const p = std.fmt.bufPrint(buf, fmt, .{home}) catch return null;
        if (exists(p)) return p;
    }
    const p = std.fmt.bufPrint(buf, "/var/lib/AccountsService/icons/{s}", .{user}) catch return null;
    if (user.len > 0 and exists(p)) return p;
    return null;
}
