# dwindle レイアウト

::infobox dwindle
種類 | タイル型の窓の並べ方
考え方 | 狙った窓の場所を、長い辺で 2 つに分けて新しい窓を入れる
使われている所 | Hyprland(既定)、bspwm に近い
SeoritsuOS | River 0.5 の WM の配置(ワークスペースごとに 1 本の木)

**dwindle** は、窓が増えるたびに、**今ある窓の場所を長いほうの辺で半分に分けていく**、タイル型の窓の並べ方です。同じ所で開き続けると、窓がらせん状に小さくなっていきます(dwindle = だんだん小さくなる)。

## 概要 {#overview}

1 つ目の窓は画面全体。2 つ目を開くと、画面を左右に半分ずつ。3 つ目は、**カーソルの下の窓**の場所を分けます。左半分の窓の上で開けば左半分が上下に分かれ、右半分の上で開けば右半分が分かれます。分ける向きは、その場所が横長なら左右、それ以外なら上下です。

窓を閉じると、隣(木の兄弟)がその場所をまるごと引き継ぎます。

## 仕組み {#how}

窓を葉、分け目を節とする 2 分木です(`src/lib/dwindle.zig`)。

```zig
/// 窓 id を入れる。target の場所を分ける(無ければいちばん右下の葉)。first なら左・上の側に入る
pub fn insert(self: *Tree, id: usize, target: ?usize, first: bool) !void {
    …
    // t は分け目になり、元の窓は old へ移る
    old.* = .{ .id = t.id, .parent = t, .box = t.box };
    t.id = 0;
    t.ratio = 0.5;
    if (first) { t.a = leaf; t.b = old; } else { t.a = old; t.b = leaf; }
}
```

- 分け目ごとに比率を持ちます(Super+Ctrl+H・L、Super+右ドラッグ)。
- Super+Ctrl+J で、その分け目の向き(左右 ⇔ 上下)を逆に固定できます(Hyprland の togglesplit)。
- SeoritsuOS は、新しい窓をカーソルの**反対側**に入れます。カーソルは元の窓の上に残るので、フォーカスが新しい窓に移りません([ウィンドウマネージャ](#/tech-wm))。

## 理論と研究 {#theory}

:::research 二分空間分割として
dwindle は二分空間分割(BSP)木です。どの葉を分けるかを、フォーカス(カーソル)で選びます。窓を開く・閉じるのは木の深さ程度の手間、並べるのは窓の数 n に対して O(n) です。

縦横比の観点では、「長い辺で分ける」規則により、各窓の縦横比は 1:2 から 2:1 程度に収まりやすく、細長い窓ができにくくなります。
:::

## 関連項目 {#see}

- [[river]] / [[spring]]

## 参考文献 {#refs}

- [Hyprland Wiki: Dwindle Layout](https://wiki.hyprland.org/Configuring/Dwindle-Layout/)
