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
| wpctl / pactl(音量) | 任意 | あり |
| playerctl(メディア) / curl(アート取得) | 任意 | あり |
| brightnessctl(明るさ) | 任意 | あり |
| nmcli / bluetoothctl(トグル) | 任意 | あり |
| foot / rivertile | セッション | あり |
| sddm / elogind または seatd / turnstile / dbus | セッション | あり(PAM: system-login に pam_turnstile・pam_elogind) |

不足時: 任意のものはその機能だけ無効になり、シェルは動き続ける。
