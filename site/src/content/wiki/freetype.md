# FreeType

::infobox FreeType
種類 | フォントのラスタライザ(C のライブラリ)
対応 | TrueType、OpenType(CFF)、WOFF ほか
役割 | 文字の輪郭を読み、ピクセルの画像にする
ame-shell | グリフを画像にしてから SDF に変換

**FreeType** は、フォントファイルを読み、文字の**輪郭(アウトライン)をピクセルの画像に変える**ための、C のライブラリです。Linux・Android・ゲーム機など、非常に多くの環境で使われています。

## 概要 {#overview}

フォントのファイルには、文字の形が「曲線のつながり」として入っています。画面に出すには、それを決まった大きさのピクセルの絵にする必要があります(ラスタライズ)。FreeType はこの仕事をします。

## 仕組み {#how}

- `FT_Load_Glyph` で、グリフ(文字の形)を読む。
- `FT_Render_Glyph` で、画像にする。モードは、アンチエイリアス(`NORMAL`)、LCD 向け、そして **SDF**(輪郭からの距離)など。
- ヒンティング: 小さな文字をピクセルの格子に合わせて、くっきりさせる処理。

## ame-shell での使われ方 {#ame}

ame-shell は、まず普通のアンチエイリアスで画像にし、それを FreeType の `bsdf`(ビットマップから距離場)で [[sdf|SDF]] に変換しています。輪郭から直接 SDF を作る `sdf` モードは、画数の多い漢字で 1 字 6.6 ms かかりましたが、`bsdf` なら 2.2 ms でした。どの大きさにも使う SDF なので、ヒンティングは切っています([文字の描画](#/tech-text))。

## 関連項目 {#see}

- [[harfbuzz]] / [[fontconfig]] / [[glyph-atlas]] / [[sdf]]

## 参考文献 {#refs}

- [FreeType の文書](https://freetype.org/freetype2/docs/)
