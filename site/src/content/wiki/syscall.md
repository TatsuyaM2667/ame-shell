# システムコール

::infobox システムコール
英語 | System call
役割 | プログラムが OS のカーネルに仕事を頼む入口
例 | read, write, open, fork, epoll_wait
呼び方 | 普通は libc の関数を通す。番号を直接使うこともできる

**システムコール**は、プログラムが OS の中心(カーネル)に「ファイルを開いて」「メモリをちょうだい」と頼むための入口です。

## 概要 {#overview}

プログラムは、安全のため、ハードウェアやほかのプログラムのメモリに直接触れられません。必要なことはカーネルに頼みます。その頼み方がシステムコールで、各機能には**番号**が付いています。

## 仕組み {#how}

- x86_64 の Linux では、番号をレジスタ `rax` に、引数を `rdi`, `rsi`, … に入れて `syscall` 命令を実行します。
- **番号は OS ごとに違います**。Linux の 286 番は `timerfd_settime` ですが、FreeBSD の 286 番は別のもの(または存在しない)です。
- 普通は libc(glibc・musl・FreeBSD の libc)の関数を呼び、libc が正しい番号で呼びます。

## ame-shell での教訓 {#ame}

Zig の標準ライブラリの `std.os.linux.*` は、libc を通さずに **Linux の番号を直接**使います。これを FreeBSD 向けにもコンパイルしてしまい、起動直後に [[sigsys|SIGSYS]] で落ちました。今は、FreeBSD 向けのバイナリを逆アセンブルして、`syscall` 命令が 0 個であることを毎回確かめています([起動とイベントループ](#/tech-loop))。

## 関連項目 {#see}

- [[sigsys]] / [[timerfd]] / [[ioctl]] / [[musl]]
