// クリップボードの履歴。小さな道具 ame-paste --watch を動かし、コピーされた文字(1 行 1 つの JSON の文字列)を覚える。
// ランチャーの「>クリップ」で選ぶと、その文字をもう一度コピーする(ame-copy)。
//
//  * 覚えるのはメモリの中だけ(ファイルに書かない。コピーしたパスワードが残らないように)。最大 MAX 件、新しい順
//  * パスワード管理のアプリが「秘密」の印を付けたもの・文字でないもの(画像など)は、ame-paste が最初から出さない
//  * ext-data-control の無いコンポジタ(River 0.3)では動かさない
const std = @import("std");
const c = @import("../c.zig");
const sys = @import("../platform/sys.zig");
const App = @import("../core/app.zig").App;

pub const MAX = 30;
const ca = std.heap.c_allocator;

pub const ClipHist = struct {
    app: *App,
    fd: c_int = -1,
    pid: c_int = 0,
    /// 新しい順
    items: [MAX][]u8 = undefined,
    n: usize = 0,
    /// 行の途中まで
    part: std.ArrayList(u8) = std.ArrayList(u8).init(ca),

    pub fn start(self: *ClipHist) void {
        if (self.fd >= 0 or self.app.dc_mgr == null or !sys.hasCommand("ame-paste")) return;
        self.fd = sys.spawnReader(&.{ "ame-paste", "--watch" }, &self.pid) orelse return;
        self.app.loop.add(self.fd, c.EPOLLIN, self, onRead) catch {
            _ = c.close(self.fd);
            self.fd = -1;
        };
    }

    pub fn stop(self: *ClipHist) void {
        if (self.fd < 0) return;
        if (self.pid > 0) _ = c.kill(self.pid, c.SIGTERM);
        self.app.loop.remove(self.fd);
        _ = c.close(self.fd);
        self.fd = -1;
    }

    pub fn get(self: *const ClipHist, i: usize) []const u8 {
        return if (i < self.n) self.items[i] else "";
    }

    /// 履歴の i 番目をもう一度コピーする(一番上に上がるのは、ame-paste --watch がそれを見たとき)
    pub fn copy(self: *ClipHist, i: usize) void {
        if (i >= self.n) return;
        var z = ca.allocSentinel(u8, self.items[i].len, 0) catch return;
        defer ca.free(z);
        @memcpy(z[0..self.items[i].len], self.items[i]);
        // 中身は文に埋め込まず引数で渡す
        sys.spawnDetachedArgs("printf '%s' \"$1\" | exec ame-copy", &.{z.ptr});
    }

    /// 新しい文字を一番上に。同じ文字が既にあれば、それを上へ動かす
    fn push(self: *ClipHist, s: []const u8) void {
        for (self.items[0..self.n], 0..) |it, i| if (std.mem.eql(u8, it, s)) {
            const keep = self.items[i];
            std.mem.copyBackwards([]u8, self.items[1 .. i + 1], self.items[0..i]);
            self.items[0] = keep;
            return;
        };
        const dup = ca.dupe(u8, s) catch return;
        if (self.n == MAX) {
            ca.free(self.items[MAX - 1]);
            self.n -= 1;
        }
        std.mem.copyBackwards([]u8, self.items[1 .. self.n + 1], self.items[0..self.n]);
        self.items[0] = dup;
        self.n += 1;
    }

    fn onRead(ctx: *anyopaque, fd: c_int, events: u32) void {
        const self: *ClipHist = @ptrCast(@alignCast(ctx));
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) {
                if (n == 0 or events & c.EPOLLHUP != 0) self.stop(); // ame-paste が終わった(画面が閉じたなど)
                break;
            }
            for (buf[0..@intCast(n)]) |ch| {
                if (ch != '\n') {
                    // 1 件は ame-paste が 64KB までにしている(JSON にすると少し増える)
                    if (self.part.items.len < 512 * 1024) self.part.append(ch) catch {};
                    continue;
                }
                if (parseLine(self.part.items)) |s| {
                    self.push(s.value);
                    s.deinit();
                }
                self.part.clearRetainingCapacity();
            }
        }
    }
};

/// 1 行(JSON の文字列)を読む
fn parseLine(line: []const u8) ?std.json.Parsed([]const u8) {
    if (line.len == 0) return null;
    return std.json.parseFromSlice([]const u8, ca, line, .{}) catch null;
}

test "履歴の行" {
    const p = parseLine("\"two\\nlines\"").?;
    defer p.deinit();
    try std.testing.expectEqualStrings("two\nlines", p.value);
    try std.testing.expect(parseLine("not json") == null);
}
