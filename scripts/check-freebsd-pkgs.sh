#!/bin/sh
# check-freebsd-pkgs.sh: install-freebsd.sh に書いたパッケージ名が、FreeBSD の公式リポジトリに
# 実在するかを確かめる(FreeBSD 14 / 15 × quarterly(既定)/ latest)。Linux からでも実行できる。POSIX sh。
#
#   sh scripts/check-freebsd-pkgs.sh
#
# 必須(REQUIRED)のパッケージが 1 つでも欠けていれば終了コード 1。
# 任意(OPTIONAL)は「a|b」のどれか 1 つがあれば可、無ければ警告だけ(インストーラは飛ばして続ける)。

set -eu
case "$0" in */*) HERE=$(cd "$(dirname "$0")" && pwd) ;; *) HERE=$(pwd) ;; esac
SCRIPT="$HERE/install-freebsd.sh"
WORK="${TMPDIR:-/tmp}/ame-pkgcheck"
mkdir -p "$WORK"

# install-freebsd.sh の REQUIRED="…" / OPTIONAL="…" と、日本語入力の追加分を取り出す
block() { awk -v v="$1" '$0 ~ "^"v"=\"" {f=1; next} f && /^"/ {f=0} f' "$SCRIPT"; }
REQUIRED=$(block REQUIRED)
OPTIONAL="$(block OPTIONAL) $(sed -n 's/.*OPTIONAL="\$OPTIONAL \(.*\)"$/\1/p' "$SCRIPT")"
GPU="drm-kmod nvidia-drm-kmod"

fail=0
for v in 14 15; do
    for b in quarterly latest; do
        d="$WORK/$v-$b"
        mkdir -p "$d"
        if [ ! -s "$d/packagesite.yaml" ] || [ -n "$(find "$d/packagesite.yaml" -mtime +1 2>/dev/null)" ]; then
            curl -sfL -o "$d/site.pkg" "https://pkg.freebsd.org/FreeBSD:$v:amd64/$b/packagesite.pkg" || { echo "取得失敗: $v/$b"; fail=1; continue; }
            tar -xf "$d/site.pkg" -C "$d" packagesite.yaml
        fi
        has() { grep -q "^{\"name\":\"$1\"," "$d/packagesite.yaml"; }
        miss_req=""
        miss_opt=""
        for p in $REQUIRED $GPU; do has "$p" || miss_req="$miss_req $p"; done
        for spec in $OPTIONAL; do
            ok=0
            old_ifs=$IFS; IFS='|'
            for c in $spec; do has "$c" && ok=1; done
            IFS=$old_ifs
            [ "$ok" = 1 ] || miss_opt="$miss_opt $spec"
        done
        if [ -n "$miss_req" ]; then
            echo "NG  FreeBSD $v / $b: 必須が無い:$miss_req"
            fail=1
        else
            echo "OK  FreeBSD $v / $b${miss_opt:+(任意で無いもの:$miss_opt)}"
        fi
    done
done
exit $fail
