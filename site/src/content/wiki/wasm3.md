# wasm3

::infobox wasm3
作者 | Volodymyr Shymanskyy、Steven Massey
種類 | WebAssembly のインタプリタ(C)
特徴 | 依存なし、小さい、マイコンでも動く、速いインタプリタ
ame-shell | ウィジェットの実行

**wasm3** は、C で書かれた、小さくて速い [[webassembly|WebAssembly]] のインタプリタです。

## ame-shell での使われ方 {#ame}

| ランタイム | 判断 |
|---|---|
| **wasm3** | ✓ 純 C・依存なし。`zig build` に C のソースとして入る |
| WAMR | JIT / AOT で速いが、ビルドの構成が大きく CMake が前提 |
| wasmtime | 高機能だが Rust で書かれていて大きい |

ウィジェットは 1 フレームに描画命令を数十個作るだけなので、インタプリタで十分速いです。[[wasi|WASI]] はコンパイルの時点で外しています([WebAssembly ウィジェット](#/tech-wasm))。

## 理論と研究 {#theory}

:::research Massey Meta Machine
wasm3 の速さの秘密は「M3(Massey Meta Machine)」という設計です。Wasm のバイトコードを、読み込み時に「次に呼ぶ関数のポインタ」の並び(threaded code)に変換し、各命令を末尾呼び出しでつないで実行します。スタックの値の一部をレジスタに置いたまま命令をつなぐので、普通の `switch` 型のインタプリタより分岐の予測が当たりやすく、速くなります。関数は**初めて呼ばれたときに**この形式に変換されるので、ame-shell は起動後のアイドル時間にウィジェットを 1 回動かしておきます。
:::

## 関連項目 {#see}

- [[webassembly]] / [[wasi]]

## 参考文献 {#refs}

- [wasm3(GitHub)と、その設計の文書(docs/Interpreter.md)](https://github.com/wasm3/wasm3)
