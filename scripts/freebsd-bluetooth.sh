#!/bin/sh
# freebsd-bluetooth.sh: FreeBSD で内蔵の Bluetooth を使えるようにする(root で実行)。POSIX sh。
#   sh scripts/freebsd-bluetooth.sh           設定する(install-freebsd.sh / ame-update からも呼ばれる)
#   sh scripts/freebsd-bluetooth.sh --check   今の状態を表示するだけ(root でなくてもよい)
#
# FreeBSD の Bluetooth は netgraph(ng_ubt)+ hcsecd(ペアリングの鍵)+ sdpd + bthidd(マウス・キーボード)。
# Realtek / Intel の USB アダプタは、つなぐたびに devd が rtlbtfw / iwmbtfw でファームウェアを書き込む
# (ファームウェア本体は pkg の rtlbt-firmware / iwmbt-firmware)。MediaTek などは FreeBSD 側が未対応。
# 機器のペアリングは root で: bluetooth-config scan(マウス・キーボードは bthidd で自動接続)。

info() { printf '    %s\n' "$*"; }

# USB の Bluetooth アダプタ(クラス 0xe0)の vendor:product
usb_bt() {
    usbconfig 2>/dev/null | sed -n 's/^\(ugen[0-9.]*\):.*/\1/p' | while read -r u; do
        d=$(usbconfig -d "$u" dump_device_desc 2>/dev/null)
        v=$(printf '%s\n' "$d" | awk '/idVendor/ {print $3; exit}')
        p=$(printf '%s\n' "$d" | awk '/idProduct/ {print $3; exit}')
        cls=$(printf '%s\n' "$d" | awk '/bDeviceClass/ {print $3; exit}')
        ifc=$(usbconfig -d "$u" dump_curr_config_desc 2>/dev/null | awk '/bInterfaceClass/ {print $3; exit}')
        case "$cls$ifc" in *0x00e0*) echo "$u $v $p" ;; esac
    done
}

check() {
    echo "== USB の Bluetooth アダプタ"
    usb_bt | sed 's/^/    /'
    echo "== ドライバ・サービス"
    for m in ng_ubt ng_hci ng_l2cap ng_btsocket; do
        if kldstat -q -m "$m" 2>/dev/null || kldstat -q -n "$m" 2>/dev/null; then info "$m: あり"; else info "$m: なし"; fi
    done
    for s in hcsecd sdpd bthidd; do info "${s}_enable=$(sysrc -n ${s}_enable 2>/dev/null)"; done
    for p in rtlbt-firmware iwmbt-firmware; do pkg info -e "$p" 2>/dev/null && info "$p: あり"; done
    echo "== HCI(ubt0hci があればアダプタは動いている)"
    ngctl list 2>/dev/null | grep -i hci | sed 's/^/    /'
    hccontrol -n ubt0hci read_bd_addr 2>&1 | sed 's/^/    /'
    dmesg 2>/dev/null | grep -iE 'ubt[0-9]|rtlbtfw|iwmbtfw|bluetooth' | tail -n 10 | sed 's/^/    /'
}

if [ "${1:-}" = --check ]; then
    check
    exit 0
fi
[ "$(id -u)" = 0 ] || { echo "root で実行してください: doas sh $0(状態を見るだけなら --check)" >&2; exit 1; }

found=$(usb_bt)
if [ -z "$found" ]; then
    info "(USB の Bluetooth アダプタが見つかりません。Bluetooth の設定はしません)"
    exit 0
fi
printf '%s\n' "$found" | while read -r u v p; do info "Bluetooth アダプタ: $u ($v:$p)"; done

# ファームウェア(Realtek: 0x0bda、Intel: 0x8087)
case "$found" in
    *" 0x0bda "*) fw=rtlbt-firmware ;;
    *" 0x8087 "*) fw=iwmbt-firmware ;;
    *) fw="" ;;
esac
if [ -n "$fw" ]; then
    if pkg info -e "$fw"; then
        info "$fw は導入済み"
    else
        pkg install -y "$fw" || info "$fw を入れられませんでした"
    fi
fi

# ドライバとサービス
cur=$(sysrc -n kld_list 2>/dev/null || true)
case " $cur " in *" ng_ubt "*) ;; *) sysrc kld_list+=" ng_ubt" >/dev/null && info "kld_list に ng_ubt を追加" ;; esac
for s in hcsecd sdpd bthidd; do
    sysrc "${s}_enable=YES" >/dev/null && info "${s}_enable=YES"
done
# 今すぐ: ファームウェアを書き込ませる(devd がアダプタを見つけ直す)→ ドライバ → サービス
kldstat -q -n ng_ubt 2>/dev/null || kldload -n ng_ubt 2>/dev/null || true
service devd restart >/dev/null 2>&1 || true
sleep 2
for s in hcsecd sdpd bthidd; do
    service "$s" status >/dev/null 2>&1 || service "$s" start >/dev/null 2>&1 || true
done
if hccontrol -n ubt0hci read_bd_addr >/dev/null 2>&1; then
    info "Bluetooth アダプタが動きました(機器のペアリング: doas bluetooth-config scan)"
else
    info "Bluetooth は再起動後に使えるようになります(確認: sh $0 --check)"
fi
