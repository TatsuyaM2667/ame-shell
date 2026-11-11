#!/bin/sh
# refcheck.sh: 学習ページのコードの参照を確かめる(refcheck.zig を ame-shell の Zig 0.13 で動かす)。POSIX sh。
#   sh learn/tools/refcheck.sh [フォルダ]
# refcheck.zig は Zig 0.13 の std.fs を使う(0.16 以降はファイルの API が変わったため、0.13 を探して使う)。
set -eu
case "$0" in */*) HERE=$(cd "$(dirname "$0")" && pwd) ;; *) HERE=$(pwd) ;; esac
cd "$HERE/../.."
ZIG=zig
T="${XDG_CACHE_HOME:-$HOME/.cache}/ame-shell/toolchain/zig-linux-x86_64-0.13.0/zig"
[ -x "$T" ] && ZIG=$T
exec "$ZIG" run learn/tools/refcheck.zig -- "$@"
