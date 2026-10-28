# evdev

::infobox evdev
正式名 | Linux の input イベントのインターフェース
場所 | /dev/input/event*
中身 | struct input_event(時刻・種類・コード・値)
FreeBSD | 同じ形式の evdev がある(ioctl の番号の作り方が違う)
ame-shell | Super キーだけのタップの検出

**evdev** は、キーボードやマウスなどの入力デバイスの出来事を、**そのまま**読めるようにした仕組みです。

## 概要 {#overview}

キーを押すと、`/dev/input/event3` のようなファイルから「この時刻に、キーの番号 125 が押された(値 1)」というデータが読めます。普通のアプリは直接読まず、コンポジタ(とその中の libinput)が読んで、各アプリに配ります。

## ame-shell での使われ方 {#ame}

「Super キーを単独で押して離したらランチャー」を実現するため、ame-shell は evdev を**読むだけ**で使っています。Wayland のアプリは、フォーカスが無いときのキー入力を受け取れず、コンポジタのキーの割り当てでは「Super を離した」ことは分かっても「その間にほかのキーを押したか」が分からないためです([OS 対応](#/tech-platform))。

- デバイスを独占(grab)しないので、ほかのアプリへの入力はそのまま。
- `EVIOCGBIT` の [[ioctl]] で、キーボード(A と Super のキーを持つ)とマウスだけを選ぶ。
- 読むには `input` グループ(FreeBSD では devfs の規則)が必要。

## 関連項目 {#see}

- [[ioctl]] / [[xkb]] / [[inotify]]

## 参考文献 {#refs}

- [Linux Input Subsystem の文書](https://www.kernel.org/doc/html/latest/input/input.html)
