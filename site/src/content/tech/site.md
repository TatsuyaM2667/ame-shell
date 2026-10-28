# このサイトの作り

<p class="file">対象: site/src/main.zig(Zig → wasm32-freestanding)/ site/static/app.js / site/src/content/**/*.md / build.zig の site ステップ / site/deploy.sh</p>

このサイトも、ame-shell と同じ考え方で作っています。**本文を HTML にするのは Zig で書いた WebAssembly**、**デモは ame-shell 本体と同じ Odin のコード**です。JavaScript は、2 つの wasm を読み込んで DOM と Canvas に渡すだけで、ライブラリもフレームワークも使っていません。

| ファイル | 大きさ | 中身 |
|---|---|---|
| `site.wasm` | 約 260 KB | 全ページの本文(Markdown に近い書式)と、それを HTML にするエンジン |
| `anim.wasm` | 約 2 KB | `anim/anim.odin`(ばね・あいまい検索・主色抽出)。ame-shell 本体と同じソース |
| `app.js` | 約 20 KB | 読み込み・ページの切り替え・3 つのデモの Canvas と入力 |

## 本文は wasm の中に埋め込む {#embed}

```zig
// site/src/main.zig
const pages = [_]Page{
    .{ .slug = "", .title = "ホーム", .src = @embedFile("content/home.md") },
    …
    .{ .tech = true, .slug = "tech-anim", .title = "ばねとアニメーションの中核", .src = @embedFile("content/tech/anim.md") },
    …
};
```

各ページの本文は `@embedFile` で**ビルドの時点で wasm の中に入れます**。ページを切り替えるたびにサーバへ取りに行かないので、切り替えは一瞬です。本文の書式を間違えても、それはビルドではなく表示で分かりますが、存在しないファイルを指すとビルドが失敗します(実際にこのページを書く前に、それで気づきました)。

## JavaScript とのやりとり: 2 つのバッファだけ {#abi}

```zig
// ---- JS とのやりとり用のバッファ ----
var in_buf: [256]u8 = undefined;          // JS → wasm(ページの名前)
var out_buf: [1 << 20]u8 = undefined;     // wasm → JS(HTML)
var out_len: usize = 0;

export fn in_ptr() [*]u8 { return &in_buf; }
export fn out_ptr() [*]const u8 { return &out_buf; }
export fn find_page(len: u32) i32 { … }   // in_buf の名前 → ページ番号
export fn render_page(i: u32) u32 { … }   // 本文の HTML を out_buf に書き、長さを返す
export fn render_nav(cur: u32) u32 { … }  // 上のナビゲーション
export fn render_toc(i: u32) u32 { … }    // 横の章の一覧と、このページの目次
export fn page_title(i: u32) u32 { … }
```

```js
// site/static/app.js
const out = (len) => dec.decode(new Uint8Array(S.memory.buffer, S.out_ptr(), len));
main.innerHTML = out(S.render_page(idx));
```

- wasm のメモリに**固定の大きさのバッファを 2 つ**置き、JS はその場所をもらって直接読み書きします。メモリの確保・解放のやりとりが要りません(wasm の中にアロケータすら無い)。
- 文字列は UTF-8 のバイト列のまま受け渡し、JS 側の `TextDecoder` で文字列にします。
- ame-shell の [WebAssembly ウィジェット](#/tech-wasm) と同じ考え方(場所を教えて、コピーせずに読む)です。

## 書式: Markdown の部分集合 + 独自のブロック {#markup}

| 書き方 | 出力 |
|---|---|
| `# ` `## 見出し {#id}` `### ` | 見出し。`##` には目次用の id とアンカー |
| `- ` `1. ` / `> ` / `>! ` | 箇条書き / 補足 / 注意 |
| ` ``` ` | コード(言語名を右上に表示) |
| `\| 表 \|` | 表。セルの先頭の ✓ ✗ △ に色 |
| `::video 名前 \| 説明` | `media/名前.mp4` と、ポスター画像 `media/名前.jpg` |
| `::img ファイル \| 説明` | 画像(クリックで拡大) |
| `::demo spring` / `fuzzy` / `color` | デモの場所 |
| `::stats` / `::cards` | 数字のカード / 機能のカード |
| `<` で始まる行 | HTML をそのまま |
| `**太字**` `` `コード` `` `[文字](URL)` | 行内の書式。http のリンクは新しいタブ |

HTML に出す文字は、すべて `&` `<` `>` `"` をエスケープします。本文に `<` が入っていても、タグとして解釈されません。

### 書いていて見つけた不具合 {#bugs}

- **`defer` は `return` の値を決めた後に動く**: 目次の HTML を `defer raw("</div>")` で閉じたら、長さを返した**後**に閉じタグが書かれ、閉じタグが落ちました。Zig の `defer` は、`return` の式を評価した後に実行されるからです。明示的に書くように直しました。
- **折り返した行が「…」で省略される**: ame-shell 本体の話ですが、歌詞を中央揃えで折り返したとき、折り返し位置の計算(グリフの右端まで)と、描くときの幅の判定(最後のグリフの送り幅まで)がわずかに食い違い、1 行目が省略されました。折り返しで収めた行は省略しないようにしています([文字](#/tech-text))。

## デモ: ame-shell の Odin をそのまま {#demos}

```zig
// build.zig — 同じ anim/anim.odin を、サイト用に共有モジュールの wasm にする
const odin_site = b.addSystemCommand(&.{ "odin", "build" });
odin_site.addDirectoryArg(b.path("anim"));
odin_site.addArgs(&.{ "-target:freestanding_wasm32", "-build-mode:shared", "-no-entry-point", "-o:speed", "-no-bounds-check", "-default-to-nil-allocator" });
const anim_site = odin_site.addPrefixedOutputFileArg("-out:", "anim.wasm");
```

```js
// デモ用の作業領域(3 ページ = 192 KiB)を anim.wasm のメモリの後ろに足す
base = A.memory.grow(3) * 65536;
…
// ばね: ame-shell と同じ関数で dt だけ進める
const sp = new Float32Array(A.memory.buffer, base, 5);   // Spring { x, v, target, response, damping }
A.ame_spring_step(base, dt);
```

- `anim.wasm` は import が 1 つも無く、メモリを外に出しています。JS は `memory.grow` で作業領域を足し、そこに `Spring` の 5 つの数・検索の文字列・画像の画素を書いて、関数を呼びます。
- **ばねのデモ**: クリック(またはドラッグ)で行き先を変えます。同じ時計(`requestAnimationFrame` の時刻)で、ばね(Odin)と、CSS と同じ `cubic-bezier` の曲線を並べて動かし、速度のグラフを描きます。最初はばねとベジェで別々の時計を使ってしまい、ベジェ側が動かない不具合がありました。
- **あいまい検索のデモ**: 入力のたびに、全アプリ名で `ame_fuzzy_score` を呼びます。一致した文字の印は、Odin と同じ「前から貪欲に」の順で JS が付けます。
- **配色のデモ**: 画像を 160×90 に縮めて画素を wasm のメモリに書き、**ガラスの色合い**は `ame_dominant_color`(Odin)で、**アクセント**は `theme.zig` の `vividHue` → `accentHue` → `fromHsl` を JS に移したもので計算します。ame-shell が実際に作る配色と同じ結果になります。選んだ画像はブラウザの外に送りません。

## ページの切り替え {#routing}

- アドレスは `#/ページ名#見出し` の形です。ページ内の目次のリンク(`#見出し`)を押したときは、ページ名を残したまま見出しへ移動します。再読み込みしても同じ場所に戻れます。
- 動画は**見えている間だけ**再生します(`IntersectionObserver`)。画面の外にある動画は止め、最初に見えるまでは読み込みもしません(`preload="none"`)。
- `file://` で開いた場合(`fetch` が使えない)は、`XMLHttpRequest` で wasm を読みます。

## ビルドと公開 {#deploy}

```sh
zig build site          # zig-out/site に index.html・style.css・app.js・site.wasm・anim.wasm・media/
sh site/deploy.sh       # Cloudflare Pages に公開(npx wrangler pages deploy)
```

- **ビルドは `zig build` だけ**。サイト用の Node のツール(バンドラなど)は使いません。
- 公開には Cloudflare の `wrangler` を使います(公開のコマンドとしてだけ使い、サイト自体は Node に依存しません)。
- 動画は、試験用の入れ子の River 0.5 で、D-Bus とホームを分けて録画しました(本物の再生中の曲や、著作権のある壁紙が映らないように、壁紙は ffmpeg で生成)。
- 表示は Chromium のヘッドレスで、デスクトップの幅とスマホの幅のスクリーンショットを撮って確かめています。
