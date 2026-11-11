# PSI(Pressure Stall Information)

::infobox PSI
OS | Linux(4.20 以降)
場所 | /proc/pressure/{cpu,memory,io}
指標 | some(1 つでも待った時間の割合)/ full(全部が待った時間の割合)
見張り | ファイルに条件を書いて poll(EPOLLPRI)
ame-shell | メモリの見張り(src/desktop/memguard.zig)

**PSI**(Pressure Stall Information)は、CPU・メモリ・ディスクが足りないせいで、プロセスがどれだけ待たされたかを表す Linux の仕組みです。

## 概要 {#overview}

`/proc/pressure/memory` を読むと、例えば次のように出ます。

```text
some avg10=0.00 avg60=0.00 avg300=0.00 total=69683514
full avg10=0.00 avg60=0.00 avg300=0.00 total=68502506
```

`some` は「メモリ待ちで止まったタスクが 1 つでもあった時間」の割合、`full` は「動けるタスクが全部止まっていた時間」の割合です。空きメモリの量(`MemAvailable`)と違い、**実際に待たされているか**が分かります。

## 見張り(トリガ) {#trigger}

ファイルを開いて条件を書き込み、[[epoll]] で `EPOLLPRI` を待つと、条件を満たしたときだけ起こしてもらえます。定期的に読む(ポーリング)必要がありません。

```c
int fd = open("/proc/pressure/memory", O_RDWR | O_NONBLOCK);
write(fd, "some 300000 2000000", 20);   // 2 秒のうち 0.3 秒以上待ったら
// epoll に EPOLLPRI で登録
```

一般ユーザーが使える窓の長さは 2 秒の倍数に限られます。

## ame-shell での使われ方 {#ame}

ame-shell は、この知らせが来たときだけ空きメモリを見て、少なければ通知し、尽きる直前にはいちばんメモリを使っているプロセスを止めます([メモリ](#/tech-memory))。

## 関連項目 {#see}

- [[epoll]]
- [[zram]]
