# MPRIS

::infobox MPRIS
正式名 | Media Player Remote Interfacing Specification
版 | 2.2
仕組み | D-Bus のインターフェース(org.mpris.MediaPlayer2.*)
ame-shell | 再生中の曲・アルバムアート・再生位置・操作(playerctl 経由)

**MPRIS** は、音楽や動画のプレーヤーを、外から**同じ方法で**見たり操作したりするための、[[dbus|D-Bus]] の約束事です。

## 概要 {#overview}

Spotify でも Firefox でも mpv でも、MPRIS に対応していれば、「今の曲は?」「一時停止して」を同じ方法で頼めます。デスクトップのメディアの表示や、キーボードのメディアキーは、これで動いています。

## 仕組み {#how}

- プレーヤーは `org.mpris.MediaPlayer2.<名前>` という名前を D-Bus に登録する。
- `Metadata`(`xesam:title`・`xesam:artist`・`xesam:album`・`mpris:artUrl`・`mpris:length` など)、`PlaybackStatus`、`Position` などのプロパティ。
- `Play`・`Pause`・`PlayPause`・`Next`・`SetPosition` などのメソッド。

## ame-shell での使われ方 {#ame}

ame-shell は D-Bus を直接話さず、**playerctl** の `--follow` を常駐させ、変化があったときに出る 1 行(タブ区切りの 8 項目)を読みます。プレーヤーの出現・消滅の追跡や、複数のプレーヤーの選択を playerctl に任せられるからです。`--follow` はシーク(再生位置のジャンプ)を知らせないので、歌詞を表示している間だけ、3 秒ごとに位置を聞き直します([メディア](#/tech-media))。

>! `Play` は「止まっていたら再生」、`Pause` は「鳴っていたら一時停止」です。作者の音楽プレーヤー(music-tui)は、どれも「反転」として扱っていたため、再生中に `Play` が届くと止まってしまう不具合がありました。

## 関連項目 {#see}

- [[dbus]] / [[lrc]]

## 参考文献 {#refs}

- [MPRIS D-Bus Interface Specification 2.2](https://specifications.freedesktop.org/mpris-spec/latest/)
