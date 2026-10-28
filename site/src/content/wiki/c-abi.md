# C ABI

::infobox C ABI
ABI | Application Binary Interface(バイナリの約束事)
決めること | 引数の渡し方(レジスタ・スタック)、構造体の並び、戻り値の返し方
例 | System V AMD64 ABI(Linux・FreeBSD の x86_64)
ame-shell | Zig と Odin の関数のつなぎ方

**C ABI** は、C の関数を呼ぶときの、機械語のレベルでの約束事です。言語が違っても、この約束を守れば、お互いの関数を呼べます。

## 概要 {#overview}

関数を呼ぶとき、1 つ目の引数はどのレジスタに入れるか、構造体の各項目はメモリにどう並ぶか、といった決まりが ABI です。多くの言語(Zig・Odin・Rust・Go の cgo)は、「C の ABI でも関数を出せる/呼べる」ようにしています。異なる言語の間の、共通語になっています。

## ame-shell での使われ方 {#ame}

- Odin の `proc "c"` と、Zig の `extern fn`・`extern struct` で、[[odin|Odin]] のばねの関数を Zig から呼んでいます。`Spring` の構造体は、両方の言語で**同じ並び**になるように書き、ポインタをそのまま渡します(コピーしない)。
- WebAssembly のウィジェットとホストの間も、`extern struct`(C と同じ並び)で、共有のメモリの形を決めています([WebAssembly ウィジェット](#/tech-wasm))。

## 関連項目 {#see}

- [[zig]] / [[odin]] / [[translate-c]]

## 参考文献 {#refs}

- [System V Application Binary Interface, AMD64 Architecture Processor Supplement](https://gitlab.com/x86-psABIs/x86-64-ABI)
