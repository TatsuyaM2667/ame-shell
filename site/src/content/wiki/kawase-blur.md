# Kawase ブラー

::infobox Kawase ブラー
考案 | 川瀬正樹(Masaki Kawase)、2003
改良 | dual Kawase(Marius Bjørge、ARM、2015)
特徴 | 少ない読み出しで大きくぼかせる
ame-shell | すりガラス(壁紙のぼかし)

**Kawase ブラー**は、少ない回数のテクスチャの読み出しで、大きくぼかすための方法です。その改良版の **dual Kawase** は、縮小しながらぼかし、拡大しながら戻すことで、さらに少ない計算で済みます。

## 概要 {#overview}

小さい写真をぼかしてから大きく引き伸ばすと、大きい写真をぼかしたのと同じように見えます。dual Kawase はこれを利用します。画像を半分、そのまた半分…と縮めながら、少しずつぼかします。縮んだ画像では、1 ピクセルが元の何ピクセル分にもなるので、少ない計算で広い範囲をぼかせます。

## 仕組み {#how}

**縮小の段**(dual Kawase の down): 出力のピクセルの位置で、中心を重み 4、斜めの 4 点を重み 1 で読み、8 で割ります。読む位置はピクセルの角(半ピクセルずれた位置)なので、テクスチャの線形補間で、1 回の読み出しが 2×2 ピクセルの平均になります。

```glsl
vec4 s = texture(u_tex, v_uv) * 4.0;
s += texture(u_tex, v_uv - u_half);
s += texture(u_tex, v_uv + u_half);
s += texture(u_tex, v_uv + vec2(u_half.x, -u_half.y));
s += texture(u_tex, v_uv - vec2(u_half.x, -u_half.y));
o = s / 8.0;
```

**拡大の段**(up): 周りの 8 点を読んで平均し、大きさを倍に戻します。

## ame-shell での使われ方 {#ame}

ame-shell は壁紙を [[fbo|FBO]] に描き、縮小を 3 段(設定 `blur 3`)、拡大を **1 段だけ**行います。ガラスは拡大して読む(線形補間でさらに滑らかになる)ので、元の大きさまで戻す必要がないからです。戻すほど計算が増え、ぼけも弱くなります([ガラス・壁紙・配色](#/tech-glass))。

## 理論と研究 {#theory}

:::research なぜ少ない読み出しで済むか
1 段の縮小で解像度が 1/2 になると、ピクセル数は 1/4 になります。k 段の縮小の合計のピクセル数は、元の画像の 1/4 + 1/16 + … < 1/3 です。各段の読み出しは 1 ピクセルあたり 5 回なので、全体でも元の画像を数回読む程度で済みます。一方、元の解像度で半径 r のガウスぼかしは、分離しても 1 ピクセルあたり 2(2r+1) 回です。

ぼけの大きさ(実効的な標準偏差)は、段の数 k に対して指数的(およそ 2^k に比例)に増えます。一方、計算量はほぼ一定です。これが、動きのある UI のすりガラス(毎フレームぼかし直す必要がある)で dual Kawase が標準的に使われている理由です。

代償として、厳密なガウスではなく、縮小・拡大の格子に由来するわずかな模様(エイリアシング)が出ることがあります。ame-shell は、ガラスのシェーダで微細なノイズを加えて、これと色の段差(バンディング)を目立たなくしています。
:::

## 関連項目 {#see}

- [[gaussian-blur]] / [[fbo]] / [[chromatic-aberration]] / [[shader]]

## 参考文献 {#refs}

- M. Kawase, "Frame Buffer Postprocessing Effects in DOUBLE-S.T.E.A.L (Wreckless)", GDC 2003.
- M. Bjørge, "Bandwidth-Efficient Rendering", SIGGRAPH 2015 Course "Moving Mobile Graphics".
