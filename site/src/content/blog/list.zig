// ブログの記事の一覧: .{ スラッグ, 題, 日付, 本文 }。古い順に並べる(一覧と横の欄は新しい順に出す)。
pub const items = .{
    .{ "blog", "開発ブログ", "", @embedFile("index.md") },
    .{ "blog/2026-10-26-start", "1 日で、River の上にガラスのシェルを作った", "2026-10-26", @embedFile("2026-10-26-start.md") },
    .{ "blog/2026-10-26-renderer", "1 種類の四角形で全部を描く: 525 ms のフレームを 0 にするまで", "2026-10-26", @embedFile("2026-10-26-renderer.md") },
    .{ "blog/2026-10-26-spring", "ばねを Odin で書いた理由: sin も exp も使えない場所で", "2026-10-26", @embedFile("2026-10-26-spring.md") },
    .{ "blog/2026-10-27-frame", "縁がニョキッと伸びる: smooth-min と、細い橋の不具合", "2026-10-27", @embedFile("2026-10-27-frame.md") },
    .{ "blog/2026-10-27-river5", "River 0.3 の壁と、0.5 でウィンドウマネージャになった話", "2026-10-27", @embedFile("2026-10-27-river5.md") },
    .{ "blog/2026-10-28-freebsd", "FreeBSD 移植記: 番号 286 の SIGSYS から、タッチパッドまで", "2026-10-28", @embedFile("2026-10-28-freebsd.md") },
    .{ "blog/2026-10-28-music", "音楽のダッシュボード: 逆向きのトーンアームと、反転する Play", "2026-10-28", @embedFile("2026-10-28-music.md") },
    .{ "blog/2026-10-28-site", "このサイトを WebAssembly で作った", "2026-10-28", @embedFile("2026-10-28-site.md") },
    .{ "blog/2026-11-02-own", "cava も playerctl も nmcli も grim もやめた", "2026-11-02", @embedFile("2026-11-02-own.md") },
    .{ "blog/2026-11-02-ripple", "ロック画面の波紋と、紙のようにたわむ窓", "2026-11-02", @embedFile("2026-11-02-ripple.md") },
    .{ "blog/2026-11-11-memory", "メモリが返ってこない: libc の mimalloc と、消されない GPU の同期オブジェクト", "2026-11-11", @embedFile("2026-11-11-memory.md") },
    .{ "blog/2026-11-14-kami", "道具に神々の名前を: curl も wf-recorder も swaylock もやめた", "2026-11-14", @embedFile("2026-11-14-kami.md") },
};
