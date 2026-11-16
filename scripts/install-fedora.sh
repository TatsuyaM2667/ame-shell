#!/bin/sh
# install-fedora.sh: Fedora(と Fedora 系)に ame-shell を入れる。POSIX sh。
#   sh install.sh が Fedora を見つけると自動でこれを呼ぶ。直接: sh scripts/install-fedora.sh [--user] [--yes] [--debug]
#
#   1. dnf で依存パッケージ(Fedora の公式リポジトリだけ。River 0.5 も公式にある)
#      Odin は Fedora に無いので、install.sh がソースからビルドする(clang と llvm-devel を使う)
#   2. サービス: NetworkManager・bluetooth を有効に
#   3. install.sh --no-deps でビルドとインストール(Zig 0.13 は公式の配布物を ~/.cache に)
# パッケージ名は Fedora 44 のリポジトリで確認済み(2026-11)。

set -eu
case "$0" in */*) HERE=$(cd "$(dirname "$0")" && pwd) ;; *) HERE=$(pwd)/scripts ;; esac
REPO=$(cd "$HERE/.." && pwd)
say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

FWD=""
USER_MODE=0
for a in "$@"; do
    case "$a" in
        --user) USER_MODE=1; FWD="$FWD --user" ;;
        --yes|-y|--debug|--no-river|--mozc|--cleanup|--no-apps) FWD="$FWD $a" ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) die "不明なオプション: $a" ;;
    esac
done
command -v dnf >/dev/null 2>&1 || die "dnf がありません(Fedora 系ではないようです)。sh install.sh を使ってください"

if [ "$(id -u)" -eq 0 ]; then SU=""
elif command -v sudo >/dev/null 2>&1; then SU=sudo
elif command -v doas >/dev/null 2>&1; then SU=doas
else SU=none; fi
as_root() { case "$SU" in "") "$@" ;; none) return 1 ;; *) $SU "$@" ;; esac; }

# ビルドに必要なもの(wayland-devel に wayland-scanner、libglvnd-devel に EGL / GLESv2、llvm-devel に llvm-config)
BUILD="git-core curl bash gcc clang llvm-devel pkgconf-pkg-config wayland-devel wayland-protocols-devel libglvnd-devel
 mesa-libEGL-devel libdrm-devel libxkbcommon-devel freetype-devel harfbuzz-devel fontconfig-devel dbus-devel pam-devel openssl-devel"
# River 0.5(ame-shell がウィンドウマネージャを兼ねるセッション)
RIVER="river xorg-x11-server-Xwayland"
# 動かすのに必要なもの(pulseaudio-libs: 音の道具 ame-uzume・ame-hamon / mpv-libs: 動画の壁紙 / ffmpeg-free: 録画 /
#  SDL3: 端末 kuraokami / bsdtar: ame-filemanager の圧縮ファイル / dbus-daemon: dbus-run-session)
RUN="greetd foot polkit upower pipewire pipewire-pulseaudio wireplumber pulseaudio-libs mpv-libs ffmpeg-free dbus-daemon
 NetworkManager bluez util-linux xdg-utils SDL3 bsdtar
 xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk
 google-noto-sans-cjk-fonts jetbrains-mono-fonts hicolor-icon-theme adwaita-icon-theme
 fastfetch wlr-randr zsh zsh-autosuggestions zsh-syntax-highlighting fzf zoxide eza bat"
# 電源のモード: Fedora Workstation は tuned-ppd(同じ D-Bus の窓口)が入っていて power-profiles-daemon とぶつかる
rpm -q tuned-ppd >/dev/null 2>&1 || RUN="$RUN power-profiles-daemon"
RUN_CMDS="foot zsh greetd dbus-run-session rfkill nmcli bluetoothctl"
JA="fcitx5 fcitx5-mozc fcitx5-gtk fcitx5-qt5 fcitx5-configtool"

say "1/3 パッケージ(dnf)"
want="$BUILD $RIVER $RUN"
case "${LANG:-}" in ja_*) want="$want $JA" ;; esac
missing=""
for p in $want; do rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"; done
if [ -z "$missing" ]; then
    info "すべて導入済み"
elif [ "$SU" = none ]; then
    info "root 権限(sudo / doas)が無いため、次のパッケージを入れてから再実行してください:"
    info "  dnf install$missing"
    die "パッケージが足りません"
else
    info "インストール:$missing"
    # shellcheck disable=SC2086
    if ! as_root dnf install -y $missing; then
        info "まとめて入れられなかったため、1 つずつ入れます"
        for p in $missing; do as_root dnf install -y "$p" || info "  (飛ばしました: $p)"; done
    fi
fi
for c in git clang llvm-config wayland-scanner pkg-config; do
    command -v "$c" >/dev/null 2>&1 || die "$c が見つかりません(dnf install で入れてください)"
done
lack=""
for c in $RUN_CMDS; do command -v "$c" >/dev/null 2>&1 || lack="$lack $c"; done
[ -n "$lack" ] && die "次のコマンドが見つかりません(dnf install で入れてから再実行してください):$lack"
info "river: $(river -version 2>&1 || echo なし)"

say "2/3 サービス"
if [ "$USER_MODE" = 1 ] || [ "$SU" = none ]; then
    info "(自分用のインストールのため、サービスは変更しません)"
elif command -v systemctl >/dev/null 2>&1; then
    for s in NetworkManager bluetooth; do
        systemctl is-enabled "$s.service" >/dev/null 2>&1 || { as_root systemctl enable "$s.service" >/dev/null 2>&1 && info "$s を有効にしました"; }
    done
fi

say "3/3 ame-shell のビルドとインストール"
# shellcheck disable=SC2086
AME_FROM_DISTRO=1 exec sh "$REPO/install.sh" --no-deps $FWD
