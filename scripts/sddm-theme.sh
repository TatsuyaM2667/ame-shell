#!/bin/sh
# sddm-theme.sh: SDDM(ログイン画面)を ame-shell のテーマ(data/sddm/ame)にする。root で実行。POSIX sh。
# 見た目は Super+L のロック画面と同じ(ぼかした壁紙・光る時計・丸い写真・ガラスの入力欄)。
#
#   doas sh scripts/sddm-theme.sh [--user 名前] [--root DIR] [--manifest FILE] [--no-compositor] [--dry-run]
#     --user          壁紙・写真を使う人(既定: doas / sudo を実行した人)
#     --root          疑似 root に入れる(試験用)
#     --manifest      入れた・書き換えたファイルを FILE に 1 行ずつ足す(install-session.sh の記録用)
#     --no-compositor ログイン画面の下で動くコンポジタを変えない
#     --dry-run       何を書くかを表示するだけ
#
# 行うこと:
#  1. テーマ(Main.qml など)を SDDM のテーマの場所へ。theme.conf には共有の置き場(sharedir)を書く
#  2. 共有の置き場 /var/lib/ame-shell/greeter/<ユーザー>(FreeBSD は /var/db/…)を、その人が書けるように作る。
#     ame-shell がここへ、ロック画面の背景(backdrop.bmp)・写真(avatar.bmp)・アクセント色(state)を書き出し、
#     次のログイン画面からそのまま使われる(root は要らない。src/desktop/sddmshare.zig)
#  3. 壁紙が画像・動画なら、それを background.jpg に(共有の置き場がまだ空のときの背景)
#  4. SDDM の設定を上書きする(/etc/sddm.conf.d/zz-ame.conf。/usr/lib の既定と conf.d の他のファイルより後に読まれる):
#     テーマ = ame、state を読むための QML_XHR_ALLOW_FILE_READ=1、
#     Linux で weston があれば、重い kwin_wayland の代わりに weston --shell=kiosk(キーボード配列も渡す)。
#     /etc/sddm.conf(すべてより優先)に Current= などがあれば、元を .ame-bak に残してその行を無効にする
# 必要なもの: qt6-declarative(SDDM と一緒に入る)、ffmpeg(3 のみ)、weston(4 のコンポジタ、任意)

set -u
info() { printf '    %s\n' "$*"; }

TARGET_USER="${DOAS_USER:-${SUDO_USER:-}}"
ROOT=""
MANIFEST=""
COMPOSITOR=1
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --user) TARGET_USER="$2"; shift 2 ;;
        --root) ROOT="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --no-compositor) COMPOSITOR=0; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done
[ -n "$ROOT" ] || [ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || { echo "root で実行してください: doas sh $0" >&2; exit 1; }

# 書き込み(--dry-run では表示だけ)。記録は ROOT を除いたパスで
put() { # put <内容のファイル> <書き先(ROOT 抜き)> <mode>
    if cmp -s "$1" "$ROOT$2"; then :
    elif [ "$DRY" = 1 ]; then info "(dry-run) 書き込み $2"
    else mkdir -p "$(dirname "$ROOT$2")" && cp "$1" "$ROOT$2.ame-new" && chmod "$3" "$ROOT$2.ame-new" && mv -f "$ROOT$2.ame-new" "$ROOT$2"
    fi
    [ -n "$MANIFEST" ] && [ "$DRY" = 0 ] && echo "$2" >> "$MANIFEST"
    return 0
}

HERE=$(cd "$(dirname "$0")" && pwd)
SRC_THEME="$HERE/../data/sddm/ame"
[ -f "$SRC_THEME/Main.qml" ] || { info "(テーマが見つかりません: $SRC_THEME)"; exit 0; }
if [ "$(uname -s)" = FreeBSD ]; then
    THEMES="/usr/local/share/sddm/themes"
    CONFD="/usr/local/etc/sddm.conf.d"
    MAINCONF="/usr/local/etc/sddm.conf"
    SHARE="/var/db/ame-shell/greeter"
else
    THEMES="/usr/share/sddm/themes"
    CONFD="/etc/sddm.conf.d"
    MAINCONF="/etc/sddm.conf"
    SHARE="/var/lib/ame-shell/greeter"
fi
NAME=ame
DIR="$THEMES/$NAME"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ame-sddm.XXXXXX") || exit 1
trap 'rm -rf "${TMP:?}"' EXIT

# ---- 1. テーマ本体(更新があれば入れ直す。背景は残す)----
put "$SRC_THEME/Main.qml" "$DIR/Main.qml" 644
put "$SRC_THEME/metadata.desktop" "$DIR/metadata.desktop" 644
{ cat "$SRC_THEME/theme.conf"; echo "# ame-shell が書き出す背景・写真・アクセント色の置き場(src/desktop/sddmshare.zig)"; echo "sharedir=$SHARE"; } > "$TMP/theme.conf"
put "$TMP/theme.conf" "$DIR/theme.conf" 644

# ---- 2. 共有の置き場(その人だけが書ける、ログイン画面(sddm ユーザー)が読める)----
UHOME=""
[ -n "$TARGET_USER" ] && UHOME=$(awk -F: -v u="$TARGET_USER" '$1 == u { print $6; exit }' /etc/passwd)
if [ -n "$TARGET_USER" ] && [ -n "$UHOME" ]; then
    if [ "$DRY" = 1 ]; then
        info "(dry-run) 置き場 $SHARE/$TARGET_USER(持ち主 $TARGET_USER、0755)"
    else
        mkdir -p "$ROOT$SHARE/$TARGET_USER"
        chmod 755 "$ROOT$(dirname "$SHARE")" "$ROOT$SHARE" "$ROOT$SHARE/$TARGET_USER"
        [ -n "$ROOT" ] || chown "$TARGET_USER" "$SHARE/$TARGET_USER"
        info "背景・写真の置き場: $SHARE/$TARGET_USER(次に ame-shell が起動・ロックしたときに書き出されます)"
    fi
fi

# ---- 3. 背景: その人の壁紙が画像・動画なら、それを background.jpg に ----
src=""
if [ -n "$UHOME" ]; then
    st="$UHOME/.local/state/ame-shell/wallpaper"
    if [ -f "$st" ]; then
        mode=$(sed -n 1p "$st")
        p=$(sed -n 2p "$st")
        case "$mode" in image|video) [ -f "$p" ] && src="$p" ;; esac
    fi
fi
if [ -z "$src" ]; then
    : # オーロラ・雨: テーマ側でオーロラ風に描く(ame-shell が書き出せばそれを使う)
elif [ "$DRY" = 1 ]; then
    info "(dry-run) 背景 $DIR/background.jpg ← $(basename "$src")"
elif ! command -v ffmpeg >/dev/null 2>&1; then
    info "(ffmpeg が無いため、壁紙から背景は作れません)"
else
    # 前回と同じ壁紙(パス・大きさ・更新時刻)なら作り直さない
    stamp="$src $(ls -l "$src" 2>/dev/null | awk '{print $5, $6, $7, $8}')"
    if [ "$(cat "$ROOT$DIR/.ame-bg-source" 2>/dev/null)" != "$stamp" ] || [ ! -f "$ROOT$DIR/background.jpg" ]; then
        vf="scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080"
        out="$ROOT$DIR/background.new.jpg"
        case "$src" in
            *.[jJ][pP][gG]|*.[jJ][pP][eE][gG]|*.[pP][nN][gG]) set -- -i "$src" ;;
            *) set -- -ss 1 -i "$src" ;; # 動画: 1 秒目のコマ
        esac
        if ffmpeg -nostdin -loglevel error -y "$@" -frames:v 1 -vf "$vf" -q:v 3 "$out" 2>/dev/null ||
            ffmpeg -nostdin -loglevel error -y -i "$src" -frames:v 1 -vf "$vf" -q:v 3 "$out" 2>/dev/null; then
            mv -f "$out" "$ROOT$DIR/background.jpg"
            printf '%s\n' "$stamp" > "$ROOT$DIR/.ame-bg-source"
            info "ログイン画面の背景を $(basename "$src") にしました"
        else
            rm -f "$out"
        fi
    fi
    if [ -f "$ROOT$DIR/background.jpg" ] && [ -n "$MANIFEST" ]; then
        echo "$DIR/background.jpg" >> "$MANIFEST"
        echo "$DIR/.ame-bg-source" >> "$MANIFEST"
    fi
fi
[ "$DRY" = 1 ] || chmod -R a+rX "$ROOT$DIR"

# ---- 4. SDDM の設定を上書き ----
# キーボード配列(weston に渡す。パスワードの記号の位置が変わらないように):
# その人の ~/.config/ame-shell/xkb-layout → X11 の設定 → localectl の X11 Layout
layout=""
[ -n "$UHOME" ] && [ -s "$UHOME/.config/ame-shell/xkb-layout" ] && layout=$(head -n 1 "$UHOME/.config/ame-shell/xkb-layout" | tr -d ' \t\r')
if [ -z "$layout" ]; then
    for f in /etc/X11/xorg.conf.d/*.conf; do
        [ -r "$f" ] || continue
        v=$(awk -F'"' 'tolower($2) == "xkblayout" { print $4; exit }' "$f")
        [ -n "$v" ] && { layout=$v; break; }
    done
fi
[ -z "$layout" ] && command -v localectl >/dev/null 2>&1 && layout=$(localectl status 2>/dev/null | awk -F': *' '/X11 Layout/ { print $2 }' | tr -d ' ')

USE_WESTON=0
if [ "$COMPOSITOR" = 1 ] && [ "$(uname -s)" != FreeBSD ] && command -v weston >/dev/null 2>&1; then
    # キオスクのシェルが無い weston を指定すると、ログイン画面が出なくなる。あるときだけ切り替える
    for d in /usr/lib/weston /usr/lib64/weston /usr/local/lib/weston /usr/lib/x86_64-linux-gnu/weston; do
        [ -f "$d/kiosk-shell.so" ] && { USE_WESTON=1; break; }
    done
    [ "$USE_WESTON" = 1 ] || info "(weston にキオスクのシェル(kiosk-shell.so)が無いため、コンポジタはそのまま)"
fi
if [ "$USE_WESTON" = 1 ]; then
    {
        echo "# ame-shell のログイン画面用の weston の設定(scripts/sddm-theme.sh が作成)"
        echo "[core]"
        echo "idle-time=0"
        echo "[keyboard]"
        [ -n "$layout" ] && echo "keymap_layout=$layout"
        echo "numlock-on=false"
        echo "[shell]"
        echo "cursor-theme=Adwaita"
        echo "cursor-size=24"
    } > "$TMP/weston.ini"
    put "$TMP/weston.ini" "$DIR/weston.ini" 644
fi
{
    echo "# ame-shell の scripts/sddm-theme.sh が作成(ログイン画面をロック画面と同じ見た目に)"
    echo "# /usr/lib/sddm/sddm.conf.d と、このディレクトリの他のファイルより後に読まれるので、それらを上書きする"
    echo "[General]"
    echo "# テーマが ame-shell の書き出した state(アクセント色)を読めるように"
    echo "GreeterEnvironment=QML_XHR_ALLOW_FILE_READ=1"
    [ "$USE_WESTON" = 1 ] && echo "DisplayServer=wayland"
    echo ""
    echo "[Theme]"
    echo "Current=$NAME"
    echo "CursorTheme=Adwaita"
    echo "CursorSize=24"
    if [ "$USE_WESTON" = 1 ]; then
        echo ""
        echo "[Wayland]"
        echo "# 既定の kwin_wayland(重い)の代わりに、画面を 1 つ出すだけの weston のキオスク"
        echo "CompositorCommand=weston --shell=kiosk --config=$DIR/weston.ini"
    fi
} > "$TMP/zz-ame.conf"
put "$TMP/zz-ame.conf" "$CONFD/zz-ame.conf" 644
# 以前の版が作ったファイル(名前が先に読まれて上書きされ得た)は消す
if [ -f "$ROOT$CONFD/ame-theme.conf" ] && grep -q "sddm-theme.sh が作成" "$ROOT$CONFD/ame-theme.conf"; then
    if [ "$DRY" = 1 ]; then info "(dry-run) 削除 $CONFD/ame-theme.conf"; else rm -f "$ROOT$CONFD/ame-theme.conf"; fi
fi
if grep -q '^CompositorCommand=weston' "$TMP/zz-ame.conf"; then
    info "SDDM のコンポジタ: weston --shell=kiosk(キーボード配列: ${layout:-既定})"
else
    [ "$(uname -s)" != FreeBSD ] && [ "$COMPOSITOR" = 1 ] && ! command -v weston >/dev/null 2>&1 &&
        info "(weston が無いため、ログイン画面のコンポジタはそのまま)"
fi

# /etc/sddm.conf は conf.d より後に読まれる: 同じ項目があれば元を .ame-bak に残して、その行を無効にする
if [ -f "$ROOT$MAINCONF" ] && grep -qE '^[[:space:]]*(Current|GreeterEnvironment|CompositorCommand|DisplayServer)[[:space:]]*=' "$ROOT$MAINCONF"; then
    awk -v m="$MAINCONF" '/^[[:space:]]*(Current|GreeterEnvironment|CompositorCommand|DisplayServer)[[:space:]]*=/ { print "# ame-shell が無効化(" m ".ame-bak に元があります): " $0; next } { print }' "$ROOT$MAINCONF" > "$TMP/sddm.conf"
    if [ "$DRY" = 1 ]; then
        info "(dry-run) $MAINCONF の Current= などを無効化(元は $MAINCONF.ame-bak)"
    else
        [ -f "$ROOT$MAINCONF.ame-bak" ] || cp -p "$ROOT$MAINCONF" "$ROOT$MAINCONF.ame-bak"
        cp "$TMP/sddm.conf" "$ROOT$MAINCONF"
        info "$MAINCONF のテーマ・コンポジタの指定を無効にしました(元は $MAINCONF.ame-bak)"
        [ -n "$MANIFEST" ] && echo "$MAINCONF" >> "$MANIFEST"
    fi
fi
info "SDDM のテーマ: $NAME(次のログイン画面から)"
exit 0
