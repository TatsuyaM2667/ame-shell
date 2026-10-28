# ウィンドウマネージャ

<p class="file">対象: src/wm/wm.zig(1233 行)/ src/wm/binds.zig(98 行)</p>

:::easy このページを読む前に
ウィンドウマネージャは「窓をどこに、どの大きさで置くか」を決める係です。[[river|River]] 0.5 では、画面に絵を出す係(River)と、窓を並べる係が分かれていて、ame-shell が並べる係を担当しています。

並べ方は「残りの場所を、長いほうの辺で半分に分けていく」([[dwindle]])です。窓が開くときは中心からポップして現れ、閉じるときは中心へ縮んで消えます。これも全部ばねで動いています。
:::

## River 0.5 の分担 {#split}

River 0.4 以降は、**「合成(描画と入力)」をコンポジタの River が、「どこに何を置くか」を別のプログラム(ウィンドウマネージャ)が**担当します。両者は `river-window-management-v1` というプロトコルで話します。ame-shell は、シェルと**同じプロセス**でこの WM を担当します。

| 方式 | 窓の配置を決めるもの | 窓のアニメーション |
|---|---|---|
| River 0.3 | River の中(レイアウトの寸法だけ外の rivertile などが返す) | **できない**(位置はコンポジタの中で決まり、途中のフレームを挟めない) |
| **River 0.5 + ame-shell** | ame-shell(WM) | ✓ 毎フレーム位置と表示範囲を送れる |
| Hyprland・Sway・KWin | コンポジタ自身 | コンポジタの中で |

ame-shell が WM を兼ねると、次のことができます。

- **窓の動きにも同じばねを使える**(位置・大きさ・表示範囲)。
- **シェルが窓の状態を正確に知っている**: ワークスペースごとのアプリ名と数、フォーカス中の窓、全画面かどうか。River 0.3 では、これを外から推測するしかありませんでした(`toplevels.zig` の推測ロジック)。
- **枠線の色をテーマのアクセントに合わせ、壁紙が変わると一緒に色が移り変わる**。

## manage sequence と render sequence {#sequences}

`river-window-management-v1` では、WM が状態を変えてよい場面が決まっています。

- **manage sequence**: 窓の大きさの提案・フォーカス・閉じる要求・タグ(ワークスペース)など、**窓の状態**を変えてよい。
- **render sequence**: 窓の**位置・表示範囲(clip box)・重なり順**など、見た目だけを変えてよい。

キー操作や ame-ctl からの要求は、届いた瞬間には実行できません。いったん `queue` に積み、`manage_dirty` で River に「manage sequence を始めて」と頼んでから処理します。

```zig
fn manage(self: *Wm) void {
    …
    // 1. 新しいウィンドウ: 出力とタグを決め、フォーカス中の窓の次に並べる
    // 2. キーバインドの作成と有効化(最初の 1 回)
    // 3. 溜まっていた操作を実行
    // 4. Super+Q で閉じる途中の窓: 縮み終わったら close
    // 5. 全画面
    // 6. 配置
    // 7. フォーカス(見えていない窓からは外す)
    // 8. 枠線(フォーカス中はテーマのアクセント色)
    // 9. シェル側(バー・ダッシュボード)へ状態を伝える
}
```

### 新しい窓の扱い {#new}

```zig
if (w.node == null) w.node = c.river_window_v1_get_node(w.obj);
// タイル型なのでサーバー側の枠(タイトルバー無し)を使ってもらう
c.river_window_v1_use_ssd(w.obj);
c.river_window_v1_set_tiled(w.obj, ALL_EDGES);
// 提案した大きさで描かれるまでは隠しておく(初回の仮の大きさが一瞬見えないように)
c.river_window_v1_hide(w.obj);
…
// 大きさの決まっている小窓(ダイアログ等)は浮かせる
if (w.max_w > 0 and w.max_w == w.min_w and w.max_h > 0 and w.max_h == w.min_h) w.floating = true;
```

- **提案した大きさで描かれるまで隠します**。アプリは最初、自分の好きな大きさで描くことがあり、それが一瞬見えると「ちらつき」になります。12 フレーム待っても応じないアプリは諦めて表示します。
- `use_ssd` + `set_tiled(全辺)`: アプリに「タイル配置されている(影や丸い角を付けなくていい)」と伝え、枠線は River に描いてもらいます。
- **最小と最大の大きさが同じ窓**(大きさを変えられないダイアログ)は、自動で浮かせます。

## 配置: dwindle {#dwindle}

```zig
/// dwindle: 残りの領域を長い辺で分け、i 番目の窓は前半、残りは後半へ
fn layout(self: *Wm, o: *WOut) void {
    …
    var r = area;
    for (tiled[0..n], 0..) |w, i| {
        var cell = r;
        if (i + 1 < n) {
            const ratio = if (i == 0) self.ratio else 0.5;
            if (r[2] >= r[3]) {                       // 横長なら左右に分ける
                const lw = (r[2] - gi) * ratio;
                cell = .{ r[0], r[1], lw, r[3] };
                r = .{ r[0] + lw + gi, r[1], r[2] - lw - gi, r[3] };
            } else {                                  // 縦長なら上下に分ける
                const th = (r[3] - gi) * ratio;
                cell = .{ r[0], r[1], r[2], th };
                r = .{ r[0], r[1] + th + gi, r[2], r[3] - th - gi };
            }
        }
        self.place(w, cell);
    }
}
```

1 つ目の窓は残り全体を `ratio`(Super+Ctrl+H / L で変える)で、2 つ目以降は半分ずつ、**その時点の残りの長い辺**で分けていきます。窓が増えるほど、らせん状に小さくなります(Hyprland の dwindle と同じ考え方)。新しい窓はフォーカス中の窓の**次**に入るので、今見ている窓のすぐ隣に開きます。

```zig
fn place(self: *Wm, w: *Window, cell: [4]f32) void {
    …
    if (pw != w.proposed[0] or ph != w.proposed[1]) {
        c.river_window_v1_propose_dimensions(w.obj, pw, ph);
        w.proposed = .{ pw, ph };
    }
    if (w.placed) {
        // 位置はスプリングで追いかける(移動・入れ替え・レイアウト変化が滑らかに)
        w.px.set(w.tx);
        w.py.set(w.ty);
    }
    self.kick();
}
```

**大きさの提案は変わったときだけ**送ります。同じ大きさを何度も送ると、アプリが毎回描き直すからです。位置はばねの**目標**を変えるだけで、実際の位置は render sequence で毎フレーム送ります。

## アニメーション: 中身を拡大せず「見える範囲」を広げる {#anim}

```zig
fn render(self: *Wm) void {
    …
    if (!w.placed) {
        …
        // 初めて表示: その場で「中心から広がる」(Hyprland の popin)
        w.placed = true;
        w.px.snap(w.tx);
        w.py.snap(w.ty);
        w.reveal.snap(0.55);
        w.reveal.set(1);
    }
    // 大きくなったときは前の大きさから clip を広げていく(縮むときは即時)
    …
    var springs = [_]*Spring{ &w.px, &w.py, &w.cw, &w.ch, &w.reveal, &w.slide };
    if (anim.stepAll(&springs, dt)) moving = true;
    …
    const sc = std.math.clamp(w.reveal.x, 0, 1.2);
    const bw = vw * @min(sc, 1);
    const bh = vh * @min(sc, 1);
    c.river_node_v1_set_position(node, @intFromFloat(@round(x)), @intFromFloat(@round(y)));
    …
    c.river_window_v1_set_clip_box(w.obj, cx, cy, bw, bh);   // 中心から bw×bh だけ見せる
    …
    c.river_window_manager_v1_render_finish(self.mgr);
    // 動いている間は次のフレームでもう一度 render sequence を回す
    self.animating = moving;
    if (moving) self.anim_timer.arm(8, 0);
}
```

**窓の中身を拡大縮小するのではなく、「見える範囲(clip box)」を中心から広げています**。WM は窓の中身(アプリが描いた画像)を変形する権限を持っていないからです。その代わり、

- 開くとき: 表示範囲を 55% から 100% へ、弾むばね(減衰 0.68)で広げる → 中心からポップして出てくるように見える。
- 閉じるとき(Super+Q): 表示範囲を 0 へ速く(応答 0.18 秒)縮め、**縮み終わってから**アプリに閉じる要求を送る。アプリが閉じなかったら(保存の確認など)、600 ms 後に元に戻す。
- 大きくなるとき: 前の大きさから表示範囲を広げていく。小さくなるときは即座に(大きいまま見せると、アプリの描き直しが追いつかない部分が見えるため)。
- ワークスペースの切り替え: 出ていく窓は横へ滑って消え、入ってくる窓は反対側から入る。

**WM にはフレームコールバックがありません**(サーフェスを持たないため)。そこで、何かが動いている間だけ **8 ms の単発タイマー**で render sequence を回し直します。止まったらタイマーを張らないので、窓が静止している間、ame-shell と River の間のやりとりは**ゼロ**です。

## 再起動をまたいで窓を保つ {#restore}

```zig
// 再起動をまたいだ窓の状態($XDG_RUNTIME_DIR/ame-wm-state-<ディスプレイ>: 「識別子 タグ 浮き」の行)
/// ame-ctl restart の直前に呼ぶ
pub fn saveState(self: *Wm) void {
    …
    for (self.windows.items) |w| {
        if (w.ident_len == 0) continue;
        bw.writer().print("{s} {d} {d}\n", .{ w.ident[0..w.ident_len], w.tags, @intFromBool(w.floating) }) catch {};
    }
    if (self.focusedOutput()) |o| bw.writer().print("@tags {d}\n", .{o.tags}) catch {};
}
```

River は窓に**識別子**を付けてくれます。この識別子は、WM が入れ替わっても変わりません。`ame-ctl restart`(と `ame-update`)の直前に「識別子・ワークスペース・浮いているか」を保存し、新しい ame-shell は窓を受け取ったときにそれを読んで元に戻します。

- ファイルは `$XDG_RUNTIME_DIR`(ログイン中だけ存在し、本人だけが読める)に、モード 0600 で置きます。
- ファイル名に `WAYLAND_DISPLAY` を含めるので、試験用の入れ子の River と本物のセッションが混ざりません。

**結果**: 更新しても、窓はそれぞれのワークスペースに残ったまま、シェルだけが新しい版になります。

## キー割り当て {#binds}

```zig
// River 0.5 セッションのキー割り当て。今の ~/.config/river/init(River 0.3)と同じ操作感にしてある。
// ランチャー・ロック等は ame-shell の機能を直接呼ぶ(ame-ctl を起動するより速い)。
.{ .keysym = c.XKB_KEY_Return, .mods = SUPER, .action = .{ .spawn = "foot" } },
.{ .keysym = c.XKB_KEY_d, .mods = SUPER, .action = .{ .ame = "launcher toggle" } },
.{ .keysym = c.XKB_KEY_XF86AudioRaiseVolume, .mods = NONE, .action = .{ .ame = "volume up" } },
```

- キーの登録は `river-xkb-bindings-v1` で行います。keysym(キーの意味)で登録するので、日本語配列・US 配列のどちらでも同じ割り当てが正しく効きます。
- 割り当ての動作は 3 種類: `spawn`(シェルのコマンドを起動)・`ame`(ame-ctl と同じコマンドを**プロセスを起動せずに**直接実行)・WM の操作(フォーカス・入れ替え・ワークスペース)。
- ランチャーや音量をプロセスの起動なしで呼ぶので、キーを押してから反応するまでに、fork / exec の時間がかかりません。

## フォーカスとレイヤー {#focus}

- ランチャーなどが**キーボードを占有**している間は、窓にフォーカスを渡しません。マウスで窓をクリックするなどの明示的な操作をしたときだけ、窓に戻します。
- マウスを窓の上に動かしたときのフォーカス移動は、「ポインタが実際に動いた」ときだけ行います。キー操作で窓が動いてポインタの下に来ただけでは、フォーカスを奪いません。
- 重なり順は「タイル → 浮いている窓 → フォーカス中の浮いている窓」の順で毎回並べ直します。

## ほかの WM との違い {#vs}

| | ame-shell | Hyprland | Sway | niri |
|---|---|---|---|---|
| WM の場所 | コンポジタの外(River 0.5)、シェルと同じプロセス | コンポジタの中 | コンポジタの中 | コンポジタの中 |
| 開く動き | 表示範囲をばねで広げる | 拡大・スライドなど(ベジェ曲線) | なし | ばね / イージング |
| 再起動で窓を保つ | ✓(River の識別子) | コンポジタが落ちると窓も消える | 同左 | 同左 |
| WM が落ちたとき | River と窓は生きている。`ame-river5-init` が起動し直す | セッションごと終わる | 同左 | 同左 |

最後の行は、River の分担方式の大きな利点です。WM(ame-shell)にバグがあって落ちても、**アプリは閉じません**。

## 研究者向けの補足 {#research}

:::research トランザクションとしての配置
`river-window-management-v1` の manage sequence と render sequence は、**状態の変更をトランザクションとしてまとめる**仕組みです。WM は sequence の中で複数の窓の状態を変え、終了(`manage_finish` / `render_finish`)で River がそれらを**原子的に**適用します。これにより、窓 A を動かしたが窓 B はまだ、という途中の状態が画面に出ません(Wayland の「すべてのフレームが完璧」の WM 版)。

アニメーションは、各 render sequence を 1 つの時刻の標本とみなし、ばねの状態をその時刻まで積分して送る**離散時間の制御**です。WM はサーフェスを持たないためフレームコールバックが無く、8 ms の単発タイマーで標本化します(約 120 Hz の上限)。標本化の間隔が表示の周期と一致しないことによる位相の揺れは、ばねが時間で積分されていること(dt を実時間で取る)で、軌跡の歪みにはなりません。

[[dwindle]] は片側に伸びる BSP 木で、窓の数 n に対して O(n) で配置が決まり、並び順だけを状態として持ちます。長い辺で分ける規則は、各セルの縦横比を、最初の領域の縦横比に応じて有界な範囲に保ちます。
:::

## 関連する用語 {#terms}

- [[river]]
- [[dwindle]]
- [[xkb]]
- [[spring]]
- [[compositor]]
