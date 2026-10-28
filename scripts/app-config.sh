#!/bin/sh
# app-config.sh: ame-shell のアプリの設定を ~/.config に入れる(自分の設定より ame-shell の見た目を優先)。POSIX sh。
#   foot:      data/xdg/foot/foot.ini          → ~/.config/foot/foot.ini(半透明・開いたら fastfetch)
#   fastfetch: data/xdg/fastfetch/config.jsonc → ~/.config/fastfetch/config.jsonc(いつもの大きいロゴ)
# FreeBSD では install-freebsd.sh と ame-update が、使う本人の権限で呼ぶ。
#   元のファイルは最初の 1 回だけ <名前>.ame-bak に残す(元に戻す: mv <名前>.ame-bak <名前>)。同じ内容なら何もしない。

HERE=$(cd "$(dirname "$0")" && pwd)
XDG="$HERE/../data/xdg"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"

put() { # put <data/xdg からの相対パス>
    src="$XDG/$1"
    dst="$CONF/$1"
    [ -f "$src" ] || { printf '    (設定が見つかりません: %s)\n' "$src"; return; }
    [ -f "$dst" ] && cmp -s "$src" "$dst" && return
    mkdir -p "$(dirname "$dst")" || return
    if [ -f "$dst" ] && [ ! -e "$dst.ame-bak" ]; then
        cp -p "$dst" "$dst.ame-bak"
        printf '    元の設定を %s に残しました\n' "$dst.ame-bak"
    fi
    cp "$src" "$dst.ame-new" && mv -f "$dst.ame-new" "$dst" && printf '    設定を入れました(%s)\n' "$dst"
}

put foot/foot.ini
put fastfetch/config.jsonc
exit 0
