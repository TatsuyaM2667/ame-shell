# fBm(非整数ブラウン運動)

::infobox fBm
英語 | fractional Brownian motion
CG での意味 | 周波数の違うノイズを、振幅を半分ずつにして重ねたもの
別名 | フラクタルノイズ、オクターブノイズ
ame-shell | オーロラの壁紙

**fBm** は、CG では「細かさの違うノイズを何層も重ねて、雲や炎のような自然な模様を作る方法」を指します。

## 概要 {#overview}

山の稜線を拡大すると、大きな起伏の中に小さな起伏があり、その中にさらに小さな起伏があります。fBm はこれを真似します。なめらかなノイズ(値が少しずつ変わる乱数)を、1 層目は大きく粗く、2 層目は倍の細かさで半分の強さ…と重ねると、自然な模様になります。

## 仕組み {#how}

```glsl
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p = p * 2.03 + 17.1;   // 周波数をほぼ倍に(ずらして規則性を消す)
        a *= 0.5;              // 振幅を半分に
    }
    return v;
}
```

`2.03` のようにちょうど 2 にしないのは、層の格子がそろって模様に規則性が出るのを防ぐためです。

## ame-shell での使われ方 {#ame}

オーロラの壁紙は、低い周波数の fbm でカーテンの中心線をゆっくり揺らし、高い周波数の fbm で縦の光の筋を作っています([ガラス・壁紙・配色](#/tech-glass))。

## 理論と研究 {#theory}

:::research 本来の fBm と、パワースペクトル
数学での fBm(Mandelbrot と Van Ness, 1968)は、ハースト指数 H(0 < H < 1)を持つガウス過程で、増分の分散が時間差の 2H 乗に比例します。パワースペクトルは周波数 f に対して `1/f^(2H+1)` に従います。

CG の「オクターブを重ねたノイズ」は、各層で周波数を倍(lacunarity = 2)、振幅を 1/2(gain = 1/2)にすることで、この冪乗則のスペクトルを近似します。gain を変えると、模様の粗さ(フラクタル次元)が変わります。ノイズの関数そのものは、Perlin(1985)の勾配ノイズや、値ノイズ(ame-shell)が使われます。
:::

## 関連項目 {#see}

- [[shader]]

## 参考文献 {#refs}

- B. Mandelbrot, J. Van Ness, "Fractional Brownian Motions, Fractional Noises and Applications", SIAM Review 10(4), 1968.
- K. Perlin, "An Image Synthesizer", SIGGRAPH 1985.
