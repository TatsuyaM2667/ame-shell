# XDG_RUNTIME_DIR

::infobox XDG_RUNTIME_DIR
例 | /run/user/1000
作る人 | ログインの仕組み(elogind・systemd-logind・turnstile など)
性質 | 本人だけが読み書きでき(0700)、ログアウトで消える
ame-shell | ソケット・歌詞・窓の状態の置き場所

**XDG_RUNTIME_DIR** は、ログイン中のユーザーのための、一時的なファイルの置き場所を示す環境変数です。

## 概要 {#overview}

Wayland のソケット、D-Bus のソケット、音のサーバのソケットなど、「ログインしている間だけ必要で、本人以外に触られたくない」ものを置く場所です。ログアウトすると消えます。

## ame-shell での使われ方 {#ame}

| 置くもの | 名前 |
|---|---|
| ame-ctl のソケット | `ame-shell-<ディスプレイ>.sock`(0600) |
| 窓の状態(再起動をまたぐ) | `ame-wm-state-<ディスプレイ>` |
| プレーヤーから渡す歌詞 | `lyrics/<プレーヤー名>.lrc` |

**ほかのユーザーが偽物を置けない**ことが大事です。例えば歌詞のファイルを、誰でも書ける `/tmp` に置くと、ほかのユーザーが偽の歌詞を置けてしまいます。この変数が無い環境では、ame-session が本人の持ち物で 0700 のディレクトリを作り、既にあれば持ち主と権限を確かめてから使います([セッション](#/tech-session))。

## 関連項目 {#see}

- [[unix-socket]] / [[wayland]]

## 参考文献 {#refs}

- [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/)
