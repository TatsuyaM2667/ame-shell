# layer-shell

::infobox wlr-layer-shell
正式名 | wlr-layer-shell-unstable-v1
提案 | wlroots プロジェクト
層 | background / bottom / top / overlay
用途 | バー・壁紙・通知・ランチャー・ロック以外のシェル部品

**layer-shell** は、[[wayland|Wayland]] の拡張プロトコルの 1 つで、バー・壁紙・通知のような「**デスクトップの部品**」を、画面の決まった層と位置に貼り付けるためのものです。

## 概要 {#overview}

普通のアプリの窓は、ウィンドウマネージャが好きな場所に置きます。でも、壁紙は一番下に、バーは画面の上端に、通知は一番手前に、と決まった場所にいてほしいものです。layer-shell を使うと、アプリが「私は壁紙です。画面全体の一番下に」と頼めます。

## 仕組み {#how}

- **層(layer)**: `background`(壁紙)・`bottom`・`top`(バー)・`overlay`(最前面)の 4 つ。
- **アンカー**: 上下左右のどの辺に貼り付くか。4 辺全部なら全画面。
- **排他領域(exclusive zone)**: 「この幅には窓を置かないで」という予約。バーが窓に重ならないのはこのおかげです。
- **キーボード**: `none`(受け取らない)・`exclusive`(独占)・`on_demand`(クリックしたら)。
- 最初は中身なしで `commit` し、コンポジタの `configure`(実際の大きさ)を待ってから描きます。

## ame-shell での使われ方 {#ame}

壁紙は `background`、枠と縦バーは `top`、ランチャー・通知・OSD・壁紙ピッカーは `overlay` に置きます([Wayland とサーフェス](#/tech-wayland))。

**全画面のサーフェスには排他領域を付けられない**(どの辺を避けるか決まらない)という仕様の制約があるため、ame-shell は各辺に**幅 1 px の透明なサーフェス**を置いて、それに排他領域だけを持たせています([枠とドロワー](#/tech-frame))。

## 関連項目 {#see}

- [[wayland]] / [[session-lock]] / [[compositor]]

## 参考文献 {#refs}

- [wlr-layer-shell-unstable-v1 の仕様](https://wayland.app/protocols/wlr-layer-shell-unstable-v1)
