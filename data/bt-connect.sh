#!/bin/sh
# bt-connect.sh: Bluetooth の機器がつながった後の「音」の後始末(ame-shell から)。POSIX sh。
# 電源・スキャン・ペアリング・接続は ame-shell が BlueZ と D-Bus で直接やりとりする(src/platform/netdbus.zig)。
# ここは PipeWire 側の操作(ame-uzume / WirePlumber の設定と再起動)だけ。pactl は使わない。
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

# ame-uzume(ame-shell と一緒に入る。libpulse で pipewire-pulse に話す)が無いと出力先を切り替えられない。つながったことは知らせる
command -v ame-uzume >/dev/null 2>&1 || { echo "audio: ame-uzume が無いため音の出力先を切り替えられません"; exit 0; }
ame-uzume >/dev/null 2>&1 || ame-uzume list sinks >/dev/null 2>&1 || { echo "audio: PipeWire(pipewire-pulse)が動いていません"; exit 0; }
card="bluez_card.$id"
wait_card() {
    i=0
    while [ $i -lt 24 ]; do
        ame-uzume list cards 2>/dev/null | grep -qx "$card" && return 0
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
if ame-uzume list cards 2>/dev/null | grep -qx "$card"; then
    # WirePlumber の既定では、どれかのアプリがマイクを開いた瞬間にイヤホンが通話用(HFP: モノラル 16kHz 以下)に
    # 切り替わり、電話のようなガサガサの音になる。自動の切り替えを止める(保存されるので 1 回でよい)
    if command -v wpctl >/dev/null 2>&1 && ! wpctl settings bluetooth.autoswitch-to-headset-profile 2>/dev/null | grep -q 'Saved: false'; then
        wpctl settings --save bluetooth.autoswitch-to-headset-profile false >/dev/null 2>&1
    fi
    # 通話用(HFP)ではなく音楽用の高音質プロファイルに(AirPods は AAC になる)
    ame-uzume profile "$card" a2dp-sink >/dev/null 2>&1
    sink=""
    i=0
    while [ $i -lt 20 ]; do
        sink=$(ame-uzume list sinks 2>/dev/null | awk -F '\t' -v id="$id" 'index($1, id) { print $1; exit }')
        [ -n "$sink" ] && break
        sleep 0.25
        i=$((i + 1))
    done
    if [ -n "$sink" ]; then
        ame-uzume use sink "$sink" >/dev/null 2>&1   # 既定にし、再生中の音も移す
        echo "audio: $sink"
    fi
    # 既定の入力がイヤホンのマイクだと、録音するアプリがあるたびに通話用(低音質)へ切り替わるので、
    # 内蔵マイクを既定の入力にしておく(イヤホンのマイクは音量のポップアウトで選べる)
    case "$(ame-uzume list sources 2>/dev/null | awk -F '\t' '$3 == "*" { print $1; exit }')" in
        bluez_input.*)
            mic=$(ame-uzume list sources 2>/dev/null | awk -F '\t' '$1 ~ /^alsa_input/ { print $1; exit }')
            [ -n "$mic" ] && ame-uzume use source "$mic" >/dev/null 2>&1
            ;;
    esac
else
    # 音の機器なのに PipeWire に現れない: Bluetooth の音声のプラグインが無い・WirePlumber が動いていない
    echo "audio: PipeWire に音の機器が現れません(WirePlumber と Bluetooth の音声のプラグインを確認。Arch: pipewire-audio)"
fi
