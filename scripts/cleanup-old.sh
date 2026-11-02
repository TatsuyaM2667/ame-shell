#!/bin/sh
# cleanup-old.sh: ame-shell が使わなくなったもの(パッケージと、消した KDE / Dolphin などの古い設定)を消す。POSIX sh。
#   sh scripts/cleanup-old.sh            何を消すかを見せて、確認してから消す
#   sh scripts/cleanup-old.sh --dry-run  見せるだけ(何も消さない)
#   sh scripts/cleanup-old.sh --yes      確認せずに消す
# Chimera(apk)・Arch(pacman)・FreeBSD(pkg)に対応。パッケージは入っているものだけ、設定はあるものだけ。
#
# もう使っていないもの:
#   cava        → メディアの波形は ame-shell の中で録音して FFT する
#   playerctl   → 再生中の曲は D-Bus(MPRIS)を直接聞く
#   grim slurp  → スクショは ame-shell が自前で撮る(ext-image-copy-capture。River 0.4 / 0.5 にある)
#   wl-clipboard → スクショのコピーも自前。ほかのアプリ(エディタなど)が使うことがあるので、聞いてから
#   Dolphin・Konsole・Kate など KDE のアプリ → ファイルは Thunar、端末は ghostty / foot

set -u
DRY=0
YES=0
for a in "$@"; do
    case "$a" in
        --dry-run|-n) DRY=1 ;;
        --yes|-y) YES=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "不明なオプション: $a" >&2; exit 2 ;;
    esac
done
say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ask() {
    [ "$YES" = 1 ] && return 0
    [ -t 0 ] || return 1
    printf '    %s [y/N] ' "$1"
    read -r ans || return 1
    case "$ans" in y*|Y*) return 0 ;; *) return 1 ;; esac
}

OS=$(uname -s)
if [ "$OS" = FreeBSD ]; then PM=pkg
elif command -v apk >/dev/null 2>&1; then PM=apk
elif command -v pacman >/dev/null 2>&1; then PM=pacman
else PM=none; fi
if [ "$(id -u)" -eq 0 ]; then SU=""
elif command -v doas >/dev/null 2>&1; then SU=doas
elif command -v sudo >/dev/null 2>&1; then SU=sudo
else SU=none; fi

installed() {
    case "$PM" in
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Qq "$1" >/dev/null 2>&1 ;;
        pkg) pkg info -e "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}
remove() {
    case "$PM" in
        apk) $SU apk del "$@" ;;
        pacman) $SU pacman -Rns --noconfirm "$@" ;;
        pkg) $SU pkg delete -y "$@" ;;
    esac
}

# ---- パッケージ ----
say "使わなくなったパッケージ"
cand="cava playerctl grim slurp"
# KDE のアプリ(ディストリごとの名前。入っているものだけ)
cand="$cand dolphin dolphin-plugins kio-extras konsole kate kwrite okular ark gwenview spectacle kdeconnect kfind"
pk=""
for p in $cand; do installed "$p" && pk="$pk $p"; done
clip=""
installed wl-clipboard && clip="wl-clipboard"
if [ "$PM" = none ]; then
    info "(パッケージの管理が分からないため飛ばします)"
elif [ -z "$pk" ] && [ -z "$clip" ]; then
    info "ありません"
else
    [ -n "$pk" ] && info "消す:$pk"
    [ -n "$clip" ] && info "任意: $clip(ame-shell は使いません。エディタなどがクリップボードに使うことがあります)"
    if [ "$DRY" = 1 ]; then
        info "(--dry-run のため消しません)"
    elif [ "$SU" = none ]; then
        info "root 権限(doas / sudo)が無いため、次を root で実行してください:"
        info "  $PM で削除:$pk $clip"
    else
        # shellcheck disable=SC2086
        if [ -n "$pk" ] && ask "これらのパッケージを消しますか?"; then remove $pk || info "(一部を消せませんでした。ほかのパッケージが使っている可能性があります)"; fi
        if [ -n "$clip" ] && ask "$clip も消しますか?"; then remove $clip || true; fi
    fi
fi

# ---- 古い設定(自分のホームの中) ----
say "使わなくなったアプリの設定・データ(~/.config・~/.local/share)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
# 本体のパッケージが残っていれば、その設定は消さない
keep_if() { installed "$1"; }
list=""
add() { [ -e "$1" ] && list="$list
$1"; }
keep_if cava || add "$CFG/cava"
if ! keep_if dolphin; then
    add "$CFG/dolphinrc"; add "$DATA/dolphin"; add "$DATA/kxmlgui5/dolphin"
fi
keep_if konsole || { add "$CFG/konsolerc"; add "$DATA/konsole"; }
keep_if kate || { add "$CFG/katerc"; add "$DATA/kate"; }
keep_if okular || { add "$CFG/okularrc"; add "$DATA/okular"; }
keep_if kdeconnect || add "$CFG/kdeconnect"
# KDE Plasma(消した後に残るもの)。plasma のパッケージが残っていれば消さない
if ! keep_if plasma-workspace && ! keep_if plasma-desktop; then
    for f in kded5rc kded6rc plasma-welcomerc plasmashellrc plasma-org.kde.plasma.desktop-appletsrc kwinrc kactivitymanagerdrc baloofilerc ksmserverrc kscreenlockerrc powerdevilrc; do add "$CFG/$f"; done
    for d in baloo kactivitymanagerd kwalletd plasmashell plasma; do add "$DATA/$d"; done
fi
if [ -z "$list" ]; then
    info "ありません"
else
    printf '%s\n' "$list" | while IFS= read -r p; do
        [ -n "$p" ] || continue
        sz=$(du -sh "$p" 2>/dev/null | cut -f1)
        info "$p(${sz:-?})"
    done
    if [ "$DRY" = 1 ]; then
        info "(--dry-run のため消しません)"
    elif ask "これらを消しますか?(元に戻せません)"; then
        printf '%s\n' "$list" | while IFS= read -r p; do
            [ -n "$p" ] || continue
            rm -rf -- "$p" && info "消しました: $p"
        done
    else
        info "消しませんでした"
    fi
fi
