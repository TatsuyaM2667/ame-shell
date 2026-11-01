#!/bin/sh
# bt-connect.sh: Bluetooth の機器がつながった後の「音」の後始末(ame-shell から)。POSIX sh。
# 電源・スキャン・ペアリング・接続は ame-shell が BlueZ と D-Bus で直接やりとりする(src/platform/netdbus.zig)。
# ここは PipeWire 側の操作(pactl / wpctl / WirePlumber の再起動)だけ。
#
#   bt-connect.sh --audio <MAC>          イヤホン・スピーカーを高音質(A2DP)にして既定の出力にし、再生中の音も移す
#   bt-connect.sh --restart-wireplumber  WirePlumber を再起動する(「音声の受け口が無い」で接続できないとき)
#
# 結果は標準出力へ: "audio: <出力名>" または "audio: <切り替えられない理由>"。

# WirePlumber(PipeWire のセッション管理)を再起動する。Chimera は dinit、Arch などは systemd のユーザーサービス
restart_wireplumber() {
    if command -v dinitctl >/dev/null 2>&1 && dinitctl --user status wireplumber >/dev/null 2>&1; then
        dinitctl --user restart wireplumber >/dev/null 2>&1
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl --user restart wireplumber >/dev/null 2>&1
    else
        return 1
    fi
}

case "${1:-}" in
    --restart-wireplumber) restart_wireplumber; exit 0 ;;
    --audio) mac="${2:-}" ;;
    *) echo "使い方: bt-connect.sh --audio <MAC> | --restart-wireplumber" >&2; exit 2 ;;
esac
[ -n "$mac" ] || { echo "audio: MAC アドレスがありません"; exit 1; }
id=$(printf '%s' "$mac" | tr ':' '_')

# pactl(Chimera: libpulse-progs / Arch: libpulse)が無いと出力先を切り替えられない。つながったことは知らせる
command -v pactl >/dev/null 2>&1 || { echo "audio: pactl が無いため音の出力先を切り替えられません"; exit 0; }
pactl info >/dev/null 2>&1 || { echo "audio: PipeWire(pipewire-pulse)が動いていません"; exit 0; }
card="bluez_card.$id"
wait_card() {
    i=0
    while [ $i -lt 24 ]; do
        pactl list short cards 2>/dev/null | grep -q "$card" && return 0
        sleep 0.25
        i=$((i + 1))
    done
    return 1
}
# Bluetooth では繋がったのに PipeWire に音の機器が現れない: bluetoothd の再起動後に WirePlumber が
# 登録し直していないときに起きる。WirePlumber を再起動すると、繋がっている機器を拾い直す
if ! wait_card && restart_wireplumber; then
    sleep 2
    wait_card
fi
if pactl list short cards 2>/dev/null | grep -q "$card"; then
    # WirePlumber の既定では、どれかのアプリがマイクを開いた瞬間にイヤホンが通話用(HFP: モノラル 16kHz 以下)に
    # 切り替わり、電話のようなガサガサの音になる。自動の切り替えを止める(保存されるので 1 回でよい)
    if command -v wpctl >/dev/null 2>&1 && ! wpctl settings bluetooth.autoswitch-to-headset-profile 2>/dev/null | grep -q 'Saved: false'; then
        wpctl settings --save bluetooth.autoswitch-to-headset-profile false >/dev/null 2>&1
    fi
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
    # 既定の入力がイヤホンのマイクだと、録音するアプリがあるたびに通話用(低音質)へ切り替わるので、
    # 内蔵マイクを既定の入力にしておく(イヤホンのマイクは音量のポップアウトで選べる)
    case "$(pactl get-default-source 2>/dev/null)" in
        bluez_input.*)
            mic=$(pactl list short sources 2>/dev/null | awk '$2 ~ /^alsa_input/ { print $2; exit }')
            [ -n "$mic" ] && pactl set-default-source "$mic" >/dev/null 2>&1
            ;;
    esac
else
    # 音の機器なのに PipeWire に現れない: Bluetooth の音声のプラグインが無い・WirePlumber が動いていない
    echo "audio: PipeWire に音の機器が現れません(WirePlumber と Bluetooth の音声のプラグインを確認。Arch: pipewire-audio)"
fi
