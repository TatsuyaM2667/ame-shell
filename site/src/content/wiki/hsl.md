# HSL 色空間

::infobox HSL
成分 | 色相(Hue)・彩度(Saturation)・輝度(Lightness)
範囲 | H: 0〜1(0〜360°)、S と L: 0〜1
提案 | Joblove & Greenberg(1978)
ame-shell | 壁紙からアクセント色を作る

**HSL** は、色を「**どんな色味か(色相)・どれだけ鮮やかか(彩度)・どれだけ明るいか(輝度)**」の 3 つで表す方法です。

## 概要 {#overview}

コンピュータの色は、普通は赤・緑・青の混ぜ具合(RGB)で表します。でも「この色をもう少し明るく」「同じ明るさで色味だけ変えて」という操作は、RGB では分かりにくいです。HSL なら、明るさだけ・色味だけを変えられます。

## 仕組み {#how}

RGB(0〜1)から HSL へ:

```
最大 M = max(r, g, b)、最小 m = min(r, g, b)
L = (M + m) / 2
S = 0(M = m のとき)、それ以外は (M − m) / (L ≤ 0.5 ? M + m : 2 − M − m)
H = 最大の成分によって、(g − b)/(M − m)、(b − r)/(M − m) + 2、(r − g)/(M − m) + 4 を 6 で割る
```

## ame-shell での使われ方 {#ame}

壁紙から配色を作るとき、まず色相を求め、**輝度を 0.72、彩度を 0.62〜0.9 に固定して** HSL から RGB に戻します。どんな壁紙からでも、暗い背景の上で読める明るさのアクセント色になります。さらに、色相を「アクセントとして見栄えの良い 8 つの色相」に寄せ、緑と赤の帯からは外します([ガラス・壁紙・配色](#/tech-glass))。

## 理論と研究 {#theory}

:::research HSL の限界と、知覚的な色空間
HSL の「輝度」は、人間が感じる明るさとは一致しません。例えば、同じ L = 0.5 でも、黄色は青よりずっと明るく見えます。人の知覚に沿った色空間としては、CIELAB(1976)や、近年の **Oklab / OKLCH**(Björn Ottosson, 2020)があり、「明るさをそろえたまま色相だけ回す」操作がより正確にできます。

ame-shell が HSL を使っているのは、計算が軽く、目的(色相の分布の山を見つけ、明るさと彩度を一定に固定する)には十分だからです。Material You(Material Design 3)の配色の自動生成は、HCT(CAM16 と CIELAB を組み合わせた色空間)を使っています。

また、**色相は円周上の値**(0 と 1 が同じ)なので、平均や距離に注意が要ります。ame-shell のアクセントの色相の比較では、`d = min(|a − h|, 1 − |a − h|)` で円周上の距離を取っています。
:::

## 関連項目 {#see}

- [[dominant-color]] / [[premultiplied-alpha]]

## 参考文献 {#refs}

- G. Joblove, D. Greenberg, "Color Spaces for Computer Graphics", SIGGRAPH 1978.
- B. Ottosson, [A perceptual color space for image processing (Oklab)](https://bottosson.github.io/posts/oklab/), 2020.
