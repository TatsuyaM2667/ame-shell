#!/bin/sh
# sddm-theme.sh: SDDM(ログイン画面)を ame-shell のテーマ(data/sddm/ame、ロック画面と同じ見た目)にし、
# 背景をその人の ame-shell の壁紙にする(root で実行)。POSIX sh。
#   doas sh scripts/sddm-theme.sh [--user 名前] [--root DIR]
#     --user  壁紙を使う人(既定: doas / sudo を実行した人)
#     --root  疑似 root に入れる(試験用)
#
# 背景: ~/.local/state/ame-shell/wallpaper(壁紙ピッカーで最後に選んだもの)。動画なら 1 秒目のコマ。
#   オーロラ・雨のときは壁紙のフォルダの最初の 1 枚。何も無ければ背景なし(夜空色の単色)。
#   作り直すのは壁紙が変わったときだけ(install-freebsd.sh と ame-update から毎回呼ばれる)。
# 必要なもの: ffmpeg(背景を作る)、qt6-declarative(SDDM と一緒に入る。ぼかしに QtQuick.Effects を使う)

set -u
info() { printf '    %s\n' "$*"; }

TARGET_USER="${DOAS_USER:-${SUDO_USER:-}}"
ROOT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --user) TARGET_USER="$2"; shift 2 ;;
        --root) ROOT="$2"; shift 2 ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done
[ -n "$ROOT" ] || [ "$(id -u)" = 0 ] || { echo "root で実行してください: doas sh $0" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
SRC_THEME="$HERE/../data/sddm/ame"
[ -f "$SRC_THEME/Main.qml" ] || { info "(テーマが見つかりません: $SRC_THEME)"; exit 0; }
if [ "$(uname -s)" = FreeBSD ]; then
    THEMES="$ROOT/usr/local/share/sddm/themes"
    CONFD="$ROOT/usr/local/etc/sddm.conf.d"
    MAINCONF="$ROOT/usr/local/etc/sddm.conf"
else
    THEMES="$ROOT/usr/share/sddm/themes"
    CONFD="$ROOT/etc/sddm.conf.d"
    MAINCONF="$ROOT/etc/sddm.conf"
fi
NAME=ame
DIR="$THEMES/$NAME"

# ---- テーマ本体(更新があれば入れ直す。背景は残す)----
mkdir -p "$DIR"
for f in Main.qml metadata.desktop theme.conf; do
    cmp -s "$SRC_THEME/$f" "$DIR/$f" || cp "$SRC_THEME/$f" "$DIR/$f"
done

# ---- 背景: その人の ame-shell の壁紙 ----
UHOME=""
[ -n "$TARGET_USER" ] && UHOME=$(awk -F: -v u="$TARGET_USER" '$1 == u { print $6; exit }' /etc/passwd)
src=""
if [ -n "$UHOME" ]; then
    st="$UHOME/.local/state/ame-shell/wallpaper"
    if [ -f "$st" ]; then
        mode=$(sed -n 1p "$st")
        p=$(sed -n 2p "$st")
        case "$mode" in image|video) [ -f "$p" ] && src="$p" ;; esac
    fi
    if [ -z "$src" ]; then
        for d in "$UHOME/Pictures/wallpapers" "$UHOME/Pictures/Wallpapers" "$UHOME/.local/share/ame-shell/wallpapers"; do
            [ -d "$d" ] || continue
            f=$(ls "$d" 2>/dev/null | grep -iE '\.(jpe?g|png|mp4|webm|mkv|mov)$' | head -n 1)
            [ -n "$f" ] && { src="$d/$f"; break; }
        done
    fi
fi

if [ -z "$src" ]; then
    info "(使える壁紙が見つからないため、ログイン画面の背景は単色です)"
elif ! command -v ffmpeg >/dev/null 2>&1; then
    info "(ffmpeg が無いため、ログイン画面の背景は作れません)"
else
    # 前回と同じ壁紙(パス・大きさ・更新時刻)なら作り直さない
    stamp="$src $(ls -l "$src" 2>/dev/null | awk '{print $5, $6, $7, $8}')"
    if [ "$(cat "$DIR/.ame-bg-source" 2>/dev/null)" = "$stamp" ] && [ -f "$DIR/background.jpg" ]; then
        info "ログイン画面の背景は最新です($(basename "$src"))"
    else
        vf="scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080"
        out="$DIR/background.new.jpg"
        case "$src" in
            *.[jJ][pP][gG]|*.[jJ][pP][eE][gG]|*.[pP][nN][gG]) set -- -i "$src" ;;
            *) set -- -ss 1 -i "$src" ;; # 動画: 1 秒目のコマ
        esac
        if ffmpeg -nostdin -loglevel error -y "$@" -frames:v 1 -vf "$vf" -q:v 3 "$out" 2>/dev/null ||
            ffmpeg -nostdin -loglevel error -y -i "$src" -frames:v 1 -vf "$vf" -q:v 3 "$out" 2>/dev/null; then
            mv -f "$out" "$DIR/background.jpg"
            printf '%s\n' "$stamp" > "$DIR/.ame-bg-source"
            info "ログイン画面の背景を $(basename "$src") にしました"
        else
            rm -f "$out"
            info "(背景を作れませんでした)"
        fi
    fi
fi
chmod -R a+rX "$DIR"

# ---- SDDM の設定: このテーマを使う ----
mkdir -p "$CONFD"
conf="$CONFD/ame-theme.conf"
want=$(printf '# ame-shell の scripts/sddm-theme.sh が作成\n[Theme]\nCurrent=%s\n' "$NAME")
[ "$(cat "$conf" 2>/dev/null)" = "$want" ] || printf '%s\n' "$want" > "$conf"
if [ -f "$MAINCONF" ] && awk '/^\[Theme\]/{t=1; next} /^\[/{t=0} t && /^Current=/{f=1} END{exit !f}' "$MAINCONF"; then
    info "注意: $MAINCONF の [Theme] Current= が優先されます。ame を使うにはその行を消してください"
fi
info "SDDM のテーマ: $NAME(次のログイン画面から)"
