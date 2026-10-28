# SIGSYS

::infobox SIGSYS
番号 | 12(FreeBSD)、31(Linux x86_64)
意味 | 不正なシステムコール(bad system call)
既定の動作 | 終了してコアダンプ
ame-shell | FreeBSD で起動直後に落ちた原因

**SIGSYS** は、プログラムが「その OS に存在しない[[syscall|システムコール]]」を呼んだとき(または seccomp などで禁止されたものを呼んだとき)に送られるシグナルです。

## ame-shell での事例 {#ame}

FreeBSD 15.1 の実機で、ame-shell が起動直後に SIGSYS で落ちました。

1. Linux 版では、[[musl]] の `struct timespec` が [[translate-c]] で扱えなかったため、[[timerfd]] の設定に Zig の `std.os.linux.timerfd_settime` を使っていた。
2. この関数は Linux の番号 286 を**直接**使う。FreeBSD 向けにも同じコードがコンパイルされた。
3. ウィンドウマネージャが最初のアニメーションでタイマーを張った瞬間、FreeBSD に 286 番が無く SIGSYS。

**分かった経緯**: シグナルで落ちたとき、ame-shell のハンドラが ASCII でシグナル名をログに出し、監督スクリプト(`ame-river5-init`)も終了コードからシグナル名を記録していました。そのログに `SIGSYS` とあったことで、原因を絞り込めました。一部のシェルは SIGSYS を古い名前(UNUSED)で返すので、それも吸収しています([セッション](#/tech-session))。

**再発の防止**: FreeBSD 向けのバイナリを `llvm-objdump` で逆アセンブルし、`syscall` 命令と `os.linux.*` の記号が 0 個であることを、ビルドのたびに確かめています([ビルド](#/tech-build))。

## 関連項目 {#see}

- [[syscall]] / [[timerfd]] / [[cross-compilation]]
