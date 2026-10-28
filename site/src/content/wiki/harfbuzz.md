# HarfBuzz

::infobox HarfBuzz
種類 | テキストシェーピングエンジン(C++ のライブラリ、C の API)
役割 | 文字の並びを、配置済みのグリフの並びにする
使われている所 | Chrome、Firefox、Android、GNOME、KDE ほか
ame-shell | すべての文字列の配置

**HarfBuzz** は、文字列を「どのグリフを、どこに置くか」に変える**シェーピング**のライブラリです。

## 概要 {#overview}

文字を左から順に並べるだけで済むのは、ごく一部の言語だけです。英語でも「fi」が 1 つのグリフにまとまる(合字)ことがあり、文字の組み合わせで間隔が変わります(カーニング)。アラビア文字は前後の文字で形が変わり、タイ語やヒンディー語では記号が上下に付きます。HarfBuzz は、フォントに入っている規則(OpenType の GSUB・GPOS の表)に従って、これを全部正しく処理します。

## 仕組み {#how}

1. 文字列(UTF-8 など)をバッファに入れる。
2. 言語・文字の種類・書く向きを決める(`hb_buffer_guess_segment_properties`)。
3. `hb_shape` で、グリフの番号と、それぞれの位置(送り幅・ずれ)を得る。
4. 各グリフには、元の文字列のどこから来たか(`cluster`)が付いている。

## ame-shell での使われ方 {#ame}

文字列を「同じフォントで描ける区間(ラン)」に分け、ランごとに HarfBuzz で並べます。区間だけでなく**文字列全体**を渡すのは、前後の文字を見る規則(文脈による形の変化)を正しく働かせるためです。`cluster` は、日本語の折り返し位置の計算に使っています([文字の描画](#/tech-text))。

## 関連項目 {#see}

- [[freetype]] / [[fontconfig]] / [[glyph-atlas]]

## 参考文献 {#refs}

- [HarfBuzz の文書](https://harfbuzz.github.io/)
- [OpenType の仕様(Microsoft)](https://learn.microsoft.com/typography/opentype/spec/)
