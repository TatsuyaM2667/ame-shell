// 画面にも OS の作りにも依存しない部品(ame-shell と、src/cmd/ の小さな道具の両方が使う)。
// どこからも @import("ame_lib") で読む(build.zig が名前を付ける)
pub const lrc = @import("lrc.zig");
pub const ai = @import("ai.zig");
pub const mcp = @import("mcp.zig");
pub const agentfmt = @import("agentfmt.zig");
pub const appid = @import("appid.zig");

test {
    _ = lrc;
    _ = ai;
    _ = mcp;
    _ = agentfmt;
    _ = appid;
}
