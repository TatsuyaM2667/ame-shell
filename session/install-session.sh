#!/bin/sh
# install-session.sh: ame-shell をインストール/アンインストールする。冪等。POSIX sh のみ。
#
#   sh session/install-session.sh                 全ユーザー用(/usr/local)+ SDDM のセッション。
#                                                 root でなければ doas / sudo で自動的に昇格する
#   sh session/install-session.sh --user          自分だけ(~/.local)。root 不要。SDDM のセッションは作れない
#   sh session/install-session.sh --uninstall [--user]
#   その他: --prefix DIR / --destdir DIR(疑似 root への試験)/ --dry-run
#          --yes(インストール後の設定を確認せずに行う)/ --no-setup(インストール後の設定をしない)
#   インストール後の設定(Linux の全ユーザー用のみ、1 つずつ確認): video・input グループへの追加、
#   NetworkManager・bluetoothd の有効化(dinit)、NetworkManager の polkit ルール(wheel)、
#   ログイン画面を ame-shell(greetd、scripts/greeter-setup.sh)に。greetd が無く SDDM があれば SDDM のテーマ
#
# 入力は zig-out/ のビルド成果物とこのリポジトリ内のファイルだけ(ここではビルドしない。ビルドは install.sh)。
# 追加したファイルは $PREFIX/share/ame-shell/installed-files に記録し、--uninstall はそれだけを消す。
# Linux(Chimera など)と FreeBSD に対応。

set -u
PREFIX=""
DESTDIR=""
UNINSTALL=0
DRY=0
USER_MODE=0
ASSUME_YES=0
NO_SETUP=0
ORIG_ARGS="$*"
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --destdir) DESTDIR="$2"; shift 2 ;;
        --destdir=*) DESTDIR="${1#*=}"; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --user) USER_MODE=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --no-setup) NO_SETUP=1; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

OS=$(uname -s)
if [ -z "$PREFIX" ]; then
    if [ "$USER_MODE" = 1 ]; then PREFIX="$HOME/.local"; else PREFIX=/usr/local; fi
fi

case "$0" in */*) HERE=$(cd "$(dirname "$0")" && pwd) ;; *) HERE=$(pwd) ;; esac
ROOT=$(dirname "$HERE")
OUT="$ROOT/zig-out"
MANIFEST_REL="$PREFIX/share/ame-shell/installed-files"
MANIFEST="$DESTDIR$MANIFEST_REL"
WARN=0

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; WARN=$((WARN + 1)); }
run() { if [ "$DRY" = 1 ]; then say "  (dry-run) $*"; else "$@"; fi; }

# ---------------------------------------------------------------------------
# 権限: 全ユーザー用のインストールは root が必要。doas / sudo があれば自動で昇格し、
# どちらも無ければ自分用(--user)に切り替える
# ---------------------------------------------------------------------------
if [ "$USER_MODE" = 0 ] && [ -z "$DESTDIR" ] && [ "$DRY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    if command -v doas >/dev/null 2>&1; then
        say "全ユーザー用にインストールするため doas で実行します(パスワードを聞かれます)"
        # shellcheck disable=SC2086  # 引数は空白を含まない前提(パスは --prefix=… の形で渡す)
        exec doas sh "$0" $ORIG_ARGS
    elif command -v sudo >/dev/null 2>&1; then
        say "全ユーザー用にインストールするため sudo で実行します(パスワードを聞かれます)"
        # shellcheck disable=SC2086
        exec sudo sh "$0" $ORIG_ARGS
    else
        say "doas / sudo が無いため、自分用(~/.local)にインストールします"
        USER_MODE=1
        PREFIX="$HOME/.local"
        MANIFEST_REL="$PREFIX/share/ame-shell/installed-files"
        MANIFEST="$MANIFEST_REL"
    fi
fi

# ---------------------------------------------------------------------------
# アンインストール
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
    if [ ! -f "$MANIFEST" ]; then
        say "記録が見つかりません ($MANIFEST)。インストールされていないようです。"
        exit 0
    fi
    say "アンインストール: $MANIFEST に記録されたファイルを削除します"
    # 記録は「インストール先の絶対パス(DESTDIR を除く)」で 1 行 1 件
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        t="$DESTDIR$f"
        if [ -e "$t.ame-bak" ]; then
            say "  restore $f"
            run mv -f "$t.ame-bak" "$t"
        elif [ -e "$t" ] || [ -L "$t" ]; then
            say "  rm $f"
            run rm -f "$t"
        fi
    done < "$MANIFEST"
    run rm -f "$MANIFEST"
    # 自分で作った空ディレクトリだけ片付ける(他のファイルがあれば残る)
    for d in "$DESTDIR$PREFIX/share/icons/ame/cursors" "$DESTDIR$PREFIX/share/icons/ame" "$DESTDIR$PREFIX/share/ame-shell/widgets" "$DESTDIR$PREFIX/share/ame-shell/xdg/foot" "$DESTDIR$PREFIX/share/ame-shell/xdg/fastfetch" "$DESTDIR$PREFIX/share/ame-shell/xdg/xdg-desktop-portal" "$DESTDIR$PREFIX/share/ame-shell/examples" "$DESTDIR$PREFIX/share/ame-shell/ghostty" "$DESTDIR$PREFIX/share/ame-shell/zsh" "$DESTDIR$PREFIX/share/ame-shell/bash" "$DESTDIR$PREFIX/share/ame-shell/xdg" "$DESTDIR$PREFIX/share/ame-shell" "$DESTDIR/usr/share/sddm/themes/ame" "$DESTDIR/usr/local/share/sddm/themes/ame" "$DESTDIR$PREFIX/opt/river-0.5/bin" "$DESTDIR$PREFIX/opt/river-0.5" "$DESTDIR$PREFIX/libexec/ame-shell" "$DESTDIR$PREFIX/share/themes/AmeGlass/gtk-3.0" "$DESTDIR$PREFIX/share/themes/AmeGlass"; do
        [ -d "$d" ] && run rmdir "$d" 2>/dev/null
    done
    say "完了しました。"
    exit 0
fi

# ---------------------------------------------------------------------------
# 事前確認
# ---------------------------------------------------------------------------
for f in "$OUT/bin/ame-shell" "$OUT/bin/ame-ctl" "$OUT/share/ame-shell/config.ame" "$HERE/ame-session" "$HERE/ame-river-init" "$HERE/ame-river5-init"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f がありません。先に 'sh install.sh'(または zig build -Doptimize=ReleaseFast)を実行してください。" >&2
        exit 1
    fi
done

# インストールを頼んだ本人(doas / sudo 経由でも元のユーザー)
U="${DOAS_USER:-${SUDO_USER:-$(id -un)}}"
UHOME=$(eval echo "~$U")

# システムの river が 0.4 以降か(FreeBSD の river パッケージなど)。
# River 0.3 が無ければ(0.4 以降しか無い・Chimera のように river パッケージが無い)、River 0.3 用の
# セッションは動かないので、内蔵ウィンドウマネージャで動くセッションだけを「Ame Shell」として入れる
NEW_RIVER=0
HAVE_RIVER03=0
if command -v river >/dev/null 2>&1; then
    case "$(river -version 2>&1)" in 0.[4-9]*|[1-9]*) NEW_RIVER=1 ;; *) HAVE_RIVER03=1 ;; esac
fi

# ---- SDDM が読むセッションディレクトリ ----
# 優先順位: 既定 < conf.d/* < sddm.conf。後から読んだ値で上書き。FreeBSD は /usr/local/etc 以下
SESS_DIR=""
if [ "$USER_MODE" = 0 ]; then
    if [ "$OS" = FreeBSD ]; then
        CONF_FILES="/usr/local/etc/sddm.conf.d/*.conf /usr/local/etc/sddm.conf"
        SESS_DIRS="/usr/local/share/wayland-sessions"
    else
        CONF_FILES="/usr/lib/sddm/sddm.conf.d/*.conf /etc/sddm.conf.d/*.conf /etc/sddm.conf"
        SESS_DIRS="/usr/share/wayland-sessions"
    fi
    for f in $CONF_FILES; do
        [ -f "$f" ] || continue
        v=$(awk -F= '/^\[/{sec=$0} sec=="[Wayland]" && $1=="SessionDir"{print $2}' "$f" | tail -n 1)
        [ -n "$v" ] && SESS_DIRS="$v"
    done
    old_ifs=$IFS; IFS=','
    for d in $SESS_DIRS; do
        [ "$d" = "$PREFIX/share/wayland-sessions" ] && SESS_DIR="$d"
    done
    if [ -z "$SESS_DIR" ]; then
        for d in $SESS_DIRS; do [ -z "$SESS_DIR" ] && [ "$d" = "/usr/share/wayland-sessions" ] && SESS_DIR="$d"; done
    fi
    if [ -z "$SESS_DIR" ]; then for d in $SESS_DIRS; do [ -z "$SESS_DIR" ] && SESS_DIR="$d"; done; fi
    IFS=$old_ifs
    say "SDDM の SessionDir: $SESS_DIRS → $SESS_DIR に配置"
fi

# ---- PAM の置き場所(Linux のみ。FreeBSD のロックは setuid の ame-auth が照合するので不要) ----
# Linux-PAM は /etc/pam.d/<svc> → /usr/lib/pam.d/<svc> の順に探す(vendordir 対応版)。
# /etc/pam.d が無い環境で、libpam が /usr/lib/pam.d を知らない古い版だと /etc/pam.d を作った瞬間に
# 他のサービスが読めなくなるので、その場合は /usr/lib/pam.d に置く。
PAM_DIR=/etc/pam.d
if [ ! -d /etc/pam.d ]; then
    lib=""
    for l in /usr/lib/libpam.so.0 /lib/libpam.so.0 /usr/lib64/libpam.so.0; do [ -f "$l" ] && lib="$l" && break; done
    # バイナリ中の文字列を探す(BSD grep はバイナリ内を検索しないので tr で印字可能文字の行にする)
    if [ -n "$lib" ] && LC_ALL=C tr -c '[:print:]' '\n' < "$lib" | grep -q '^/usr/lib/pam.d'; then
        PAM_DIR=/etc/pam.d
    else
        PAM_DIR=/usr/lib/pam.d
    fi
fi
PAM_SRC=""
for p in /etc/pam.d/swaylock /usr/lib/pam.d/swaylock; do [ -f "$p" ] && PAM_SRC="$p" && break; done
LOGIN_SRC=""
for p in /etc/pam.d/login /usr/lib/pam.d/login; do [ -f "$p" ] && LOGIN_SRC="$p" && break; done

# ---------------------------------------------------------------------------
# インストール
# ---------------------------------------------------------------------------
TMP_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/ame-manifest.XXXXXX") || exit 1
trap 'rm -f "$TMP_MANIFEST"' EXIT

# install_file <src> <dst(DESTDIR抜き)> <mode>
install_file() {
    src=$1; dst=$2; mode=$3; t="$DESTDIR$dst"
    run mkdir -p "$(dirname "$t")"
    if [ -e "$t" ] && ! grep -qx "$dst" "$MANIFEST" 2>/dev/null; then
        # 自分が入れたものでない既存ファイルは .ame-bak に退避してから上書き
        if ! cmp -s "$src" "$t"; then
            say "  backup $dst → $dst.ame-bak"
            run cp -p "$t" "$t.ame-bak"
        fi
    fi
    say "  install $dst ($mode)"
    run cp "$src" "$t.ame-new" && run chmod "$mode" "$t.ame-new" && run mv -f "$t.ame-new" "$t"
    echo "$dst" >> "$TMP_MANIFEST"
}

# retire <dst(DESTDIR抜き)>: 以前の版が入れたが今は使わないファイルを消し、記録からも外す
# (自分が入れたもの=記録にあるものだけ。退避した元のファイルがあれば戻す)
RETIRED=""
retire() {
    dst=$1; t="$DESTDIR$dst"
    grep -qx "$dst" "$MANIFEST" 2>/dev/null || return 0
    if [ -e "$t.ame-bak" ]; then
        say "  restore $dst(使わなくなったため)"
        run mv -f "$t.ame-bak" "$t"
    elif [ -e "$t" ]; then
        say "  rm $dst(使わなくなったため)"
        run rm -f "$t"
    fi
    RETIRED="$RETIRED
$dst"
}

# install_link <リンク先> <dst(DESTDIR抜き)>: シンボリックリンク(カーソルの古い名前など)
install_link() {
    tgt=$1; dst=$2; t="$DESTDIR$dst"
    run mkdir -p "$(dirname "$t")"
    say "  link $dst -> $tgt"
    run rm -f "$t" && run ln -s "$tgt" "$t"
    echo "$dst" >> "$TMP_MANIFEST"
}

say "インストール先: ${DESTDIR}${PREFIX}($( [ "$USER_MODE" = 1 ] && echo "自分用" || echo "全ユーザー用"))"
install_file "$OUT/bin/ame-shell" "$PREFIX/bin/ame-shell" 755
install_file "$OUT/bin/ame-ctl" "$PREFIX/bin/ame-ctl" 755
# 画面を持たない小さな道具(src/cmd/。単独でも使える)
for t in ame-lyrics ame-ai ame-agent ame-config ame-weather ame-airpods ame-handtrack ame-keyring amaterasu ame-tajikara ame-uzume ame-hamon ame-copy ame-paste ame-yatagarasu ame-rec ame-iwato; do install_file "$OUT/bin/$t" "$PREFIX/bin/$t" 755; done
# 名前を変えた道具(2026-11): 古い名前でもしばらく呼べるよう、新しい名前へのリンクを置く
for pair in ame-light:amaterasu ame-power:ame-tajikara ame-kuraokami:ame-weather ame-emaki:ame-rec ame-vol:ame-uzume ame-spectrum:ame-hamon; do
    old=${pair%%:*}; new=${pair#*:}
    say "  link $PREFIX/bin/$old → $new(古い名前)"
    run ln -sf "$new" "$DESTDIR$PREFIX/bin/$old"
    echo "$PREFIX/bin/$old" >> "$TMP_MANIFEST"
done
install_file "$HERE/ame-session" "$PREFIX/bin/ame-session" 755
install_file "$HERE/ame-update" "$PREFIX/bin/ame-update" 755
install_file "$HERE/ame-term-shell" "$PREFIX/bin/ame-term-shell" 755
install_file "$HERE/ame-greeter" "$PREFIX/bin/ame-greeter" 755
install_file "$HERE/ame-terminal" "$PREFIX/bin/ame-terminal" 755
# ファイルアプリ(Thunar)を端末と同じ半透明のテーマで開く入口と、そのテーマ(AmeGlass)
install_file "$HERE/libexec/thunar" "$PREFIX/libexec/ame-shell/thunar" 755
install_file "$OUT/share/ame-shell/themes/AmeGlass/gtk-3.0/gtk.css" "$PREFIX/share/themes/AmeGlass/gtk-3.0/gtk.css" 644
# ame-update が git pull してビルドし直すための、ソースの場所の記録
tmp=$(mktemp "${TMPDIR:-/tmp}/ame-src.XXXXXX") || exit 1
echo "$ROOT" > "$tmp"
# 2 行目: 入れたときのコミット(ame-update が「入っている版が古い」ことに気づけるように)。
# root で他人のリポジトリを読むと git が拒むので safe.directory を付ける
git -c safe.directory="$ROOT" -C "$ROOT" rev-parse HEAD >> "$tmp" 2>/dev/null || true
install_file "$tmp" "$PREFIX/share/ame-shell/source" 644
rm -f "$tmp"
install_file "$HERE/ame-river-init" "$PREFIX/share/ame-shell/ame-river-init" 755
install_file "$HERE/ame-river5-init" "$PREFIX/share/ame-shell/ame-river5-init" 755
install_file "$HERE/ame-display-scale" "$PREFIX/share/ame-shell/ame-display-scale" 755
install_file "$OUT/share/ame-shell/config.ame" "$PREFIX/share/ame-shell/config.ame" 644
install_file "$OUT/share/ame-shell/bt-connect.sh" "$PREFIX/share/ame-shell/bt-connect.sh" 755
install_file "$OUT/share/ame-shell/xdg/foot/foot.ini" "$PREFIX/share/ame-shell/xdg/foot/foot.ini" 644
install_file "$OUT/share/ame-shell/xdg/fastfetch/config.jsonc" "$PREFIX/share/ame-shell/xdg/fastfetch/config.jsonc" 644
# 端末(ghostty)と zsh の ame-shell の設定(自分の ~/.config/ghostty/config・~/.zshrc があればそちらが使われる)
install_file "$OUT/share/ame-shell/ghostty/config" "$PREFIX/share/ame-shell/ghostty/config" 644
install_file "$OUT/share/ame-shell/zsh/.zshrc" "$PREFIX/share/ame-shell/zsh/.zshrc" 644
install_file "$OUT/share/ame-shell/zsh/.zprofile" "$PREFIX/share/ame-shell/zsh/.zprofile" 644
install_file "$OUT/share/ame-shell/bash/bashrc" "$PREFIX/share/ame-shell/bash/bashrc" 644
install_file "$OUT/share/ame-shell/xdg/xdg-desktop-portal/river-portals.conf" "$PREFIX/share/ame-shell/xdg/xdg-desktop-portal/river-portals.conf" 644
# ユーザー設定の例(~/.config/ame-shell/environment・autostart。README を参照)
install_file "$OUT/share/ame-shell/examples/environment" "$PREFIX/share/ame-shell/examples/environment" 644
install_file "$OUT/share/ame-shell/examples/autostart" "$PREFIX/share/ame-shell/examples/autostart" 755
for w in "$OUT"/share/ame-shell/widgets/*.wasm; do
    [ -f "$w" ] || continue
    install_file "$w" "$PREFIX/share/ame-shell/widgets/$(basename "$w")" 644
done
# マウスカーソルのテーマ "ame"(古い名前・ハッシュの名前は同じファイルへのシンボリックリンク)
if [ -d "$OUT/share/icons/ame/cursors" ]; then
    for f in "$OUT"/share/icons/ame/cursors/*; do
        n=$(basename "$f")
        if [ -L "$f" ]; then
            install_link "$(readlink "$f")" "$PREFIX/share/icons/ame/cursors/$n"
        else
            install_file "$f" "$PREFIX/share/icons/ame/cursors/$n" 644
        fi
    done
    install_file "$OUT/share/icons/ame/index.theme" "$PREFIX/share/icons/ame/index.theme" 644
fi

# ghostty をソースからビルドした場合(Chimera などパッケージが無い環境。install.sh が ~/.cache に作る)
GPFX="$UHOME/.cache/ame-shell/toolchain/ghostty-prefix"
if [ -x "$GPFX/bin/ghostty" ]; then
    say "ghostty($GPFX)を $PREFIX に入れます"
    (cd "$GPFX" && find . \( -type f -o -type l \) | sed "s|^\./||") | while IFS= read -r rel; do
        if [ -L "$GPFX/$rel" ]; then
            install_link "$(readlink "$GPFX/$rel")" "$PREFIX/$rel"
        elif [ -x "$GPFX/$rel" ]; then
            install_file "$GPFX/$rel" "$PREFIX/$rel" 755
        else
            install_file "$GPFX/$rel" "$PREFIX/$rel" 644
        fi
    done
fi

# River 0.5 を自分でビルドしている場合(~/.local/opt/river-0.5)、全ユーザーが使えるよう $PREFIX/opt へ
if [ "$USER_MODE" = 0 ] && [ "$NEW_RIVER" = 0 ]; then
    for r in "${AME_RIVER5:-}" "$UHOME/.local/opt/river-0.5/bin/river"; do
        if [ -n "$r" ] && [ -x "$r" ]; then
            install_file "$r" "$PREFIX/opt/river-0.5/bin/river" 755
            break
        fi
    done
fi

# .desktop: @PREFIX@ を実際のパスに置換(sed -i は使わない: BSD/GNU で書式が違うため)。
# SDDM はホームの下を読まないので、自分用インストールでは作らない
if [ "$USER_MODE" = 0 ]; then
    # セーフモード(ame-shell-safe)は廃止。以前の版が入れたものは消す
    retire "$SESS_DIR/ame-shell-safe.desktop"
    if [ "$HAVE_RIVER03" = 1 ]; then
        DESKTOPS="ame-shell ame-shell-river5"
    else
        # River 0.3 が無い: 内蔵 WM のセッションだけを「Ame Shell」として入れる
        DESKTOPS="ame-shell-river5"
        retire "$SESS_DIR/ame-shell.desktop"
    fi
    for d in $DESKTOPS; do
        tmp=$(mktemp "${TMPDIR:-/tmp}/ame-desktop.XXXXXX") || exit 1
        if [ "$HAVE_RIVER03" = 0 ]; then
            sed -e "s|@PREFIX@|$PREFIX|g" -e 's|^Name=.*|Name=Ame Shell|' -e 's|^Name\[ja\]=.*|Name[ja]=Ame Shell(雨)|' "$HERE/$d.desktop" > "$tmp"
        else
            sed "s|@PREFIX@|$PREFIX|g" "$HERE/$d.desktop" > "$tmp"
        fi
        install_file "$tmp" "$SESS_DIR/$d.desktop" 644
        rm -f "$tmp"
    done
fi

# PAM(ロック画面用。Linux の全ユーザー用インストールのみ)
if [ "$USER_MODE" = 0 ] && [ "$OS" != FreeBSD ]; then
    if [ -n "$PAM_SRC" ] || [ -n "$LOGIN_SRC" ]; then
        tmp=$(mktemp "${TMPDIR:-/tmp}/ame-pam.XXXXXX") || exit 1
        {
            echo "# ame-shell のロック画面用(install-session.sh が作成)"
            if [ -n "$PAM_SRC" ]; then
                echo "# $PAM_SRC と同じ内容"
                grep -v '^#' "$PAM_SRC" | grep -v '^[[:space:]]*$'
            else
                echo "# $LOGIN_SRC の auth/account を流用"
                echo "auth include login"
                echo "account include login"
            fi
        } > "$tmp"
        install_file "$tmp" "$PAM_DIR/ame-shell" 644
        rm -f "$tmp"
    else
        warn "swaylock も login の PAM 設定も見つからないため PAM サービス ame-shell を作りません(ロック画面は無効になります)"
    fi
fi

# PAM(ログイン画面 greetd の顔認証。全ユーザー用インストールで、greetd の PAM 設定があるときだけ)
# ame-greetd: 顔認証のモジュール(ame-greeter が頼んだときだけカメラを使う)→ だめなら greetd と同じ認証。
# greetd の config.toml の [general] service = "ame-greetd" で使う(scripts/greeter-setup.sh が書く)
#   Linux-PAM: $PAM_DIR に置く。モジュールが無くても止まらないよう "-auth"
#   FreeBSD(OpenPAM): "-auth" の書き方が無いので "auth"。greetd の版によって /etc/pam.d と
#   /usr/local/etc/pam.d のどちらでサービスを探すかが違うので、両方に置く(中身は同じ)
if [ "$USER_MODE" = 0 ] && [ -f "$OUT/lib/libpam_ame_face.so" ]; then
    GREETD_PAM=""
    for p in /etc/pam.d/greetd /usr/lib/pam.d/greetd /usr/local/etc/pam.d/greetd; do [ -f "$p" ] && GREETD_PAM="$p" && break; done
    if [ -n "$GREETD_PAM" ]; then
        install_file "$OUT/lib/libpam_ame_face.so" "$PREFIX/lib/ame-shell/pam_ame_face.so" 755
        NOLOGIN=""
        for m in /lib/security/pam_nologin.so /usr/lib/security/pam_nologin.so /lib64/security/pam_nologin.so /usr/lib/x86_64-linux-gnu/security/pam_nologin.so /usr/lib/pam_nologin.so; do
            [ -f "$m" ] && NOLOGIN=1 && break
        done
        if [ "$OS" = FreeBSD ]; then
            CTRL="auth"
            FACE_PAM_DIRS="/etc/pam.d /usr/local/etc/pam.d"
        else
            CTRL="-auth"
            FACE_PAM_DIRS="$PAM_DIR"
        fi
        tmp=$(mktemp "${TMPDIR:-/tmp}/ame-pam.XXXXXX") || exit 1
        {
            echo "# ame-shell のログイン画面(greetd)用(install-session.sh が作成)"
            echo "# 顔認証(ame-greeter が頼んだときだけ。一致しなければ次へ)→ $GREETD_PAM と同じ認証"
            [ -n "$NOLOGIN" ] && echo "auth requisite pam_nologin.so"
            echo "$CTRL sufficient $PREFIX/lib/ame-shell/pam_ame_face.so"
            echo "auth include greetd"
            echo "account include greetd"
            echo "password include greetd"
            echo "session include greetd"
        } > "$tmp"
        for d in $FACE_PAM_DIRS; do install_file "$tmp" "$d/ame-greetd" 644; done
        rm -f "$tmp"
    fi
fi

# FreeBSD: ログイン画面がすでに ame-greeter なら、greeter-setup をやり直して顔認証の PAM サービス(ame-greetd)を
# 使わせる(Linux は下の「インストール後の設定」の 4 で同じことをする。FreeBSD ではその設定を行わないため)
if [ "$USER_MODE" = 0 ] && [ "$OS" = FreeBSD ] && [ -z "$DESTDIR" ] && [ "$DRY" = 0 ] &&
    [ -f "$ROOT/scripts/greeter-setup.sh" ] && grep -q "ame-greeter" /usr/local/etc/greetd/config.toml 2>/dev/null; then
    sh "$ROOT/scripts/greeter-setup.sh" --user "$U" --prefix "$PREFIX" --manifest "$TMP_MANIFEST" >/dev/null &&
        say "  ログイン画面(greetd)の設定を更新しました(顔認証)"
fi

# FreeBSD のロック画面: pam_unix は root でないと照合できないので、照合の補助 ame-auth を root の setuid で入れる
# (照合するのは呼び出した人のパスワードだけ。swaylock が setuid で入るのと同じ考え。src/auth_helper.zig)
if [ "$USER_MODE" = 0 ] && [ "$OS" = FreeBSD ]; then
    install_file "$OUT/bin/ame-auth" "$PREFIX/libexec/ame-shell/ame-auth" 4755
    run chown root:wheel "$DESTDIR$PREFIX/libexec/ame-shell/ame-auth" || true
    # 持ち主を変えると setuid が外れることがあるので、もう一度付ける
    run chmod 4755 "$DESTDIR$PREFIX/libexec/ame-shell/ame-auth"
    tmp=$(mktemp "${TMPDIR:-/tmp}/ame-pam.XXXXXX") || exit 1
    {
        echo "# ame-shell のロック画面用(install-session.sh が作成。ame-auth が使う)"
        if [ -f /usr/local/etc/pam.d/swaylock ]; then
            echo "# /usr/local/etc/pam.d/swaylock と同じ内容"
            grep -v '^#' /usr/local/etc/pam.d/swaylock | grep -v '^[[:space:]]*$'
        else
            echo "auth include system"
            echo "account include system"
        fi
    } > "$tmp"
    install_file "$tmp" "/usr/local/etc/pam.d/ame-shell" 644
    rm -f "$tmp"
fi

# ---------------------------------------------------------------------------
# 表示の言語: Linux のコンソール(TTY)は日本語を表示できず豆腐になるので、英語で出す
# (doas は LANG を引き継がないので TERM で判断する。AME_ASCII=1 でも英語)
# ---------------------------------------------------------------------------
EN=0
if [ "${TERM:-}" = linux ] || [ "${TERM:-}" = vt220 ] || [ "${AME_ASCII:-0}" = 1 ]; then EN=1; fi
# m <日本語> <英語>: 言語に合わせてどちらかを返す
m() { if [ "$EN" = 1 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
ok() { say "  [ok] $(m "$1" "$2")"; }
ng() { warn "$(m "$1" "$2")"; }

# ---------------------------------------------------------------------------
# インストール後の設定(Linux の全ユーザー用のみ。root で動いている。1 つずつ確認してから行う)
# FreeBSD は scripts/install-freebsd.sh が同じことを行う
# ---------------------------------------------------------------------------
# ask <日本語> <英語>: --yes なら常に はい。端末でなければ いいえ。--dry-run では聞かずに表示だけ
ask() {
    [ "$ASSUME_YES" = 1 ] && return 0
    if [ "$DRY" = 1 ]; then say "  (dry-run) $(m "$1" "$2")"; return 0; fi
    [ -t 0 ] || return 1
    printf '  %s [y/N] ' "$(m "$1" "$2")"
    read -r a || return 1
    case "$a" in [yY]*) return 0 ;; esac
    return 1
}
in_group() { id -Gn "$U" 2>/dev/null | tr ' ' '\n' | grep -qx "$1"; }
SETUP_LATER=""
later() { SETUP_LATER="$SETUP_LATER
    $1"; }

if [ "$USER_MODE" = 0 ] && [ "$OS" != FreeBSD ] && [ "$NO_SETUP" = 0 ] && [ -z "$DESTDIR" ]; then
    say ""
    say "== $(m "インストール後の設定" "Post-install setup") =="
    # 1. video / input グループ(明るさの変更・Super 単独でのランチャー)
    groups=""
    for g in video input; do
        getent group "$g" >/dev/null 2>&1 || continue
        in_group "$g" || groups="$groups,$g"
    done
    groups=${groups#,}
    if [ -n "$groups" ]; then
        if ask "$U を $groups グループに追加しますか?(次のログインから有効)" "Add $U to group(s) $groups? (effective from next login)"; then
            run usermod -aG "$groups" "$U" && ok "$U を $groups に追加しました" "added $U to $groups"
        else
            later "usermod -aG $groups $U"
        fi
    fi
    # 2. dinit のサービス(NetworkManager・Bluetooth。ログイン画面は 4 で)。boot.d へのリンクで「次の起動から」有効にする
    #    (dinitctl enable はすぐに起動するため、インストール中に画面が SDDM に切り替わってしまう)
    if command -v dinitctl >/dev/null 2>&1 && [ -d /etc/dinit.d ]; then
        for svc in networkmanager bluetoothd; do
            [ -f "/usr/lib/dinit.d/$svc" ] || [ -f "/etc/dinit.d/$svc" ] || continue
            [ -e "/etc/dinit.d/boot.d/$svc" ] && continue
            if ask "dinit のサービス $svc を有効にしますか?(次の起動から)" "Enable dinit service $svc? (from next boot)"; then
                svc_file="/usr/lib/dinit.d/$svc"
                [ -f "/etc/dinit.d/$svc" ] && svc_file="/etc/dinit.d/$svc"
                run mkdir -p /etc/dinit.d/boot.d
                run ln -s "$svc_file" "/etc/dinit.d/boot.d/$svc" && ok "$svc を有効にしました" "enabled $svc"
            else
                later "dinitctl --system enable $svc"
            fi
        done
    fi
    # 3. NetworkManager を一般ユーザー(wheel)が操作できるように(無いと Wi-Fi パネルから接続できない)
    RULE=/etc/polkit-1/rules.d/50-networkmanager.rules
    if [ -d /usr/share/polkit-1 ] && command -v nmcli >/dev/null 2>&1; then
        if [ -e "$RULE" ] && ! grep -qx "$RULE" "$MANIFEST" 2>/dev/null; then
            ok "$RULE は既にあります(そのまま)" "$RULE already exists (left as is)"
        elif in_group network; then
            : # 既定のルール(network グループ)で操作できる
        elif grep -qx "$RULE" "$MANIFEST" 2>/dev/null || ask "wheel グループが NetworkManager を操作できるよう polkit のルールを置きますか?($RULE)" "Install a polkit rule so the wheel group can control NetworkManager? ($RULE)"; then
            tmp=$(mktemp "${TMPDIR:-/tmp}/ame-polkit.XXXXXX") || exit 1
            cat > "$tmp" <<'RULES'
// ame-shell(install-session.sh)が作成: wheel グループの人が、ログイン中の画面から
// NetworkManager を操作できるようにする(Wi-Fi パネルからの接続・切断・オン/オフ)
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 &&
        subject.isInGroup("wheel") && subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
RULES
            install_file "$tmp" "$RULE" 644
            rm -f "$tmp"
        else
            later "$(m "polkit のルール" "polkit rule"): $RULE"
        fi
    fi
    # 4. ログイン画面: greetd があれば ame-shell のログイン画面(ロック画面と同じ見た目。SDDM は要らなくなる)。
    #    greetd が無く SDDM があるときは、SDDM のテーマをロック画面と同じ見た目に(下の 5)
    GREETD_DONE=0
    if command -v greetd >/dev/null 2>&1 && [ -f "$ROOT/scripts/greeter-setup.sh" ]; then
        if grep -q "ame-greeter" /etc/greetd/config.toml 2>/dev/null ||
            ask "ログイン画面を ame-shell(greetd。ロック画面と同じ見た目)にしますか?SDDM は使わなくなります" \
                "Use the ame-shell login screen (greetd, same look as the lock screen) instead of SDDM?"; then
            if [ "$DRY" = 1 ]; then
                sh "$ROOT/scripts/greeter-setup.sh" --user "$U" --prefix "$PREFIX" --dry-run
            else
                sh "$ROOT/scripts/greeter-setup.sh" --user "$U" --prefix "$PREFIX" --manifest "$TMP_MANIFEST" && ok "ログイン画面: ame-shell(greetd)" "login screen: ame-shell (greetd)"
            fi
            GREETD_DONE=1
        else
            later "sh $ROOT/scripts/greeter-setup.sh --user $U"
        fi
    fi
    # 4b. SDDM と、そのために入った KDE Plasma を消す(Chimera)。安全なときだけ聞く:
    #     ログイン画面が ame-shell(greetd)に設定済みで、いまのログインが greetd 経由(sddm が動いていない)。
    #     ame-shell が使うもの(KDE と一緒に入っていたもの)は残すよう明示する
    if command -v apk >/dev/null 2>&1 && apk info -e sddm >/dev/null 2>&1 &&
        grep -q "ame-greeter" /etc/greetd/config.toml 2>/dev/null &&
        ps -o comm= -A 2>/dev/null | grep -qx greetd && ! ps -o comm= -A 2>/dev/null | grep -qx sddm; then
        KEEP="greetd greetd-dinit thunar tumbler ffmpeg mpv-libs libpulse-progs xwayland upower power-profiles-daemon mesa-dri"
        if ask "ログイン画面は ame-shell で動いています。SDDM と、そのために入った KDE Plasma(800 以上のパッケージ)を消しますか?" \
            "The login screen runs on ame-shell. Remove SDDM and the KDE Plasma it pulled in (800+ packages)?"; then
            # shellcheck disable=SC2086
            if [ "$DRY" = 1 ]; then say "  (dry-run) apk add $KEEP '!sddm'"
            else apk add $KEEP '!sddm' && ok "SDDM と KDE を消しました" "removed SDDM and KDE"; fi
        else
            later "apk add $KEEP '!sddm'"
        fi
    fi
    # 5. SDDM を使うなら: ロック画面と同じ見た目にし、SDDM の設定を上書きする(scripts/sddm-theme.sh)。
    #    テーマ ame・ame-shell が背景や写真を書き出す置き場・weston のキオスク(kwin_wayland より軽い)
    if [ "$GREETD_DONE" = 0 ] && command -v sddm >/dev/null 2>&1 && [ -f "$ROOT/scripts/sddm-theme.sh" ]; then
        SDDM_CONF=/etc/sddm.conf.d/zz-ame.conf
        if grep -qx "$SDDM_CONF" "$MANIFEST" 2>/dev/null ||
            ask "ログイン画面(SDDM)をロック画面と同じ見た目にし、SDDM の設定を上書きしますか?(テーマ ame、コンポジタ weston)" \
                "Make the SDDM login screen look like the lock screen and override the SDDM settings? (theme ame, weston compositor)"; then
            if [ "$DRY" = 1 ]; then
                sh "$ROOT/scripts/sddm-theme.sh" --user "$U" --dry-run
            else
                sh "$ROOT/scripts/sddm-theme.sh" --user "$U" --manifest "$TMP_MANIFEST" && ok "SDDM: テーマ ame" "SDDM: theme ame"
            fi
        else
            later "sh $ROOT/scripts/sddm-theme.sh --user $U"
        fi
    fi
fi

# 記録(前回分とマージして重複を除く)
if [ "$DRY" = 0 ]; then
    mkdir -p "$(dirname "$MANIFEST")"
    printf '%s\n' "$RETIRED" | grep -v '^$' > "$TMP_MANIFEST.retired"
    { [ -f "$MANIFEST" ] && cat "$MANIFEST"; cat "$TMP_MANIFEST"; echo "$MANIFEST_REL"; } | sort -u |
        grep -vxF -f "$TMP_MANIFEST.retired" > "$MANIFEST.new"
    rm -f "$TMP_MANIFEST.retired"
    mv -f "$MANIFEST.new" "$MANIFEST"
    chmod 644 "$MANIFEST"
fi

# ---------------------------------------------------------------------------
# 確認(表示のみ)。TTY では英語
# ---------------------------------------------------------------------------
say ""
say "== $(m "確認" "Checks") =="
if [ "$OS" = FreeBSD ]; then PKG="pkg install"; else PKG="apk add"; fi
# chk <コマンド> <パッケージ> <日本語の用途> <英語の用途>
chk() {
    if command -v "$1" >/dev/null 2>&1; then say "  [ok] $1"
    else ng "$1 がありません($3: $PKG $2)" "$1 not found ($4: $PKG $2)"; fi
}
if [ "$USER_MODE" = 0 ]; then
    if command -v greetd >/dev/null 2>&1; then say "  [ok] greetd"
    elif command -v sddm >/dev/null 2>&1; then say "  [ok] sddm"
    else ng "ログイン画面(greetd)がありません($PKG greetd)" "no login manager (greetd) found ($PKG greetd)"; fi
fi
if command -v ghostty >/dev/null 2>&1 || [ -x "$DESTDIR$PREFIX/bin/ghostty" ]; then say "  [ok] ghostty"; else chk foot foot "端末(ghostty が無いので foot)" "terminal (foot; ghostty not found)"; fi
chk zsh zsh "端末のシェル" "terminal shell"
chk dbus-run-session dbus "D-Bus" "D-Bus"


[ "$OS" != FreeBSD ] && chk pactl libpulse-progs "音量・Bluetooth の音" "volume / Bluetooth audio"
[ "$OS" != FreeBSD ] && chk rfkill util-linux-rfkill "Wi-Fi・Bluetooth のブロック解除" "unblock Wi-Fi / Bluetooth"
if [ "$NEW_RIVER" = 1 ]; then
    ok "river $(river -version 2>&1)(ame-shell がウィンドウマネージャを兼ねます)" "river $(river -version 2>&1) (ame-shell acts as window manager)"
elif [ -x "$UHOME/.local/opt/river-0.5/bin/river" ] || [ -x "$DESTDIR$PREFIX/opt/river-0.5/bin/river" ]; then
    ok "River 0.5(ウィンドウアニメーションつきのセッションが使えます)" "River 0.5 (session with window animations)"
elif [ "$HAVE_RIVER03" = 1 ]; then
    ok "river $(river -version 2>&1)(River 0.5 が無いので River 0.3 のセッションだけが使えます)" "river $(river -version 2>&1) (no River 0.5: only the River 0.3 session works)"
else
    ng "River 0.5 も River 0.3 もありません(sh install.sh が River 0.5 をビルドします)" "Neither River 0.5 nor River 0.3 found (sh install.sh builds River 0.5)"
fi
if [ "$OS" = FreeBSD ]; then
    for svc in dbus seatd sddm; do
        if [ "$(sysrc -n "${svc}_enable" 2>/dev/null)" = YES ]; then say "  [ok] ${svc}_enable=YES"; else ng "${svc} が有効になっていません(例: sysrc ${svc}_enable=YES)" "${svc} is not enabled (e.g. sysrc ${svc}_enable=YES)"; fi
    done
elif command -v dinitctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    DM=sddm
    grep -q ame-greeter /etc/greetd/config.toml 2>/dev/null && DM=greetd
    for svc in dbus $DM networkmanager bluetoothd; do
        [ -f "/usr/lib/dinit.d/$svc" ] || [ -f "/etc/dinit.d/$svc" ] || continue
        # dbus は Chimera では dbus-daemon が起動時に動く(dbus はそれを包むだけ)
        if [ -e "/etc/dinit.d/boot.d/$svc" ] || [ -e "/usr/lib/dinit.d/boot.d/$svc" ] ||
            { [ "$svc" = dbus ] && { [ -e /usr/lib/dinit.d/boot.d/dbus-daemon ] || [ -e /etc/dinit.d/boot.d/dbus-daemon ]; }; }; then
            ok "dinit: $svc は有効" "dinit: $svc enabled"
        else
            ng "dinit のサービス $svc が有効になっていません(例: doas dinitctl enable $svc)" "dinit service $svc is not enabled (e.g. doas dinitctl enable $svc)"
        fi
    done
    if dinitctl --system status elogind 2>/dev/null | grep -q STARTED; then
        ok "dinit: elogind(libseat は logind 経由で動きます)" "dinit: elogind (libseat uses logind)"
    elif dinitctl --system status seatd 2>/dev/null | grep -q STARTED; then
        if in_group _seatd; then
            ok "seatd 起動中 / $U は _seatd グループ所属" "seatd running / $U is in group _seatd"
        else
            ng "seatd を使う場合は $U を _seatd グループへ(例: doas usermod -aG _seatd $U)" "With seatd, add $U to group _seatd (e.g. doas usermod -aG _seatd $U)"
        fi
    else
        ng "elogind も seatd も起動していません(例: doas dinitctl enable elogind)" "Neither elogind nor seatd is running (e.g. doas dinitctl enable elogind)"
    fi
fi
for g in video input; do
    if in_group "$g"; then
        ok "$U は $g グループ所属" "$U is in group $g"
    elif [ "$DRY" = 0 ] && id -Gn "$U" >/dev/null 2>&1 && getent group "$g" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -qx "$U"; then
        ok "$U は $g グループに追加済み(次のログインから)" "$U added to group $g (from next login)"
    else
        ng "$U は $g グループに未所属(明るさの変更・Super 単独のランチャーに必要)" "$U is not in group $g (needed for brightness and the Super-key launcher)"
    fi
done
if [ -n "$SETUP_LATER" ]; then
    say ""
    say "$(m "あとで root で行ってください:" "Please run later as root:")$SETUP_LATER"
fi

say ""
if [ "$USER_MODE" = 1 ]; then
    say "$(m "インストール完了(自分用、警告 $WARN 件)。" "Installed for this user ($WARN warning(s)).")"
    say "  $(m "起動: TTY でログインして" "Start: log in on a TTY and run")  $PREFIX/bin/ame-session --river5"
    say "  $(m "(SDDM の一覧に出すには、全ユーザー用のインストールが必要です: sh $0)" "(for the SDDM session list, install system-wide: sh $0)")"
    say "$(m "元に戻す" "Uninstall"): sh $0 --uninstall --user"
else
    if [ "$HAVE_RIVER03" = 0 ]; then
        if grep -q ame-greeter /etc/greetd/config.toml 2>/dev/null; then
            say "$(m "インストール完了(警告 $WARN 件)。再起動すると ame-shell のログイン画面が出ます。" "Installed ($WARN warning(s)). Reboot to get the ame-shell login screen.")"
        else
            say "$(m "インストール完了(警告 $WARN 件)。ログイン画面で \"Ame Shell\" を選んでください。" "Installed ($WARN warning(s)). Choose \"Ame Shell\" on the login screen.")"
        fi
    else
        say "$(m "インストール完了(警告 $WARN 件)。SDDM で \"Ame Shell\"(River 0.3)か \"Ame Shell (River 0.5)\" を選んでください。" "Installed ($WARN warning(s)). Choose \"Ame Shell\" (River 0.3) or \"Ame Shell (River 0.5)\" in SDDM.")"
    fi
    say "$(m "元に戻す" "Uninstall"): sh $0 --uninstall"
fi
exit 0
