# Odin

::infobox Odin
作者 | Ginger Bill(2016〜)
種類 | 汎用のシステムプログラミング言語
特徴 | 数値計算・データ指向の書きやすさ、配列のプログラミング、C ABI
ame-shell | ばね・あいまい検索・主色抽出(192 行)

**Odin** は、C の代わりを目指した言語で、特にゲームや数値計算のような「データを大量に処理する」プログラムを書きやすいように作られています。

## ame-shell での使われ方 {#ame}

ame-shell は、**数値の核の 3 つの関数**だけを Odin で書いています([[spring|ばね]]、[[fuzzy-matching|あいまい検索]]、[[dominant-color|主色抽出]])。

- `proc "c"` で書くと、C の呼び出し規約([[c-abi]])になり、Zig の本体からそのまま呼べます。
- **同じソースを `freestanding_wasm32`(OS の無い WebAssembly)にもビルドできます**。そのため、WebAssembly のウィジェットとこのサイトのデモでも、同じ関数が同じ答えを出します。
- そのための制約として、ランタイム(アロケータ・コンテキスト)・動的配列・libm(`sin` など)を使わず、**四則演算だけ**で書いています([言語とツールチェイン](#/tech-lang))。

## 関連項目 {#see}

- [[zig]] / [[webassembly]] / [[c-abi]]

## 参考文献 {#refs}

- [Odin の概要(公式)](https://odin-lang.org/docs/overview/)
