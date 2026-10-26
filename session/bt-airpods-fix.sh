#!/bin/sh
# bt-airpods-fix.sh: AirPods などのイヤホンが「br-connection-refused」で繋がらない・すぐ切れる問題の対策。
# root で実行する(例: doas sh session/bt-airpods-fix.sh)。POSIX sh のみ。冪等。
#
# /etc/bluetooth/main.conf の [General] に次を設定して bluetoothd を再起動する:
#   ControllerMode = bredr        … イヤホンへは従来の Bluetooth(BR/EDR)だけで接続する
#                                   (AirPods は LE でも応答するため、LE で繋ごうとして拒否されることがある)
#   JustWorksRepairing = always   … 機器側でペアリングし直したとき(古い鍵)でも再ペアリングを受け入れる
#   FastConnectable = true        … 機器からの自動接続に素早く応答する
# 元のファイルは main.conf.ame-bak に退避する。元に戻す: sh bt-airpods-fix.sh --undo
# 注意: ControllerMode = bredr にすると Bluetooth LE 専用の機器(一部のマウス・センサー等)は使えなくなる。

set -u
CONF=/etc/bluetooth/main.conf
BAK=$CONF.ame-bak

if [ "$(id -u)" -ne 0 ]; then
    echo "root で実行してください(例: doas sh $0)" >&2
    exit 1
fi

restart_bt() {
    if command -v dinitctl >/dev/null 2>&1; then
        dinitctl restart bluetoothd && echo "bluetoothd を再起動しました"
    else
        echo "bluetoothd を手動で再起動してください"
    fi
}

if [ "${1:-}" = "--undo" ]; then
    if [ -f "$BAK" ]; then
        mv -f "$BAK" "$CONF" && echo "元に戻しました: $CONF"
        restart_bt
    else
        echo "退避したファイルがありません ($BAK)"
    fi
    exit 0
fi

[ -f "$CONF" ] || { echo "$CONF がありません" >&2; exit 1; }
[ -f "$BAK" ] || cp -p "$CONF" "$BAK"

tmp=$(mktemp "${TMPDIR:-/tmp}/ame-btconf.XXXXXX") || exit 1
# [General] の中の同じキー(コメントアウトされたものも)を消し、見出しの直後に入れ直す
awk '
    BEGIN { done = 0 }
    /^\[/ { sec = $0 }
    sec == "[General]" && /^[#[:space:]]*(ControllerMode|JustWorksRepairing|FastConnectable)[[:space:]]*=/ { next }
    { print }
    $0 == "[General]" && !done {
        print "# ame-shell: AirPods 等のイヤホン接続の対策(bt-airpods-fix.sh)"
        print "ControllerMode = bredr"
        print "JustWorksRepairing = always"
        print "FastConnectable = true"
        done = 1
    }
    END {
        if (!done) {
            print "[General]"
            print "ControllerMode = bredr"
            print "JustWorksRepairing = always"
            print "FastConnectable = true"
        }
    }
' "$CONF" > "$tmp" || { rm -f "$tmp"; exit 1; }
chmod 644 "$tmp"
mv -f "$tmp" "$CONF"
echo "設定しました: $CONF(元のファイル: $BAK)"
grep -nE "^(ControllerMode|JustWorksRepairing|FastConnectable)" "$CONF"
restart_bt
echo ""
echo "次に、AirPods を一度削除してペアリングし直してください:"
echo "  1. 端末で: bluetoothctl devices で MAC を確認し、bluetoothctl remove <MAC>"
echo "  2. AirPods をケースに入れたまま蓋を開け、背面のボタンを白く点滅するまで長押し"
echo "  3. パネルの「スキャン」→ AirPods を選んでペアリング(接続後は自動で音の出力先になります)"
