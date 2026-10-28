# WebAssembly

::infobox WebAssembly
略称 | Wasm
策定 | W3C(2019 年に勧告)
形 | スタックマシンのバイトコード
特徴 | 移植性、隔離されたメモリ(線形メモリ)、検証可能
ame-shell | ダッシュボードのウィジェット、このサイト

**WebAssembly(Wasm)**は、どの CPU・OS でも同じように動く、小さく速いバイトコードの形式です。もとはブラウザのために作られましたが、今はブラウザの外でも使われています。

## 概要 {#overview}

Wasm のプログラムは、自分専用の「線形メモリ」(1 本のバイト列)の中でしか動けません。外の世界(ファイル・ネットワーク・画面)に触れるには、ホスト(動かす側)が与えた関数(import)を呼ぶしかありません。そのため、**部品を安全に動かす**のに向いています。

## 仕組み {#how}

- 型の付いた命令(`i32.add`、`f32.mul`、`call` …)の並び。実行の前に、型が正しいかを**検証**できます。
- メモリは 64 KiB の「ページ」単位。範囲外のアクセスは**トラップ**(実行の中断)になり、外のメモリは壊れません。
- import(ホストから与える関数)と export(ホストに見せる関数・メモリ)で外とつながります。

## ame-shell での使われ方 {#ame}

- **ウィジェット**: ダッシュボードの時計やカレンダーは、Zig で書いて wasm32 にビルドし、[[wasm3]] で動かしています。外への出口は `ame.action` の 1 つだけ、メモリは 1 MiB 固定、[[wasi|WASI]] は無しです([WebAssembly ウィジェット](#/tech-wasm))。
- **このサイト**: 本文を HTML にする部分が Zig の Wasm、デモが [[odin|Odin]] の Wasm です([このサイトの作り](#/tech-site))。

## 理論と研究 {#theory}

:::research 形式的な意味論
WebAssembly は、言語仕様に**形式的な意味論**(型付け規則と簡約規則)を持つ数少ない実用の言語です。Haas ほか(2017)は、その型システムの健全性(検証を通ったプログラムは、未定義の動作に陥らない)を示し、Watt(2018)は Isabelle で機械的に証明しました。ame-shell のウィジェットが「壊れても、シェルは落ちない」のは、この性質と、ホスト側の境界チェックによります。
:::

## 関連項目 {#see}

- [[wasm3]] / [[wasi]] / [[zig]] / [[odin]]

## 参考文献 {#refs}

- A. Haas et al., "Bringing the Web up to Speed with WebAssembly", PLDI 2017.
- C. Watt, "Mechanising and Verifying the WebAssembly Specification", CPP 2018.
- [WebAssembly Core Specification(W3C)](https://www.w3.org/TR/wasm-core-2/)
