#!/bin/sh
# install-freebsd.sh: FreeBSD 14 / 15(amd64)に ame-shell を「完全自動」で入れる。POSIX sh のみ。
#
#   sh scripts/install-freebsd.sh [--user NAME] [--jobs N] [--no-gpu] [--no-ja] [--no-super-tap] [--yes]
#
# やること(すべて冪等。2 回目以降は済んでいる手順を飛ばす):
#   1. pkg で依存を入れる(River 0.4 以降・SDDM・Xorg(SDDM のログイン画面用)・Wayland・フォント など)
#   2. GPU のドライバ(drm-kmod の amdgpu / i915kms、NVIDIA は nvidia-drm)を入れて起動時に読み込む
#   3. dbus / seatd / sddm を有効にし、ユーザーを video グループへ
#   4. Zig 0.13.0 と Odin(dev-2026-08)をソースからビルド(FreeBSD 向けの配布物が無いため。数十分かかる)
#   5. ame-shell をビルドして /usr/local にインストール(SDDM に「Ame Shell」が出る)
# FreeBSD の river パッケージは 0.4 以降(ウィンドウマネージャを別に必要とする版)なので、
# ame-shell がウィンドウマネージャを兼ねて動く。
#
# オプション:
#   --user NAME     使う人(省略時は doas / sudo を実行した人)
#   --jobs N        ビルドの並列数(省略時は CPU 数)
#   --no-gpu        GPU ドライバを触らない(VM や、自分で設定済みのとき)
#   --no-ja         日本語入力(fcitx5 + mozc)を入れない(日本語フォントは入れる)
#   --no-super-tap  Super 単独でランチャーを開く機能のための入力デバイスの権限を設定しない
#   --debug         デバッグ情報つき・安全検査ありでビルドする(クラッシュ時のバックトレースに関数名が出る)
#   --yes           確認せずに進める

set -eu

TARGET_USER=""
JOBS=""
DO_GPU=1
DO_JA=1
DO_TAP=1
BUILD_OPTS="-Doptimize=ReleaseFast"
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --user) TARGET_USER="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --no-gpu) DO_GPU=0; shift ;;
        --no-ja) DO_JA=0; shift ;;
        --no-super-tap) DO_TAP=0; shift ;;
        --debug) BUILD_OPTS="-Doptimize=ReleaseSafe -Dstrip=false"; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = FreeBSD ] || die "FreeBSD 専用です(Linux では install.sh を使ってください)"
[ "$(uname -m)" = amd64 ] || die "今のところ amd64 のみ対応です"

# ---- root で動かす(doas / sudo があれば自動で昇格、無ければ su で root のパスワードを聞く) ----
case "$0" in */*) SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0") ;; *) SELF=$(pwd)/$0 ;; esac
if [ "$(id -u)" -ne 0 ]; then
    me=$(id -un)
    if command -v doas >/dev/null 2>&1; then exec doas sh "$SELF" --user "${TARGET_USER:-$me}" "$@"; fi
    if command -v sudo >/dev/null 2>&1; then exec sudo sh "$SELF" --user "${TARGET_USER:-$me}" "$@"; fi
    echo "root のパスワードを入力してください(su)"
    # su -c は 1 つの文字列を取るので、オプションを引用付きでつなげて渡す
    args=""
    for a in "$@"; do args="$args '$a'"; done
    exec su root -c "sh '$SELF' --user '${TARGET_USER:-$me}'$args"
fi

[ -n "$TARGET_USER" ] || TARGET_USER="${DOAS_USER:-${SUDO_USER:-$(logname 2>/dev/null || true)}}"
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ] || die "使う人を --user NAME で指定してください(root 以外)"
id "$TARGET_USER" >/dev/null 2>&1 || die "ユーザー $TARGET_USER がいません"
UHOME=$(pw usershow "$TARGET_USER" | awk -F: '{print $9}')
[ -n "$JOBS" ] || JOBS=$(sysctl -n hw.ncpu)

REPO=$(cd "$(dirname "$SELF")/.." && pwd)
[ -f "$REPO/build.zig" ] || die "ame-shell のリポジトリの中で実行してください($REPO)"

TOOLS=/usr/local/ame-toolchain
ZIG_VER=0.13.0
ODIN_TAG=dev-2026-08

echo "ame-shell を FreeBSD $(freebsd-version) にインストールします"
echo "  使う人: $TARGET_USER($UHOME)/ 並列数: $JOBS / ツール: $TOOLS"
echo "  GPU ドライバ: $([ $DO_GPU = 1 ] && echo 設定する || echo 触らない) / 日本語入力: $([ $DO_JA = 1 ] && echo 入れる || echo 入れない)"
if [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
    printf '続けますか? [Y/n] '
    read -r ans || ans=y
    case "$ans" in [nN]*) exit 1 ;; esac
fi

# ---------------------------------------------------------------------------
say "1/5 パッケージ"
export ASSUME_ALWAYS_YES=yes
pkg -N >/dev/null 2>&1 || pkg bootstrap -y
pkg update -q
# 必須: これが無いとビルドできない / セッションが動かない
REQUIRED="
 git cmake ninja gmake bash pkgconf llvm18 zstd wayland wayland-protocols
 mesa-libs mesa-dri libglvnd libxkbcommon xkeyboard-config freetype2 harfbuzz fontconfig dbus
 libepoll-shim libinotify
 river sddm xorg-minimal seatd foot curl
"
# あれば使う: 無ければ飛ばす(その機能だけ使えない)。"a|b" は「a が無ければ b」
OPTIONAL="
 playerctl cava swaylock grim slurp wl-clipboard mpv ffmpeg
 xdg-desktop-portal xdg-desktop-portal-wlr
 noto-sans-jp nerd-fonts-symbols
"
# 日本語入力。fcitx5 用の Mozc は latest リポジトリにしか無いことがある(quarterly には無い)ので候補を順に試す
[ "$DO_JA" = 1 ] && OPTIONAL="$OPTIONAL fcitx5 fcitx5-qt6 fcitx5-gtk3 fcitx5-configtool ja-fcitx5-mozc|ja-fcitx5-mozc3"

# 候補("a|b")のうち、導入済みのもの → リポジトリにあるもの の順に 1 つ選ぶ。どれも無ければ空
pick() {
    old_ifs=$IFS; IFS='|'
    for c in $1; do pkg info -e "$c" && { IFS=$old_ifs; echo "installed:$c"; return; }; done
    for c in $1; do [ -n "$(pkg rquery '%n' "$c" 2>/dev/null)" ] && { IFS=$old_ifs; echo "available:$c"; return; }; done
    IFS=$old_ifs
}
to_install=""
absent_req=""
skipped=""
for spec in $REQUIRED; do
    r=$(pick "$spec")
    case "$r" in
        installed:*) ;;
        available:*) to_install="$to_install ${r#available:}" ;;
        *) absent_req="$absent_req $spec" ;;
    esac
done
for spec in $OPTIONAL; do
    r=$(pick "$spec")
    case "$r" in
        installed:*) ;;
        available:*) to_install="$to_install ${r#available:}" ;;
        *) skipped="$skipped $spec" ;;
    esac
done
if [ -n "$absent_req" ]; then
    die "必須のパッケージがリポジトリにありません:$absent_req
    (pkg -vv で使っているリポジトリを確認してください。/usr/local/etc/pkg/repos/FreeBSD.conf で
     url を .../latest にすると新しいパッケージが使えます)"
fi
if [ -n "$to_install" ]; then
    info "インストール:$to_install"
    # shellcheck disable=SC2086
    pkg install -y $to_install
else
    info "必要なパッケージはすべて導入済み"
fi
if [ -n "$skipped" ]; then
    info "リポジトリに無いため飛ばしました:$skipped"
    case "$skipped" in
        *mozc*) info "  (fcitx5 用の Mozc は latest リポジトリか ports の japanese/fcitx5-mozc で入れられます。導入済みなら問題ありません)" ;;
    esac
fi
river_ver=$(river -version 2>&1 || true)
info "river: $river_ver"

# ---------------------------------------------------------------------------
say "2/5 GPU ドライバ"
add_kld() {
    cur=$(sysrc -n kld_list 2>/dev/null || true)
    case " $cur " in *" $1 "*) info "kld_list に $1 は設定済み" ;; *) sysrc kld_list+=" $1" >/dev/null; info "kld_list に $1 を追加" ;; esac
    kldstat -q -m "$1" 2>/dev/null || kldload "$1" 2>/dev/null || info "($1 は再起動後に読み込まれます)"
}
if [ "$DO_GPU" = 1 ]; then
    # 表示装置(class=0x03)のベンダー ID
    vendors=$(pciconf -lv 2>/dev/null | awk '/^[a-z]/{cls=($0 ~ /class=0x03/)} cls && /vendor=/{print}' | grep -o ' vendor=0x[0-9a-f]*' | sort -u)
    case "$vendors" in
        *0x1002*)
            pkg info -e drm-kmod || pkg install -y drm-kmod || info "drm-kmod を入れられませんでした(GPU ドライバは手動で設定してください)"
            add_kld amdgpu ;;
        *0x8086*)
            pkg info -e drm-kmod || pkg install -y drm-kmod || info "drm-kmod を入れられませんでした(GPU ドライバは手動で設定してください)"
            add_kld i915kms ;;
        *0x10de*)
            pkg info -e nvidia-drm-kmod || pkg install -y nvidia-drm-kmod || info "nvidia-drm-kmod を入れられませんでした(GPU ドライバは手動で設定してください)"
            add_kld nvidia-drm
            grep -q '^hw.nvidiadrm.modeset=' /boot/loader.conf 2>/dev/null || echo 'hw.nvidiadrm.modeset="1"' >> /boot/loader.conf ;;
        *)
            info "対応する GPU が見つかりませんでした(VM など)。ドライバは設定しません" ;;
    esac
else
    info "(--no-gpu のため省略)"
fi

# ---------------------------------------------------------------------------
say "3/5 サービスと権限"
for svc in dbus seatd sddm; do
    sysrc "${svc}_enable=YES" >/dev/null
    info "${svc}_enable=YES"
done
service dbus status >/dev/null 2>&1 || service dbus start || true
service seatd status >/dev/null 2>&1 || service seatd start || true
# sddm は今は起動しない(この端末の画面を取ってしまうため)。再起動後に起動する
pw groupmod video -m "$TARGET_USER" && info "$TARGET_USER を video グループへ(seatd・明るさ)"
if [ "$DO_TAP" = 1 ]; then
    # Super キー単独のタップを検出するため、video グループに入力デバイスの読み取りを許可する
    # (Linux の input グループと同じ。キー入力を読めるようになる点に注意)
    if ! grep -q '^\[ame_input=' /etc/devfs.rules 2>/dev/null; then
        cur_rs=$(sysrc -n devfs_system_ruleset 2>/dev/null || true)
        if [ -n "$cur_rs" ] && [ "$cur_rs" != ame_input ]; then
            info "devfs_system_ruleset=$cur_rs が設定済みのため、入力デバイスの権限は変更しません(Super 単独のランチャーは無効)"
        else
            printf '\n[ame_input=42]\nadd path '"'"'input/event*'"'"' mode 0640 group video\n' >> /etc/devfs.rules
            sysrc devfs_system_ruleset=ame_input >/dev/null
            service devfs restart >/dev/null 2>&1 || true
            info "/dev/input/event* を video グループで読めるようにしました"
        fi
    else
        info "入力デバイスの権限は設定済み"
    fi
fi

# ---------------------------------------------------------------------------
say "4/5 ツールチェイン(Zig $ZIG_VER・Odin $ODIN_TAG)"
mkdir -p "$TOOLS/src"
ZIG="$TOOLS/zig-$ZIG_VER/bin/zig"
if [ -x "$ZIG" ] && [ "$("$ZIG" version)" = "$ZIG_VER" ]; then
    info "Zig $ZIG_VER は導入済み"
else
    info "Zig $ZIG_VER をソースからビルドします(LLVM 18 を使用。30 分〜1 時間ほど、メモリを 8GB 程度使います)"
    cd "$TOOLS/src"
    [ -f "zig-$ZIG_VER.tar.xz" ] || fetch -o "zig-$ZIG_VER.tar.xz" "https://ziglang.org/download/$ZIG_VER/zig-$ZIG_VER.tar.xz"
    rm -rf "zig-$ZIG_VER"
    tar -xf "zig-$ZIG_VER.tar.xz"
    mkdir -p "zig-$ZIG_VER/build"
    cd "zig-$ZIG_VER/build"
    # LLVM 18 は -lzstd を要求する。FreeBSD の base の zstd は private 名(libprivatezstd)なので、
    # pkg の zstd(/usr/local/lib)を見つけられるよう、検索パスとリンクのパスに /usr/local を足す
    cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="/usr/local/llvm18;/usr/local" \
        -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/lib" \
        -DCMAKE_INSTALL_PREFIX="$TOOLS/zig-$ZIG_VER" \
        -DZIG_STATIC_LLVM=OFF -DZIG_NO_LIB=OFF ||
        die "Zig の cmake に失敗しました。root で再実行してください: sh $SELF"
    ninja -j "$JOBS" install ||
        die "Zig のビルドに失敗しました(ビルドディレクトリは root の持ち物なので、再実行は root で: sh $SELF)"
    [ "$("$ZIG" version)" = "$ZIG_VER" ] || die "Zig のビルドに失敗しました"
fi
ODIN_DIR="$TOOLS/odin-$ODIN_TAG"
if [ -x "$ODIN_DIR/odin" ]; then
    info "Odin $ODIN_TAG は導入済み"
else
    info "Odin $ODIN_TAG をソースからビルドします"
    rm -rf "$ODIN_DIR"
    git clone --depth 1 --branch "$ODIN_TAG" https://github.com/odin-lang/Odin "$ODIN_DIR"
    cd "$ODIN_DIR"
    env LLVM_CONFIG=/usr/local/bin/llvm-config18 bash build_odin.sh release
    [ -x "$ODIN_DIR/odin" ] || die "Odin のビルドに失敗しました"
fi
chmod -R a+rX "$TOOLS"

# ---------------------------------------------------------------------------
say "5/5 ame-shell のビルドとインストール"
# ビルドは本人の権限で(リポジトリのキャッシュが root の持ち物にならないように)
chown -R "$TARGET_USER" "$REPO"
su -m "$TARGET_USER" -c "cd '$REPO' && env HOME='$UHOME' PATH='$TOOLS/zig-$ZIG_VER/bin:$ODIN_DIR:$PATH' zig build $BUILD_OPTS" ||
    die "ame-shell のビルドに失敗しました"
sh "$REPO/session/install-session.sh" --prefix /usr/local

# キーボード配列: コンソールの keymap(rc.conf の keymap="jp.kbd" など)と同じ配列を Wayland でも使う
kbd=$(sysrc -n keymap 2>/dev/null || true)
if [ -n "$kbd" ] && [ ! -f "$UHOME/.config/ame-shell/xkb-layout" ]; then
    layout=${kbd%%.*}
    mkdir -p "$UHOME/.config/ame-shell"
    echo "$layout" > "$UHOME/.config/ame-shell/xkb-layout"
    chown -R "$TARGET_USER" "$UHOME/.config/ame-shell"
    info "キーボード配列: $layout(コンソールの keymap=$kbd から)"
fi

# 日本語入力: セッション開始時に fcitx5 が起動するよう、環境変数をユーザーの設定に
if [ "$DO_JA" = 1 ]; then
    prof="$UHOME/.config/ame-shell/river5-extra.sh"
    if [ ! -f "$prof" ]; then
        mkdir -p "$(dirname "$prof")"
        cat > "$prof" <<'EOF'
# install-freebsd.sh が作成: 日本語入力(fcitx5 + mozc)
export XMODIFIERS=@im=fcitx GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx SDL_IM_MODULE=fcitx
EOF
        chown -R "$TARGET_USER" "$UHOME/.config/ame-shell"
        info "$prof を作成(日本語入力)"
    fi
fi

cat <<EOF

完了しました。再起動すると SDDM が起動します:  shutdown -r now
SDDM のセッション一覧から「Ame Shell」を選んでログインしてください。
  - ログ: $UHOME/.local/state/ame-shell/session.log
  - キーボード配列は、ログイン前に環境変数 XKB_DEFAULT_LAYOUT(例: jp)で指定できます
  - 元に戻す: sh $REPO/session/install-session.sh --uninstall
EOF
