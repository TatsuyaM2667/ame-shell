#!/bin/sh
# install-freebsd.sh: FreeBSD 14 / 15(amd64)に ame-shell を「完全自動」で入れる。POSIX sh のみ。
#
#   sh scripts/install-freebsd.sh [--user NAME] [--jobs N] [--no-gpu] [--no-ja] [--mozc] [--no-super-tap] [--yes]
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
#   --mozc          fcitx5 用の Mozc をソースからビルドして入れる(リポジトリに無いとき。10〜20 分)
#   --cleanup       使わなくなったパッケージ(cava・playerctl など)と KDE の古い設定を、確認してから消す
#   --no-super-tap  Super 単独でランチャーを開く機能のための入力デバイスの権限を設定しない
#   --debug         デバッグ情報つき・安全検査ありでビルドする(クラッシュ時のバックトレースに関数名が出る)
#   --yes           確認せずに進める

set -eu

TARGET_USER=""
JOBS=""
DO_GPU=1
DO_JA=1
DO_MOZC=0
DO_CLEANUP=0
DO_TAP=1
BUILD_OPTS="-Doptimize=ReleaseFast"
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --user) TARGET_USER="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --no-gpu) DO_GPU=0; shift ;;
        --no-ja) DO_JA=0; shift ;;
        --mozc) DO_MOZC=1; shift ;;
        --cleanup) DO_CLEANUP=1; shift ;;
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
# 必須: これが無いとビルドできない / セッションが動かない / スクショ・波形・メディア・ロック・アイコンが使えない
REQUIRED="
 git cmake ninja gmake bash pkgconf llvm18 zstd wayland wayland-protocols
 mesa-libs mesa-dri libglvnd libxkbcommon xkeyboard-config freetype2 harfbuzz fontconfig dbus
 libepoll-shim libinotify
 river sddm xorg-minimal seatd foot curl
 hicolor-icon-theme adwaita-icon-theme pulseaudio
"
# あれば使う: 無ければ飛ばす(その機能だけ使えない)。"a|b" は「a が無ければ b」
OPTIONAL="
 mpv ffmpeg fastfetch wlr-randr thunar tumbler xdg-utils upower polkit greetd
 ghostty zsh zsh-autosuggestions zsh-syntax-highlighting fzf zoxide eza bat
 libva mesa-gallium-va
 xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk
 noto-sans-jp nerd-fonts-symbols|nerd-fonts jetbrains-mono
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
        *mozc*) [ "$DO_MOZC" = 1 ] || info "  (fcitx5 用の Mozc は --mozc でソースからビルドできます。latest リポジトリや ports の japanese/fcitx5-mozc でも入ります)" ;;
    esac
fi
if [ "$DO_MOZC" = 1 ] && [ "$DO_JA" = 1 ] && [ ! -e /usr/local/lib/fcitx5/fcitx5-mozc.so ]; then
    say "日本語入力 Mozc をソースからビルド"
    sh "$REPO/scripts/build-mozc.sh" --yes || info "(Mozc のビルドに失敗しました。日本語入力なしで続けます)"
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
# カメラ(ハンド操作): FreeBSD では webcamd が USB カメラを /dev/video0(V4L2)として見せる。
# cuse(ユーザー空間のキャラクタデバイス)を読み込み、webcamd をサービスとして有効にし、webcamd グループで読めるようにする
if pkg info -e webcamd || pkg install -y webcamd >/dev/null 2>&1; then
    add_kld cuse
    sysrc webcamd_enable=YES >/dev/null
    pw groupmod webcamd -m "$TARGET_USER" 2>/dev/null && info "$TARGET_USER を webcamd グループへ(カメラ・ハンド操作)"
    service webcamd status >/dev/null 2>&1 || service webcamd start >/dev/null 2>&1 || info "(webcamd は再起動後に動きます)"
else
    info "(webcamd を入れられませんでした。ハンド操作のカメラは使えません: pkg install webcamd)"
fi
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

# タッチパッド(I2C / PS/2 のドライバ)
sh "$REPO/scripts/freebsd-touchpad.sh"
# Bluetooth(ファームウェア・ng_ubt・hcsecd / sdpd / bthidd)
sh "$REPO/scripts/freebsd-bluetooth.sh"
# Wi-Fi(wpa_supplicant を ame-shell のパネルから操作できるように)
sh "$REPO/scripts/freebsd-wifi.sh" --user "$TARGET_USER"

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
    rm -rf "${ODIN_DIR:?}"
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
# ログイン画面(SDDM)のテーマ: ロック画面と同じ見た目、背景はその人の ame-shell の壁紙
sh "$REPO/scripts/sddm-theme.sh" --user "$TARGET_USER"

# foot・fastfetch の設定を ame-shell のものに(元のファイルは *.ame-bak に残る)
su -m "$TARGET_USER" -c "env HOME='$UHOME' XDG_CONFIG_HOME= sh '$REPO/scripts/app-config.sh'"
# フォルダを開くアプリ: 決まっていなければ thunar に
if command -v thunar >/dev/null 2>&1 && command -v xdg-mime >/dev/null 2>&1; then
    su -m "$TARGET_USER" -c "env HOME='$UHOME' XDG_CONFIG_HOME= sh -c '[ -n \"\$(xdg-mime query default inode/directory 2>/dev/null)\" ] || xdg-mime default thunar.desktop inode/directory'"
fi

# 音質: PulseAudio のサンプリング周波数の変換を高い品質に(Linux の PipeWire の resample.quality = 10 と同じ考え)。
# 自分で daemon.conf を置いていればそのまま
if [ ! -f "$UHOME/.config/pulse/daemon.conf" ]; then
    su -m "$TARGET_USER" -c "env HOME='$UHOME' sh -c 'mkdir -p \"\$HOME/.config/pulse\" && printf \"%s\\n\" \"# ame-shell: 音質(サンプリング周波数の変換)\" \"resample-method = speex-float-10\" \"default-sample-format = float32le\" > \"\$HOME/.config/pulse/daemon.conf\"'" &&
        info "音質の設定: ~/.config/pulse/daemon.conf"
fi

# キーボード配列: コンソールの keymap(rc.conf の keymap="jp.kbd" など)と同じ配列を Wayland でも使う
kbd=$(sysrc -n keymap 2>/dev/null || true)
if [ -n "$kbd" ] && [ ! -f "$UHOME/.config/ame-shell/xkb-layout" ]; then
    layout=${kbd%%.*}
    mkdir -p "$UHOME/.config/ame-shell"
    echo "$layout" > "$UHOME/.config/ame-shell/xkb-layout"
    chown -R "$TARGET_USER" "$UHOME/.config/ame-shell"
    info "キーボード配列: $layout(コンソールの keymap=$kbd から)"
fi

# 日本語入力: fcitx5 用の環境変数をユーザーの ~/.config/ame-shell/environment に(ame-session が読む。
# 以前の版は river5-extra.sh に書いていたので、そちらに既にあれば作らない)
if [ "$DO_JA" = 1 ]; then
    envf="$UHOME/.config/ame-shell/environment"
    old="$UHOME/.config/ame-shell/river5-extra.sh"
    if [ ! -f "$envf" ] && ! grep -q XMODIFIERS "$old" 2>/dev/null; then
        mkdir -p "$(dirname "$envf")"
        cp "$REPO/data/examples/environment" "$envf"
        chown -R "$TARGET_USER" "$UHOME/.config/ame-shell"
        info "$envf を作成(日本語入力。例: $REPO/data/examples/environment)"
    fi
fi

if [ "$DO_CLEANUP" = 1 ]; then
    # パッケージは root で消し、設定はその人のホームの中を見る
    if [ "$ASSUME_YES" = 1 ]; then cu="--yes"; else cu=""; fi
    HOME="$UHOME" XDG_CONFIG_HOME="" XDG_DATA_HOME="" sh "$REPO/scripts/cleanup-old.sh" $cu
fi

cat <<EOF

完了しました。再起動すると SDDM が起動します:  shutdown -r now
SDDM のセッション一覧から「Ame Shell」を選んでログインしてください。
  - ログ: $UHOME/.local/state/ame-shell/session.log
  - キーボード配列は、ログイン前に環境変数 XKB_DEFAULT_LAYOUT(例: jp)で指定できます
  - 元に戻す: sh $REPO/session/install-session.sh --uninstall
EOF
