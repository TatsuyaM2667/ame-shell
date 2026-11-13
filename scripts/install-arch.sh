#!/bin/sh
# install-arch.sh: Arch Linux(と Arch 系: EndeavourOS / Manjaro など)に ame-shell を入れる。POSIX sh。
#   sh install.sh が Arch を見つけると自動でこれを呼ぶ。直接: sh scripts/install-arch.sh [--user] [--yes] [--debug]
#
#   1. pacman で依存パッケージ(公式リポジトリだけ。AUR は使わない)
#      River 0.5・Odin・wlroots 0.20 も公式にあるので、ソースからのビルドは ame-shell 本体と Zig 0.13 の取得だけ
#   2. サービス: NetworkManager・bluetooth を有効に(ログイン画面は install-session.sh の設定で ame-shell(greetd)に)
#   3. install.sh --no-deps でビルドとインストール(Zig 0.13 は公式の配布物を ~/.cache に。Arch の zig は新しすぎるため)
# パッケージ名は Arch の core / extra のデータベースで確認済み(2026-10)。

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
        --yes|-y|--debug|--no-river|--mozc|--cleanup) FWD="$FWD $a" ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) die "不明なオプション: $a" ;;
    esac
done
command -v pacman >/dev/null 2>&1 || die "pacman がありません(Arch 系ではないようです)。sh install.sh を使ってください"

if [ "$(id -u)" -eq 0 ]; then SU=""
elif command -v sudo >/dev/null 2>&1; then SU=sudo
elif command -v doas >/dev/null 2>&1; then SU=doas
else SU=none; fi
as_root() { case "$SU" in "") "$@" ;; none) return 1 ;; *) $SU "$@" ;; esac; }

# ビルドに必要なもの(wayland に wayland-scanner、llvm に llvm-config が入っている)
BUILD="git curl bash base-devel clang llvm pkgconf wayland wayland-protocols mesa libglvnd libxkbcommon freetype2 harfbuzz fontconfig dbus odin"
# River 0.5(ame-shell がウィンドウマネージャを兼ねるセッション)
RIVER="river xorg-xwayland"
# 動かすのに必要なもの・あると使うもの
# (pipewire-audio: Bluetooth のイヤホン・スピーカー(bluez5 のプラグイン)/ libpulse: pactl /
#  ttf-nerd-fonts-symbols: バーのアイコン / hicolor・adwaita: アプリのアイコン)
RUN="greetd foot polkit upower power-profiles-daemon pipewire pipewire-audio pipewire-pulse wireplumber libpulse mpv ffmpeg swaylock
 networkmanager bluez bluez-utils util-linux thunar tumbler gvfs xdg-utils
 xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk
 noto-fonts-cjk ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols hicolor-icon-theme adwaita-icon-theme
 fastfetch wlr-randr
 ghostty zsh zsh-autosuggestions zsh-syntax-highlighting fzf zoxide eza bat
 libva-mesa-driver"
# 動かすのに欠かせないコマンド(入れた後に確かめる)
RUN_CMDS="foot zsh greetd dbus-run-session pactl swaylock rfkill nmcli bluetoothctl"
# 日本語入力(あれば)
JA="fcitx5 fcitx5-mozc fcitx5-gtk fcitx5-qt fcitx5-configtool"

say "1/3 パッケージ(pacman)"
want="$BUILD $RIVER $RUN"
case "${LANG:-}" in ja_*) want="$want $JA" ;; esac
missing=""
for p in $want; do pacman -Qq "$p" >/dev/null 2>&1 || missing="$missing $p"; done
if [ -z "$missing" ]; then
    info "すべて導入済み"
elif [ "$SU" = none ]; then
    info "root 権限(sudo / doas)が無いため、次のパッケージを入れてから再実行してください:"
    info "  pacman -S --needed$missing"
    die "パッケージが足りません"
else
    info "インストール:$missing"
    # 公式リポジトリに無い名前があっても止まらないよう、まとめて失敗したら 1 つずつ
    # shellcheck disable=SC2086
    if ! as_root pacman -S --needed --noconfirm $missing; then
        info "まとめて入れられなかったため、1 つずつ入れます"
        for p in $missing; do as_root pacman -S --needed --noconfirm "$p" || info "  (飛ばしました: $p)"; done
    fi
fi
# 足りないと必ずビルドに失敗するもの
for c in git clang wayland-scanner pkg-config odin; do
    command -v "$c" >/dev/null 2>&1 || die "$c が見つかりません(pacman -S で入れてください)"
done
# スクショ・波形・音量などに欠かせないもの: 1 つずつ入れて飛ばしたものがあれば、ここで止める
lack=""
for c in $RUN_CMDS; do command -v "$c" >/dev/null 2>&1 || lack="$lack $c"; done
[ -n "$lack" ] && die "次のコマンドが見つかりません(pacman -S で入れてから再実行してください):$lack"
info "river: $(river -version 2>&1 || echo なし) / odin: $(odin version 2>&1 | head -n 1)"

say "2/3 サービス"
if [ "$USER_MODE" = 1 ] || [ "$SU" = none ]; then
    info "(自分用のインストールのため、サービスは変更しません)"
elif command -v systemctl >/dev/null 2>&1; then
    # ログイン画面は、インストール後の設定(install-session.sh)で ame-shell(greetd)にするかを聞く
    for s in NetworkManager bluetooth; do
        systemctl is-enabled "$s.service" >/dev/null 2>&1 || { as_root systemctl enable --now "$s.service" >/dev/null 2>&1 && info "$s を有効にしました"; }
    done
else
    info "(systemctl が無いため、NetworkManager / bluetooth は手動で有効にしてください)"
fi

say "3/3 ame-shell のビルドとインストール"
# shellcheck disable=SC2086
AME_FROM_ARCH=1 exec sh "$REPO/install.sh" --no-deps $FWD
