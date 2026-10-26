#!/bin/sh
# install-session.sh: Ame Shell を SDDM のセッションとしてインストール/アンインストールする。
# root で実行する前提(--destdir 指定時は一般ユーザーでも可)。冪等。POSIX sh のみ。
#
#   sh session/install-session.sh [--prefix /usr/local] [--destdir DIR] [--dry-run]
#   sh session/install-session.sh --uninstall [--prefix /usr/local] [--destdir DIR]
#
# 入力は zig-out/ のビルド成果物とこのリポジトリ内のファイルだけ(ここではビルドしない)。
# 追加したファイルは $PREFIX/share/ame-shell/installed-files に記録し、--uninstall はそれだけを消す。

set -u
PREFIX=/usr/local
DESTDIR=""
UNINSTALL=0
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --destdir) DESTDIR="$2"; shift 2 ;;
        --destdir=*) DESTDIR="${1#*=}"; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

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
    for d in "$DESTDIR$PREFIX/share/ame-shell/widgets" "$DESTDIR$PREFIX/share/ame-shell"; do
        [ -d "$d" ] && run rmdir "$d" 2>/dev/null
    done
    say "完了しました。"
    exit 0
fi

# ---------------------------------------------------------------------------
# 事前確認
# ---------------------------------------------------------------------------
for f in "$OUT/bin/ame-shell" "$OUT/bin/ame-ctl" "$OUT/share/ame-shell/config.ame" "$HERE/ame-session" "$HERE/ame-river-init"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f がありません。先に 'zig build -Doptimize=ReleaseFast' を実行してください。" >&2
        exit 1
    fi
done
if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ] && [ "$DRY" = 0 ]; then
    echo "ERROR: root で実行してください(例: doas sh $0)。試験なら --destdir を指定。" >&2
    exit 1
fi

# ---- SDDM が読むセッションディレクトリ ----
# 優先順位: /usr/lib/sddm/sddm.conf.d/* < /etc/sddm.conf.d/* < /etc/sddm.conf。後から読んだ値で上書き。
SESS_DIRS=""
for f in /usr/lib/sddm/sddm.conf.d/*.conf /etc/sddm.conf.d/*.conf /etc/sddm.conf; do
    [ -f "$f" ] || continue
    v=$(awk -F= '/^\[/{sec=$0} sec=="[Wayland]" && $1=="SessionDir"{print $2}' "$f" | tail -n 1)
    [ -n "$v" ] && SESS_DIRS="$v"
done
[ -n "$SESS_DIRS" ] || SESS_DIRS="/usr/share/wayland-sessions"
SESS_DIR=""
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

# ---- PAM の置き場所 ----
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

say "インストール先: ${DESTDIR}${PREFIX}"
install_file "$OUT/bin/ame-shell" "$PREFIX/bin/ame-shell" 755
install_file "$OUT/bin/ame-ctl" "$PREFIX/bin/ame-ctl" 755
install_file "$HERE/ame-session" "$PREFIX/bin/ame-session" 755
install_file "$HERE/ame-river-init" "$PREFIX/share/ame-shell/ame-river-init" 755
install_file "$OUT/share/ame-shell/config.ame" "$PREFIX/share/ame-shell/config.ame" 644
for w in "$OUT"/share/ame-shell/widgets/*.wasm; do
    [ -f "$w" ] || continue
    install_file "$w" "$PREFIX/share/ame-shell/widgets/$(basename "$w")" 644
done

# .desktop: @PREFIX@ を実際のパスに置換(sed -i は使わない: BSD/GNU で書式が違うため)
for d in ame-shell ame-shell-safe; do
    tmp=$(mktemp "${TMPDIR:-/tmp}/ame-desktop.XXXXXX") || exit 1
    sed "s|@PREFIX@|$PREFIX|g" "$HERE/$d.desktop" > "$tmp"
    install_file "$tmp" "$SESS_DIR/$d.desktop" 644
    rm -f "$tmp"
done

# PAM(ロック画面用)
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
U="${DOAS_USER:-${SUDO_USER:-$(id -un)}}"
chk() { if command -v "$1" >/dev/null 2>&1; then say "  [ok] $1"; else warn "$1 がありません ($2)"; fi; }
chk river "doas apk add river"
chk sddm "doas apk add sddm"
chk foot "doas apk add foot"
chk rivertile "river に同梱"
chk dbus-run-session "doas apk add dbus"
chk wpctl "音量表示に必要: doas apk add wireplumber"
chk playerctl "メディア表示に必要: doas apk add playerctl"
if ! command -v dinitctl >/dev/null 2>&1; then
    say "  (dinit が無いためサービス確認を省略)"
elif [ "$(id -u)" -ne 0 ]; then
    say "  (root でないため dinit のシステムサービスは確認できません。root で実行すると確認します)"
else
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
if grep -qs pam_turnstile /etc/pam.d/system-login /usr/lib/pam.d/system-login; then
    say "  [ok] PAM に pam_turnstile があります(XDG_RUNTIME_DIR が用意されます)"
else
    warn "PAM に pam_turnstile が見当たりません(XDG_RUNTIME_DIR は ame-session が代替を作ります)"
fi
for g in video input; do
    if id -Gn "$U" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then say "  [ok] $U は $g グループ所属"; else warn "$U は $g グループに未所属(明るさ変更などに必要な場合あり)"; fi
done

say ""
say "インストール完了(警告 $WARN 件)。SDDM で \"Ame Shell (Safe Mode)\" → \"Ame Shell\" の順に試してください。"
say "元に戻す: doas sh $0 --uninstall --prefix $PREFIX"
exit 0
