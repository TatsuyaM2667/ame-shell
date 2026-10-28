# 設計

## 使う言語と、使わないもの {#languages}

| 言語 | 使いどころ | 理由 |
|---|---|---|
| **Zig**(約 17,600 行) | 本体のほぼすべて・ビルド・ウィジェット | C のライブラリ(Wayland・EGL・FreeType・HarfBuzz・libdbus)をそのまま使える。メモリの使い方を自分で決められる。`zig build` だけで C のコードやプロトコルの生成まで完結する |
| **Odin**(192 行) | ばね・あいまい検索・主色抽出 | 数値計算を書きやすい。C ABI でそのままリンクでき、**同じソースを wasm32 にもビルドできる**(ウィジェットとこのサイトで共有) |
| **C** | 既存のライブラリ | wasm3(WebAssembly のインタプリタ)・stb_image・nanosvg |
| **WebAssembly** | ウィジェット・このサイト | 安全に差し替えられる部品。ホットリロード |

**使わないもの**: Qt・GTK・Electron・Node.js・Python・C++・QML(唯一の例外は SDDM のテーマ。SDDM は QML でしか書けないため)。補助のスクリプトも POSIX sh だけで書き、bash や GNU 独自の機能は使いません(FreeBSD や Chimera Linux の BSD 系のコマンドでも動かすため)。

## 全体の構成 {#overview}

```
                       ┌──────────────── ame-shell(1 プロセス・1 EGL コンテキスト)───────────────┐
 River ◀─Wayland──▶   │ app.zig        グローバル / 出力 / seat / River の状態 / 入力の配送          │
 (layer-shell,        │ wm/wm.zig      ウィンドウマネージャ(river-window-management-v1、dwindle)   │
  session-lock,       │ surface.zig    layer / lock サーフェス。wl_surface.frame に合わせて描く         │
  window-mgmt,        │ gfx.zig        GLES3 の 2D レンダラ(インスタンス描画の四角形 1 種類 + SDF)     │
  xkb-bindings)       │ text.zig       fontconfig → HarfBuzz → FreeType → SDF → 共有グリフアトラス       │
                       │ anim.zig ────▶ anim/anim.odin(Odin: ばね / あいまい検索 / 主色抽出、C ABI)    │
                       │ bar / wallpaper / osd / launcher / notify / dashboard / lock / media / video   │
                       │ wasm.zig ────▶ wasm3(C)── widgets/*.wasm(Zig + Odin を wasm32 に)          │
                       │ ipc.zig        Unix ソケット ◀── ame-ctl                                       │
                       │ platform/      loop.zig(epoll + timerfd) / sys.zig / bsd.zig(FreeBSD)        │
                       └────────────────────────────────────────────────────────────────────────────────┘
```

## イベントループ {#loop}

すべてのデータの出どころを **fd として 1 つの epoll** に入れます。スレッドもポーリングも使いません。

| fd | 起きるタイミング |
|---|---|
| Wayland | 入力・画面更新の合図・configure・River の状態 |
| 時計の timerfd | 次の「分」の境目ちょうど |
| システムの timerfd | 20 秒ごと(バッテリー・ネットワーク・明るさ) |
| 壁紙の timerfd | ライブ壁紙の fps ごと(静止時は止まる) |
| `pactl subscribe` | 音量が変わったときだけ |
| `playerctl --follow` | 曲・再生状態が変わったときだけ |
| D-Bus | 通知が来たとき |
| inotify | 設定ファイル・ウィジェットの `.wasm` を保存したとき |
| IPC ソケット | ame-ctl を実行したとき |
| 動画のパイプ | libmpv / ffmpeg から新しいコマが来たとき |

FreeBSD では epoll と timerfd を libepoll-shim、inotify を libinotify で使います。OS ごとの違いは `src/platform/` に閉じ込めています(Linux は sysfs / procfs、FreeBSD は sysctl・kenv・ifconfig・mixer・backlight)。

## ウィンドウマネージャ {#wm}

River 0.4 以降は、「合成(描画と入力)」を River が、「どこに何を置くか」をウィンドウマネージャ(WM)が担当する分担になっています。ame-shell はシェルと同じプロセスで WM も担当します。

- WM の状態(大きさの提案・フォーカス・閉じる要求)は、River の **manage sequence** の中でしか変えられません。キー操作や ame-ctl からの要求はいったん積んでおき、manage sequence を起こしてから処理します。
- アニメーション中だけ毎フレーム配置を更新し、止まれば River とのやりとりはありません。
- `ame-ctl restart` で ame-shell を入れ替えても、River が付けた窓の識別子からタグや浮き状態を戻すので、**窓はそのまま**です。
- ame-shell が落ちても、`ame-river5-init` が起動し直します。30 秒以内に 3 回落ちたら River を終了してログイン画面に戻ります(黒い画面に閉じ込めないため)。

## WebAssembly のウィジェット {#widgets}

- ホストとウィジェットの約束事(ABI)は `src/widget_abi.zig` にまとめ、両方から import します。
- ウィジェットは自分のメモリに描画命令の配列と状態を持ち、ホストはそれを直接読み書きします(**コピーしない**)。
- import は `ame.action(i32, f32)` だけです。WASI は無効、メモリは 1 MiB 固定です。不正な命令は無視し、文字列は範囲を確認します。
- `.wasm` が更新されたら、状態の領域を退避 → 読み込み直し → 大きさが同じなら書き戻す、の順で、**状態を保ったまま**差し替えます。

## まわりのソフトとの約束事 {#conventions}

| 約束事 | 使う人 |
|---|---|
| MPRIS(`xesam:album`・`mpris:artUrl`・`mpris:length`・Position) | ダッシュボードのメディア |
| `$XDG_RUNTIME_DIR/lyrics/<プレーヤー名>.lrc`(`[ti:]` `[ar:]` `[al:]` つき) | プレーヤーから同期歌詞を渡す(music-tui-bsd が対応) |
| `org.freedesktop.Notifications` | 通知(ほかのデーモンがいれば譲る) |
| `~/.local/state/ame-shell/wallpaper` | 壁紙。SDDM のテーマの背景にも使う |

## このサイトの作り {#site}

このドキュメントサイトも、ame-shell と同じ考え方で作っています。

- 本文は Markdown に似た簡単な書式で書きます(`site/src/content/*.md`)。それを **Zig で書いた WebAssembly**(`site/src/main.zig`)がブラウザ上で HTML にします。
- [アニメーション](#/animation)・[ランチャー](#/shell)・[配色](#/shell)のデモは、ame-shell 本体の `anim/anim.odin` を Odin で `freestanding_wasm32` にビルドしたもの(約 2 KB)を、そのまま呼んでいます。
- JavaScript は、2 つの wasm を読み込んで DOM に入れ、Canvas に描くだけです。ライブラリやフレームワークは使っていません。
- ビルドは `zig build`、公開は Cloudflare Pages(`wrangler pages deploy`)です。
