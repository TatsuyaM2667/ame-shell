# インストール

どのディストリでも、入れ方は同じです。

```sh
git clone https://github.com/TatsuyaM2667/ame-shell && cd ame-shell
sh install.sh
```

`install.sh` が OS を見て、必要なものを判断します。依存パッケージ、ツールチェイン(Zig 0.13・Odin)、River、ame-shell のビルド、インストール、ログイン画面(SDDM)のセッションまで、すべて自動です。終わったら、ログイン画面のセッション一覧から **「Ame Shell (River 0.5)」** を選んでください。

| OS | 依存パッケージ | River 0.5 | 備考 |
|---|---|---|---|
| Chimera Linux | apk で自動 | 無ければソースからビルド | 作者の環境 |
| Arch Linux(EndeavourOS・Manjaro など) | pacman で自動(公式リポジトリだけ。AUR は使わない) | 公式パッケージ | `scripts/install-arch.sh` |
| FreeBSD 14 / 15 | pkg で自動 | 公式パッケージ(0.4 以降) | `scripts/install-freebsd.sh`。GPU ドライバ・タッチパッド・Bluetooth・SDDM のテーマまで |
| そのほかの Linux | 足りないものを表示 | 無ければソースからビルド | 表示されたパッケージを入れてから再実行 |

## オプション {#options}

```sh
sh install.sh --user        # 自分だけ(~/.local)。root 不要。SDDM には出ないので TTY から ame-session --river5
sh install.sh --yes         # 確認しない
sh install.sh --debug       # デバッグ情報つき・安全検査ありでビルド(クラッシュの原因が分かりやすい)
sh install.sh --uninstall   # 元に戻す(入れたファイルは share/ame-shell/installed-files に記録されている)
```

- どのユーザーが実行してもかまいません。root の権限が必要なところだけ、doas か sudo を使います。どちらも無い人は、自動で `--user` になります。
- インストールせずに試す: `PATH=$PWD/zig-out/bin:$PATH AME_SESSION_NESTED=1 session/ame-session --river5`(今のセッションの中に窓として開きます)

## Arch Linux {#arch}

```sh
sudo pacman -S --needed git
git clone https://github.com/TatsuyaM2667/ame-shell && cd ame-shell
sh install.sh
```

1. 公式リポジトリから pacman で入れます(River 0.5・Odin・wlroots 0.20 も公式にあります)。パッケージ名は Arch の core / extra のデータベースで確認しています。
2. sddm・NetworkManager・bluetooth を有効にします。すでに別のログイン画面(gdm など)が有効なら、そのままにします。
3. Zig だけは 0.13 が必要なので、公式の配布物を `~/.cache/ame-shell` に取ってきます(Arch の zig は新しすぎるため)。

## FreeBSD {#freebsd}

```sh
pkg install git
git clone https://github.com/TatsuyaM2667/ame-shell && cd ame-shell
sh install.sh        # root で。完全自動
shutdown -r now
```

FreeBSD のインストーラは次のことまで行います。

- **GPU ドライバ**: drm-kmod を入れ、amdgpu / i915kms などを設定します(NVIDIA は nvidia-drm)。
- **サービス**: dbus・seatd・sddm を有効にし、video グループへ追加します。
- **カメラ**(ハンド操作): webcamd を入れて有効にし(cuse を読み込む)、webcamd グループへ追加します。USB カメラが `/dev/video0` になります。
- **顔認証**: ロック画面の顔認証は Linux と同じように使えます(パスワードの照合は setuid の ame-auth、カメラは webcamd。赤外線カメラが要ります)。ログイン画面での顔認証は greetd のとき(`sh scripts/greeter-setup.sh`)だけで、PAM モジュール `pam_ame_face.so` を OpenPAM に組み込みます(`/etc/pam.d/ame-greetd` と `/usr/local/etc/pam.d/ame-greetd`)。SDDM では使えません。
- **音質**: PulseAudio のサンプリング周波数の変換を高品質に(`~/.config/pulse/daemon.conf` が無いときだけ)。
- **ツールチェイン**: Zig 0.13 と Odin をソースからビルドします(FreeBSD のパッケージに無いため)。
- **タッチパッド**: I2C(ig4・iichid・hmt)と PS/2(psm の Synaptics / Elantech)の設定をします。
- **Bluetooth**: ファームウェア(Realtek / Intel)・ng_ubt・hcsecd・sdpd・bthidd を設定します。
- **見た目**: foot と fastfetch の設定、SDDM のテーマ(背景は自分の壁紙)。
- **キーボード配列**: rc.conf の keymap から Wayland の配列を決めます。日本語入力(fcitx5 + Mozc)も入れます。

> ame-shell の FreeBSD 版は、Linux の直接のシステムコールを 1 つも含まないことを、逆アセンブルして確認しています(以前 SIGSYS で落ちた原因を断つため)。

> 手の認識([ame-hand](https://github.com/TatsuyaM2667/ame-hand))と顔認証([ame-face](https://github.com/TatsuyaM2667/ame-face))は別のリポジトリです。初めてビルドするときに、Zig が GitHub から取ってきます(どの OS でもネットワークが要ります。2 回目からは `~/.cache/zig` を使います)。

## 機能ごとの OS の違い {#os-features}

| 機能 | Chimera / Arch | FreeBSD |
|---|---|---|
| ハンド操作 | ○(カメラは `/dev/video*`。旧 River 0.3 のセッションでは riverctl で窓を操作) | ○(webcamd。インストーラが設定) |
| ロック画面の顔認証 | ○ | ○(パスワードは setuid の ame-auth、カメラは webcamd) |
| ログイン画面の顔認証 | ○(greetd のとき。PAM サービス `ame-greetd` を `/etc/pam.d` に) | ○(greetd のとき。`/etc/pam.d` と `/usr/local/etc/pam.d` の両方に。SDDM では使えない) |
| 曲のウィジェット・「再生中」・歌詞 | ○ | ○(ビジュアライザーの音は PulseAudio のモニター) |
| 充電のアニメーション | ○(カーネルの uevent で抜き差しを知る) | ○(devd の ACPI の知らせ) |
| スリープのあとにイヤホンをつなぎ直す | ○(logind・elogind) | ×(BlueZ が無い) |
| AirPods をつないだときのカード | ○(BlueZ) | ×(BlueZ が無い。FreeBSD の Bluetooth は AirPods の音にも標準では対応しない) |
| AirPods の頭の動き | △(BlueZ。AirPods が頭の向きを送らないことがある) | × |

- **Bluetooth の DeviceID**(AirPods の頭の動き用): `/etc/bluetooth/main.conf` の `[General]` に `DeviceID = bluetooth:004C:0000:0000` を書いて、Bluetooth を再起動します(Chimera: `doas dinitctl restart bluetoothd` / Arch: `sudo systemctl restart bluetooth`)。
- **ログイン画面の顔認証**は、ログイン画面を greetd(ame-greeter)にしたときだけ使えます。更新(`ame-update`)のたびに、ログイン画面の設定も入れ直します(FreeBSD も)。

## 更新 {#update}

```sh
ame-update            # OS のパッケージ(pkg / apk)→ ame-shell(git pull → ビルド → 入れ直し)→ 動いている ame-shell を再起動
ame-update --check    # 更新があるかを見るだけ
ame-update --no-pkg   # ame-shell だけ(--no-self でパッケージだけ)
```

- ランチャーで `>` →「アップデート」からも実行できます。
- 動いている ame-shell は、**窓とワークスペースをそのまま**新しい版に入れ替わります(`ame-ctl restart`)。
- ソースに自分の変更があるときは `git pull` をせず、今のソースでビルドします。

## うまくいかないとき {#trouble}

| 症状 | 見るところ |
|---|---|
| ログインしてもすぐ戻る | `~/.local/state/ame-shell/session.log`。5 秒以内に終わる失敗が 3 回続くと、次はセーフモードで起動(`rm ~/.local/state/ame-shell/crashloop` で解除) |
| 画面が出ない(FreeBSD) | `docs/freebsd-test.md`、`sh scripts/check-freebsd-pkgs.sh` |
| タッチパッドが動かない(FreeBSD) | `sh scripts/freebsd-touchpad.sh --check` |
| Bluetooth(FreeBSD) | `sh scripts/freebsd-bluetooth.sh --check` |
| AirPods が繋がらない(Linux) | `doas sh session/bt-airpods-fix.sh`(BlueZ を BR/EDR 接続に) |
| 動画の壁紙が重い | `grep -E 'video|ffmpeg|mpv' ~/.local/state/ame-shell/session.log` で、どの方法で再生しているかを確認 |
| 重くなる・急に固まる | スワップの無い機械でメモリが尽きている。`doas sh scripts/zram-setup.sh` で圧縮したスワップを作る。止まったアプリは `grep memguard ~/.local/state/ame-shell/session.log` で分かる([メモリ](#/tech-memory)) |
| 設定が効かない | `ame-config check` で、間違っている行と理由が出る |
