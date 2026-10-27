#!/bin/sh
# install.sh: ame-shell を入れる。依存パッケージ・ツールチェイン・ビルド・インストールまで全自動。POSIX sh のみ。
#
#   sh install.sh               全ユーザー用(/usr/local + SDDM のセッション)。必要なときだけ doas / sudo を使う
#   sh install.sh --user        自分だけ(~/.local)。root 不要(パッケージの導入は、できなければ飛ばす)
#   sh install.sh --uninstall [--user]
#
# オプション: --no-deps(パッケージを入れない)/ --no-river(River が無くても作らない)/ --yes(確認しない)
# FreeBSD では scripts/install-freebsd.sh(完全自動)に任せる。
#
# Linux で行うこと:
#   1. 依存パッケージ(Chimera Linux の apk は自動。その他のディストリは足りないものを表示)
#   2. Zig 0.13.0(無ければ公式の配布物を ~/.cache に)と Odin(無ければソースからビルド)
#   3. River が無ければ River 0.5 をソースからビルド(Zig 0.16 + wlroots 0.20)
#   4. ame-shell をビルドして、session/install-session.sh でインストール

set -eu

USER_MODE=0
UNINSTALL=0
NO_DEPS=0
NO_RIVER=0
ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --user) USER_MODE=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --no-deps) NO_DEPS=1 ;;
        --no-river) NO_RIVER=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

case "$0" in */*) REPO=$(cd "$(dirname "$0")" && pwd) ;; *) REPO=$(pwd) ;; esac
say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---- FreeBSD は専用スクリプトへ ----
if [ "$(uname -s)" = FreeBSD ]; then
    if [ "$UNINSTALL" = 1 ]; then exec sh "$REPO/session/install-session.sh" --uninstall; fi
    [ "$USER_MODE" = 1 ] && info "FreeBSD では全ユーザー用のインストールのみ対応です(--user は無視します)"
    if [ "$ASSUME_YES" = 1 ]; then exec sh "$REPO/scripts/install-freebsd.sh" --yes; fi
    exec sh "$REPO/scripts/install-freebsd.sh"
fi
[ "$(uname -s)" = Linux ] || die "Linux と FreeBSD に対応しています($(uname -s) は未対応)"

if [ "$UNINSTALL" = 1 ]; then
    if [ "$USER_MODE" = 1 ]; then exec sh "$REPO/session/install-session.sh" --uninstall --user; fi
    exec sh "$REPO/session/install-session.sh" --uninstall
fi

# ---- root 権限で実行する手段(root なら不要、無ければ doas / sudo、どれも無ければ不可) ----
if [ "$(id -u)" -eq 0 ]; then
    SU=""
elif command -v doas >/dev/null 2>&1; then
    SU=doas
elif command -v sudo >/dev/null 2>&1; then
    SU=sudo
else
    SU=none
fi
as_root() {
    case "$SU" in
        "") "$@" ;;
        none) return 1 ;;
        *) $SU "$@" ;;
    esac
}
if [ "$USER_MODE" = 0 ] && [ "$SU" = none ]; then
    info "doas / sudo が無いため、自分用(~/.local)にインストールします"
    USER_MODE=1
fi

ARCH=$(uname -m)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ame-shell/toolchain"
mkdir -p "$CACHE"
ZIG_VER=0.13.0
ZIG_RIVER_VER=0.16.0
ODIN_TAG=dev-2026-08

fetch_to() { # fetch_to <url> <file>
    if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then wget -O "$2" "$1"
    else die "curl か wget が必要です"; fi
}

echo "ame-shell をインストールします($(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}") / $ARCH)"
echo "  インストール先: $([ $USER_MODE = 1 ] && echo "自分用(~/.local)" || echo "全ユーザー用(/usr/local + SDDM)")"
if [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
    printf '続けますか? [Y/n] '
    read -r ans || ans=y
    case "$ans" in [nN]*) exit 1 ;; esac
fi

# ---------------------------------------------------------------------------
say "1/4 依存パッケージ"
# ビルドに必要なもの / 動かすのに必要なもの / River 0.5 のビルドに必要なもの(Chimera Linux の名前)
APK_BUILD="git curl bash clang llvm-devel pkgconf wayland-devel wayland-progs mesa-devel libxkbcommon-devel freetype-devel harfbuzz-devel fontconfig-devel dbus-devel"
APK_RUN="sddm foot dbus playerctl cava pipewire wireplumber libpulse-progs mpv-libs ffmpeg grim slurp wl-clipboard swaylock brightnessctl networkmanager bluez xdg-desktop-portal-wlr fonts-noto-sans-cjk-otf fonts-nerd-jetbrains-mono"
APK_RIVER="wlroots0.20-devel wayland-protocols libevdev-devel pixman-devel libinput-devel xwayland xwayland-devel"
NEED_CMDS="git curl clang wayland-scanner pkg-config"
if [ "$NO_DEPS" = 1 ]; then
    info "(--no-deps のため省略)"
elif command -v apk >/dev/null 2>&1 && grep -q "^ID=chimera" /etc/os-release 2>/dev/null; then
    missing=""
    for p in $APK_BUILD $APK_RUN $APK_RIVER; do apk info -e "$p" >/dev/null 2>&1 || missing="$missing $p"; done
    if [ -z "$missing" ]; then
        info "すべて導入済み"
    elif [ "$SU" = none ]; then
        info "root 権限が無いため、次のパッケージは入れられません:$missing"
    else
        info "インストール:$missing"
        # shellcheck disable=SC2086
        as_root apk add $missing || info "一部のパッケージを入れられませんでした(続けます)"
    fi
else
    info "このディストリのパッケージは自動では入れません。ビルドには次のコマンドとライブラリの開発ファイルが必要です:"
    info "  コマンド: $NEED_CMDS"
    info "  ライブラリ: wayland, EGL/GLESv2(mesa), xkbcommon, freetype, harfbuzz, fontconfig, dbus"
    for cmd in $NEED_CMDS; do command -v "$cmd" >/dev/null 2>&1 || info "  見つかりません: $cmd"; done
fi

# ---------------------------------------------------------------------------
say "2/4 ツールチェイン(Zig $ZIG_VER・Odin)"
ZIG=""
if command -v zig >/dev/null 2>&1 && [ "$(zig version)" = "$ZIG_VER" ]; then
    ZIG=$(command -v zig)
else
    ZIG="$CACHE/zig-linux-$ARCH-$ZIG_VER/zig"
    if [ ! -x "$ZIG" ]; then
        info "Zig $ZIG_VER を取得します"
        fetch_to "https://ziglang.org/download/$ZIG_VER/zig-linux-$ARCH-$ZIG_VER.tar.xz" "$CACHE/zig-$ZIG_VER.tar.xz"
        tar -xf "$CACHE/zig-$ZIG_VER.tar.xz" -C "$CACHE"
    fi
fi
info "zig: $ZIG($("$ZIG" version))"
ODIN=""
if command -v odin >/dev/null 2>&1; then
    ODIN=$(command -v odin)
else
    ODIN_DIR="$CACHE/odin-$ODIN_TAG"
    ODIN="$ODIN_DIR/odin"
    if [ ! -x "$ODIN" ]; then
        info "Odin $ODIN_TAG をソースからビルドします(clang と llvm-config を使用)"
        rm -rf "$ODIN_DIR"
        git clone --depth 1 --branch "$ODIN_TAG" https://github.com/odin-lang/Odin "$ODIN_DIR"
        (cd "$ODIN_DIR" && bash build_odin.sh release)
    fi
fi
[ -x "$ODIN" ] || die "Odin を用意できませんでした"
info "odin: $ODIN"
TOOLPATH="$(dirname "$ZIG"):$(dirname "$ODIN"):$PATH"

# ---------------------------------------------------------------------------
say "3/4 River"
RIVER5_DIR="$HOME/.local/opt/river-0.5"
if command -v river >/dev/null 2>&1; then
    info "river $(river -version 2>&1) が入っています"
fi
if [ -x "$RIVER5_DIR/bin/river" ]; then
    info "River 0.5: $RIVER5_DIR(ウィンドウアニメーションつきのセッションに使います)"
elif command -v river >/dev/null 2>&1; then
    info "(River 0.5 は作りません。ウィンドウアニメーションも欲しい場合は River 0.5 を $RIVER5_DIR に入れてください)"
elif [ "$NO_RIVER" = 1 ]; then
    info "(--no-river のため River を作りません。River が無いとセッションは起動できません)"
else
    info "River が無いため River 0.5 をソースからビルドします(Zig $ZIG_RIVER_VER + wlroots 0.20)"
    ZIG16="$CACHE/zig-$ARCH-linux-$ZIG_RIVER_VER/zig"
    if [ ! -x "$ZIG16" ]; then
        fetch_to "https://ziglang.org/download/$ZIG_RIVER_VER/zig-$ARCH-linux-$ZIG_RIVER_VER.tar.xz" "$CACHE/zig-$ZIG_RIVER_VER.tar.xz"
        tar -xf "$CACHE/zig-$ZIG_RIVER_VER.tar.xz" -C "$CACHE"
    fi
    RSRC="$CACHE/river-0.5"
    [ -d "$RSRC" ] || git clone --depth 1 --branch v0.5.0 https://codeberg.org/river/river "$RSRC"
    (cd "$RSRC" && { "$ZIG16" build -Doptimize=ReleaseSafe -Dxwayland --prefix "$RIVER5_DIR" install ||
        "$ZIG16" build -Doptimize=ReleaseSafe --prefix "$RIVER5_DIR" install; }) || die "River 0.5 のビルドに失敗しました"
    info "River 0.5 → $RIVER5_DIR"
fi

# ---------------------------------------------------------------------------
say "4/4 ame-shell のビルドとインストール"
(cd "$REPO" && PATH="$TOOLPATH" "$ZIG" build -Doptimize=ReleaseFast) || die "ame-shell のビルドに失敗しました"
if [ "$USER_MODE" = 1 ]; then
    sh "$REPO/session/install-session.sh" --user
else
    # install-session.sh が自分で doas / sudo を使う(River 0.5 も全ユーザー用にコピーされる)
    sh "$REPO/session/install-session.sh"
fi
