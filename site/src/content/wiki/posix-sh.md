# POSIX シェル

::infobox POSIX シェル
規格 | POSIX.1(IEEE Std 1003.1)の Shell Command Language
実装 | dash、FreeBSD の sh、busybox ash、bash(POSIX モード)ほか
ame-shell | インストーラ・セッション・補助スクリプトはすべてこれ

**POSIX シェル**は、Unix 系の OS で共通に使えるように規格で決められた、シェルの言語です。bash や zsh の独自の機能は含みません。

## 概要 {#overview}

bash で書いたスクリプトは、bash が無い(または古い)環境では動きません。POSIX の範囲だけで書けば、Linux でも FreeBSD でも、どの `sh` でも動きます。

## ame-shell での使われ方 {#ame}

ame-shell は、Chimera Linux(BSD 系のコマンド)と FreeBSD でも動かすので、スクリプトは POSIX sh だけで書いています。実際にぶつかった違い:

| GNU / bash の書き方 | 問題 | 代わり |
|---|---|---|
| `sed -i` | BSD の sed は書き方が違う | 一時ファイルに書いて置き換える |
| `readlink -f` | BSD に無い | `cd "$(dirname "$0")" && pwd` |
| バイナリの中を `grep` | BSD の grep は検索しない | `LC_ALL=C tr -c '[:print:]' '\n'` で文字列にしてから |
| 配列 | sh に無い | `set --` と位置引数 |

`sh -n` で構文を確かめ、偽のコマンドを PATH の先頭に置いて流れを試しています([セッション](#/tech-session))。

## 関連項目 {#see}

- [[fork-exec]] / [[pipe]]

## 参考文献 {#refs}

- [POSIX.1-2017 Shell Command Language](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html)
