// 画面にも OS の作りにも依存しない部品(ame-shell と、src/cmd/ の小さな道具の両方が使う)。
// どこからも @import("ame_lib") で読む(build.zig が名前を付ける)
pub const lrc = @import("lrc.zig");

test {
    _ = lrc;
}
