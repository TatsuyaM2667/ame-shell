# inotify

::infobox inotify
OS | Linux(2.6.13 以降)。FreeBSD では libinotify(kqueue で再現)
役割 | ファイルやディレクトリの変更を通知する
ame-shell | 設定の自動反映、ウィジェットの差し替え、入力デバイスの抜き差し

**inotify** は、ファイルやディレクトリが**変わったときに知らせてくれる**、Linux の仕組みです。

## 概要 {#overview}

「設定ファイルを保存したら、すぐ反映したい」とき、1 秒ごとにファイルの更新時刻を調べる方法もありますが、何もしていなくても毎秒起きてしまいます。inotify に「このディレクトリを見張って」と頼むと、変わったときだけ fd が読めるようになります。

## 仕組み {#how}

```c
int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
inotify_add_watch(fd, "/home/u/.config/ame-shell", IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE);
// 読めるようになったら read() で struct inotify_event の並びを受け取る
```

## ame-shell での使われ方 {#ame}

**ファイルではなくディレクトリを見張る**のがポイントです。Vim などの多くのエディタは、保存するときに「一時ファイルに書いてから名前を変える」ので、ファイル自体を見張っていると、2 回目以降の保存に気づけません。ディレクトリを見張り、`IN_CLOSE_WRITE`(書き終わった)と `IN_MOVED_TO`(名前が変わって現れた)を拾います([設定と ame-ctl](#/tech-config))。

1 つの inotify を、設定・WebAssembly のウィジェット・`/dev/input`(Super キーの検出)で共有しています。

## 関連項目 {#see}

- [[epoll]] / [[kqueue]]

## 参考文献 {#refs}

- `man 7 inotify`
