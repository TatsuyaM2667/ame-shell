# timerfd

::infobox timerfd
OS | Linux(2.6.25 以降)、FreeBSD 14 以降(libc)
役割 | タイマーを fd として扱う
主な呼び出し | timerfd_create, timerfd_settime
ame-shell | 時計・OSD・壁紙・キーリピート・WM のアニメーション

**timerfd** は、タイマーを**ファイル記述子(fd)**として扱える仕組みです。決めた時刻になると、その fd が「読める」状態になります。

## 概要 {#overview}

タイマーが fd になると、[[epoll]] で、ほかの fd(画面・ソケット)と**一緒に**待てます。シグナル(`SIGALRM`)でタイマーを受け取る古い方法と違い、処理の途中に割り込まれることがありません。

## 仕組み {#how}

```c
int fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
struct itimerspec t = { .it_value = {1, 0}, .it_interval = {0, 0} };  // 1 秒後に 1 回
timerfd_settime(fd, 0, &t, NULL);
// epoll で読めるようになったら、read(fd, &count, 8) で発火回数を読み捨てる
```

`CLOCK_MONOTONIC` は、時計合わせ(NTP)で時刻が飛んでも、影響を受けない時計です。

## ame-shell での使われ方 {#ame}

ame-shell は、タイマーを「**次に何かが変わる時刻**」にだけ張ります。時計なら次の分の 0 秒、OSD なら 1.4 秒後。決まった間隔で起きて調べることはしません([起動とイベントループ](#/tech-loop))。

## SIGSYS の件 {#sigsys}

FreeBSD 14 以降の libc にも `timerfd_settime` がありますが、ame-shell は以前、Linux 版で Zig の `std.os.linux.timerfd_settime`(Linux の[[syscall|システムコール]]の番号 286 を直接呼ぶ)を使っていました。FreeBSD 向けにもそのままコンパイルされ、FreeBSD には 286 番が無いので、起動直後に [[sigsys|SIGSYS]] で落ちました。今は Linux 以外では libc の関数を呼んでいます。

## 関連項目 {#see}

- [[epoll]] / [[sigsys]] / [[syscall]]

## 参考文献 {#refs}

- `man 2 timerfd_create`
