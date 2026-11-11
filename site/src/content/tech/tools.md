# 小さな道具(Unix 哲学)

<p class="file">対象: src/cmd/*.zig / src/lib/*.zig / scripts/split-repos.sh / build.zig の cmds</p>

ame-shell は「画面を描く 1 つのプロセス」と「画面の要らない仕事をする小さなコマンドたち」に分かれています。小さなコマンドは 1 つのことだけをし、文字(テキストか 1 行 1 つの JSON)を標準入出力でやりとりします。ame-shell もそれを子プロセスとして動かして出力を読むだけなので、**端末からも同じものが使え、単独で試せます**。

:::easy このページを読む前に
Unix には「1 つのことをうまくやる小さな道具を、パイプ(`|`)でつないで使う」という考え方があります。`ls | grep zig` のように、ある道具の出力を別の道具の入力にできるのは、どの道具も「文字」でやりとりしているからです。

ame-shell の歌詞さがし・AI との会話・天気・鍵束なども、そういう小さな道具になっています。だから ame-shell が無くても、端末で `ame-weather Tokyo` と打てば天気が出ます。
:::

## 考え方 {#idea}

- **画面は 1 プロセス**(ame-shell)。描画と入力は 1 つの [[egl|EGL]] コンテキスト・1 つの [[epoll]] にまとめます(プロセスを増やすと GPU のドライバを何度も読み込み、メモリが増えるため)。
- **画面の要らない仕事は小さなコマンド**に分けます。止まったり落ちたりしても ame-shell は巻き込まれず、壊れたら単独で直して試せます。
- **部品(`src/lib/`)は画面にも OS にも依存しません**。コマンドと画面の両方が `@import("ame_lib")` で同じ部品を使い、試験は `zig build test` で走ります。
- **数値の重い処理は Odin(`anim/`)**、**他人が書けるウィジェットは WASM(`widgets/`)**、OS の違いは `src/platform/` に閉じ込めます。

## 道具の一覧 {#list}

| コマンド | すること | 入力 → 出力 |
|---|---|---|
| `ame-lyrics [-d 秒] アーティスト 曲名` | 同期歌詞を探す(music-tui・LRCLIB・NetEase・Kugou、キャッシュつき) | → LRC。終了コード 0 見つかった / 1 無い / 2 一時的な失敗 |
| `ame-ai [-p 会社] [-m モデル] [-i 画像]` | いろいろな会社の AI と話す。`--json` で会話と MCP のツール呼び出し | 質問 → 返事 / 会話の JSON → 出来事の JSON の行 |
| `ame-ai models` / `providers` | モデル・会社の一覧 | → 1 行 1 つ |
| `CLI の出力 \| ame-agent [-f 形式]` | Claude Code・Gemini・Codex・OpenCode・Kimi・Antigravity の出力を共通の出来事に | JSON の行 → 出来事の JSON の行 |
| `ame-agent sessions [フォルダ]` / `history フォルダ id` | Claude Code の会話の一覧・記録 | → JSON の行 |
| `ame-config check [ファイル]` / `path` | 設定ファイルの文法と値を確かめる・場所を出す | → 「ファイル:行: 内容」。終了コード 0 / 1 警告 / 2 読めない |
| `ame-weather [--json] [場所]` | 今の天気(wttr.in) | → 「12°C 晴れ(場所)」/ JSON。終了コード 0 / 1 分からない / 2 つながらない |
| `ame-airpods head` / `battery` / `find` | AirPods の頭の動き・電池・接続中のもの(AAP、Linux) | → 1 行 1 つの JSON(head は止めるまで流し続ける) |
| `ame-handtrack [-d カメラ]` | カメラに映った手の形と位置・関節 21 点 | → 1 行 1 つの JSON(止めるまで流し続ける) |
| `ame-keyring` / `ame-keyring list` | 鍵束(`org.freedesktop.secrets`)。Zed などが API キーをしまう(gnome-keyring の代わり) | D-Bus の Secret Service / 一覧 |
| `ame-ctl …` | 動いている ame-shell を操作する(`ame-ctl help`) | 引数 → 結果の文字 |
| `ame-ctl watch` | 出来事(ワークスペース・フォーカス・窓の開閉・通知・曲・ロック)を流し続ける | → 最初に今の状態、そのあと 1 行 1 つの JSON |

例:

```sh
echo 'Zig の comptime を一言で' | ame-ai -p anthropic
claude -p 直して --output-format stream-json --verbose | ame-agent -C "$PWD" | jq -r 'select(.type=="tool").title'
ame-ctl watch | jq -r 'select(.event=="workspace").workspace'   # ワークスペースが変わるたびに番号
ame-config check || echo "設定に間違いがあります"
```

## 終了コードで答える {#exit}

小さな道具は、結果の「種類」を終了コードで返します。例えば `ame-weather` は、0 = 取れた、1 = 場所が分からない、2 = つながらない。ame-shell はこれを見て、「場所の名前を見直して」と「ネットにつながっていません」を出し分けます。シェルスクリプトからも `if ame-weather …; then` で同じ判断ができます。

## 鍵束(ame-keyring) {#keyring}

Zed などのアプリは、API キーを `org.freedesktop.secrets`(Secret Service)という D-Bus の口にしまいます。この口を持つプロセス(普通は gnome-keyring)がいないと、キーは再起動のたびに消えます。ame-keyring はこの口を自前で持つ小さなデーモンです。

- 中身は `$XDG_DATA_HOME/ame-shell/keyring/login.keyring` に **XChaCha20-Poly1305** で暗号化して保存します(鍵は同じ場所の `master.key`、0600)。
- やりとりは平文のセッション(`plain`)だけです。同じユーザーのプロセスからしか D-Bus のセッションバスに入れないので、それで足ります。
- gnome-keyring を入れずに済み、ame-shell 以外への依存が増えません。

## 単独のリポジトリにも {#split}

`src/cmd` の道具は、どれも単独でビルドできるリポジトリにも切り出してあります([ame-lyrics](https://github.com/TatsuyaM2667/ame-lyrics)・[ame-ai](https://github.com/TatsuyaM2667/ame-ai)・[ame-agent](https://github.com/TatsuyaM2667/ame-agent)・[ame-config](https://github.com/TatsuyaM2667/ame-config)・[ame-weather](https://github.com/TatsuyaM2667/ame-weather)・[ame-airpods](https://github.com/TatsuyaM2667/ame-airpods)・[ame-handtrack](https://github.com/TatsuyaM2667/ame-handtrack)・[ame-keyring](https://github.com/TatsuyaM2667/ame-keyring))。正本は ame-shell(全部入り)で、`sh scripts/split-repos.sh` が、道具が使う `src/lib` の部品だけを集めて各リポジトリを生成・同期します。

新しい機能を足すときは、画面が要らない部分をまず `src/lib/` に純粋な関数として書いて試験を付け、外から使える意味があれば `src/cmd/` にコマンドを足します(`build.zig` の `cmds` と `session/install-session.sh` にも名前を足す)。

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
