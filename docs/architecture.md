# アーキテクチャ

```
                       ┌──────────────── ame-shell(1プロセス・1 EGL コンテキスト)────────────────┐
 River ◀─Wayland──▶   │ app.zig        globals / 出力 / seat / River status・control / 入力配送      │
 (layer-shell,        │ surface.zig    layer/lock サーフェス。wl_surface.frame 駆動の描画             │
  session-lock,       │ gfx.zig        GLES3 2D レンダラ(インスタンス化した1種類の四角形 + SDF)       │
  river-status)       │ text.zig       fontconfig → HarfBuzz → FreeType SDF → 共有グリフアトラス     │
                       │ anim.zig ────▶ anim/anim.odin(Odin: スプリング/ファジー/主色抽出, C ABI)    │
                       │ bar / wallpaper / osd / launcher / notify / dashboard / lock / media         │
                       │ wasm.zig ────▶ wasm3(C)── widgets/*.wasm(Zig + Odin を wasm32 に)        │
                       │ ipc.zig        Unix ソケット ◀── ame-ctl(Zig, libc のみ)                    │
                       │ platform/      loop.zig(epoll+timerfd) / sys.zig(sysfs, procfs, 外部コマンド)│
                       └──────────────────────────────────────────────────────────────────────────────┘
```

## イベントループ
全てのデータ源を fd として 1 つの epoll に入れる。

| fd | 起きるタイミング |
|---|---|
| Wayland | コンポジタからのイベント(入力・frame done・configure・River の状態) |
| clock timerfd | 次の「分」の境目ちょうど(秒表示時は秒) |
| sys timerfd | 20 秒ごと(バッテリー・ネットワーク・明るさ) |
| wallpaper timerfd | ライブ壁紙の FPS ごと(AC/バッテリーで切替、静止時は停止) |
| `pactl subscribe` の pipe | 音量が変わったときだけ |
| `playerctl --follow` の pipe | 曲・再生状態が変わったときだけ |
| D-Bus fd | 通知が来たとき |
| inotify | 設定ファイル / ウィジェット .wasm の保存時 |
| IPC ソケット | ame-ctl 実行時 |
| 各種 one-shot timerfd | OSD の自動非表示、通知の期限、キーリピート、ダッシュボードの 1 秒更新(開いている間だけ) |

## 描画モデル
1. 状態が変わる → `Surface.schedule()` が `wl_surface.frame` を要求してコミット
2. コンポジタの `done` で `render(dt)` → 各部品の `draw()` がスプリングを `dt` だけ進め、命令を積む
3. まだ動いていれば次のフレームを要求(eglSwapBuffers の commit に相乗り)。止まれば何もしない
4. `eglSwapInterval(0)`: 同期はフレームコールバックで取るので、複数サーフェスが互いの vblank を待たない

## ガラス
- 壁紙を出力ごとの FBO(`Backdrop.scene`)に描き、dual Kawase(down×N, up×1)でぼかした `blurred` を保持。
- パネルのシェーダはサーフェスの出力上の位置 `u_origin` を足して「真後ろ」をサンプル。
- 縁は SDF の勾配を法線として UV をずらし(屈折)、RGB を少しずらして(色収差)、左上光源で縁のハイライト、ハッシュノイズとスパークルを加算。
- 他のアプリのウィンドウ越しのブラーは、River 0.3.5 が `ext_background_effect` を出していないため不可能(確認済み)。ウィンドウ上に出るポップアップは色を濃くして対応。

## WASM ウィジェット
- ABI: `src/widget_abi.zig`(ホストとウィジェットの両方が import)。
- ウィジェットは自分のメモリにコマンド配列とストアを持ち、ホストはそれを `m3_GetMemory` で直接読み書きする(ゼロコピー)。
- import は `ame.action(i32, f32)` だけ。WASI 無効、メモリ 1MiB 固定。不正なコマンド種別は無視、文字列は境界チェック。
- ホットリロード: inotify で `.wasm` の更新を検知 → `ame_state()` の領域を退避 → 再インスタンス化 → サイズが同じなら書き戻す。

## 設定
`config.ame`(KDL/TOML 風 DSL、`src/config.zig`)。ディレクトリを inotify で監視し、保存した瞬間に再読込。
