# musl

::infobox musl
種類 | C の標準ライブラリ(libc)
作者 | Rich Felker(2011〜)
特徴 | 小さい、規格に忠実、静的リンクに向く
使っている OS | Chimera Linux、Alpine Linux、Void Linux(musl 版)
ame-shell | 作者の環境(Chimera Linux)の libc

**musl** は、小さく、規格(POSIX・C)に忠実な、C の標準ライブラリです。多くの Linux は glibc を使いますが、Chimera Linux や Alpine Linux は musl を使います。

## ame-shell での関わり {#ame}

- ame-shell は musl(Chimera)・glibc(Arch)・FreeBSD の libc のどれでも動くように書いています。
- musl のヘッダの書き方が、Zig の [[translate-c]] でうまく扱えないことがあり(`struct timespec`・`struct statvfs`・`SIG_IGN`)、回避策を入れています。
- `ioctl` の第 2 引数の型が、musl は `int`、FreeBSD は `unsigned long` と違うため、コンパイル時に型を調べて合わせています([[ioctl]])。
- 作者の Rust のアプリ(music-tui)は、musl では既定で完全な静的リンクになり、ALSA が PipeWire のプラグインを読み込めず音が出ませんでした。動的リンクにして直しています。

## 関連項目 {#see}

- [[translate-c]] / [[ioctl]] / [[pipewire]]

## 参考文献 {#refs}

- [musl libc](https://musl.libc.org/)
