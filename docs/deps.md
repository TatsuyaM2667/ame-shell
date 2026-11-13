# 依存関係(Chimera Linux, 2026-10-26 時点で実機確認)

**River はこのマシンでは apk 管理外(`/usr/bin/river` 0.3.5、`apk info -W` で所有パッケージ無し)。apk の Chimera リポジトリにも river は見つからない。** SDDM セッションはシステムにインストール済みの River を使う。

| 用途 | 必須 | このマシンでの状態 |
|---|---|---|
| ビルド: zig 0.13 | ✔ | `/usr/local/zig-0.13.0`(apk に無し) |
| ビルド: odin | ✔ | `~/.local/bin/odin`(ソースビルド) |
| ビルド: wayland-scanner | ✔ | あり |
| wayland-client / wayland-egl / EGL / GLESv2 | ✔ | Mesa 26.2.4 |
| xkbcommon / freetype / harfbuzz / fontconfig / dbus-1 | ✔ | あり |
| wasm3 / stb_image | ✔ | `third_party/` に同梱(MIT / パブリックドメイン) |
| フォント: Noto Sans CJK JP, JetBrainsMono Nerd Font | 推奨 | あり |
| libpam(実行時に dlopen) | ロック画面 | あり(ヘッダは不要) |
| 音量: ame-uzume(同梱。Odin。libpulse を実行時に読み、pipewire-pulse に話す。wpctl は使わない)/ pactl(録画の音の出力先・Bluetooth の音の切り替え) | 任意 | あり |
| クリップボード: ame-copy / ame-paste(同梱。ext-data-control。wl-copy / wl-paste の代わり。River 0.3 のスクショのコピーだけは wl-copy) | 任意 | あり |
| 再生中の曲(MPRIS を D-Bus で直接。playerctl は使わない)/ curl(アート・歌詞の取得) | 任意 | あり |
| libpulse-simple(ame-hamon が実行時に読む。スペクトラムの録音。cava は使わない) | 任意 | あり |
| 明るさ: amaterasu(同梱。sysfs、書けなければ logind の SetBrightness。brightnessctl は使わない) / 電源プロファイル: ame-tajikara(同梱。power-profiles-daemon に D-Bus で直接。powerprofilesctl は使わない) | 任意 | あり |
| NetworkManager / BlueZ(D-Bus で直接。nmcli / bluetoothctl は使わない) | 任意 | あり |
| foot / rivertile | セッション | あり |
| sddm / elogind または seatd / turnstile / dbus | セッション | あり(PAM: system-login に pam_turnstile・pam_elogind) |

不足時: 任意のものはその機能だけ無効になり、シェルは動き続ける。
