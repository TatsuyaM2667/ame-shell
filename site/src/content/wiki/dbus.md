# D-Bus

::infobox D-Bus
種類 | プロセス間のメッセージバス
バス | セッションバス(ユーザーごと)、システムバス(機械全体)
ライブラリ | libdbus、GDBus(GLib)、sd-bus(systemd)
ame-shell | 通知のサーバ、電源操作(FreeBSD の ConsoleKit2)、MPRIS(playerctl 経由)

**D-Bus** は、デスクトップのアプリ同士が、名前でメッセージを送り合うための仕組みです。

## 概要 {#overview}

「通知を出して」「音楽を一時停止して」「再起動して」といった頼みごとを、相手のプログラムの名前(例: `org.freedesktop.Notifications`)に送ります。間に「バス」というプログラムが入って、メッセージを届けます。

## 仕組み {#how}

- 各プログラムは、バスに名前を登録できる(`RequestName`)。
- **メソッドの呼び出し**(返事がある)と、**シグナル**(一斉に知らせる)の 2 種類のメッセージ。
- オブジェクトのパス(`/org/freedesktop/Notifications`)とインターフェースで、どの機能かを指定する。

## ame-shell での使われ方 {#ame}

ame-shell は、通知のサーバ(`org.freedesktop.Notifications`)を自分で持ちます。

- **libdbus の private 接続**を使い、その fd を [[epoll]] に入れます。D-Bus 用のスレッドは要りません。
- すでに別の通知のプログラム(mako など)が名前を持っていれば、奪わずに譲ります(`DO_NOT_QUEUE`)。
- GDBus(GLib のループが前提)や sd-bus(systemd の一部で、Chimera と FreeBSD には無い)は使いません([通知](#/tech-notify-lock))。

## 関連項目 {#see}

- [[mpris]] / [[unix-socket]] / [[epoll]]

## 参考文献 {#refs}

- [D-Bus の仕様](https://dbus.freedesktop.org/doc/dbus-specification.html)
- [Desktop Notifications の仕様](https://specifications.freedesktop.org/notification-spec/latest/)
