# 小さな道具(Unix 哲学)

<p class="file">対象: src/cmd/*.zig / odin/*/ / src/lib/*.zig / scripts/split-repos.sh / build.zig の cmds・odin_cmds</p>

ame-shell は「画面を描く 1 つのプロセス」と「画面の要らない仕事をする小さなコマンドたち」に分かれています。小さなコマンドは 1 つのことだけをし、文字(テキストか 1 行 1 つの JSON)を標準入出力でやりとりします。ame-shell もそれを子プロセスとして動かして出力を読むだけなので、**端末からも同じものが使え、単独で試せます**。

:::easy このページを読む前に
Unix には「1 つのことをうまくやる小さな道具を、パイプ(`|`)でつないで使う」という考え方があります。`ls | grep zig` のように、ある道具の出力を別の道具の入力にできるのは、どの道具も「文字」でやりとりしているからです。

ame-shell の歌詞さがし・AI との会話・天気・鍵束・明るさ・音量・録画・ロックなども、そういう小さな道具になっています。だから ame-shell が無くても、端末で `ame-kuraokami Tokyo` と打てば天気が出ますし、`amaterasu set +5` で画面が明るくなります。

名前の多くは日本の神話から取りました。ame は「雨」と「天(あめ)」の両方で、神話の神には「天之(あめの)〜」で始まる名前が多いからです。
:::

## 考え方 {#idea}

- **画面は 1 プロセス**(ame-shell)。描画と入力は 1 つの [[egl|EGL]] コンテキスト・1 つの [[epoll]] にまとめます(プロセスを増やすと GPU のドライバを何度も読み込み、メモリが増えるため)。
- **画面の要らない仕事は小さなコマンド**に分けます。止まったり落ちたりしても ame-shell は巻き込まれず、壊れたら単独で直して試せます。
- **部品(`src/lib/`)は画面にも OS にも依存しません**。コマンドと画面の両方が `@import("ame_lib")` で同じ部品を使い、試験は `zig build test` で走ります。
- **数値と音の処理は Odin**(`anim/` と、音の道具 `odin/`)、D-Bus・Wayland・OpenSSL につなぐ道具は Zig、**他人が書けるウィジェットは WASM(`widgets/`)**、OS の違いは `src/platform/` に閉じ込めます。

## 道具の一覧 {#list}

| コマンド | すること | 入力 → 出力 |
|---|---|---|
| `ame-lyrics [-d 秒] アーティスト 曲名` | 同期歌詞を探す(music-tui・LRCLIB・NetEase・Kugou、キャッシュつき) | → LRC。終了コード 0 見つかった / 1 無い / 2 一時的な失敗 |
| `ame-ai [-p 会社] [-m モデル] [-i 画像]` | いろいろな会社の AI と話す。`--json` で会話と MCP のツール呼び出し | 質問 → 返事 / 会話の JSON → 出来事の JSON の行 |
| `ame-ai models` / `providers` | モデル・会社の一覧 | → 1 行 1 つ |
| `CLI の出力 \| ame-agent [-f 形式]` | Claude Code・Gemini・Codex・OpenCode・Kimi・Antigravity の出力を共通の出来事に | JSON の行 → 出来事の JSON の行 |
| `ame-agent sessions [フォルダ]` / `history フォルダ id` | Claude Code の会話の一覧・記録 | → JSON の行 |
| `ame-config check [ファイル]` / `path` | 設定ファイルの文法と値を確かめる・場所を出す | → 「ファイル:行: 内容」。終了コード 0 / 1 警告 / 2 読めない |
| `ame-kuraokami [--json] [場所]` | 今の天気(wttr.in) | → 「12°C 晴れ(場所)」/ JSON。終了コード 0 / 1 分からない / 2 つながらない |
| `ame-airpods head` / `battery` / `find` | AirPods の頭の動き・電池・接続中のもの(AAP、Linux) | → 1 行 1 つの JSON(head は止めるまで流し続ける) |
| `ame-handtrack [-d カメラ]` | カメラに映った手の形と位置・関節 21 点 | → 1 行 1 つの JSON(止めるまで流し続ける) |
| `ame-keyring` / `ame-keyring list` | 鍵束(`org.freedesktop.secrets`)。Zed などが API キーをしまう(gnome-keyring の代わり) | D-Bus の Secret Service / 一覧 |
| `amaterasu` / `set 40`(`+5`・`-5`)/ `restore` | 画面の明るさ。set した値を覚え、ログインで戻す(brightnessctl の代わり) | → 0〜100 の数 |
| `ame-tajikara` / `set 名前` / `restore` | 電源プロファイル。覚えて戻す(powerprofilesctl の代わり) | → power-saver / balanced / performance |
| `ame-uzume` / `set N`(`+N`・`-N`)/ `mute` / `restore` / `watch` | 音量と消音(Odin)。覚えて戻す(wpctl・`pactl subscribe` の代わり) | → 「45」/「45 muted」。watch は変わるたびに 1 行 |
| `ame-hamon [-b 本数]` | 今鳴っている音のスペクトラム(Odin。cava の代わり) | → 棒の高さ 0〜1000 を ';' でつないだ行 |
| `ame-yatagarasu [curl と同じ] URL` | URL の中身を取ってくる(curl の代わり) | → 中身。終了コードも curl と同じ |
| `ame-emaki -f 保存先` | 画面を動画に録る(wf-recorder の代わり) | SIGINT で保存して終わる |
| `ame-iwato [-f]` | 画面をロックする(swaylock の代わり) | 正しいパスワードで 0 |
| `ame-copy` / `ame-paste [-l]` | クリップボードに入れる・出す(wl-copy・wl-paste の代わり) | 標準入力 → クリップボード → 標準出力 |
| `ame-ctl …` | 動いている ame-shell を操作する(`ame-ctl help`) | 引数 → 結果の文字 |
| `ame-ctl watch` | 出来事(ワークスペース・フォーカス・窓の開閉・通知・曲・ロック)を流し続ける | → 最初に今の状態、そのあと 1 行 1 つの JSON |

例:

```sh
echo 'Zig の comptime を一言で' | ame-ai -p anthropic
claude -p 直して --output-format stream-json --verbose | ame-agent -C "$PWD" | jq -r 'select(.type=="tool").title'
ame-ctl watch | jq -r 'select(.event=="workspace").workspace'   # ワークスペースが変わるたびに番号
ame-config check || echo "設定に間違いがあります"
amaterasu set +5; ame-uzume set 40                           # 明るさを 5% 上げ、音量を 40% に
ame-uzume watch | while read v; do echo "音量: $v"; done        # 音量が変わるたびに 1 行
ame-yatagarasu -sSf -w '\n%{http_code}' https://wttr.in/?format=3
ame-emaki -f ~/Videos/a.mp4                                     # Ctrl+C で保存して終わる
echo hi | ame-copy; ame-paste
```

## 終了コードで答える {#exit}

小さな道具は、結果の「種類」を終了コードで返します。例えば `ame-kuraokami` は、0 = 取れた、1 = 場所が分からない、2 = つながらない。ame-shell はこれを見て、「場所の名前を見直して」と「ネットにつながっていません」を出し分けます。シェルスクリプトからも `if ame-kuraokami …; then` で同じ判断ができます。

## 名前の由来 {#names}

| 道具 | 名前 | 由来 |
|---|---|---|
| 明るさ | amaterasu | 光の神、天照大神(あまてらす) |
| 電源プロファイル | ame-tajikara | 力の神、天手力男神(あめのたぢからお) |
| 音量 | ame-uzume | 天岩戸の前で舞い、音を鳴らした芸能の神、天宇受売命(あめのうずめ) |
| スペクトラム | ame-hamon | 雨粒が水面に広げる波紋 |
| 通信 | ame-yatagarasu | 遠くへ道案内をし、ものを運ぶ八咫烏(やたがらす) |
| 録画 | ame-emaki | 動く場面を巻物に残す絵巻 |
| ロック | ame-iwato | 天照大神がこもって世界を閉ざした天岩戸 |
| 天気 | ame-kuraokami | 雨を司る龍神、闇龗神(くらおかみ) |
| 手の認識(別のリポジトリ) | ame-senju | 千の手を持つ千手観音 |
| 顔認証(別のリポジトリ) | ame-kagami | 顔を映す八咫鏡(三種の神器) |

天照・宇受売・手力男は、どれも天岩戸の話に出てきます。古い名前(ame-light・ame-power・ame-weather・ame-vol・ame-spectrum)は、しばらく新しい名前へのリンクとして入ります。

## 明るさ・音量・電源を覚えて戻す {#restore}

Linux は起動のたびに画面の明るさをファームウェアの値に戻します。音量は出力の機器(スピーカー・イヤホン)ごとに別に覚えられるので、イヤホンの無い起動では、昔スピーカーで消した音量に戻ることがあります。そこで amaterasu・ame-uzume・ame-tajikara は、**自分で set した値を `~/.local/state/ame-shell/` に覚え**、ログインのときに `restore` で戻します(セッションの init が呼ぶ)。何も覚えていなければ何もしません。

明るさの `/sys/class/backlight/*/brightness` は普通 root しか書けません。amaterasu は書けなければ logind(elogind)の `Session.SetBrightness` に頼むので、root も setuid も要りません。

## 音の道具は Odin(ame-uzume・ame-hamon) {#odin}

音量は PulseAudio の口(PipeWire なら pipewire-pulse)に libpulse で話します。libpulse は**実行時に読む**ので、ヘッダも -dev パッケージも要りません。`ame-uzume watch` は音量が変わるたびに新しい値の 1 行を書くので、ame-shell は読み直さずに済みます(以前は `pactl subscribe` の行が来るたびに `wpctl` をもう 1 つ起こしていました)。

ame-hamon は今鳴っている音(`@DEFAULT_MONITOR@`)を録り、窓をかけて FFT(ame-shell と同じ `anim/fft.odin`)、50Hz〜12kHz を対数で分けて dB にし、最近の大きい音でそろえて、棒の高さを 1 行ずつ書きます(cava の raw ascii と同じ形)。全部 0 の行は続けて書かないので、無音の間は読む側(ame-shell)を起こしません。ame-shell は波形が見えている間だけ ame-hamon を動かします。

`zig build` が `odin/<名前>/` を `odin build` で実行ファイルにし、`odin test` も走らせます。

## 通信(ame-yatagarasu) {#fetch}

HTTP/1.1(chunked・転送・`-w '%{http_code}'`・`-K -` の設定・`-G` / `--data-urlencode`)は自分で話し、暗号(TLS 1.2 / 1.3)とサーバの証明書の確認だけを OpenSSL に任せます。ame-shell の道具が使っていた curl のオプションをそのまま読み、終了コードも curl と同じ番号(22 = HTTP の誤り、28 = 時間切れ、60 = 証明書が正しくない…)なので、呼ぶ側は名前を変えるだけで済みました。

Zig 0.13 の標準の HTTP は TLS 1.3 しか話せないので使っていません。暗号は自作しません。

## 録画(ame-emaki) {#rec}

画面は ext-image-copy-capture で**変わったときだけ** 1 コマ撮り、生の画素を ffmpeg の標準入力に流します。変換は GPU(VAAPI の H.264)を先に試し、使えなければ CPU(libx264)。音は `@DEFAULT_MONITOR@`。

- 時刻は届いたまま書きます(`-fps_mode passthrough`)。`vfr` にすると 25 コマ/秒に並べ直され、動画が実際より短くなりました。
- 画面が止まっている間も 1 秒ごとに同じコマを送ります(送らないと、動画が最後に変わった所で終わってしまう)。
- 止めるときは ffmpeg の入力を閉じてから SIGINT を送ります。音の入力は自分では終わらないためです。

## ロック(ame-iwato) {#lock}

ame-shell の中のロック画面(顔認証・曲のカードつき)とは別の、**どのコンポジタでも動く単体のロック画面**です。ext-session-lock で全部の画面を閉ざし、雨の夜の色の上に入力の輪を出します。打った数だけ点が増え、確かめている間は輪が欠けて橙、違ったときは点が消えて赤(色だけに頼らない)。

照合は PAM を子プロセスで行います(FreeBSD は setuid の ame-auth)。照合できない構成ならロックしません(閉じ込め防止)。ame-shell が落ちてロックが残ったときは、別の端末から `WAYLAND_DISPLAY` を合わせて `ame-iwato` を実行すると外せます。

## クリップボード(ame-copy / ame-paste) {#clip}

1 つの実行ファイルを 2 つの名前で入れ、呼ばれた名前で動きを変えます。ext-data-control を使います(River 0.5 / wlroots 0.19 以降)。ame-copy は裏に回り、ほかのアプリがクリップボードを取るまで渡し続けます(wl-copy と同じ)。

## 鍵束(ame-keyring) {#keyring}

Zed などのアプリは、API キーを `org.freedesktop.secrets`(Secret Service)という D-Bus の口にしまいます。この口を持つプロセス(普通は gnome-keyring)がいないと、キーは再起動のたびに消えます。ame-keyring はこの口を自前で持つ小さなデーモンです。

- 中身は `$XDG_DATA_HOME/ame-shell/keyring/login.keyring` に **XChaCha20-Poly1305** で暗号化して保存します(鍵は同じ場所の `master.key`、0600)。
- やりとりは平文のセッション(`plain`)だけです。同じユーザーのプロセスからしか D-Bus のセッションバスに入れないので、それで足ります。
- gnome-keyring を入れずに済み、ame-shell 以外への依存が増えません。

## 単独のリポジトリにも {#split}

道具は、どれも単独でビルドできるリポジトリにも切り出してあります。正本は ame-shell(全部入り)で、`sh scripts/split-repos.sh` が、道具が使う部品だけを集めて各リポジトリを生成・同期します。

- Zig の道具(`zig build`): [amaterasu](https://github.com/TatsuyaM2667/amaterasu)・[ame-tajikara](https://github.com/TatsuyaM2667/ame-tajikara)・[ame-yatagarasu](https://github.com/TatsuyaM2667/ame-yatagarasu)・[ame-lyrics](https://github.com/TatsuyaM2667/ame-lyrics)・[ame-ai](https://github.com/TatsuyaM2667/ame-ai)・[ame-agent](https://github.com/TatsuyaM2667/ame-agent)・[ame-config](https://github.com/TatsuyaM2667/ame-config)・[ame-kuraokami](https://github.com/TatsuyaM2667/ame-kuraokami)・[ame-airpods](https://github.com/TatsuyaM2667/ame-airpods)・[ame-handtrack](https://github.com/TatsuyaM2667/ame-handtrack)・[ame-keyring](https://github.com/TatsuyaM2667/ame-keyring)
- Odin の道具(`sh build.sh`・`odin test .`): [ame-uzume](https://github.com/TatsuyaM2667/ame-uzume)・[ame-hamon](https://github.com/TatsuyaM2667/ame-hamon)
- Wayland の道具(プロトコルの XML を持ち、ビルドで wayland-scanner を通す): [ame-emaki](https://github.com/TatsuyaM2667/ame-emaki)・[ame-iwato](https://github.com/TatsuyaM2667/ame-iwato)・[ame-clip](https://github.com/TatsuyaM2667/ame-clip)
- 推論(ame-shell が依存として取ってくる): [ame-senju](https://github.com/TatsuyaM2667/ame-senju)(手)・[ame-kagami](https://github.com/TatsuyaM2667/ame-kagami)(顔)

新しい機能を足すときは、画面が要らない部分をまず `src/lib/` に純粋な関数として書いて試験を付け、外から使える意味があれば `src/cmd/`(Zig)か `odin/<名前>/`(Odin)にコマンドを足します(`build.zig` の `cmds` / `odin_cmds`、`session/install-session.sh`、`scripts/split-repos.sh` にも名前を足す)。

## 研究者向けの補足 {#research}

:::research プロセス分割の境界の決め方
境界は「画面(GPU のコンテキスト)を持つかどうか」で引いています。GPU のドライバはプロセスごとに数十 MB を読み込むので、画面を持つプロセスは 1 つに保ち、それ以外を分けます。分けたコマンドとの間は文字の行(JSON Lines)で、型の取り決めは `src/lib` の同じ構造体を両側が使うことで保証しています(直列化の形式を 2 か所で書かない)。
:::

## 関連する用語 {#terms}

- [[pipe]]
- [[fork-exec]]
- [[unix-socket]]
- [[dbus]]
- [[posix-sh]]
