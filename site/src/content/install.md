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
- **ツールチェイン**: Zig 0.13 と Odin をソースからビルドします(FreeBSD のパッケージに無いため)。
- **タッチパッド**: I2C(ig4・iichid・hmt)と PS/2(psm の Synaptics / Elantech)の設定をします。
- **Bluetooth**: ファームウェア(Realtek / Intel)・ng_ubt・hcsecd・sdpd・bthidd を設定します。
- **見た目**: foot と fastfetch の設定、SDDM のテーマ(背景は自分の壁紙)。
- **キーボード配列**: rc.conf の keymap から Wayland の配列を決めます。日本語入力(fcitx5 + Mozc)も入れます。

> ame-shell の FreeBSD 版は、Linux の直接のシステムコールを 1 つも含まないことを、逆アセンブルして確認しています(以前 SIGSYS で落ちた原因を断つため)。

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
