# セッションとインストーラ

<p class="file">対象: session/ame-session(222 行)・ame-river5-init(95)・ame-update(181)・install-session.sh / install.sh / scripts/install-freebsd.sh・install-arch.sh・sddm-theme.sh ほか(すべて POSIX sh)</p>

ログイン画面で「Ame Shell」を選んでから、デスクトップが出るまでの流れです。

```
SDDM → ame-session --river5(環境を整える)→ River 0.5 → ame-river5-init(監督)→ ame-shell
```

## ame-session: 環境を整える {#session}

| 処理 | 理由 |
|---|---|
| `XDG_SESSION_TYPE=wayland` など、アプリ向けの環境変数 | Firefox(`MOZ_ENABLE_WAYLAND`)・Qt(`QT_QPA_PLATFORM`)・SDL・Java・Electron を Wayland で動かす |
| `XDG_CONFIG_DIRS` の先頭に ame-shell の設定 | foot・fastfetch などの**既定の見た目**を、ユーザーの設定を上書きせずに足す。各アプリは自分の `~/.config` を先に読むので、ユーザーの設定がある場合はそちらが優先される |
| カーソルの大きさ(未設定のときだけ 24) | アプリごとにカーソルの大きさがばらつかないように |
| `XDG_RUNTIME_DIR` が無ければ作る(本人が持ち主・0700 であることを確かめる) | turnstile / elogind の PAM の設定が無い環境のため。他人が作ったディレクトリは使わない |
| D-Bus | 既存のセッションバス → `$XDG_RUNTIME_DIR/bus` → `dbus-run-session` で自分を起動し直す、の順 |
| シート(libseat) | elogind のセッションがある → seatd のソケットに読み書きできる → `seatd-launch` 経由、の順で判定(FreeBSD は `/var/run/seatd.sock`) |
| `rfkill unblock all`(Linux) | 前回のセッションの状態で Wi-Fi / Bluetooth がブロックされたままのことがある。`/dev/rfkill` はログイン中の本人に許可されている(udev の uaccess) |
| クラッシュループの検出 | 5 秒以内に終わる失敗が 3 回続いたら、次回はセーフモードで起動する(印のファイル `crashloop`) |
| River の版を見分ける | `river -version` が 0.4 以降なら、ame-shell が WM を兼ねるセッションにする |
| キーボード配列 | `XKB_DEFAULT_LAYOUT` → `~/.config/ame-shell/xkb-layout` → River 0.3 の init の設定、の順 |

## ame-river5-init: 監督する {#supervise}

```sh
crashes=""
while :; do
    start=$(date +%s)
    ame-shell >> "$LOG" 2>&1
    rc=$?
    now=$(date +%s)
    if [ "$rc" -eq 0 ]; then
        log "ame-shell exited normally / 正常に終了しました"
        stop_river
        exit 0
    fi
    if [ "$rc" -gt 128 ]; then
        sig=$((rc - 128))
        signame=$(kill -l "$sig" 2>/dev/null || echo "?")
        [ "$signame" = UNUSED ] && signame=SYS   # Linux の一部のシェルは SIGSYS(31)を古い名前で返す
        log "ame-shell killed by signal SIG$signame ($sig), rc=$rc, after $((now - start))s / シグナル SIG$signame で落ちました"
    …
    if [ "$#" -ge 3 ]; then
        log "ame-shell crashed 3 times within 30s, giving up / 30 秒以内に 3 回落ちたためセッションを終了します"
        stop_river
        exit 1
    fi
    sleep 1
done
```

- **落ちたら起動し直す**: River 0.5 の WM は別のプロセスなので、ame-shell が落ちても**アプリの窓は閉じません**。1 秒後に ame-shell を起動し直し、窓を受け取り直します。
- **30 秒以内に 3 回落ちたら諦める**: そのまま起動し直し続けると、黒い画面から抜けられなくなります。River を終了してログイン画面に戻します。
- **シグナル名をログに残す**: 終了コード 128 + n はシグナル n で落ちたことを表します。FreeBSD の SIGSYS の件は、このログで原因が分かりました。一部のシェルが SIGSYS を古い名前(UNUSED)で返すのも吸収しています。
- **River の init には "riverctl" という文字列を入れない**: River 0.5 は、init スクリプトにこの文字列が含まれていると、コメントの中であっても起動を拒否します(実際に試して分かりました)。そのため `ame-river5-init` には、説明のコメントにもこの単語を書いていません。

## POSIX sh だけで書く {#posix}

インストーラと補助のスクリプトは、すべて POSIX sh です。bash や GNU 独自の機能を使いません。

| 使わないもの | 代わり | 理由 |
|---|---|---|
| `sed -i` | 一時ファイルに書いて `cat > 元のファイル` | BSD の sed は `-i` の書き方が違う |
| `readlink -f` | `cd "$(dirname "$0")" && pwd` | BSD に無い |
| `getent passwd` | `awk -F: '$1 == u { print $6 }' /etc/passwd` | FreeBSD の getent は出力が違うことがある |
| `grep` でバイナリの中を探す | `LC_ALL=C tr -c '[:print:]' '\n' < ファイル \| grep` | BSD の grep はバイナリの中を検索しない |
| bash の配列 | `set --` と位置引数 | sh に配列は無い |

`sh -n` で構文を確かめ、`--destdir` で疑似的な root にインストールして中身を確かめ、偽のコマンド(偽の `pacman` など)を PATH の先頭に置いて流れを試します。

## インストールは「記録して、元に戻せる」 {#manifest}

```sh
# install_file <src> <dst(DESTDIR抜き)> <mode>
install_file() {
    src=$1; dst=$2; mode=$3; t="$DESTDIR$dst"
    run mkdir -p "$(dirname "$t")"
    if [ -e "$t" ] && ! grep -qx "$dst" "$MANIFEST" 2>/dev/null; then
        # 自分が入れたものでない既存ファイルは .ame-bak に退避してから上書き
        …
    fi
    run cp "$src" "$t.ame-new" && run chmod "$mode" "$t.ame-new" && run mv -f "$t.ame-new" "$t"
    echo "$dst" >> "$TMP_MANIFEST"
}
```

- 入れたファイルを `share/ame-shell/installed-files` に**全部記録**します。`--uninstall` はその記録を読んで消し、`.ame-bak` があれば元に戻します。
- **自分が入れたものではない既存のファイル**は、上書きする前に `.ame-bak` に退避します。
- **「新しい名前に書いてから `mv`」で置き換えます**。コピーの途中で止まっても、壊れた半端なファイルが残りません(`mv` は同じファイルシステムの中では原子的)。動いている ame-shell の実行ファイルを上書きしても、動いているプロセスには影響しません。

### PAM の設定ファイルの置き場所を、libpam の中身を見て決める {#pam}

```sh
# Linux-PAM は /etc/pam.d/<svc> → /usr/lib/pam.d/<svc> の順に探す(vendordir 対応版)。
# /etc/pam.d が無い環境で、libpam が /usr/lib/pam.d を知らない古い版だと /etc/pam.d を作った瞬間に
# 他のサービスが読めなくなるので、その場合は /usr/lib/pam.d に置く。
if [ -n "$lib" ] && LC_ALL=C tr -c '[:print:]' '\n' < "$lib" | grep -q '^/usr/lib/pam.d'; then
    PAM_DIR=/etc/pam.d
else
    PAM_DIR=/usr/lib/pam.d
fi
```

Chimera には `/etc/pam.d` が無く、`/usr/lib/pam.d` だけがあります。古い libpam は「`/etc/pam.d` が存在すれば、そこだけを見る」ので、`/etc/pam.d` を作った瞬間に、**ほかのすべてのサービス(ログインなど)の設定が見えなくなります**。そこで libpam の実行ファイルの中に `/usr/lib/pam.d` という文字列があるか(= 両方を見る新しい版か)を確かめてから、置き場所を決めています。

## OS ごとのインストーラ {#installers}

| | Chimera Linux | Arch 系 | FreeBSD |
|---|---|---|---|
| 入口 | `install.sh` | `install.sh` → `scripts/install-arch.sh` | `install.sh` → `scripts/install-freebsd.sh` |
| 依存 | apk | pacman(公式リポジトリだけ) | pkg |
| River 0.5 | 無ければソースから(Zig 0.16 + wlroots 0.20) | 公式パッケージ | 公式パッケージ(0.4 以降) |
| Zig 0.13 | 公式の配布物を `~/.cache` に | 同左(Arch の zig は新しすぎる) | ソースからビルド(LLVM 18) |
| Odin | PATH に無ければソースから | 公式パッケージ | ソースからビルド |
| そのほか | — | sddm・NetworkManager・bluetooth を有効に | GPU ドライバ・seatd・タッチパッド・Bluetooth・SDDM のテーマ・foot / fastfetch の設定・キーボード配列・日本語入力 |

**パッケージの名前を推測で書かない**: Arch と FreeBSD のパッケージ名は、公式のパッケージのデータベース(Arch の `core.db` / `extra.db`、FreeBSD の `packagesite.yaml`)を取ってきて、1 つずつ照合しています。FreeBSD 用には `scripts/check-freebsd-pkgs.sh` があります。

**無いものは飛ばす**: 必須のもの以外(cava・wf-recorder・日本語入力など)は、リポジトリに無ければ飛ばして続けます。FreeBSD の quarterly には無いことがある `ja-fcitx5-mozc` などは、候補を順に試します。

## ame-update {#update}

1. OS のパッケージを更新する(`pkg upgrade` / `apk upgrade`)。
2. ame-shell のソースを `git pull --ff-only` する。**手元に変更があれば pull しない**(自分の変更を守るため)。
3. インストール時に用意したツールチェイン(Zig 0.13・Odin)で `zig build` し、**この ame-update が入っている場所**(全ユーザー用か自分用か)に入れ直す。
4. 動いている ame-shell に `ame-ctl restart` を送る。[窓はそのまま](#/tech-wm#restore)新しい版になる。
5. FreeBSD では、後から追加した設定(タッチパッド・Bluetooth・SDDM の背景)がまだなら行う。

**ame-update は自分自身も更新する**ので、新しい手順は「次に実行したとき」から有効になります。
