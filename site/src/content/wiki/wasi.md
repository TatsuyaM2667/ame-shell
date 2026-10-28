# WASI

::infobox WASI
正式名 | WebAssembly System Interface
役割 | WebAssembly からファイル・時計・乱数・ネットワークを使うための標準の import
ame-shell | 使わない(コンパイルの時点で外す)

**WASI** は、[[webassembly|WebAssembly]] のプログラムが、OS の機能(ファイル・時計・乱数など)を使うための、標準の関数の集まりです。

## ame-shell での使われ方 {#ame}

ame-shell は WASI を**使いません**。[[wasm3]] をコンパイルするとき、WASI の部分(`d_m3HasWASI` など)を 0 にして、コードそのものを入れていません。

そのため、ウィジェットはファイル・ネットワーク・時計に**原理的に触れられません**。時刻も、ホスト(ame-shell)が共有のメモリ(ストア)に書き込んだ値を読むだけです。外への出口は、`ame.action(番号, 値)` の 1 つ(10 種類の操作)だけです([WebAssembly ウィジェット](#/tech-wasm))。

## 関連項目 {#see}

- [[webassembly]] / [[wasm3]]

## 参考文献 {#refs}

- [WASI(GitHub)](https://github.com/WebAssembly/WASI)
