# クロスコンパイル

::infobox クロスコンパイル
意味 | ある OS・CPU の上で、別の OS・CPU 向けのプログラムを作ること
必要なもの | 対象のライブラリとヘッダ(sysroot)
ame-shell | Linux の上で FreeBSD 向けにビルドして検査

**クロスコンパイル**は、今使っている機械とは違う OS や CPU で動くプログラムを作ることです。

## ame-shell での使われ方 {#ame}

FreeBSD の実機が手元に無くても、毎回の変更で FreeBSD 向けのビルドとリンクが通ることを確かめています。

1. FreeBSD の `base.txz`(libc など)と、必要なパッケージ(wayland・mesa・freetype・libepoll-shim…)を展開して、**sysroot**(FreeBSD の「/」のコピー)を作る。
2. `zig build -Dtarget=x86_64-freebsd --sysroot <sysroot> --libc libc.txt --prefix <別の場所>` でビルドする。
3. できたバイナリを `llvm-objdump` で逆アセンブルし、Linux の直接の[[syscall|システムコール]]が残っていないかを数える([[sigsys]] の再発防止)。

[[zig|Zig]] は、1 つのコンパイラで多くの対象に出力できるので、クロスコンパイラを別に用意する必要がありません([ビルド](#/tech-build))。

## 関連項目 {#see}

- [[zig]] / [[sigsys]] / [[syscall]]
