# FreeBSD での確認手順

対象: FreeBSD 14 / 15(amd64)。2026-10-28 の修正(SIGSYS・zstd)の確認用。

## 1. 更新して入れ直す

```sh
cd ~/ame-shell
git pull
sh install.sh --debug      # root のパスワードを聞かれる。Zig / Odin は作り直さない(導入済みなら飛ばす)
```

`--debug` はデバッグ情報つき(関数名が残る)・安全検査ありでビルドします。動作確認が済んだら `sh install.sh` で通常版に戻せます。

## 2. TTY で直接起動して確かめる(SDDM を通す前に)

SDDM のログイン画面で Ctrl+Alt+F2 などで TTY に切り替え、本人でログインして:

```sh
/usr/local/bin/ame-session --river5
```

期待すること:
- 壁紙・縦のバー・枠が出る。Super+Return で foot が開き、窓が中心から広がるアニメーションで出る
- Super+Shift+E でセッションが終わり、TTY に戻る

ログ(TTY でも読めるよう主要な行は英語):

```sh
grep -a -E "starting|crashed|killed by|stopping River|keybind|wm:" ~/.local/state/ame-shell/session.log | tail -n 20
```

- `ame-shell starting (pid N, freebsd)` … 起動した
- `wm: キーバインド 94 個を登録` … ウィンドウマネージャとして動き始めた(前回はこの直後に落ちていた)

## 3. それでも落ちる場合

ログに `ame-shell: crashed with SIGxxx …` と `ame-shell killed by signal SIGxxx` が出ます。
30 秒以内に 3 回落ちると River ごと終了してログイン画面(TTY から起動したときは TTY)に戻ります。

コアがあれば、今回は関数名つきでバックトレースが取れます:

```sh
lldb /usr/local/bin/ame-shell -c ~/ame-shell.core -b -o 'bt' -o 'register read rax'
```

この出力とログの最後の 30 行を送ってください。

## 4. (任意)Zig のビルドの修正の確認

今回の手元の回避策(`/usr/local/llvm18/lib/libzstd.so` のシンボリックリンク)が無くても Zig 0.13 がビルドできることを確かめる場合
(30 分〜1 時間かかります):

```sh
su root -c 'rm -f /usr/local/llvm18/lib/libzstd.so && rm -rf /usr/local/ame-toolchain/zig-0.13.0 /usr/local/ame-toolchain/src/zig-0.13.0'
sh install.sh --debug
```

## 原因のまとめ(2026-10-28)

- SIGSYS: `src/platform/loop.zig` の `Timer.arm` が `std.os.linux.timerfd_settime`(Linux のシステムコール番号 286 を直接発行)を使っていた。
  FreeBSD では 286 は存在しないシステムコールなので SIGSYS。ウィンドウマネージャがキーバインドを登録した直後の最初のアニメーションで呼ばれていた。
  FreeBSD 14 以降の timerfd は libc にあるので、Linux 以外は libc の `timerfd_settime` を呼ぶよう修正。
  FreeBSD 向けのバイナリに Linux の直接のシステムコール(`syscall` 命令・`os.linux.*`)が 1 つも残っていないことを逆アセンブルで確認済み。
- zstd: LLVM 18 が `-lzstd` を要求するが、FreeBSD の base の zstd は private 名。pkg の `zstd` を必須にし、Zig の cmake に
  `-DCMAKE_PREFIX_PATH="/usr/local/llvm18;/usr/local"` と `-DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/lib"` を追加。

## タッチパッド
- USB マウスは動くのにタッチパッドが動かない: タッチパッドのドライバが読み込まれていない。I2C 接続(ACPI の PNP0C50)は
  ig4 + iichid + hmt(AMD は amdgpio も)、PS/2 接続は loader.conf の `hw.psm.synaptics_support` / `hw.psm.elantech_support`。
  `doas sh scripts/freebsd-touchpad.sh` で設定して再起動。`sh scripts/freebsd-touchpad.sh --check` で、機器・モジュール・/dev/input の一覧を表示。
- 動くがタップでクリックできない: libinput の既定は無効。ame-shell(River 0.5 の WM)が river_libinput_config_v1 で有効にする(設定 tap-to-click)。
