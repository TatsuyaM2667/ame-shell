#!/bin/sh
# bt-connect.sh <MAC>: Bluetooth 機器に接続し、イヤホン・スピーカーなら音の出力先にする(ame-shell の設定パネルから)。
# POSIX sh。結果は標準出力へ: 成功なら最後に "Connection successful"、失敗なら "Failed: <理由>"。
#
#  1. 信頼済みにする(次から機器側からの自動接続も通る)
#  2. 接続(AirPods は 1 回目が失敗しやすいので、少し待ってもう 1 回)
#     「音声の受け口が無い」(profile-unavailable)なら WirePlumber を再起動してからもう 1 回
#  3. PipeWire に出力が現れるのを待ち、高音質(A2DP)にして既定の出力にし、再生中の音も移す

mac="$1"
[ -n "$mac" ] || { echo "Failed: MAC アドレスがありません"; exit 1; }
id=$(printf '%s' "$mac" | tr ':' '_')

bluetoothctl trust "$mac" >/dev/null 2>&1

try_connect() {
    timeout 15 bluetoothctl connect "$mac" 2>&1
}
ok() {
    case "$1" in *"Connection successful"*|*"already connected"*|*"AlreadyConnected"*) return 0 ;; esac
    bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"
}

out=$(try_connect)
if ! ok "$out"; then
    case "$out" in
        *profile-unavailable*)
            # PipeWire(WirePlumber)が BlueZ に音声の受け口を登録していない(bluetoothd の再起動後など)
            if command -v dinitctl >/dev/null 2>&1; then
                dinitctl --user restart wireplumber >/dev/null 2>&1
                sleep 3
            fi
            ;;
        *) sleep 2 ;;
    esac
    out=$(try_connect)
fi
if ! ok "$out"; then
    reason=$(printf '%s\n' "$out" | grep -E "Failed|Error|not available" | tail -n 1)
    [ -n "$reason" ] || reason="応答がありません (timeout)"
    echo "Failed: $reason"
    exit 1
fi

# ---- 音声の出力先にする ----
command -v pactl >/dev/null 2>&1 || { echo "Connection successful"; exit 0; }
card="bluez_card.$id"
i=0
while [ $i -lt 24 ]; do
    pactl list short cards 2>/dev/null | grep -q "$card" && break
    sleep 0.25
    i=$((i + 1))
done
if pactl list short cards 2>/dev/null | grep -q "$card"; then
    # 通話用(HFP)ではなく音楽用の高音質プロファイルに(AirPods は AAC になる)
    pactl set-card-profile "$card" a2dp-sink >/dev/null 2>&1
    sink=""
    i=0
    while [ $i -lt 20 ]; do
        sink=$(pactl list short sinks 2>/dev/null | awk -v id="$id" 'index($2, id) { print $2; exit }')
        [ -n "$sink" ] && break
        sleep 0.25
        i=$((i + 1))
    done
    if [ -n "$sink" ]; then
        pactl set-default-sink "$sink" >/dev/null 2>&1
        pactl list short sink-inputs 2>/dev/null | while read -r n _; do
            pactl move-sink-input "$n" "$sink" >/dev/null 2>&1
        done
        echo "audio: $sink"
    fi
fi
echo "Connection successful"
