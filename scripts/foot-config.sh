#!/bin/sh
# foot-config.sh: ame-shell の foot の設定(data/xdg/foot/foot.ini)を ~/.config/foot/foot.ini に入れる。POSIX sh。
# FreeBSD では install-freebsd.sh と ame-update が、foot を使う本人の権限で呼ぶ(自分の foot.ini より ame-shell の見た目を優先)。
#   元の foot.ini は最初の 1 回だけ foot.ini.ame-bak に残す(元に戻す: mv ~/.config/foot/foot.ini.ame-bak ~/.config/foot/foot.ini)。
#   同じ内容なら何もしない。

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../data/xdg/foot/foot.ini"
[ -f "$SRC" ] || { printf '    (foot の設定が見つかりません: %s)\n' "$SRC"; exit 0; }
DIR="${XDG_CONFIG_HOME:-$HOME/.config}/foot"
DST="$DIR/foot.ini"

if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
    exit 0
fi
mkdir -p "$DIR" || exit 0
if [ -f "$DST" ] && [ ! -e "$DST.ame-bak" ]; then
    cp -p "$DST" "$DST.ame-bak"
    printf '    元の foot.ini を %s に残しました\n' "$DST.ame-bak"
fi
cp "$SRC" "$DST.ame-new" && mv -f "$DST.ame-new" "$DST" && printf '    foot の設定を入れました(%s)\n' "$DST"
exit 0
