#!/bin/sh
# freebsd-wifi.sh: FreeBSD の Wi-Fi を ame-shell のパネルから操作できるようにする(root で実行)。POSIX sh。
#   sh scripts/freebsd-wifi.sh [--user 名前]   設定する(install-freebsd.sh / ame-update からも呼ばれる)
#   sh scripts/freebsd-wifi.sh --check         今の状態を表示するだけ(root でなくてもよい)
#
# FreeBSD の Wi-Fi は wpa_supplicant(NetworkManager は無い)。ame-shell のパネルは wpa_cli で
# スキャン・接続・切断をするので、一般ユーザーが wpa_supplicant の操作口(ソケット)に入れるようにする:
#   - wlan0 が無ければ、net.wlan.devices の最初の無線デバイスから作る(rc.conf の wlans_<dev> と ifconfig_wlan0)
#   - /etc/wpa_supplicant.conf に ctrl_interface(GROUP=network)と update_config=1(パネルで追加した
#     ネットワークを保存できるように)。元のファイルは /etc/wpa_supplicant.conf.ame-bak に残す
#   - 使う人を network グループに入れる(反映は次のログインから)

info() { printf '    %s\n' "$*"; }
CONF=${AME_WPA_CONF:-/etc/wpa_supplicant.conf}  # 試験用に差し替えられる

check() {
    echo "== 無線デバイス / インターフェース"
    info "net.wlan.devices=$(sysctl -n net.wlan.devices 2>/dev/null)"
    info "IF: $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^wlan' | tr '\n' ' ')"
    for v in $(sysrc -a 2>/dev/null | grep -E '^(wlans_|ifconfig_wlan)' | cut -d: -f1); do info "$v=$(sysrc -n "$v")"; done
    echo "== $CONF"
    grep -E '^(ctrl_interface|update_config)' "$CONF" 2>/dev/null | sed 's/^/    /'
    grep -c '^network=' "$CONF" 2>/dev/null | sed 's/^/    保存済みのネットワーク: /'
    echo "== 操作口"
    ls -l /var/run/wpa_supplicant 2>/dev/null | sed 's/^/    /'
    info "network グループ: $(pw groupshow network 2>/dev/null)"
    if wpa_cli status >/dev/null 2>&1; then info "wpa_cli: このユーザーで操作できます"; else info "wpa_cli: このユーザーでは操作できません"; fi
}

USER_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check; exit 0 ;;
        --user) USER_NAME="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[ "$(id -u)" = 0 ] || { echo "root で実行してください: doas sh $0(状態を見るだけなら --check)" >&2; exit 1; }
[ -n "$USER_NAME" ] || USER_NAME="${DOAS_USER:-${SUDO_USER:-$(logname 2>/dev/null || true)}}"

# ---- wlan0 ----
wlan=$(ifconfig -l | tr ' ' '\n' | grep '^wlan' | head -n 1)
if [ -z "$wlan" ]; then
    dev=$(sysctl -n net.wlan.devices 2>/dev/null | awk '{print $1}')
    if [ -z "$dev" ]; then
        info "(無線 LAN のデバイスが見つかりません。ドライバが読み込まれているか確認してください: dmesg | grep -i wlan)"
        exit 0
    fi
    sysrc "wlans_$dev=wlan0" >/dev/null && info "wlans_$dev=wlan0"
    sysrc ifconfig_wlan0="WPA SYNCDHCP" >/dev/null && info 'ifconfig_wlan0="WPA SYNCDHCP"'
    wlan=wlan0
    NEW_IF=1
fi
info "無線 LAN: $wlan"

# ---- wpa_supplicant.conf ----
[ -f "$CONF" ] || : > "$CONF"
[ -f "$CONF.ame-bak" ] || cp -p "$CONF" "$CONF.ame-bak"
if grep -q '^ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=network$' "$CONF" && grep -q '^update_config=1$' "$CONF"; then
    info "$CONF は設定済み"
    CHANGED=0
else
    tmp=$(mktemp "$CONF.XXXXXX") || exit 1
    {
        echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=network"
        echo "update_config=1"
        grep -vE '^(ctrl_interface|ctrl_interface_group|update_config)=' "$CONF"
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONF"
    info "$CONF: ctrl_interface(GROUP=network)と update_config=1 を設定(元は $CONF.ame-bak)"
    CHANGED=1
fi

# ---- グループ ----
if [ -n "$USER_NAME" ] && id "$USER_NAME" >/dev/null 2>&1; then
    if id -Gn "$USER_NAME" | tr ' ' '\n' | grep -qx network; then
        info "$USER_NAME は network グループに入っています"
    else
        pw groupmod network -m "$USER_NAME" && info "$USER_NAME を network グループへ(次のログインから有効)"
    fi
fi

# ---- 反映: wpa_supplicant を起動し直す(数秒切れる)----
if [ "${NEW_IF:-0}" = 1 ]; then
    service netif restart >/dev/null 2>&1 || true
    info "wlan0 を作りました(つながらなければ再起動してください)"
elif [ "$CHANGED" = 1 ]; then
    service netif restart "$wlan" >/dev/null 2>&1 || true
    info "wpa_supplicant を起動し直しました"
fi
