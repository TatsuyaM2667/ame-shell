# Wayland とサーフェス

<p class="file">対象: src/app.zig(1090 行)/ src/surface.zig(307 行)</p>

:::easy このページを読む前に
[[wayland|Wayland]] では、アプリは自分で絵を描いて、[[compositor|コンポジタ]](ame-shell の場合は [[river|River]])に渡します。ame-shell のバーや壁紙も、そうやって渡された「絵」です。

大事なのは「いつ描くか」です。ame-shell は、コンポジタから「今描けば次の画面の更新に間に合うよ」という合図([[frame-callback]])をもらったときだけ描きます。動いているものが無ければ合図を頼まないので、何も描きません。
:::

## シェルは「layer-shell のサーフェスの集まり」 {#layers}

Wayland では、普通のアプリは「窓(xdg_toplevel)」を作ります。デスクトップシェルは **wlr-layer-shell** を使い、画面の層(背景・下・上・最前面)に貼り付くサーフェスを作ります。ame-shell が作るサーフェスは次のとおりです。

| サーフェス | 層 | 出力ごと? | 中身 |
|---|---|---|---|
| 壁紙 | background | ✓ | シェーダ・画像・動画。全面、入力は受けない |
| 枠(caelestia レイアウト) | top | ✓ | 縁・縦バー・全ドロワーを 1 枚で描く。入力領域はバー・縁・開いているドロワーの矩形だけ |
| 排他領域用の透明サーフェス | top | ✓ | 各辺に幅 1px。窓が枠に重ならないよう、場所を確保する([枠](#/tech-frame)) |
| 壁紙ピッカー・ランチャー(classic) | overlay | — | 開いている間だけ作る |
| OSD(classic) | overlay | — | 表示中だけ作り、消えたら破棄 |
| ロック画面 | (ext-session-lock) | ✓ | ロック中だけ |

**作り方の手順**(`Surface.createLayer`):

```zig
const ls = c.zwlr_layer_shell_v1_get_layer_surface(app.layer_shell, wl, o.output, o.layer, o.namespace.ptr) orelse return error.Layer;
c.zwlr_layer_surface_v1_set_size(ls, o.width, o.height);
c.zwlr_layer_surface_v1_set_anchor(ls, o.anchor);
c.zwlr_layer_surface_v1_set_exclusive_zone(ls, o.exclusive);
c.zwlr_layer_surface_v1_set_margin(ls, o.margin[0], o.margin[1], o.margin[2], o.margin[3]);
c.zwlr_layer_surface_v1_set_keyboard_interactivity(ls, o.keyboard);
c.wl_surface_commit(wl); // 初回は中身なしでコミット → configure を待つ
```

layer-shell の約束で、最初のコミットは中身(バッファ)なしで行い、コンポジタからの `configure`(実際の大きさ)を待ってから描きます。`configure` で初めて EGL のウィンドウを作ります。

## 描画はフレームコールバックで {#frame}

```zig
// src/surface.zig
// 描画は必ず wl_surface.frame コールバック駆動:
//   状態が変わる → schedule() でフレームコールバックを要求
//   → コンポジタが次の vblank で done を送る → draw() → まだ動いていれば次を要求
// 動きが止まればコールバックを要求しないので、何もしない間は一切描画しない。

/// 次のフレームで描き直す。
pub fn schedule(self: *Surface) void {
    if (!self.configured) {
        self.want_frame = true;   // configure が来たら描く
        return;
    }
    if (self.frame_cb != null) {
        self.want_frame = true;   // もう頼んである(二重に頼まない)
        return;
    }
    self.requestFrame();
    c.wl_surface_commit(self.wl);
}
```

```zig
fn onFrameDone(data: ?*anyopaque, cb: ?*c.struct_wl_callback, time: u32) callconv(.C) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    c.wl_callback_destroy(cb);
    s.frame_cb = null;
    // 前回描画からの経過時間。初回や長い休止明けは 1/60 秒として扱う(ジャンプ防止)。
    var dt: f32 = 1.0 / 60.0;
    if (s.last_ms != 0 and time > s.last_ms) {
        dt = @as(f32, @floatFromInt(time - s.last_ms)) / 1000.0;
        if (dt > 0.1) dt = 1.0 / 60.0;
    }
    s.last_ms = time;
    s.render(dt);
}
```

**ポイント**

- **`dt` はコンポジタが渡す時刻から計算します**。自分の時計ではなく「画面が実際に更新された時刻」の差なので、120 Hz の画面でも 60 Hz の画面でも、ばねは同じ速さで動きます。
- **長く止まっていた後は `dt` を 1/60 秒にする**: 10 秒ぶりに描くとき `dt = 10` で進めると、アニメーションが一瞬で終わる(または跳ぶ)からです。
- **二重に頼まない**: 1 フレームの間に何度 `schedule` しても、コールバックは 1 つです。
- **描いた後の次のフレームの要求は、`eglSwapBuffers` のコミットに相乗り**させます(`render` の中で `requestFrame` してから swap)。余計な `wl_surface_commit` を出しません。

```zig
// src/surface.zig ensureEgl
// フレームコールバックで同期するので、eglSwapBuffers 自体は待たせない。
// (待たせると複数サーフェスで互いの vblank を待ってカクつく)
_ = c.eglSwapInterval(self.app.gpu.dpy, 0);
```

**`eglSwapInterval(0)` の理由**: 既定(1)では `eglSwapBuffers` が次の垂直同期まで止まります。ame-shell は 1 つのスレッドで複数のサーフェス(枠・壁紙・ロック画面…)を描くので、それぞれが vblank を待つと、2 つ目のサーフェスは 1 フレーム遅れ、3 つ目は 2 フレーム遅れ…と互いに足を引っ張ります。同期はフレームコールバックで取れているので、swap 自体は待たせません。

### ほかの方法との違い {#vs-frame}

| 方法 | 違い |
|---|---|
| 一定間隔のタイマーで描く(例: 60 fps で回し続ける) | 何も動いていなくても GPU と CPU を使う。画面のリフレッシュレートとずれてカクつく |
| `eglSwapInterval(1)` で vblank に同期 | 1 つのサーフェスなら素直だが、複数のサーフェスを 1 スレッドで描くと互いに待つ |
| サーフェスごとにスレッド | GL のコンテキストの切り替えと、状態の共有にロックが要る |

## 描画の時間を測る {#stats}

```zig
// AME_DEBUG_FRAMES=<ms>: その時間を超えたフレームの内訳を出す(性能調査用)
if (t_end - t0 > thr_ms * 1_000_000) {
    std.log.warn("slow frame {d}x{d}: setup={d}us draw={d}us gl={d}us swap={d}us", …);
}
```

`render` は「準備・部品の draw(ばねを進めて命令を積む)・GL の描画・swap」の 4 つを別々に計ります。遅いフレームがどこで遅いのかがすぐ分かり、[性能](#/performance)の改善(グリフの生成・アイコンのデコード)はすべてこのログから見つけました。`ame-ctl stats` は平均と最大を返します。

## 画面の拡大率 {#scale}

```zig
fn onPreferredScale(data: ?*anyopaque, _: ?*c.struct_wl_surface, factor: i32) callconv(.C) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    if (factor == s.scale or factor < 1) return;
    s.scale = factor;
    if (s.configured) { s.ensureEgl(); s.schedule(); }
}
```

- `wl_compositor` v6 以降は、コンポジタが「このサーフェスに最適な拡大率」(`preferred_buffer_scale`)を教えてくれます。それより古いコンポジタでは、サーフェスが入った出力(`enter`)の拡大率を使います。
- 拡大率が変わったら、EGL のウィンドウを `拡大率 × 論理サイズ` に作り直し、`wl_surface_set_buffer_scale` を設定します。UI の座標は論理ピクセルのままで、シェーダが `u_scale` で 1 物理ピクセルの幅を知り、輪郭のなめらかさを合わせます(`px = 1.0 / u_scale`)。

## グローバルのつなぎ方 {#globals}

```zig
fn bind(reg: ?*c.struct_wl_registry, name: u32, i: *const c.struct_wl_interface, ver: u32, want: u32) ?*anyopaque {
    return c.wl_registry_bind(reg, name, i, @min(ver, want));
}
```

**`@min(コンポジタの版, 自分が対応している版)` でつなぐ**のが Wayland の約束です。新しいコンポジタが新しい版を出しても、自分が知らないイベントは届きません(知らないイベントが届くと、リスナに関数が無くて落ちます)。

**無いものは無いなりに動く**: `river_libinput_config_v1`(タップでクリック)・`wp_cursor_shape_manager_v1`(カーソルの形)・`ext_session_lock_manager_v1`(ロック)などは、コンポジタが出していなければ、その機能だけが無効になります。River 0.3 では WM のプロトコルが無いので、窓のアニメーション以外の機能で動きます。

## キーボード {#keyboard}

```zig
fn kKeymap(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, format: u32, fd: i32, size: u32) callconv(.C) void {
    …
    const map = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    defer _ = c.munmap(map, size);
    const km = c.xkb_keymap_new_from_string(app.xkb_ctx, @ptrCast(map), c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
    …
}
```

- キーの配列(keymap)はコンポジタが fd で渡してきます。`mmap` で読み、xkbcommon で解釈します。ame-shell は配列を自分で決めず、**コンポジタと同じ配列**を使います(日本語配列でも記号がずれない)。
- **キーリピートは timerfd** で行います。コンポジタが教える `repeat_info`(遅延と回数/秒)どおりに、押している間だけ周期タイマーを張り、離したら止めます。押していないときにタイマーは存在しません。
- リピートするキーかどうかは `xkb_keymap_key_repeats` で確かめます(Shift などの修飾キーはリピートしない)。

## マウスとカーソル {#pointer}

- `wp_cursor_shape_v1` があれば、カーソルの見た目は名前(「指」「テキスト」など)でコンポジタに頼みます。カーソルの画像を自分で読み込んで描く必要がありません。
- 入力を受けたサーフェスから、そのサーフェスの持ち主(`Handler` の `pointer`)に配ります。**入力領域**(`wl_surface_set_input_region`)を必要な矩形だけにすることで、全画面の枠のサーフェスでも、それ以外の場所のクリックは下の窓にそのまま届きます。

## 研究者向けの補足 {#research}

:::research フレームのペーシングと遅延
フレームコールバックによる描画は、**コンポジタが主導するペーシング**です。クライアントが自前の時計で描くと、描画の周期とディスプレイの周期の位相がずれ、フレームが捨てられる(または 2 回表示される)ジャダーが生じます。`done` の時刻の差を dt として物理量を進めることで、リフレッシュレートが 60・120 Hz や可変(VRR)でも、時間に対して同じ軌跡になります。

入力から表示までの遅延の下限は、およそ「入力を受けて描き始めるまで + 描画 + コンポジタの合成 + 走査出力」です。`eglSwapInterval(0)` で swap を待たせないのは、単一スレッドで複数のサーフェスを描くときの**直列化された待ち**(サーフェス数 × 1 フレーム)を避けるためです。より厳密な予測(表示予定時刻での物理状態の評価)には `wp_presentation` のフィードバックが使えます。
:::

## 関連する用語 {#terms}

- [[wayland]]
- [[compositor]]
- [[layer-shell]]
- [[frame-callback]]
- [[vsync]]
- [[egl]]
