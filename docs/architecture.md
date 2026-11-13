# アーキテクチャ

## 考え方(Unix 哲学)
- **画面は 1 プロセス**(ame-shell)。描画と入力は 1 つの EGL コンテキスト・1 つの epoll にまとめ、メモリの予算(PSS < 80MB)を守る。
- **画面の要らない仕事は小さなコマンド**に分ける。1 つのことをし、文字(テキスト / 1 行 1 つの JSON)を標準入出力でやりとりする。
  ame-shell もそれを子プロセスとして動かして出力を読むだけなので、端末からも同じものが使え、単独で試せる。
- **部品(src/lib/)は画面にも OS にも依存しない**。コマンドと画面の両方が `@import("ame_lib")` で使い、試験は `zig build test` で走る。
- **数値の重い処理は Odin(anim/。音の道具 odin/ も)**、**他人が書けるウィジェットは WASM(widgets/)**、OS の違いは `src/platform/` に閉じ込める。

## 小さな道具(zig-out/bin)
| コマンド | すること | 入力 → 出力 |
|---|---|---|
| `ame-lyrics [-d 秒] アーティスト 曲名` | 歌詞を探す(music-tui・LRCLIB・NetEase・Kugou、キャッシュつき) | → LRC。終了コード 0 見つかった / 1 無い / 2 一時的な失敗 |
| `ame-ai [-p 会社] [-m モデル]` | いろいろな会社の AI と話す。`--json` で会話と MCP のツール呼び出し | 質問 → 返事 / 会話の JSON → 出来事の JSON の行 |
| `ame-ai models` / `ame-ai providers` | モデル・会社の一覧 | → 1 行 1 つ |
| `CLI の出力 \| ame-agent [-f 形式]` | Claude Code・Gemini・Codex・OpenCode・Kimi の出力を共通の出来事に | JSON の行 → 出来事の JSON の行 |
| `ame-agent sessions [フォルダ]` / `history フォルダ id` | Claude Code の会話の一覧・記録 | → JSON の行 |
| `ame-config check [ファイル]` / `path` | 設定ファイルの文法と値を確かめる・場所を出す | → 「ファイル:行: 内容」。終了コード 0 / 1 警告 / 2 読めない |
| `ame-kuraokami [--json] [場所]` | 今の天気(wttr.in) | → 「12°C 晴れ(場所)」/ JSON。終了コード 0 / 1 分からない / 2 つながらない |
| `ame-airpods head` / `battery` / `find` | AirPods の頭の動き・電池・接続中のもの(AAP、Linux) | → 1 行 1 つの JSON(head は止めるまで流し続ける) |
| `ame-handtrack [-d カメラ]` | カメラに映った手の形と位置・関節 21 点(ame-hand で推論) | → 1 行 1 つの JSON(status / frame。止めるまで流し続ける) |
| `ame-keyring` / `ame-keyring list` | 鍵束(org.freedesktop.secrets)。Zed などが API キー・パスワードをしまう(gnome-keyring の代わり) | D-Bus の Secret Service / 名前と属性の一覧 |
| `amaterasu` / `amaterasu set 40`(`+5`・`-5`)/ `restore` | 画面の明るさ(sysfs、書けなければ logind の SetBrightness。brightnessctl の代わり)。set した値を覚え、ログインで戻す | → 0〜100 の数 |
| `ame-tajikara` / `set 名前` / `restore` | 電源プロファイル(power-profiles-daemon に D-Bus。powerprofilesctl の代わり)。覚えて戻す | → power-saver / balanced / performance |
| `ame-uzume` / `set N`(`+N`・`-N`)/ `mute [on・off]` / `restore` / `watch` | 音量(Odin。libpulse を実行時に読む。wpctl・`pactl subscribe` の代わり)。覚えて戻す | → 「45」/「45 muted」。watch は変わるたびに 1 行 |
| `ame-hamon [-b 本数]` | 今鳴っている音のスペクトラム(Odin。@DEFAULT_MONITOR@ を録って FFT。cava の代わり) | → 棒の高さ 0〜1000 を ';' でつないだ行(1 秒に約 60 行。無音の間は書かない) |
| `ame-yatagarasu [curl と同じオプション] URL` | URL の中身を取ってくる(HTTP/1.1 は自前、暗号は OpenSSL。curl の代わり) | → 中身。終了コードも curl と同じ番号 |
| `ame-emaki -f 保存先 [--no-audio] [--cpu]` | 画面を動画に録る(ext-image-copy-capture で撮り、ffmpeg が変換。wf-recorder の代わり) | SIGINT で保存して終わる |
| `ame-iwato [-f]` | 画面をロックする(単体。ext-session-lock + PAM。swaylock の代わり) | 正しいパスワードで 0 |
| `ame-copy [-t 種類]`(標準入力から)/ `ame-paste [-t 種類]`・`ame-paste -l` | クリップボード(ext-data-control。wl-copy・wl-paste の代わり) | 標準入力 → クリップボード → 標準出力 |
| `ame-ctl …` | 動いている ame-shell を操作する(`ame-ctl help`) | 引数 → 結果の文字 |
| `ame-ctl watch` | 出来事(ワークスペース・フォーカス・窓の開閉・通知・曲・ロック)を流し続ける | → 最初に今の状態(hello)、そのあと 1 行 1 つの JSON |
| `ame-auth` | ロック画面のパスワード照合(FreeBSD、setuid。ame-shell の中のロックと ame-iwato が使う) | — |

例: `echo 'Zig の comptime を一言で' | ame-ai -p anthropic`、
`claude -p 直して --output-format stream-json --verbose | ame-agent -C "$PWD" | jq -r 'select(.type=="tool").title'`

名前の多くは日本の神話から(天照大神・天手力男神・天宇受売命・八咫烏・天岩戸・闇龗神・千手観音・八咫鏡)、ほかに波紋・絵巻。
古い名前(ame-light・ame-power・ame-weather・ame-vol・ame-spectrum)は、しばらく新しい名前へのリンクとして入る。

道具は、どれも単独でビルドできるリポジトリにも切り出してある
([amaterasu](https://github.com/TatsuyaM2667/amaterasu)・[ame-tajikara](https://github.com/TatsuyaM2667/ame-tajikara)・[ame-uzume](https://github.com/TatsuyaM2667/ame-uzume)・[ame-hamon](https://github.com/TatsuyaM2667/ame-hamon)・[ame-yatagarasu](https://github.com/TatsuyaM2667/ame-yatagarasu)・[ame-emaki](https://github.com/TatsuyaM2667/ame-emaki)・[ame-iwato](https://github.com/TatsuyaM2667/ame-iwato)・[ame-clip](https://github.com/TatsuyaM2667/ame-clip)・[ame-lyrics](https://github.com/TatsuyaM2667/ame-lyrics)・[ame-ai](https://github.com/TatsuyaM2667/ame-ai)・[ame-agent](https://github.com/TatsuyaM2667/ame-agent)・[ame-config](https://github.com/TatsuyaM2667/ame-config)・[ame-kuraokami](https://github.com/TatsuyaM2667/ame-kuraokami)・[ame-airpods](https://github.com/TatsuyaM2667/ame-airpods)・[ame-handtrack](https://github.com/TatsuyaM2667/ame-handtrack)・[ame-keyring](https://github.com/TatsuyaM2667/ame-keyring))。
Zig の道具は `zig build`、Odin の道具は `sh build.sh` と `odin test .`、Wayland の道具はプロトコルの XML を持ち、ビルドで wayland-scanner を通す。
正本はこの ame-shell(全部入り)で、切り出したものは `sh scripts/split-repos.sh` が生成して同期する(道具を直したら実行し直す)。

## ソースの置き場
```
src/
  main.zig ctl.zig auth_helper.zig   実行ファイルの入口(ame-shell / ame-ctl / ame-auth)
  c.zig                               C ライブラリの取り込み(ここ 1 か所だけ)
  core/      本体の状態と Wayland の接続(app)・設定(config)・ame-ctl の口(ipc)・サーフェス・足りない道具の案内
  gfx/       GLES3 の 2D レンダラ・文字(HarfBuzz/FreeType)・アイコン・PNG・配色・アニメ(Odin へのつなぎ)・波紋
  frame/     画面の枠: 縦のバー・ダイナミックアイランド・AI のパネル・ダッシュボードの中身など
  desktop/   バー・ダッシュボード・ランチャー・通知・OSD・壁紙(と動画)・スクショ・クリップボード・日本語入力・システムの変化の監視
  lock/      ロック画面(状態と認証 / 見た目)・ログイン画面
  media/     再生中の曲(MPRIS)・音の出力先・歌詞(ame-lyrics を呼ぶ)・曲のカードとウィジェット
  ai/        AI チャット(ame-ai を呼ぶ)・コーディング CLI(出力の読み方は lib/agentfmt)・MCP の選択
  device/    AirPods(ame-airpods を動かして頭の動きを操作に・つないだときのカード・スリープ後のつなぎ直し)
  widget/    WASM ウィジェットの実行(wasm3)とホストとの取り決め(ABI)
  wm/        River 0.4 以降で使う内蔵のウィンドウマネージャ
  hand/ face/  手の操作(認識は ame-handtrack を動かす)・顔の認証(カメラ)
  platform/  OS ごとの違い(Linux / FreeBSD)・イベントループ
  lib/       画面にも OS にも依存しない部品(lrc・ai・mcp・agentfmt・appid・config・weather・aap・secretstore)
  cmd/       Zig の小さな道具(ame-lyrics・ame-ai・ame-agent・ame-config・ame-kuraokami・ame-airpods・ame-handtrack・ame-keyring・
             amaterasu・ame-tajikara・ame-yatagarasu・ame-emaki・ame-iwato・ame-clip(ame-copy / ame-paste)。sysbus.zig は D-Bus の共通の包み)
anim/        Odin: ばね・あいまい検索・主色抽出・FFT・画像の縮小(C ABI。wasm32 にも同じものをビルド)
odin/        Odin の小さな道具(ame-uzume・ame-hamon。zig build が odin build / odin test を呼ぶ)
widgets/     WASM ウィジェット(Zig → wasm32)
```
新しい機能を足すとき: 画面が要らない部分はまず `src/lib/` に純粋な関数として書いて試験を付け、
外から使える意味があれば `src/cmd/`(Zig)か `odin/<名前>/`(Odin)にコマンドを足す(`build.zig` の `cmds` / `odin_cmds`、`session/install-session.sh`、`scripts/split-repos.sh` にも名前を足す)。

## プロセスの図
```
                       ┌──────────────── ame-shell(1プロセス・1 EGL コンテキスト)────────────────┐
 River ◀─Wayland──▶   │ core/app       globals / 出力 / seat / River status・control / 入力配送       │
 (layer-shell,        │ core/surface   layer/lock サーフェス。wl_surface.frame 駆動の描画              │
  session-lock,       │ gfx/gfx        GLES3 2D レンダラ(インスタンス化した1種類の四角形 + SDF)        │
  river-wm)           │ gfx/text       fontconfig → HarfBuzz → FreeType SDF → 共有グリフアトラス      │
                       │ gfx/anim ────▶ anim/*.odin(Odin: ばね/ファジー/主色/FFT/縮小, C ABI)         │
                       │ desktop/ lock/ media/ ai/ frame/ wm/                                          │
                       │ widget/wasm ─▶ wasm3(C)── widgets/*.wasm(Zig + Odin を wasm32 に)         │
                       │ core/ipc       Unix ソケット ◀── ame-ctl(Zig, libc のみ)                    │
                       │ platform/      loop(epoll+timerfd) / sys(sysfs, procfs, 外部コマンド)      │
                       └───────┬──────────────────────────────────────────────────────────────────────┘
                               │ 子プロセス(標準入出力・1 行 1 つの JSON)
                               ├── ame-uzume watch(音量の変化)・ame-hamon(スペクトラム)  ── libpulse
                               ├── amaterasu・ame-tajikara(明るさ・電源)                    ── システムの D-Bus
                               ├── ame-lyrics(歌詞)・ame-kuraokami(天気)                  ── ame-yatagarasu
                               ├── ame-ai(AI・MCP)                                         ── ame-yatagarasu / MCP サーバ
                               ├── ame-emaki(録画)                                         ── ffmpeg
                               └── claude などのコーディング CLI(出力は lib/agentfmt で読む。ame-agent と同じ)
```

## イベントループ
全てのデータ源を fd として 1 つの epoll に入れる。

| fd | 起きるタイミング |
|---|---|
| Wayland | コンポジタからのイベント(入力・frame done・configure・River の状態) |
| clock timerfd | 次の「分」の境目ちょうど(秒表示時は秒) |
| sys timerfd | 20 秒ごと(バッテリー・ネットワーク・明るさ) |
| wallpaper timerfd | ライブ壁紙の FPS ごと(AC/バッテリーで切替、静止時は停止) |
| `ame-uzume watch` の pipe | 音量が変わったときだけ(新しい音量の 1 行が来る) |
| MPRIS(セッションの D-Bus)の fd | 曲・再生状態・シークが変わったときだけ |
| `ame-hamon` の pipe | メディアのタブ・ロック画面・アイランドで曲が流れている間だけ(約 1/60 秒ごと。無音の間は来ない) |
| D-Bus fd | 通知が来たとき |
| inotify | 設定ファイル / ウィジェット .wasm の保存時 |
| IPC ソケット | ame-ctl 実行時 |
| 各種 one-shot timerfd | OSD の自動非表示、通知の期限、キーリピート、ダッシュボードの 1 秒更新(開いている間だけ) |

## 描画モデル
1. 状態が変わる → `Surface.schedule()` が `wl_surface.frame` を要求してコミット
2. コンポジタの `done` で `render(dt)` → 各部品の `draw()` がスプリングを `dt` だけ進め、命令を積む
3. まだ動いていれば次のフレームを要求(eglSwapBuffers の commit に相乗り)。止まれば何もしない
4. `eglSwapInterval(0)`: 同期はフレームコールバックで取るので、複数サーフェスが互いの vblank を待たない

## ガラス
- 壁紙を出力ごとの FBO(`Backdrop.scene`)に描き、dual Kawase(down×N, up×1)でぼかした `blurred` を保持。
- パネルのシェーダはサーフェスの出力上の位置 `u_origin` を足して「真後ろ」をサンプル。
- 縁は SDF の勾配を法線として UV をずらし(屈折)、RGB を少しずらして(色収差)、左上光源で縁のハイライト、ハッシュノイズとスパークルを加算。
- 他のアプリのウィンドウ越しのブラーは、River 0.3.5 が `ext_background_effect` を出していないため不可能(確認済み)。ウィンドウ上に出るポップアップは色を濃くして対応。

## WASM ウィジェット
- ABI: `src/widget/widget_abi.zig`(ホストとウィジェットの両方が import)。
- ウィジェットは自分のメモリにコマンド配列とストアを持ち、ホストはそれを `m3_GetMemory` で直接読み書きする(ゼロコピー)。
- import は `ame.action(i32, f32)` だけ。WASI 無効、メモリ 1MiB 固定。不正なコマンド種別は無視、文字列は境界チェック。
- ホットリロード: inotify で `.wasm` の更新を検知 → `ame_state()` の領域を退避 → 再インスタンス化 → サイズが同じなら書き戻す。

## 設定
`config.ame`(KDL/TOML 風 DSL、`src/core/config.zig`)。ディレクトリを inotify で監視し、保存した瞬間に再読込。
