// `ame-ctl watch` に流す出来事。ame-shell の中で起きたこと(ワークスペースの切り替え・フォーカス・窓の開閉・
// 通知・再生中の曲・ロック)を、つないでいる人みんなに 1 行 1 つの JSON で送る。
//
//   {"event":"workspace","output":"DP-1","workspace":3,"tags":4,"occupied":5}
//   {"event":"focus","title":"…","app_id":"…"}            (River 0.3 は app_id が空)
//   {"event":"window","action":"open"|"close","app_id":"…"}  (内蔵 WM のときだけ)
//   {"event":"notification","id":1,"app":"…","summary":"…","body":"…"}
//   {"event":"media","status":"playing"|"paused"|"none","artist":"…","title":"…"}
//   {"event":"lock","locked":true|false}
//
// つないだときに、今の状態を {"event":"hello",…} で 1 行送る(ipc.zig)。
// 受け取りが追いつかない人(ソケットが詰まった)は切る。描画のループを止めないため、書き込みは待たない。
const std = @import("std");
const c = @import("../c.zig");

const MAX = 8;
var fds: [MAX]c_int = [_]c_int{-1} ** MAX;

/// 受け取る人を足す(fd はこちらが持って、切れたら閉じる)。いっぱいなら false
pub fn add(fd: c_int) bool {
    for (&fds) |*f| if (f.* < 0) {
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        f.* = fd;
        return true;
    };
    return false;
}

pub fn any() bool {
    for (fds) |f| if (f >= 0) return true;
    return false;
}

/// 出来事を 1 行の JSON にして全員に送る(誰もいなければ何もしない)
pub fn emit(v: anytype) void {
    if (!any()) return;
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    std.json.stringify(v, .{}, fbs.writer()) catch return; // 長すぎるものは送らない
    fbs.writer().writeByte('\n') catch return;
    sendAll(fbs.getWritten());
}

pub fn sendAll(line: []const u8) void {
    for (&fds) |*f| if (f.* >= 0) {
        const n = c.send(f.*, line.ptr, line.len, c.MSG_NOSIGNAL);
        if (n != @as(isize, @intCast(line.len))) {
            _ = c.close(f.*);
            f.* = -1;
        }
    };
}

/// タグのマスク → ワークスペースの番号(1〜9。特別なワークスペースなど 1〜9 に無ければ 0)
pub fn workspaceOf(tags: u32) u32 {
    const low = tags & 0x1ff;
    return if (low == 0) 0 else @ctz(low) + 1;
}

test "workspace number" {
    try std.testing.expectEqual(@as(u32, 1), workspaceOf(1));
    try std.testing.expectEqual(@as(u32, 3), workspaceOf(4));
    try std.testing.expectEqual(@as(u32, 0), workspaceOf(1 << 20));
}
