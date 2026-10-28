# 言語とツールチェイン

<p class="file">対象: リポジトリ全体 / build.zig / src/c.zig / anim/anim.odin</p>

## 結論 {#summary}

| 言語 | 量 | 担当 |
|---|---|---|
| Zig 0.13(固定) | 約 17,600 行 | 本体・WM・ウィジェット・ビルド・このサイトの描画エンジン |
| Odin dev-2026-08 | 192 行 | ばね・あいまい検索・主色抽出 |
| C(既存のもの) | — | wasm3(WebAssembly インタプリタ)・stb_image・nanosvg・Wayland のプロトコル(wayland-scanner が生成) |
| POSIX sh | — | セッション・インストーラ・補助スクリプト |

**使わないもの**: Qt・GTK・Electron・Node.js・Python・C++・QML(SDDM のテーマだけは例外。SDDM が QML しか受け付けないため)。

結果として、**直接リンクするライブラリは 9 つ**だけです: `libwayland-client`・`libwayland-egl`・`libEGL`・`libGLESv2`・`libxkbcommon`・`libfreetype`・`libharfbuzz`・`libfontconfig`・`libdbus-1`(と libc)。strip した ame-shell の実行ファイルは **1.8 MB**(wasm3・stb_image・nanosvg・Wayland のプロトコルのコードを含む)、ame-ctl は **14 KB**、WebAssembly のウィジェットは 1 つ **8〜11 KB** です。

## なぜ Zig か {#zig}

### 1. C のライブラリを「そのまま」使える

Wayland・EGL・FreeType・HarfBuzz・fontconfig・libdbus は、どれも C のライブラリです。Zig は C のヘッダを読んで、その型と関数をそのまま Zig から呼べるようにします(`@cImport`)。バインディングを手で書いたり、別の生成ツールを使ったりする必要がありません。

```zig
// src/c.zig — 全ての C ライブラリをここで一度だけ取り込む
// (@cImport を複数箇所に書くと型が別物として扱われ、モジュール間で受け渡せなくなるため)
pub usingnamespace @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/epoll.h");
    @cInclude("sys/timerfd.h");
    …
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    …
});
```

**`@cImport` を 1 か所にまとめている理由**: Zig は `@cImport` を書くたびに別の名前空間を作ります。2 か所で `wl_surface` を取り込むと「同じ C の型なのに Zig では別の型」になり、モジュール間で受け渡すとコンパイルエラーになります。`c.zig` に集めることで、全モジュールが同じ型を共有します。

**translate-c の落とし穴と回避策**(実際にぶつかったもの):

| 問題 | 原因 | 回避策 |
|---|---|---|
| musl の `struct timespec` が不透明型になる | musl のヘッダの書き方を translate-c が解釈できない | timerfd の設定だけ `std.os.linux.itimerspec` を使い、Linux 専用のシステムコールで呼ぶ([FreeBSD では逆にこれが SIGSYS の原因になった](#/tech-loop)) |
| `DBusError` が不透明型になる | ビットフィールドを含む構造体を translate-c が扱えない | 同じレイアウトの `extern struct` を自分で定義(`notify.zig`) |
| musl の `SIG_IGN` マクロが使えない | 関数ポインタへのキャストを含むマクロ | `std.posix.SIG.IGN` を使う(`main.zig`) |
| `ioctl` の第 2 引数の型が libc で違う | musl は `int`、FreeBSD は `unsigned long` | `@typeInfo` で引数の型を調べ、ビット列のまま変換する(`supertap.zig`) |

### 2. メモリの使い方が全部見える

Zig には隠れたメモリ確保がありません。確保する関数は必ずアロケータを引数に取ります。ame-shell は**リリースでは `std.heap.c_allocator`(malloc)、Debug では `GeneralPurposeAllocator`(解放漏れ・二重解放の検出つき)**を使います。

```zig
// src/main.zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = if (@import("builtin").mode == .Debug) gpa.allocator() else std.heap.c_allocator;
```

さらに、多くの部品は**固定長の配列**で状態を持ちます(曲名は `[160]u8`、設定の文字列は `[256]u8` など)。描画のたびの確保をなくし、断片化を防ぐためです。四角形の配列(`std.ArrayList(f32)`)は `clearRetainingCapacity` で使い回すので、定常状態ではフレームごとの確保が 0 です。

### 3. ビルドとクロスコンパイルが 1 つの道具で済む

`zig build` だけで、C のコードのコンパイル、Wayland のプロトコルの生成、Odin のオブジェクトのリンク、WebAssembly のウィジェット、このサイトまで作れます(CMake・Make・Meson を使いません)。詳しくは [ビルド](#/tech-build)。

FreeBSD 向けのバイナリも Linux 上で作れます(`-Dtarget=x86_64-freebsd --sysroot …`)。これで、FreeBSD の実機が無くても、毎回の変更でビルドとリンクが通ることを確かめています。

### 4. 安全検査を切り替えられる

`ReleaseSafe` にすると、範囲外アクセス・整数のオーバーフロー・null の参照を実行時に検出し、スタックトレースを出します。インストーラの `--debug` は `-Doptimize=ReleaseSafe -Dstrip=false` で、FreeBSD での原因の分からない落ち方を調べるのに使いました。

### ほかの言語との比較 {#vs}

| 言語 | 良いところ | ame-shell で採らなかった理由 |
|---|---|---|
| **C** | 依存が最小、どこでも動く | 文字列・配列の境界やエラー処理を全部手で書くことになる。安全検査を切り替えられない |
| **C++** | 資産が多い(Hyprland・KWin) | 規模に対して言語が大きい。ビルドが重い(作者のルールで不使用) |
| **Rust** | メモリ安全、smithay・wayland-rs | C のライブラリ(EGL・FreeType・HarfBuzz・libdbus)をつなぐ層が厚くなる。依存クレートとビルド時間が増える |
| **Go** | 書きやすい | GC の停止がフレームに入りうる。cgo の呼び出しが重い |
| **Qt / QML** | UI を速く作れる(Quickshell・Plasma) | Qt のランタイムだけで数十 MB。描画の細部(ガラスの屈折・SDF の枠)を自分で制御しにくい |
| **GTK** | layer-shell 用のライブラリもある | 同上。ウィジェットの見た目と動きがツールキットに縛られる |

## なぜ Odin か {#odin}

ばね・あいまい検索・主色抽出の 3 つだけを Odin で書いています。

```odin
// anim/anim.odin(冒頭)
// なぜ Odin か: 数値処理を書きやすく、C ABI でそのまま Zig 本体にリンクでき、
// 同じソースを freestanding_wasm32 にもビルドできる(WASMウィジェットと共有するため)。
//
// 制約: ランタイム(アロケータ/コンテキスト)に依存しないよう、全エクスポートは
// `proc "c"` で、スライス・動的配列・libm 関数を使わない。四則演算だけで書くことで
// ネイティブ(musl/glibc)と wasm32 の両方でシンボル未解決なくリンクできる。
```

**得られた結果**: 同じ 192 行が、次の 4 か所で**同じ答え**を出します。

1. ame-shell 本体(x86_64 / aarch64 の Linux と FreeBSD。`-build-mode:obj` で `.o` を作り、Zig がリンク)
2. WebAssembly のウィジェット(`freestanding_wasm32` の `.o` を各ウィジェットにリンク)
3. このサイトのデモ(`freestanding_wasm32` の共有モジュール、2 KB)
4. `zig build test`(純粋なロジックのテスト)

**制約の意味**: Odin の `proc "c"` はコンテキスト(アロケータなど)を持たない呼び出し規約です。動的配列や libm(`sin`・`exp`)を使うと、wasm32 の freestanding では解決できない記号が残ります。そこで**四則演算だけ**で書いています。ばねを解析解ではなく数値積分にしている理由の 1 つがこれです([ばね](#/tech-anim))。

**なぜ全部 Odin にしないか**: Wayland・EGL・FreeType などをつなぐ層は、C との相互運用とビルドの仕組みで Zig のほうが楽だからです。Odin は「数値の核」に限ることで、その利点(書きやすさ・wasm への移植性)だけを使っています。

## なぜ C のライブラリを 3 つ同梱するか {#c}

| ライブラリ | 用途 | 選んだ理由 |
|---|---|---|
| wasm3 | WebAssembly のインタプリタ | 純 C・依存なし。musl でもそのまま `zig build` に入る([詳しく](#/tech-wasm)) |
| stb_image | PNG・JPEG のデコード | ヘッダ 1 つ。libpng・libjpeg に依存しない |
| nanosvg | SVG アイコンのラスタライズ | ヘッダ 1 つ。librsvg(GLib・cairo・Rust を引き込む)を避けられる |

どれも `build.zig` から C のソースとしてコンパイルするので、システムに入っている必要がありません。

## なぜシェルスクリプトは POSIX sh だけか {#sh}

ame-shell は Chimera Linux(chimerautils = FreeBSD 由来のコマンド)と FreeBSD でも動かします。bash や GNU 独自の機能(`sed -i`、`readlink -f`、`date -d`、`find -printf`)を使うと、そこで壊れます。実際に次の違いにぶつかりました。

- BSD の `grep` はバイナリの中を検索しない → `LC_ALL=C tr -c '[:print:]' '\n'` で文字列にしてから探す(libpam の版を調べるとき)
- `tr` はロケールによって動きが変わる → `LC_ALL=C` を付ける
- FreeBSD の `/etc/passwd` から家のディレクトリを取るときは `getent` ではなく `awk -F:` で読む
