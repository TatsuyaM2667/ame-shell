#!/bin/sh
# zram-setup.sh: メモリを圧縮して使うスワップ(zram)を有効にする(Chimera Linux / dinit)。POSIX sh。
#
# スワップの無い機械はメモリが尽きると、OOM キラーが動く前に何分も固まる。zram は RAM の中に圧縮した
# スワップを作るので(ディスクに書かない)、溢れた分を 1/3 ほどに縮めて逃がせる。
#
# 使い方: doas sh scripts/zram-setup.sh [大きさ(既定: RAM の半分)]
#         doas sh scripts/zram-setup.sh --remove     (やめる)
# 書くもの: /etc/dinit-zram.conf(zram0 の設定)、/etc/fstab に /dev/zram0 のスワップの行。どちらも元を .ame-bak に残す。
set -eu

CONF=/etc/dinit-zram.conf
FSTAB=/etc/fstab
LINE='/dev/zram0 none swap defaults,pri=100 0 0'

if [ "$(id -u)" -ne 0 ]; then
    echo "root で実行してください: doas sh $0" >&2
    exit 1
fi

if [ "${1:-}" = "--remove" ]; then
    swapoff /dev/zram0 2>/dev/null || true
    dinitctl disable zram-device@zram0 2>/dev/null || true
    if [ -f "$FSTAB" ] && grep -q '^/dev/zram0 ' "$FSTAB"; then
        cp -p "$FSTAB" "$FSTAB.ame-bak"
        grep -v '^/dev/zram0 ' "$FSTAB.ame-bak" > "$FSTAB"
    fi
    [ -f "$CONF" ] && mv -f "$CONF" "$CONF.ame-bak"
    echo "zram をやめました(元の設定は .ame-bak)"
    exit 0
fi

# 大きさ: 指定が無ければ RAM の半分(MiB)
if [ -n "${1:-}" ]; then
    SIZE=$1
else
    SIZE="$(awk '/^MemTotal:/{print int($2 / 1024 / 2)}' /proc/meminfo)M"
fi

[ -f "$CONF" ] && cp -p "$CONF" "$CONF.ame-bak"
cat > "$CONF" <<EOF
; ame-shell の scripts/zram-setup.sh が書いた(圧縮したスワップ)
[zram0]
size = $SIZE
algorithm = zstd
format = mkswap -U clear %0
EOF

if ! grep -q '^/dev/zram0 ' "$FSTAB" 2>/dev/null; then
    [ -f "$FSTAB" ] && cp -p "$FSTAB" "$FSTAB.ame-bak"
    printf '%s\n' "$LINE" >> "$FSTAB"
fi

dinitctl enable zram-device@zram0
# 今すぐ使う(次の起動からは fstab で有効になる)
swapon -p 100 /dev/zram0 2>/dev/null || true
echo "zram を有効にしました($SIZE、zstd):"
cat /proc/swaps
