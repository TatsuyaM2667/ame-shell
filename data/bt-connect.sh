#!/bin/sh
# bt-connect.sh: Bluetooth の操作(ame-shell の設定パネル・サイドバーから)。POSIX sh。
#
#   bt-connect.sh <MAC>            接続し、イヤホン・スピーカーなら音の出力先にする
#   bt-connect.sh --pair <MAC>     ペアリング → 信頼 → 接続(上と同じ)
#   bt-connect.sh --power on|off   アダプタの電源(オンのときは rfkill のブロックも外す)
#   bt-connect.sh --scan <秒>      周りの機器を探す(電源が切れていれば入れてから)
#
# 結果は標準出力へ: 成功なら最後に "Connection successful"(電源・スキャンは "ok")、失敗なら "Failed: <理由>"。
#
# 接続の流れ:
#  1. 信頼済みにする(次から機器側からの自動接続も通る)
#  2. 接続(AirPods は 1 回目が失敗しやすいので、少し待ってもう 1 回)
#     「音声の受け口が無い」(profile-unavailable)なら WirePlumber を再起動してからもう 1 回
#  3. PipeWire に出力が現れるのを待ち、高音質(A2DP)にして既定の出力にし、再生中の音も移す

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

# 電源を入れる。ソフトブロック(rfkill)されていると BlueZ は電源を入れられない(org.bluez.Error.Blocked)
power_on() {
    command -v rfkill >/dev/null 2>&1 && rfkill unblock bluetooth >/dev/null 2>&1
    if bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then return 0; fi
    out=$(bluetoothctl power on 2>&1)
    case "$out" in *succeeded*|*"Changing power on"*) return 0 ;; esac
    # rfkill を外した直後はアダプタの準備に少しかかる
    sleep 1
    out=$(bluetoothctl power on 2>&1)
    case "$out" in
        *succeeded*|*"Changing power on"*) return 0 ;;
        *Blocked*) echo "Failed: Bluetooth がブロックされています(rfkill unblock bluetooth を試してください)"; return 1 ;;
        *) bluetoothctl show 2>/dev/null | grep -q "Powered: yes" && return 0
           echo "Failed: 電源を入れられません: $(printf '%s\n' "$out" | tail -n 1)"; return 1 ;;
    esac
}

case "${1:-}" in
    --power)
        if [ "${2:-}" = off ]; then
            bluetoothctl power off >/dev/null 2>&1 && echo ok || echo "Failed: 電源を切れません"
        else
            power_on && echo ok
        fi
        exit 0
        ;;
    --scan)
        power_on || exit 1
        # 見つかった機器は BlueZ のシグナルで ame-shell が一覧を読み直す
        bluetoothctl --timeout "${2:-10}" scan on >/dev/null 2>&1
        echo ok
        exit 0
        ;;
    --pair)
        mac="${2:-}"
        [ -n "$mac" ] || { echo "Failed: MAC アドレスがありません"; exit 1; }
        power_on || exit 1
        bluetoothctl pairable on >/dev/null 2>&1
        # エージェント(確認の受け答え役)が無いと、多くの機器でペアリングが AuthenticationFailed になる。
        # 画面で数字を確かめられないので「入力も表示も無い」機器として名乗る(イヤホン・スピーカー・マウスは通る)
        out=$(timeout 40 bluetoothctl --agent NoInputNoOutput pair "$mac" 2>&1)
        case "$out" in
            *"Pairing successful"*|*AlreadyExists*|*"already paired"*) ;;
            *AuthenticationFailed*|*AuthenticationRejected*|*AuthenticationCanceled*)
                # 前のペアリングの情報が食い違っている: 消してからもう 1 回
                bluetoothctl remove "$mac" >/dev/null 2>&1
                sleep 2
                bluetoothctl --timeout 8 scan on >/dev/null 2>&1
                out=$(timeout 40 bluetoothctl --agent NoInputNoOutput pair "$mac" 2>&1)
                case "$out" in
                    *"Pairing successful"*|*AlreadyExists*) ;;
                    *) echo "Failed: $(printf '%s\n' "$out" | grep -E "Failed|Error" | tail -n 1)"; exit 1 ;;
                esac
                ;;
            *)
                reason=$(printf '%s\n' "$out" | grep -E "Failed|Error|not available" | tail -n 1)
                echo "Failed: ${reason:-ペアリングの応答がありません (timeout)}"
                exit 1
                ;;
        esac
        shift
        ;;
esac

mac="${1:-}"
[ -n "$mac" ] || { echo "Failed: MAC アドレスがありません"; exit 1; }
id=$(printf '%s' "$mac" | tr ':' '_')
power_on || exit 1

bluetoothctl trust "$mac" >/dev/null 2>&1
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
            restart_wireplumber && sleep 3
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
# pactl(Chimera: libpulse-progs / Arch: libpulse)が無いと出力先を切り替えられない。つながったことは知らせる
command -v pactl >/dev/null 2>&1 || { echo "audio: pactl が無いため音の出力先を切り替えられません"; echo "Connection successful"; exit 0; }
pactl info >/dev/null 2>&1 || { echo "audio: PipeWire(pipewire-pulse)が動いていません"; echo "Connection successful"; exit 0; }
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
elif bluetoothctl info "$mac" 2>/dev/null | grep -q "UUID: Audio Sink"; then
    # 音の機器なのに PipeWire に現れない: Bluetooth の音声のプラグインが無い・WirePlumber が動いていない
    echo "audio: PipeWire に音の機器が現れません(WirePlumber と Bluetooth の音声のプラグインを確認。Arch: pipewire-audio)"
fi
echo "Connection successful"
