#!/bin/sh
# check-real.sh: 教材の説明が「本物のコード」と合っているかを確かめる。POSIX sh。
#   anim/anim.odin を Odin でオブジェクトにし、learn/*/real_test.zig(演習と同じ不変条件・本文の数値)を当てる。
# 使い方: sh learn/check-real.sh
# 要るもの: odin・zig(どちらも ame-shell のビルドに使うもの)
set -eu
case "$0" in */*) HERE=$(cd "$(dirname "$0")" && pwd) ;; *) HERE=$(pwd) ;; esac
REPO=$(cd "$HERE/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT INT TERM

case "$(uname -s)-$(uname -m)" in
    FreeBSD-arm64 | FreeBSD-aarch64) T=freebsd_arm64 ;;
    FreeBSD-*) T=freebsd_amd64 ;;
    *-aarch64 | *-arm64) T=linux_arm64 ;;
    *) T=linux_amd64 ;;
esac

echo "==> anim/anim.odin を Odin でオブジェクトに($T)"
odin build "$REPO/anim" -build-mode:obj -no-entry-point -o:speed -no-bounds-check \
    -default-to-nil-allocator -no-thread-local -reloc-mode:pic -target:$T -out:"$TMP/anim.o"

status=0
for t in "$HERE"/*/real_test.zig; do
    echo "==> $t"
    zig test "$t" "$TMP/anim.o" || status=1
done
[ $status -eq 0 ] && echo "==> 教材の説明と本物のコードは一致しています"
exit $status
