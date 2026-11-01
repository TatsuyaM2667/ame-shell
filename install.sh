#!/bin/sh
# install.sh: ame-shell を入れる。依存パッケージ・ツールチェイン・ビルド・インストールまで全自動。POSIX sh のみ。
#
#   sh install.sh               全ユーザー用(/usr/local + SDDM のセッション)。必要なときだけ doas / sudo を使う
#   sh install.sh --user        自分だけ(~/.local)。root 不要(パッケージの導入は、できなければ飛ばす)
#   sh install.sh --uninstall [--user]
#
# オプション: --no-deps(パッケージを入れない)/ --no-river(River が無くても作らない)/ --no-ghostty(ghostty を作らない)/ --yes(確認しない)
#           --debug(デバッグ情報つき・安全検査ありでビルド。クラッシュのバックトレースに関数名が出る)
# FreeBSD では scripts/install-freebsd.sh、Arch 系では scripts/install-arch.sh(どちらも完全自動)に任せる。
#
# Linux で行うこと:
#   1. 依存パッケージ(Chimera Linux の apk・Arch の pacman は自動。その他のディストリは足りないものを表示)
#   2. Zig 0.13.0(無ければ公式の配布物を ~/.cache に)と Odin(無ければソースからビルド)
#   3. River が無ければ River 0.5 をソースからビルド(Zig 0.16 + wlroots 0.20)
#   4. 端末 ghostty が無ければソースからビルド(Zig 0.17。Chimera はパッケージが無い)。失敗しても foot で続ける
#   5. ame-shell をビルドして、session/install-session.sh でインストール
#      (グループ・SDDM などのサービス・NetworkManager の polkit ルールは確認してから設定)
#   6. PipeWire / WirePlumber / pipewire-pulse のユーザーサービスを確認して有効に
#   7. zsh の候補表示(zsh-autosuggestions)がパッケージに無ければ取ってくる・フォルダを開くアプリ

set -eu

USER_MODE=0
UNINSTALL=0
NO_DEPS=0
NO_RIVER=0
NO_GHOSTTY=0
ASSUME_YES=0
BUILD_OPTS="-Doptimize=ReleaseFast"
FWD=""
for a in "$@"; do
    case "$a" in
        --user) USER_MODE=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --no-deps) NO_DEPS=1 ;;
        --no-river) NO_RIVER=1 ;;
        --no-ghostty) NO_GHOSTTY=1 ;;
        --yes|-y) ASSUME_YES=1; FWD="$FWD --yes" ;;
        --debug) BUILD_OPTS="-Doptimize=ReleaseSafe -Dstrip=false"; FWD="$FWD --debug" ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
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
    # shellcheck disable=SC2086  # FWD は空白区切りのオプション
    exec sh "$REPO/scripts/install-freebsd.sh" $FWD
fi
[ "$(uname -s)" = Linux ] || die "Linux と FreeBSD に対応しています($(uname -s) は未対応)"

if [ "$UNINSTALL" = 1 ]; then
    if [ "$USER_MODE" = 1 ]; then exec sh "$REPO/session/install-session.sh" --uninstall --user; fi
    exec sh "$REPO/session/install-session.sh" --uninstall
fi

# ---- Arch 系(Arch / EndeavourOS / Manjaro など)は専用スクリプトで pacman から依存を入れる ----
# (そのスクリプトが最後に install.sh --no-deps を呼び戻す)
if [ "$NO_DEPS" = 0 ] && [ -z "${AME_FROM_ARCH:-}" ] && command -v pacman >/dev/null 2>&1 &&
    { grep -qE '^ID="?arch"?$' /etc/os-release 2>/dev/null || grep -qE '^ID_LIKE=.*arch' /etc/os-release 2>/dev/null; }; then
    fwd=""
    [ "$USER_MODE" = 1 ] && fwd="--user"
    # shellcheck disable=SC2086  # FWD は空白区切りのオプション
    exec sh "$REPO/scripts/install-arch.sh" $fwd $FWD
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
ZIG_GHOSTTY_VER=0.17.0
GHOSTTY_VER=1.4.0
ODIN_TAG=dev-2026-08

fetch_to() { # fetch_to <url> <file>
    if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then wget -O "$2" "$1"
    else die "curl か wget が必要です"; fi
}

echo "ame-shell をインストールします($(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}") / $ARCH)"
echo "  インストール先: $([ $USER_MODE = 1 ] && echo "自分用(~/.local)" || echo "全ユーザー用(/usr/local + ログイン画面)")"
if [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
    printf '続けますか? [Y/n] '
    read -r ans || ans=y
    case "$ans" in [nN]*) exit 1 ;; esac
fi

# ---------------------------------------------------------------------------
say "1/7 依存パッケージ"
# Chimera Linux のパッケージ名(すべて `apk search -e` で実在を確認済み)。
# APK_BUILD / APK_RIVER / APK_RUN は必須: 入れられなければ止める。APK_OPT は無くても動く(その機能だけ使えない)
#   ビルド: ame-shell と Odin のビルドに必要なもの
APK_BUILD="git curl bash clang llvm-devel linux-headers pkgconf wayland-devel wayland-progs wayland-protocols
 mesa-devel libdrm-devel libxkbcommon-devel freetype-devel harfbuzz-devel fontconfig-devel dbus-devel linux-pam-devel
 gtk4-devel libadwaita-devel gtk4-layer-shell-devel blueprint-compiler gettext-devel ncurses"
#   (2 行目は端末 ghostty のビルド用。Chimera には ghostty のパッケージが無い)
#   River 0.5 のビルド(Chimera のリポジトリには river が無いので必ずソースから作る)
APK_RIVER="wlroots0.20-devel libevdev-devel pixman-devel libinput-devel xwayland xwayland-devel"
#   動かすのに必要なもの。pipewire-pulse は pipewire パッケージに含まれる
#   ログイン画面は greetd + ame-shell(ame-greeter)。SDDM は入れない(Chimera の sddm は既定のテーマ・コンポジタの
#   ために KDE Plasma 一式を引き込む。SDDM を使うなら sddm-theme-none と sddm-default-weston も一緒に)
#   (スクショ: grim slurp wl-clipboard / 波形: cava / 音量・Bluetooth の音: libpulse-progs(pactl)/ 無線: util-linux-rfkill)
APK_RUN="greetd greetd-dinit foot dbus mesa-dri polkit upower power-profiles-daemon playerctl cava pipewire wireplumber libpulse-progs mpv-libs ffmpeg
 grim slurp wl-clipboard swaylock brightnessctl util-linux-rfkill networkmanager bluez thunar tumbler xdg-utils
 zsh zsh-syntax-highlighting fzf zoxide
 xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk
 fonts-noto-sans-cjk-otf fonts-nerd-jetbrains-mono fonts-nerd-symbols-only adwaita-icon-theme hicolor-icon-theme"
APK_OPT="fastfetch wf-recorder wlr-randr gvfs eza bat"
NEED_CMDS="git curl clang wayland-scanner pkg-config"
# 動かすのに欠かせないコマンド(パッケージを入れた後に確かめる)
RUN_CMDS="foot zsh greetd dbus-run-session playerctl cava pactl grim slurp wl-copy swaylock brightnessctl rfkill nmcli bluetoothctl"
# Odin のビルドは llvm-config という名前を探せないため明示する
export LLVM_CONFIG="${LLVM_CONFIG:-llvm-config}"
if [ "$NO_DEPS" = 1 ]; then
    info "(--no-deps のため省略)"
# os-release の ID は引用符付き(ID="chimera")のこともある。以前は引用符付きを見落とし、パッケージを一度も入れていなかった
elif command -v apk >/dev/null 2>&1 && grep -qE '^ID="?chimera"?$' /etc/os-release 2>/dev/null; then
    # 未導入のものを「必須」「任意」に分けて集める。必須なのにリポジトリに無いものは止める
    missing=""
    unavailable=""
    for p in $APK_BUILD $APK_RIVER $APK_RUN; do
        apk info -e "$p" >/dev/null 2>&1 && continue
        if [ -n "$(apk search -qe "$p" 2>/dev/null)" ]; then missing="$missing $p"; else unavailable="$unavailable $p"; fi
    done
    opt_missing=""
    for p in $APK_OPT; do
        apk info -e "$p" >/dev/null 2>&1 && continue
        [ -n "$(apk search -qe "$p" 2>/dev/null)" ] && opt_missing="$opt_missing $p"
    done
    [ -n "$unavailable" ] && die "必須のパッケージがリポジトリにありません:$unavailable
    (doas apk update を実行してからやり直してください。それでも無ければ不具合として報告してください)"
    if [ -z "$missing$opt_missing" ]; then
        info "すべて導入済み"
    elif [ "$SU" = none ]; then
        die "root 権限(doas / sudo)が無いため、次のパッケージを入れられません。入れてから再実行してください:
      doas apk add$missing$opt_missing"
    else
        info "インストール:$missing$opt_missing"
        # まとめて入れられなければ 1 つずつ(どれが原因か分かるように)。必須が入らなければ止める
        # shellcheck disable=SC2086
        if ! as_root apk add $missing $opt_missing; then
            failed=""
            for p in $missing; do as_root apk add "$p" || failed="$failed $p"; done
            for p in $opt_missing; do as_root apk add "$p" || info "  (任意のため飛ばしました: $p)"; done
            [ -n "$failed" ] && die "必須のパッケージを入れられませんでした:$failed"
        fi
    fi
    lack=""
    for cmd in $RUN_CMDS; do command -v "$cmd" >/dev/null 2>&1 || lack="$lack $cmd"; done
    [ -n "$lack" ] && die "パッケージを入れた後も次のコマンドが見つかりません:$lack"
    info "必須のコマンドはすべてあります($RUN_CMDS)"
else
    info "このディストリのパッケージは自動では入れません。ビルドには次のコマンドとライブラリの開発ファイルが必要です:"
    info "  コマンド: $NEED_CMDS"
    info "  ライブラリ: wayland, EGL/GLESv2(mesa), xkbcommon, freetype, harfbuzz, fontconfig, dbus"
    info "  動かすのに必要なコマンド: $RUN_CMDS"
    for cmd in $NEED_CMDS $RUN_CMDS; do command -v "$cmd" >/dev/null 2>&1 || info "  見つかりません: $cmd"; done
fi

# ---------------------------------------------------------------------------
say "2/7 ツールチェイン(Zig $ZIG_VER・Odin)"
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
say "3/7 River"
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
say "4/7 端末(ghostty)"
# ame-shell と同じ Zig 製の端末。パッケージがあればそれ(Arch・FreeBSD)、無ければ公式のソースから
# ビルドして ~/.cache に置く(install-session.sh が $PREFIX へコピーする)。失敗しても foot で続ける
GHOSTTY_PREFIX="$CACHE/ghostty-prefix"
if command -v ghostty >/dev/null 2>&1; then
    info "ghostty: $(command -v ghostty)"
elif [ -x "$GHOSTTY_PREFIX/bin/ghostty" ] && [ "$(cat "$GHOSTTY_PREFIX/.ame-version" 2>/dev/null)" = "$GHOSTTY_VER" ]; then
    info "ghostty $GHOSTTY_VER: ビルド済み($GHOSTTY_PREFIX)"
elif [ "$NO_GHOSTTY" = 1 ]; then
    info "(--no-ghostty のため作りません。端末は foot を使います)"
elif ! pkg-config --exists gtk4 libadwaita-1 2>/dev/null; then
    info "(GTK4 / libadwaita の開発ファイルが無いため ghostty は作りません。端末は foot を使います)"
else
    info "ghostty $GHOSTTY_VER をソースからビルドします(Zig $ZIG_GHOSTTY_VER。数分かかります)"
    ZIG17="$CACHE/zig-$ARCH-linux-$ZIG_GHOSTTY_VER/zig"
    if [ ! -x "$ZIG17" ]; then
        fetch_to "https://ziglang.org/download/$ZIG_GHOSTTY_VER/zig-$ARCH-linux-$ZIG_GHOSTTY_VER.tar.xz" "$CACHE/zig-$ZIG_GHOSTTY_VER.tar.xz" &&
            tar -xf "$CACHE/zig-$ZIG_GHOSTTY_VER.tar.xz" -C "$CACHE"
    fi
    GSRC="$CACHE/ghostty-$GHOSTTY_VER"
    if [ ! -d "$GSRC" ]; then
        fetch_to "https://release.files.ghostty.org/$GHOSTTY_VER/ghostty-$GHOSTTY_VER.tar.gz" "$CACHE/ghostty-$GHOSTTY_VER.tar.gz" &&
            tar -xzf "$CACHE/ghostty-$GHOSTTY_VER.tar.gz" -C "$CACHE"
    fi
    rm -rf "$GHOSTTY_PREFIX"
    if [ -x "$ZIG17" ] && [ -d "$GSRC" ] &&
        (cd "$GSRC" && "$ZIG17" build -Doptimize=ReleaseFast -Dgtk-x11=false --prefix "$GHOSTTY_PREFIX"); then
        echo "$GHOSTTY_VER" > "$GHOSTTY_PREFIX/.ame-version"
        info "ghostty $GHOSTTY_VER → $GHOSTTY_PREFIX"
    else
        rm -rf "$GHOSTTY_PREFIX"
        info "ghostty のビルドに失敗しました。端末は foot を使います(--no-ghostty で次から飛ばせます)"
    fi
fi

# ---------------------------------------------------------------------------
say "5/7 ame-shell のビルドとインストール"
(cd "$REPO" && PATH="$TOOLPATH" "$ZIG" build $BUILD_OPTS) || die "ame-shell のビルドに失敗しました"
SESS_OPTS=""
[ "$ASSUME_YES" = 1 ] && SESS_OPTS="--yes"
if [ "$USER_MODE" = 1 ]; then
    sh "$REPO/session/install-session.sh" --user
else
    # install-session.sh が自分で doas / sudo を使う(River 0.5 も全ユーザー用にコピーされる)。
    # グループ・サービス・polkit の設定は 1 つずつ確認してから行う
    # shellcheck disable=SC2086
    sh "$REPO/session/install-session.sh" $SESS_OPTS
fi

# ---------------------------------------------------------------------------
say "6/7 音のユーザーサービス(PipeWire / WirePlumber / pipewire-pulse)"
# 音量・メディア・Bluetooth の音に必要。自分のユーザーのサービスなので root は要らない
confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    [ -t 0 ] || return 1
    printf '    %s [Y/n] ' "$1"
    read -r a || return 1
    case "$a" in [nN]*) return 1 ;; esac
    return 0
}
AUDIO_SVCS="pipewire pipewire-pulse wireplumber"
if command -v dinitctl >/dev/null 2>&1 && [ -d /usr/lib/dinit.d/user ]; then
    # Chimera Linux: turnstile が動かすユーザーの dinit。~/.config/dinit.d/boot.d にあれば次のログインから起動する
    off=""
    for s in $AUDIO_SVCS; do
        [ -f "/usr/lib/dinit.d/user/$s" ] || continue
        if [ -e "$HOME/.config/dinit.d/boot.d/$s" ] || dinitctl --user status "$s" 2>/dev/null | grep -q STARTED; then
            info "[ok] $s"
        else
            off="$off $s"
        fi
    done
    if [ -n "$off" ] && confirm "有効になっていないサービスを有効にしますか?:$off"; then
        for s in $off; do dinitctl --user enable "$s" >/dev/null 2>&1 && info "$s を有効にしました" || info "$s を有効にできませんでした(dinitctl --user enable $s)"; done
    elif [ -n "$off" ]; then
        info "有効にするには: dinitctl --user enable$off"
    fi
elif command -v systemctl >/dev/null 2>&1; then
    # Arch など systemd: ソケットで起動するのが既定
    off=""
    for s in pipewire.socket pipewire-pulse.socket wireplumber.service; do
        systemctl --user is-enabled "$s" >/dev/null 2>&1 && { info "[ok] $s"; continue; }
        off="$off $s"
    done
    if [ -n "$off" ] && confirm "有効になっていないサービスを有効にしますか?:$off"; then
        # shellcheck disable=SC2086
        systemctl --user enable --now $off >/dev/null 2>&1 && info "有効にしました:$off" || info "有効にできませんでした: systemctl --user enable --now$off"
    elif [ -n "$off" ]; then
        info "有効にするには: systemctl --user enable --now$off"
    fi
else
    info "(このシステムのユーザーサービスは確認できません。PipeWire が自動で起動するようにしてください)"
fi

# ---------------------------------------------------------------------------
# フォルダを開くアプリ(ファイルマネージャ): 決まっていない、または KDE の Dolphin(消した場合など)なら thunar に
if command -v thunar >/dev/null 2>&1 && command -v xdg-mime >/dev/null 2>&1; then
    cur=$(xdg-mime query default inode/directory 2>/dev/null)
    case "$cur" in
        ""|*dolphin*|*kfmclient*|org.kde.*)
            xdg-mime default thunar.desktop inode/directory && info "フォルダを開くアプリ: thunar(Super+E)" ;;
        *) info "フォルダを開くアプリ: $cur(そのまま)" ;;
    esac
fi

# ---------------------------------------------------------------------------
say "7/7 端末のシェル(zsh)"
# 灰色の候補(zsh-autosuggestions)は Chimera にパッケージが無いので、無ければ取ってくる(ame-shell の zsh の設定が読む)
ZPLUG="$HOME/.local/share/ame-shell/zsh"
have_autosuggest=0
for f in /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
    /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh "$ZPLUG/zsh-autosuggestions/zsh-autosuggestions.zsh"; do
    [ -r "$f" ] && have_autosuggest=1
done
if [ "$have_autosuggest" = 0 ] && command -v zsh >/dev/null 2>&1; then
    mkdir -p "$ZPLUG"
    git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions "$ZPLUG/zsh-autosuggestions" >/dev/null 2>&1 &&
        info "zsh-autosuggestions → $ZPLUG" || info "(zsh-autosuggestions を取ってこられませんでした。候補表示なしで使えます)"
fi
if command -v zsh >/dev/null 2>&1; then
    if [ -f "$HOME/.zshrc" ]; then
        info "zsh: 自分の ~/.zshrc を使います(ame-shell の設定は share/ame-shell/zsh/.zshrc)"
    else
        info "zsh: ame-shell の設定で開きます(端末の中だけ。ログインシェルは変えません)"
    fi
fi
