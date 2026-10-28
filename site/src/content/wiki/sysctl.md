# sysctl

::infobox sysctl
OS | FreeBSD ほか BSD 系(Linux にも同名の仕組みがある)
形 | 名前の付いたカーネルの値(例: kern.cp_time、hw.acpi.battery.life)
読み方 | sysctl(8) コマンド、sysctlbyname(3) 関数
ame-shell | FreeBSD での CPU・メモリ・電池・温度の取得

**sysctl** は、カーネルが持っている値(CPU の時間・メモリ・電池・温度など)を、名前で読み書きする、BSD の仕組みです。Linux の `/proc` や `/sys` に当たります。

## ame-shell での使われ方 {#ame}

FreeBSD では、次の値を `sysctlbyname(3)` で**直接**読みます。ダッシュボードを開いている間は 1 秒ごとに読むので、`sysctl` コマンドを毎回起動するのは無駄だからです([OS 対応](#/tech-platform))。

| 値 | 名前 |
|---|---|
| CPU の時間 | `kern.cp_time`(user, nice, sys, intr, idle) |
| メモリ | `vm.stats.vm.v_page_count`、`v_free_count`、`v_inactive_count`、`v_laundry_count` |
| 電池 | `hw.acpi.battery.life`、`hw.acpi.battery.state`、`hw.acpi.acline` |
| CPU 温度 | `dev.cpu.0.temperature`(0.1 K 単位) |

## 関連項目 {#see}

- [[kqueue]] / [[syscall]]

## 参考文献 {#refs}

- `man 3 sysctlbyname`(FreeBSD)
