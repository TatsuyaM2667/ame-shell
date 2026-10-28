#!/bin/sh
# install-session.sh: ame-shell をインストール/アンインストールする。冪等。POSIX sh のみ。
#
#   sh session/install-session.sh                 全ユーザー用(/usr/local)+ SDDM のセッション。
#                                                 root でなければ doas / sudo で自動的に昇格する
#   sh session/install-session.sh --user          自分だけ(~/.local)。root 不要。SDDM のセッションは作れない
#   sh session/install-session.sh --uninstall [--user]
#   その他: --prefix DIR / --destdir DIR(疑似 root への試験)/ --dry-run
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
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
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
    for d in "$DESTDIR$PREFIX/share/ame-shell/widgets" "$DESTDIR$PREFIX/share/ame-shell/xdg/foot" "$DESTDIR$PREFIX/share/ame-shell/xdg" "$DESTDIR$PREFIX/share/ame-shell" "$DESTDIR$PREFIX/opt/river-0.5/bin" "$DESTDIR$PREFIX/opt/river-0.5"; do
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

# システムの river が 0.4 以降か(FreeBSD の river パッケージなど)。0.4 以降は River 0.3 用の init が動かないので、
# 内蔵ウィンドウマネージャで動くセッションだけを入れる
NEW_RIVER=0
if command -v river >/dev/null 2>&1; then
    case "$(river -version 2>&1)" in 0.[4-9]*|[1-9]*) NEW_RIVER=1 ;; esac
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

# ---- PAM の置き場所(Linux のみ。FreeBSD のロックは setuid の swaylock に任せるので不要) ----
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

say "インストール先: ${DESTDIR}${PREFIX}($( [ "$USER_MODE" = 1 ] && echo "自分用" || echo "全ユーザー用"))"
install_file "$OUT/bin/ame-shell" "$PREFIX/bin/ame-shell" 755
install_file "$OUT/bin/ame-ctl" "$PREFIX/bin/ame-ctl" 755
install_file "$HERE/ame-session" "$PREFIX/bin/ame-session" 755
install_file "$HERE/ame-update" "$PREFIX/bin/ame-update" 755
# ame-update が git pull してビルドし直すための、ソースの場所の記録
tmp=$(mktemp "${TMPDIR:-/tmp}/ame-src.XXXXXX") || exit 1
echo "$ROOT" > "$tmp"
install_file "$tmp" "$PREFIX/share/ame-shell/source" 644
rm -f "$tmp"
install_file "$HERE/ame-river-init" "$PREFIX/share/ame-shell/ame-river-init" 755
install_file "$HERE/ame-river5-init" "$PREFIX/share/ame-shell/ame-river5-init" 755
install_file "$OUT/share/ame-shell/config.ame" "$PREFIX/share/ame-shell/config.ame" 644
install_file "$OUT/share/ame-shell/bt-connect.sh" "$PREFIX/share/ame-shell/bt-connect.sh" 755
install_file "$OUT/share/ame-shell/xdg/foot/foot.ini" "$PREFIX/share/ame-shell/xdg/foot/foot.ini" 644
for w in "$OUT"/share/ame-shell/widgets/*.wasm; do
    [ -f "$w" ] || continue
    install_file "$w" "$PREFIX/share/ame-shell/widgets/$(basename "$w")" 644
done

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
    if [ "$NEW_RIVER" = 1 ]; then
        # River 0.4 以降しか無い: 内蔵 WM のセッションだけを「Ame Shell」として入れる
        DESKTOPS="ame-shell-river5"
    else
        DESKTOPS="ame-shell ame-shell-safe ame-shell-river5"
    fi
    for d in $DESKTOPS; do
        tmp=$(mktemp "${TMPDIR:-/tmp}/ame-desktop.XXXXXX") || exit 1
        if [ "$NEW_RIVER" = 1 ]; then
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

# 記録(前回分とマージして重複を除く)
if [ "$DRY" = 0 ]; then
    mkdir -p "$(dirname "$MANIFEST")"
    { [ -f "$MANIFEST" ] && cat "$MANIFEST"; cat "$TMP_MANIFEST"; echo "$MANIFEST_REL"; } | sort -u > "$MANIFEST.new"
    mv -f "$MANIFEST.new" "$MANIFEST"
    chmod 644 "$MANIFEST"
fi

# ---------------------------------------------------------------------------
# 前提チェック(表示のみ。設定は変更しない)
# ---------------------------------------------------------------------------
say ""
say "== 前提チェック =="
if [ "$OS" = FreeBSD ]; then PKG="pkg install"; else PKG="apk add"; fi
chk() { if command -v "$1" >/dev/null 2>&1; then say "  [ok] $1"; else warn "$1 がありません ($2)"; fi; }
chk river "$PKG river"
[ "$USER_MODE" = 0 ] && chk sddm "$PKG sddm"
chk foot "$PKG foot"
chk dbus-run-session "$PKG dbus"
chk playerctl "メディア表示に必要: $PKG playerctl"
if [ "$NEW_RIVER" = 1 ]; then
    say "  [ok] river $(river -version 2>&1)(ame-shell がウィンドウマネージャを兼ねます)"
elif [ -x "$UHOME/.local/opt/river-0.5/bin/river" ] || [ -x "$DESTDIR$PREFIX/opt/river-0.5/bin/river" ]; then
    say "  [ok] River 0.5(ウィンドウアニメーションつきのセッションが使えます)"
else
    say "  (River 0.5 が無いため「Ame Shell (River 0.5)」は River 0.3 で起動します)"
fi
if [ "$OS" = FreeBSD ]; then
    for svc in dbus seatd sddm; do
        if [ "$(sysrc -n "${svc}_enable" 2>/dev/null)" = YES ]; then say "  [ok] ${svc}_enable=YES"; else warn "${svc} が有効になっていません(例: sysrc ${svc}_enable=YES)"; fi
    done
    chk swaylock "ロックに必要: pkg install swaylock"
elif command -v dinitctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    for svc in sddm dbus; do
        if dinitctl --system status "$svc" 2>/dev/null | grep -q STARTED; then
            say "  [ok] dinit: $svc は起動中"
        else
            warn "dinit サービス $svc が起動していません(例: doas dinitctl enable $svc)"
        fi
    done
    if dinitctl --system status elogind 2>/dev/null | grep -q STARTED; then
        say "  [ok] dinit: elogind(libseat は logind 経由で動きます)"
    elif dinitctl --system status seatd 2>/dev/null | grep -q STARTED; then
        if id -Gn "$U" 2>/dev/null | tr ' ' '\n' | grep -qx _seatd; then
            say "  [ok] seatd 起動中 / $U は _seatd グループ所属"
        else
            warn "seatd を使う場合は $U を _seatd グループへ(例: doas usermod -aG _seatd $U)"
        fi
    else
        warn "elogind も seatd も起動していません(例: doas dinitctl enable elogind)"
    fi
fi
for g in video input; do
    if id -Gn "$U" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then say "  [ok] $U は $g グループ所属"; else warn "$U は $g グループに未所属(明るさ変更・Super 単独のランチャーに必要な場合あり)"; fi
done

say ""
if [ "$USER_MODE" = 1 ]; then
    say "インストール完了(自分用、警告 $WARN 件)。"
    say "  起動: TTY でログインして  $PREFIX/bin/ame-session --river5"
    say "  (SDDM の一覧に出すには、全ユーザー用のインストールが必要です: sh $0)"
    say "元に戻す: sh $0 --uninstall --user"
else
    if [ "$NEW_RIVER" = 1 ]; then
        say "インストール完了(警告 $WARN 件)。SDDM で \"Ame Shell\" を選んでください。"
    else
        say "インストール完了(警告 $WARN 件)。SDDM で \"Ame Shell (Safe Mode)\" → \"Ame Shell\" の順に試してください。"
    fi
    say "元に戻す: sh $0 --uninstall"
fi
exit 0
