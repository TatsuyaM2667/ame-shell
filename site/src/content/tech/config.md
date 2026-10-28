# 設定と ame-ctl

<p class="file">対象: src/config.zig(345 行)/ src/ipc.zig(242 行)/ src/ctl.zig(59 行)/ app.zig の inotify</p>

## 設定の言語: 小さな DSL {#dsl}

```zig
// src/config.zig
// 設定 DSL(KDL/TOML 風の小さな言語)のパーサ。
//
//   // コメント(# の後に空白、でも可)
//   theme {
//     accent #7ab8ff
//     radius 18
//   }
//   wallpaper { mode aurora; fps 30 }
//
// 文法: <セクション名> { <キー> <値> (改行 or ;) ... }
// 値: 数値 / 文字列("…") / 裸の単語 / #RRGGBB / true|false
// 未知のキーは警告して無視(古い設定でも起動できるように)。
```

### なぜ JSON / TOML / YAML ではないか {#why}

| 形式 | 問題 |
|---|---|
| JSON | コメントが書けない。手で書くと末尾のカンマや引用符で間違えやすい |
| TOML | 色の `#7ab8ff` がコメントの記号と衝突する(文字列として引用が必要)。セクションの入れ子の書き方が独特 |
| YAML | 字下げの間違いで意味が変わる。仕様が大きく、パーサも大きい |
| **自前の DSL** | ✓ `accent #7ab8ff` のように**引用なしで色が書ける**。コメントは `//` と `# `(# の後に空白)。パーサは 100 行程度 |

**`#` の扱い**: `#` の直後が空白・改行・`#` のときだけコメントにします。`#7ab8ff` は色、`# メモ` はコメントです。

```zig
// コメント: "//" か、"#" の直後が空白/改行/終端
const is_hash_comment = ch == '#' and (self.i + 1 >= self.src.len or self.src[self.i + 1] == ' ' or self.src[self.i + 1] == '\n' or self.src[self.i + 1] == '#');
```

### パーサ: 字句を並べて「キー 値」を適用するだけ {#parse}

```zig
pub fn parse(src: []const u8, base: Config, diag: *Diag) Config {
    var cfg = base;                 // 既定値から始める
    …
    while (true) {
        const t = lx.next();
        switch (t) {
            .word, .string => |w| { … words に積む … },
            .lbrace => { … セクションに入る … },
            .rbrace, .sep, .eof => {
                if (nw >= 2 and depth > 0) {
                    apply(&cfg, section, words[0], words[1], diag, lx.line);
                } else if (nw == 1 and depth > 0) {
                    // 値の無いキー = true(例: "show-seconds")
                    apply(&cfg, section, words[0], "true", diag, lx.line);
                }
                …
            },
        }
    }
    return cfg;
}
```

- **既定値に上書きしていく**: 設定ファイルに書いていない項目は既定値のままです。設定ファイルは「変えたいところだけ」書けば済みます。
- **間違いで止まらない**: 知らないキー・読めない値は、その行だけを無視して、**行番号つきの警告**をログに出します。ame-shell の版を上げて項目の名前が変わっても、古い設定のまま起動できます。
- **値の範囲を丸める**: `radius` は 0〜40、`blur` は 1〜4 など、範囲外の値は範囲に収めます(極端な値で描画が壊れないように)。
- **文字列は固定長**(`Str`: 256 バイト)で持つので、設定を読み直すたびにメモリを確保しません。

## 保存した瞬間に反映: inotify {#inotify}

```zig
// エディタは「別名で書いて rename」することが多いのでディレクトリごと監視する
const dir = std.fs.path.dirname(self.config_path[0..self.config_path_len]) orelse return;
…
self.config_wd = c.inotify_add_watch(self.inotify_fd, dz.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_CREATE);
self.loop.add(self.inotify_fd, c.EPOLLIN, self, onInotify) catch {};
```

- **ファイルではなくディレクトリを監視する理由**: Vim などの多くのエディタは、保存するときに「一時ファイルに書いてから名前を変える」(原子的な置き換え)をします。ファイル自体を監視していると、置き換えの後は**古いファイル**(もう存在しない)を見続けてしまい、2 回目以降の保存に気づけません。ディレクトリを見て、`IN_CLOSE_WRITE`(書き終わった)と `IN_MOVED_TO`(名前が変わって現れた)を拾います。
- 1 つの inotify を、設定・ウィジェットの `.wasm`・`/dev/input`(Super キーの検出)で共有します。
- 読み直したら、前の設定と比べて**変わった部分だけ**を反映します(例: 壁紙の種類が変わったときだけ壁紙を切り替える)。

**ポーリングとの違い**: 「1 秒ごとにファイルの更新時刻を調べる」方式だと、何もしていなくても毎秒起きます。inotify なら、保存されたときだけカーネルが起こしてくれます。

## ame-ctl: Unix ソケットに 1 行 {#ctl}

```zig
// src/ipc.zig
// ame-ctl からの操作を受ける Unix ソケット。
// パス: $XDG_RUNTIME_DIR/ame-shell-$WAYLAND_DISPLAY.sock(ネストしたテスト用インスタンスと衝突しないよう
// Wayland ディスプレイ名を含める)。1行1コマンド、応答も1行(複数行の場合あり)で返して切断する。
const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
…
_ = c.chmod(p.ptr, 0o600);
```

| 判断 | 理由 |
|---|---|
| **Unix ソケット** | 同じ機械の中だけ。ネットワークに開かない |
| **`$XDG_RUNTIME_DIR` + 0600** | 本人以外はソケットに触れない(ほかのユーザーが他人のシェルを操作できない) |
| **ファイル名に `WAYLAND_DISPLAY`** | 試験用の入れ子のセッション(wayland-2)と本物(wayland-1)の ame-shell が、同じソケットを取り合わない |
| **1 接続 = 1 行のコマンド** | 状態を持たないので、クライアントの実装が単純(`echo "volume up" | socat …` でも送れる) |
| **受信に 1 秒のタイムアウト** | 接続して何も送らないクライアントがいても、ame-shell が止まらない |
| **D-Bus を使わない** | D-Bus のインターフェースの定義・登録が要らない。依存が少なく、起動も速い |

```zig
// src/ctl.zig — libc だけに依存する 59 行の CLI
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});
…
_ = c.write(fd, &line_buf, len);
_ = c.shutdown(fd, c.SHUT_WR);    // 書き終わったことを伝えてから、返事を読む
```

ame-ctl は**libc だけ**にリンクする 14 KB のプログラムです。キーの割り当てやスクリプトから頻繁に呼ばれても、起動のコストはほとんどありません。

### キーの割り当ては ame-ctl を経由しない {#same-path}

ame-ctl のコマンドを処理する関数(`ipc.runCommand`)は、River 0.5 のキーの割り当てからも**直接**呼ばれます([ウィンドウマネージャ](#/tech-wm#binds))。外からも中からも同じコマンドの言葉で操作でき、キーを押したときにはプロセスを起動しません。
