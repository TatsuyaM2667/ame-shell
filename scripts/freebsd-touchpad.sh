#!/bin/sh
# freebsd-touchpad.sh: FreeBSD でノート PC のタッチパッドを使えるようにする(root で実行)。POSIX sh。
#   sh scripts/freebsd-touchpad.sh           設定する(install-freebsd.sh からも呼ばれる)。反映は再起動後
#   sh scripts/freebsd-touchpad.sh --check   今の状態を表示するだけ(root でなくてもよい)
#
# タッチパッドのつながり方は 2 通り:
#   - I2C(最近のノート PC の多く。ACPI の PNP0C50): ig4(I2C コントローラ)+ iichid + hmt(マルチタッチ)。
#     iichid は GPIO 割り込みに未対応で、その場合は自動でポーリング(sampling mode)になる
#   - PS/2: psm の Synaptics / Elantech / TrackPoint 対応を loader.conf で有効にする
# USB マウスは何もしなくても使える(usbhid / ums)。

info() { printf '    %s\n' "$*"; }

check() {
    echo "== タッチパッドらしい機器(ACPI / dmesg)"
    devinfo -v 2>/dev/null | grep -iE 'PNP0C50|ACPI0C50|ELAN|SYNA|GXTP|MSFT0001|iichid|hmt|psm' | sed 's/^ */    /' | head -n 20
    dmesg 2>/dev/null | grep -iE 'iichid|hmt[0-9]|ig4iic|psm0|synaptics|elantech|amdgpio' | sed 's/^/    /' | tail -n 20
    echo "== 読み込まれているモジュール"
    for m in ig4 iichid hidbus hmt hms amdgpio; do
        if kldstat -q -m "$m" 2>/dev/null || kldstat -q -n "$m" 2>/dev/null; then info "$m: あり"; else info "$m: なし"; fi
    done
    echo "== loader.conf / rc.conf"
    grep -E '^(hw\.psm\.|ig4|iichid|hmt|amdgpio)' /boot/loader.conf 2>/dev/null | sed 's/^/    /'
    info "kld_list=$(sysrc -n kld_list 2>/dev/null)"
    echo "== 入力デバイス(/dev/input)"
    for d in /dev/input/event*; do
        [ -e "$d" ] || continue
        n=$(sysctl -n "kern.evdev.input.${d#/dev/input/event}.name" 2>/dev/null)
        info "$d  $n"
    done
    if command -v libinput >/dev/null 2>&1; then
        echo "== libinput list-devices(タッチパッドは Capabilities に pointer、Tap-to-click がある)"
        libinput list-devices 2>/dev/null | grep -E '^(Device|Capabilities|Tap-to-click):' | sed 's/^/    /'
    fi
}

if [ "${1:-}" = --check ]; then
    check
    exit 0
fi
[ "$(id -u)" = 0 ] || { echo "root で実行してください: doas sh $0(状態を見るだけなら --check)" >&2; exit 1; }

add_kld() {
    cur=$(sysrc -n kld_list 2>/dev/null || true)
    case " $cur " in *" $1 "*) ;; *) sysrc kld_list+=" $1" >/dev/null && info "kld_list に $1 を追加" ;; esac
}

# I2C のタッチパッド
add_kld ig4
add_kld iichid
add_kld hmt
# 今すぐ読み込む(読み込めれば再起動しなくても動く)
for m in ig4 iichid hmt; do kldstat -q -n "$m" 2>/dev/null || kldload -n "$m" 2>/dev/null || true; done
# PS/2 のタッチパッド
for kv in hw.psm.synaptics_support hw.psm.elantech_support hw.psm.trackpoint_support; do
    if ! grep -q "^$kv=" /boot/loader.conf 2>/dev/null; then
        echo "$kv=\"1\"" >> /boot/loader.conf
        info "/boot/loader.conf に $kv=\"1\" を追加"
    fi
done
info "タッチパッドの設定をしました(再起動後に有効。確認: sh $0 --check)"
