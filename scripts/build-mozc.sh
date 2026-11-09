#!/bin/sh
# build-mozc.sh: 日本語入力 Mozc(fcitx5 用)をソースからビルドして入れる。POSIX sh。
#   Chimera Linux(musl)にはパッケージが無く、glibc 向けのバイナリも Flatpak も動かない。
#   FreeBSD も quarterly のリポジトリには無いことがある。そういうときのための任意の手順。
#   sh install.sh --mozc / sh scripts/install-freebsd.sh --mozc から呼ばれる。直接: sh scripts/build-mozc.sh [--yes]
#
# 方法(~/Downloads の作業ログで確かめた手順):
#   * fcitx/mozc-cmake(Bazel を使わない CMake のビルド。Bazel は musl で動かない)を --recursive で取得
#   * Chimera: fts.h は musl に無いので chimerautils-devel から / msgfmt は gettext
#   * GUI の設定ツール(mozc_tool)は Qt6 の uic が .ui のクラス名を読めず失敗するので作らない(-DBUILD_TOOL=OFF)。
#     入力に要るのは mozc_server と fcitx5-mozc.so だけ
#   * インストール先: Linux は /usr(mozc_server は /usr/lib/mozc)、FreeBSD は /usr/local
# ビルドは 10〜20 分ほど。ソースは ~/.cache/ame-shell/mozc-cmake に置く(次からは差分だけ)。

set -eu
say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) die "不明なオプション: $a" ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then SU=""
elif command -v doas >/dev/null 2>&1; then SU=doas
elif command -v sudo >/dev/null 2>&1; then SU=sudo
else die "root 権限(doas / sudo)が必要です(パッケージの導入と /usr へのインストール)"; fi
as_root() { if [ -z "$SU" ]; then "$@"; else $SU "$@"; fi; }

OS=$(uname -s)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ame-shell"
SRC="$CACHE/mozc-cmake"
NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
# Mozc の大きなファイルは 1 つで 1〜2GB 使う: メモリ 2GB あたり 1 つ
if [ "$OS" = FreeBSD ]; then
    MEM_GB=$(( $(sysctl -n hw.physmem 2>/dev/null || echo 4294967296) / 1073741824 ))
else
    MEM_GB=$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 }' /proc/meminfo 2>/dev/null || echo 4)
fi
JOBS=$(( ${MEM_GB:-4} / 2 ))
[ "$JOBS" -lt 1 ] && JOBS=1
[ "$JOBS" -gt "$NCPU" ] && JOBS=$NCPU

say "1/4 ビルドに要るパッケージ"
case "$OS" in
    Linux)
        command -v apk >/dev/null 2>&1 || die "この手順は Chimera Linux(apk)用です。Arch は pacman -S fcitx5-mozc で入ります"
        PKGS="git cmake ninja clang pkgconf python gettext chimerautils-devel qt6-qtbase-devel abseil-cpp-devel protobuf-devel protobuf-protoc fcitx5 fcitx5-devel"
        missing=""
        for p in $PKGS; do apk info -e "$p" >/dev/null 2>&1 || missing="$missing $p"; done
        if [ -n "$missing" ]; then
            info "インストール:$missing"
            # shellcheck disable=SC2086
            as_root apk add $missing || die "パッケージを入れられませんでした:$missing"
        else
            info "すべて導入済み"
        fi
        PREFIX=/usr
        ;;
    FreeBSD)
        PKGS="git cmake ninja pkgconf python3 gettext-tools qt6-base abseil protobuf fcitx5"
        # shellcheck disable=SC2086
        as_root pkg install -y $PKGS || die "パッケージを入れられませんでした"
        PREFIX=/usr/local
        ;;
    *) die "$OS は未対応です" ;;
esac

say "2/4 ソースの取得(fcitx/mozc-cmake と Mozc 本体)"
mkdir -p "$CACHE"
if [ -d "$SRC/.git" ]; then
    (cd "$SRC" && git pull -q --ff-only || info "(更新できませんでした。手元のソースでビルドします)")
else
    rm -rf "${SRC:?}"
    git clone -q --depth 1 https://github.com/fcitx/mozc-cmake.git "$SRC" || die "取得できませんでした(ネットワークを確認)"
fi
# Mozc 本体のさらに下のサブモジュール(用例辞書 usage_dict.txt など)まで。足りないと辞書が欠ける
(cd "$SRC" && git submodule update -q --init --recursive --depth 1) || die "サブモジュールを取得できませんでした"

say "3/4 ビルド(${JOBS} 並列。10〜20 分ほどかかります)"
B="$SRC/build"
CXXFLAGS_EXTRA=""
# FreeBSD: mozc_server の場所は Linux の /usr/lib/mozc が組み込みの既定なので、/usr/local/lib/mozc を教える
[ "$OS" = FreeBSD ] && CXXFLAGS_EXTRA="-DMOZC_SERVER_DIR=\\\"$PREFIX/lib/mozc\\\""
cmake -S "$SRC" -B "$B" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS_EXTRA" \
    -DBUILD_TOOL=OFF >/dev/null || die "cmake の構成に失敗しました"
ninja -C "$B" -j "$JOBS" || die "ビルドに失敗しました(ninja -C $B で続きから試せます)"

say "4/4 インストール($PREFIX)"
if [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
    printf '    %s に mozc_server と fcitx5-mozc を入れます。よろしいですか? [Y/n] ' "$PREFIX"
    read -r ans || ans=""
    case "$ans" in n*|N*) info "やめました(ビルドしたものは $B に残っています)"; exit 0 ;; esac
fi
as_root ninja -C "$B" install || die "インストールに失敗しました"
info "Mozc を入れました。fcitx5 を再起動し(fcitx5 -r -d)、設定で「Mozc」を入力メソッドに追加してください"
info "(ame-shell のセッションでは、次のログインから fcitx5 が Mozc を読み込みます)"
