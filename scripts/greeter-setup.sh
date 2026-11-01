#!/bin/sh
# greeter-setup.sh: ログイン画面を ame-shell(greetd + ame-greeter)にする。root で実行。POSIX sh。
# SDDM は使わなくなる(消してもよい)。見た目と動きはロック画面と同じ(src/greeter.zig)。
#
#   doas sh scripts/greeter-setup.sh [--user 名前] [--prefix DIR] [--manifest FILE] [--dry-run]
#   doas sh scripts/greeter-setup.sh --undo      SDDM に戻す(config.toml を元に戻し、サービスを入れ替える)
#     --user     写真・壁紙の置き場を作る人(既定: doas / sudo を実行した人)
#     --prefix   ame-shell を入れた場所(既定: /usr/local)
#     --manifest 書いたファイルを FILE に足す(install-session.sh の記録用)
#
# 行うこと:
#  1. /etc/greetd/config.toml: greeter を $PREFIX/bin/ame-greeter に(元のファイルは .ame-bak に残す)
#  2. 置き場 /var/lib/ame-shell/greeter/<ユーザー>(その人が書け、誰でも読める): ame-shell が写真・壁紙を書き出す
#     と、キーボード配列(xkb-layout)
#  3. サービス: sddm をやめて greetd を有効に(次の起動から。dinit は boot.d のリンク、systemd は enable / disable)
# 動かなかったときは TTY(Ctrl+Alt+F2)でログインして: doas sh scripts/greeter-setup.sh --undo

set -u
info() { printf '    %s\n' "$*"; }

TARGET_USER="${DOAS_USER:-${SUDO_USER:-}}"
PREFIX=/usr/local
MANIFEST=""
DRY=0
UNDO=0
while [ $# -gt 0 ]; do
    case "$1" in
        --user) TARGET_USER="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --undo) UNDO=1; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || { echo "root で実行してください: doas sh $0" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then info "(dry-run) $*"; else "$@"; fi; }

if [ "$(uname -s)" = FreeBSD ]; then
    CONF=/usr/local/etc/greetd/config.toml
    SHARE=/var/db/ame-shell/greeter
else
    CONF=/etc/greetd/config.toml
    SHARE=/var/lib/ame-shell/greeter
fi

# ---- サービスの入れ替え(dinit / systemd / FreeBSD の rc)----
# switch_dm <有効にする> <やめる>
switch_dm() {
    on=$1; off=$2
    if command -v dinitctl >/dev/null 2>&1 && [ -d /etc/dinit.d ]; then
        # 次の起動から(dinitctl enable はすぐに起動して、今の画面が切り替わってしまう)
        if [ ! -e "/etc/dinit.d/boot.d/$on" ]; then
            f="/usr/lib/dinit.d/$on"
            [ -f "/etc/dinit.d/$on" ] && f="/etc/dinit.d/$on"
            if [ -f "$f" ]; then
                run mkdir -p /etc/dinit.d/boot.d
                run ln -s "$f" "/etc/dinit.d/boot.d/$on"
                info "$on: 次の起動から有効"
            else
                info "($on の dinit のサービスがありません。パッケージ ${on}-dinit を入れてください)"
                return 1
            fi
        fi
        # 有効にできたときだけ、もう一方をやめる(どちらも無い状態にしない)
        if [ -e "/etc/dinit.d/boot.d/$off" ]; then run rm -f "/etc/dinit.d/boot.d/$off"; info "$off: 次の起動から使いません"; fi
    elif command -v systemctl >/dev/null 2>&1; then
        run systemctl disable "$off.service" >/dev/null 2>&1
        run systemctl enable "$on.service" >/dev/null 2>&1 && info "$on: 次の起動から有効($off は無効)"
    elif [ "$(uname -s)" = FreeBSD ]; then
        run sysrc "${off}_enable=NO" >/dev/null
        run sysrc "${on}_enable=YES" >/dev/null && info "$on: 次の起動から有効($off は無効)"
    else
        info "(サービスの管理方法が分からないため、$on の有効化と $off の無効化は手動で行ってください)"
    fi
    return 0
}

if [ "$UNDO" = 1 ]; then
    if [ -f "$CONF.ame-bak" ]; then
        run mv -f "$CONF.ame-bak" "$CONF"
        info "$CONF を元に戻しました"
    fi
    if command -v sddm >/dev/null 2>&1; then
        switch_dm sddm greetd
    else
        info "(sddm が入っていません。ログインは TTY から: ログインして ame-session --river5)"
        if command -v dinitctl >/dev/null 2>&1 && [ -e /etc/dinit.d/boot.d/greetd ]; then run rm -f /etc/dinit.d/boot.d/greetd; fi
    fi
    info "次の起動から元のログイン画面に戻ります"
    exit 0
fi

command -v greetd >/dev/null 2>&1 || [ "$DRY" = 1 ] || { echo "greetd がありません(Chimera: doas apk add greetd greetd-dinit / Arch: pacman -S greetd)" >&2; exit 1; }
GREETER="$PREFIX/bin/ame-greeter"
[ -x "$GREETER" ] || [ "$DRY" = 1 ] || { echo "$GREETER がありません(先に session/install-session.sh で ame-shell を入れてください)" >&2; exit 1; }

# greeter を動かすユーザー: 今の config.toml の user(Chimera: _greetd / Arch: greeter)
GUSER=""
[ -f "$CONF" ] && GUSER=$(awk -F'"' '/^[[:space:]]*user[[:space:]]*=/ { print $2; exit }' "$CONF")
if [ -z "$GUSER" ] || [ "$GUSER" = root ]; then
    for u in _greetd greeter greetd; do
        if awk -F: -v u="$u" '$1 == u { f = 1 } END { exit !f }' /etc/passwd; then GUSER=$u; break; fi
    done
fi
[ -n "$GUSER" ] || GUSER=_greetd

# greeter のユーザーが画面(DRM)と入力を使えるように(logind が無い・seatd の環境や Arch で要ることがある)
for g in video input _seatd; do
    getent group "$g" >/dev/null 2>&1 || continue
    id -Gn "$GUSER" 2>/dev/null | tr " " "\n" | grep -qx "$g" && continue
    if [ "$(uname -s)" = FreeBSD ]; then run pw groupmod "$g" -m "$GUSER"
    else run usermod -aG "$g" "$GUSER"; fi
    info "$GUSER を $g グループに追加"
done

# ---- 1. config.toml ----
TMP=$(mktemp "${TMPDIR:-/tmp}/ame-greetd.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
# ame-shell の scripts/greeter-setup.sh が作成(元のファイルは $CONF.ame-bak)
# ログイン画面は ame-shell(ロック画面と同じ見た目)。元に戻す: doas sh scripts/greeter-setup.sh --undo
[terminal]
vt = 7

[default_session]
command = "$GREETER"
user = "$GUSER"
EOF
if cmp -s "$TMP" "$CONF"; then
    info "$CONF は設定済み"
elif [ "$DRY" = 1 ]; then
    info "(dry-run) $CONF を書き換え(greeter: $GREETER、ユーザー: $GUSER)"
else
    mkdir -p "$(dirname "$CONF")"
    [ -f "$CONF" ] && [ ! -f "$CONF.ame-bak" ] && cp -p "$CONF" "$CONF.ame-bak"
    cp "$TMP" "$CONF" && chmod 644 "$CONF"
    info "$CONF: greeter を ame-greeter に(ユーザー $GUSER)"
fi
[ -n "$MANIFEST" ] && [ "$DRY" = 0 ] && echo "$CONF" >> "$MANIFEST"

# ---- 2. 置き場とキーボード配列 ----
UHOME=""
[ -n "$TARGET_USER" ] && UHOME=$(awk -F: -v u="$TARGET_USER" '$1 == u { print $6; exit }' /etc/passwd)
run mkdir -p "$SHARE"
run chmod 755 "$(dirname "$SHARE")" "$SHARE"
if [ -n "$UHOME" ]; then
    run mkdir -p "$SHARE/$TARGET_USER"
    run chown "$TARGET_USER" "$SHARE/$TARGET_USER"
    run chmod 755 "$SHARE/$TARGET_USER"
    info "写真・壁紙の置き場: $SHARE/$TARGET_USER(ame-shell が次に起動・ロックしたときに書き出します)"
fi
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
if [ -n "$layout" ]; then
    if [ "$DRY" = 1 ]; then info "(dry-run) キーボード配列 $layout → $SHARE/xkb-layout"; else echo "$layout" > "$SHARE/xkb-layout" && chmod 644 "$SHARE/xkb-layout"; fi
    [ -n "$MANIFEST" ] && [ "$DRY" = 0 ] && echo "$SHARE/xkb-layout" >> "$MANIFEST"
fi

# ---- 3. サービス ----
if switch_dm greetd sddm; then
    info "ログイン画面: ame-shell(次の起動から)。動かないときは TTY(Ctrl+Alt+F2)で: doas sh $0 --undo"
else
    info "greetd を有効にできなかったため、ログイン画面は今のまま(SDDM など)です"
fi
exit 0
