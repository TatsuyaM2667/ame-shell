# 符号付き距離場(SDF)

::infobox 符号付き距離場
英語 | Signed Distance Field / Function
定義 | 各点から形の境界までの距離。内側を負(または正)にする
主な用途 | 文字の描画、角丸・影、レイマーチング
ame-shell | UI の形・文字・ガラスの法線・枠の融合

**符号付き距離場(SDF)**は、空間の各点に「**いちばん近い形の縁までの距離**」を割り当てた関数です。形の内側では負、外側では正(または逆)という**符号**を付けます。

## 概要 {#overview}

角丸の四角を描くことを考えます。普通は「このピクセルは中か外か」を判定しますが、それだと縁がギザギザになります。SDF は「縁から何ピクセル離れているか」が分かるので、**縁から 0.5 ピクセル以内は半透明に**、というふうに滑らかに塗れます。さらに、距離が分かれば「縁から 3 ピクセル外側まで光らせる(発光)」「縁の近くだけ屈折させる」といった効果も、同じ値から作れます。

## 仕組み {#how}

角丸の矩形(中心が原点、半分の大きさ `b`、角の半径 `r`)の SDF は次の式です([Inigo Quilez](https://iquilezles.org/articles/distfunctions2d/) の形)。

```glsl
float sdBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
```

- `abs(p)` で 4 つの象限を 1 つにまとめる(対称性)。
- 角の外側では、角の円の中心からの距離 − 半径。辺の外側では、辺からの距離。内側では、いちばん近い辺までの距離を負で。

描くときは、距離 `d` を「画面の 1 ピクセルの大きさ」で割って、0〜1 の不透明度にします: `alpha = clamp(0.5 − d / px, 0, 1)`。

## ame-shell での使われ方 {#ame}

- **UI の形**: 角丸・影・円弧・線分は、すべて SDF の式で描きます([GPU レンダラ](#/tech-gpu))。
- **文字**: グリフを SDF の画像にしてアトラスに入れ、どの大きさでもくっきり描きます([[glyph-atlas]]、[文字の描画](#/tech-text))。
- **ガラスの法線**: SDF の**勾配**(どちらに距離が増えるか)は縁に垂直な方向なので、それを法線として屈折の向きに使います。
- **枠とドロワー**: 2 つの SDF を [[smooth-min]] でつなぐと、付け根が丸く融合します。

## 理論と研究 {#theory}

:::research 正確な距離と、その性質
SDF `f` が**正確な距離関数**なら、勾配の大きさは至る所で 1 です(アイコナール方程式 `|∇f| = 1`)。このため、`f` を「1 ピクセルの大きさ」で割るだけで、画面の空間での距離になり、輪郭の幅を常に 1 ピクセルにできます。

`min`(和集合)や `max`(積集合)で組み合わせた SDF は、外側では正確な距離ではなくなりますが、**下界**(本当の距離以下)にはなります。この性質(Lipschitz 定数が 1 以下)があれば、輪郭の位置(`f = 0`)は正しく、アンチエイリアスにも十分です。

画像としての SDF(文字のアトラス)は、2 値の画像から**距離変換**で作ります。厳密なユークリッド距離変換は、Felzenszwalb と Huttenlocher の線形時間のアルゴリズムで、画素数 N に対して O(N) で求められます。文字の描画に SDF を使う方法は、Valve の Chris Green が 2007 年の SIGGRAPH で発表し、ゲームで広まりました。鋭い角が丸まる欠点は、チャンネルごとに別の距離を持つ MSDF(Chlumský, 2015)で改善できます。
:::

## 関連項目 {#see}

- [[smooth-min]] / [[glyph-atlas]] / [[shader]] / [[premultiplied-alpha]]

## 参考文献 {#refs}

- C. Green, "Improved Alpha-Tested Magnification for Vector Textures and Special Effects", SIGGRAPH 2007 Course.
- P. Felzenszwalb, D. Huttenlocher, "Distance Transforms of Sampled Functions", Theory of Computing 8, 2012.
- V. Chlumský, "Shape Decomposition for Multi-channel Distance Fields", 修士論文, Czech Technical University, 2015.
- I. Quilez, [2D distance functions](https://iquilezles.org/articles/distfunctions2d/)
