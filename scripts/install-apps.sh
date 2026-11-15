#!/bin/sh
# install-apps.sh: ame のアプリを GitHub から取ってきてビルドし、自分用(~/.local)に入れる。POSIX sh。
#
#   sh scripts/install-apps.sh [名前 ...]       省くと全部。install.sh(と FreeBSD の install-freebsd.sh)が呼ぶ
#   sh scripts/install-apps.sh --uninstall      この script が入れたものを外す
#   sh scripts/install-apps.sh --latest [名前 ...]  決めた版(scripts/pins.sh のコミット)ではなく最新を入れる
#
#   ame-filemanager  ファイルマネージャ(Odin。Super+E・フォルダを開く既定のアプリ)
#   kuraokami        端末(Odin + SDL3。Super+Return の ame-terminal が最初に使う)
#   seoritsu         コードエディタ(Odin。tree-sitter の部分だけ Zig 0.17 でビルド)
#
# 環境変数: ODIN(既定 PATH の odin)・ZIG(0.13。kuraokami の文字の整形の部品を zig cc で作る)・
#           ZIG17(seoritsu 用。無ければ ~/.cache/ame-shell/toolchain に取ってくる)・PREFIX(既定 ~/.local)
# 自分で入れた(この script が入れたのでない)同じ名前のコマンドが $PREFIX/bin にあれば、上書きしない(開発中のものを壊さない)。
# どれかが作れなくても、ほかは続ける。作れなかったものは最後にまとめて出し、1 で終わる。
set -u
# 版とその確かめ方(コミット・SHA-256)
. "$(dirname "$0")/pins.sh"

OWNER=https://github.com/TatsuyaM2667
PREFIX="${PREFIX:-$HOME/.local}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ame-shell/toolchain"
SRC="${XDG_CACHE_HOME:-$HOME/.cache}/ame-shell/apps"
MARK="$PREFIX/share/ame-shell/apps"   # この script が入れた印(名前のファイル)
ODIN="${ODIN:-odin}"
ZIG="${ZIG:-zig}"
ARCH=$(uname -m)
OS=$(uname -s)

say() { printf '    %s\n' "$*"; }

# 名前|リポジトリ|.desktop(リポジトリの中)|アイコン(リポジトリの中)
APPS='ame-filemanager|ame-Filemanager|ame-filemanager.desktop|assets/ame-filemanager.svg
kuraokami|kuraokami|assets/kuraokami.desktop|assets/kuraokami.svg
seoritsu|seoritsu|packaging/seoritsu.desktop|assets/seoritsu.svg'

LATEST=0
if [ "${1:-}" = --latest ]; then LATEST=1; shift; fi
if [ "${1:-}" = --uninstall ]; then
    for f in "$MARK"/*; do
        [ -f "$f" ] || continue
        n=$(basename "$f")
        rm -f "$PREFIX/bin/$n" "$PREFIX/share/applications/$n.desktop" "$PREFIX/share/icons/hicolor/scalable/apps/$n.svg" "$f"
        say "外しました: $n"
    done
    exit 0
fi

# seoritsu の tree-sitter の部品(wasm.zig)は Zig 0.17 で書かれている
zig17() {
    if [ -n "${ZIG17:-}" ] && [ -x "$ZIG17" ]; then echo "$ZIG17"; return 0; fi
    os=$(echo "$OS" | tr '[:upper:]' '[:lower:]')
    d="$CACHE/zig-$ARCH-$os-$ZIG17_VER"
    if [ ! -x "$d/zig" ]; then
        mkdir -p "$CACHE"
        fetch_verified "https://ziglang.org/download/$ZIG17_VER/zig-$ARCH-$os-$ZIG17_VER.tar.xz" "$CACHE/zig-$ZIG17_VER.tar.xz" "$(zig_sha256 "$ZIG17_VER" "$ARCH-$os")" >&2 &&
            tar -xf "$CACHE/zig-$ZIG17_VER.tar.xz" -C "$CACHE" || return 1
    fi
    echo "$d/zig"
}

# pins.sh で決めたアプリのコミット(名前の - は _ に)
pinned() { eval "echo \"\${APP_COMMIT_$(echo "$1" | tr - _):-}\""; }

# 取ってくる。既定は pins.sh で決めたコミット(確かめる)、--latest なら最新。浅い clone で十分
get() { # get <名前> <リポジトリ>
    dir="$SRC/$1"
    mkdir -p "$SRC"
    if [ "$LATEST" = 0 ]; then
        commit=$(pinned "$1")
        [ -n "$commit" ] || { say "$1: 決めた版が pins.sh にありません"; return 1; }
        git_at "$OWNER/$2.git" "" "$commit" "$dir"
    elif [ -d "$dir/.git" ]; then
        git -C "$dir" fetch -q --depth 1 origin HEAD && git -C "$dir" checkout -q FETCH_HEAD ||
            { rm -rf "${dir:?}"; git clone -q --depth 1 "$OWNER/$2.git" "$dir"; }
    else
        rm -rf "${dir:?}"
        git clone -q --depth 1 "$OWNER/$2.git" "$dir"
    fi
}

# ビルドして、できた実行ファイルの場所を出す
build() { # build <名前>
    dir="$SRC/$1"
    case "$1" in
    ame-filemanager)
        link=""
        [ "$OS" = FreeBSD ] && link='-extra-linker-flags:-L/usr/local/lib'
        mkdir -p "$dir/zig-out/bin"
        # shellcheck disable=SC2086
        (cd "$dir" && "$ODIN" build src/gui -out:zig-out/bin/ame-filemanager -o:speed $link) >&2 && echo "$dir/zig-out/bin/ame-filemanager" ;;
    kuraokami)
        # build.sh は odin root と zig cc を使う
        (cd "$dir" && PATH="$(dirname "$ODIN"):$PATH" ZIG="$ZIG" sh build.sh) >&2 && echo "$dir/kuraokami" ;;
    seoritsu)
        z=$(zig17) || { say "seoritsu: Zig $ZIG17_VER を用意できません" >&2; return 1; }
        (cd "$dir" && ZIG="$z" ODIN="$ODIN" sh build.sh) >&2 && echo "$dir/seoritsu" ;;
    esac
}

failed=""
echo "$APPS" | {
    while IFS='|' read -r name repo desktop icon; do
        if [ $# -gt 0 ]; then
            want=0
            for x in "$@"; do [ "$x" = "$name" ] && want=1; done
            [ "$want" = 1 ] || continue
        fi
        bin="$PREFIX/bin/$name"
        if { [ -e "$bin" ] || [ -L "$bin" ]; } && [ ! -f "$MARK/$name" ]; then
            say "$name: 自分で入れたもの($bin)があるので、そのまま使います"
            continue
        fi
        # 決めた版がもう入っていれば作り直さない(ame-update から毎回呼ばれるので)
        if [ "$LATEST" = 0 ] && [ -x "$bin" ] && [ -s "$MARK/$name" ]; then
            case "$(pinned "$name")" in "$(cat "$MARK/$name")"*) say "$name: 最新です($(cat "$MARK/$name"))"; continue ;; esac
        fi
        say "$name: 取ってきてビルドします"
        if ! get "$name" "$repo"; then failed="$failed $name"; say "$name: 取ってこられませんでした"; continue; fi
        out=$(build "$name") || out=""
        if [ -z "$out" ] || [ ! -x "$out" ]; then failed="$failed $name"; say "$name: ビルドに失敗しました"; continue; fi
        mkdir -p "$PREFIX/bin" "$PREFIX/share/applications" "$PREFIX/share/icons/hicolor/scalable/apps" "$MARK"
        cp "$out" "$bin.ame-new" && chmod 755 "$bin.ame-new" && mv -f "$bin.ame-new" "$bin"
        cp "$SRC/$name/$icon" "$PREFIX/share/icons/hicolor/scalable/apps/$name.svg"
        # ランチャーは PATH に ~/.local/bin が無いことがあるので、Exec はフルパスに
        sed "s|^Exec=$name|Exec=$bin|; s|^TryExec=$name|TryExec=$bin|" "$SRC/$name/$desktop" > "$PREFIX/share/applications/$name.desktop"
        git -C "$SRC/$name" rev-parse --short HEAD > "$MARK/$name" 2>/dev/null || : > "$MARK/$name"
        say "$name: $bin($(cat "$MARK/$name"))"
    done
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" 2>/dev/null
    if [ -n "$failed" ]; then
        say "作れなかったもの:$failed(あとで sh scripts/install-apps.sh$failed でやり直せます)"
        exit 1
    fi
    exit 0
}
