# ioctl

::infobox ioctl
種類 | システムコール
形 | ioctl(fd, request, 引数)
役割 | デバイスごとの特別な操作(読み書き以外)
ame-shell | evdev の能力を調べる(EVIOCGBIT)

**ioctl** は、デバイスのファイルに対して、普通の読み書き以外の「**特別な操作**」を頼むための[[syscall|システムコール]]です。

## 概要 {#overview}

`read` と `write` だけでは、「このキーボードにはどのキーがある?」「画面の大きさは?」といった質問ができません。ioctl は、デバイスごとに決められた番号(request)で、こうした操作を頼みます。

## 仕組み {#how}

request の番号は、「向き(読む・書く)」「種類の文字」「番号」「引数の大きさ」を詰めた 32 ビットの値です。Linux では `_IOC(向き, 種類, 番号, 大きさ)` マクロで作ります。

## ame-shell での使われ方 {#ame}

[[evdev]] の `EVIOCGBIT(EV_KEY, len)` で、デバイスが持つキーの一覧を読みます。

```zig
// ioctl 番号の作り方は OS で違う(Linux の _IOC_READ は 2<<30、FreeBSD の IOC_OUT は 1<<30)
const dir: u32 = if (@import("builtin").os.tag == .freebsd) 1 << 30 else 2 << 30;
return dir | ((len & 0x1fff) << 16) | ('E' << 8) | (0x20 + 1);
```

さらに、`ioctl` の第 2 引数の**型**が、musl では `int`、FreeBSD では `unsigned long` です。ame-shell は [[zig|Zig]] の `@typeInfo` でコンパイル時に型を調べ、同じビット列のまま変換しています([OS 対応](#/tech-platform))。

## 関連項目 {#see}

- [[evdev]] / [[syscall]] / [[musl]]
