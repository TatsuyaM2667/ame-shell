# ame-shell コード検査レポート

検査環境: `nix develop`（flake.nix の devShell。zig 0.13.0 / odin dev-2026-10 / shellcheck 0.11.0 / ripgrep 15.2.0）。
wayland-scanner は devShell の PATH に無かったため nix store から補完し、EGL/GLESv2 の pkg-config は libglvnd-dev を追加して実行（いずれも環境側の問題で、リポジトリの変更ではない）。
検査は読み取りと機械検査のみ。install.sh・ame-shell・ame-session・zig build run は実行していない。

## サマリ

アーキテクチャの理解:

- ame-shell は 1 プロセス・1 EGL コンテキストの Wayland シェルデーモン。River 0.5 セッションでは内蔵 WM（src/wm/、dwindle 配置・スプリングアニメーション）も兼ねる
- 制御は Unix ソケット（`$XDG_RUNTIME_DIR/ame-shell-<display>.sock`、0600）経由の ame-ctl → src/ipc.zig
- 認証は ext-session-lock + PAM を fork 子プロセスで（src/lock.zig）。FreeBSD は setuid root の ame-auth（src/auth_helper.zig）に委譲。greetd の顔認証は pam_ame_face.so（ame-face 依存、root で動く）
- WASM ウィジェットは wasm3（WASI 無効・1MiB 固定メモリ・import は ame.action のみ）で実行し、コマンド配列をホストがゼロコピーで読む（src/wasm.zig + src/widget_abi.zig）
- 描画は全サーフェス wl_surface.frame 駆動で、止まっている間はフレーム要求も River への manage も出さない

全体評価: セキュリティ上の致命傷は見つからなかった。認証・秘密情報・IPC・外部データのパースは全体に丁寧で、README の仕様（顔認証 cos≥0.6・3 コマ・3 回失敗、ai-keys/face.bin の 0600 など）は実装と一致している。一方、この環境（glibc）では `zig build` がソースのコンパイルエラーで失敗するため、ame-shell 本体のフルビルドは確認できなかった。

最重要所見 3 つ:

1. （中）`zig build` が glibc 2.36+ の環境で失敗する — src/airpods.zig:296 の `c.connect(fd, @ptrCast(&sa), ...)` が新 glibc の `__CONST_SOCKADDR_ARG`(union) 型でコンパイルエラー。標的の Chimera(musl) では顕在化しない可能性があるが、glibc 系 Linux ではビルドできない
2. （中）FreeBSD の Wi-Fi 接続でパスワードが wpa_cli の argv に乗る — src/frame/netpanel.zig:717-718。短命プロセスとはいえ他のローカルユーザーの `ps`/procfs から読める。Linux 側は D-Bus 直叩きでコマンドラインに出ない
3. （低）試験用バックドア `AME_LOCK_FAKE`+`AME_SESSION_NESTED=1` でロックがパスワード "ame" で解除できる — src/lock.zig:424-426。その環境変数が設定されたセッションではロックが無力化される

## 機械検査の結果（フェーズ 1）

| コマンド | 結果 | 出力の要約 |
|---|---|---|
| `zig fmt --check .` | 失敗 (exit 1) | 未整形 4 ファイル: src/lyrics.zig, src/frame/vbar.zig, src/shot.zig, tools/cursorgen.zig |
| `zig build` (Debug) | 失敗 | 依存 ame-hand/ame-face は GitHub から取得成功。`src/airpods.zig:296:23: error: expected pointer type, found 'cimport.__CONST_SOCKADDR_ARG'` で ame-shell のビルドが停止（ame-ctl・ame-auth は生成済み） |
| `zig build test` | 成功 (exit 0) | 4/4 steps。pure_tests.zig の 3 test すべて pass |
| `odin check anim` | 单体では error | 「Undefined entry point procedure 'main'」は anim が `-no-entry-point` 前提のため想定内。`odin check anim -no-entry-point` は exit 0 |
| `zig build tools` | 成功 (exit 0) | zig-out/bin に vptr・vkbd を生成 |
| `shellcheck install.sh scripts/*.sh session/*.sh` | exit 1 | error 4 件: install.sh:321-322 の複数行 if 条件の途中にある `# shellcheck disable=SC2086` がパースを壊す (SC1009/SC1072/SC1073/SC1126)。`sh -n` は全ファイル OK なので実害なし。info 6 件 (SC2009×2, SC2012×2, SC2015, SC2016) |

## 所見の一覧

### 重大度 中

1. **glibc 環境でビルドできない（移植性）** — src/airpods.zig:296
   - 証拠: `if (c.connect(fd, @ptrCast(&sa), @sizeOf(SockaddrL2)) != 0 ...)`。zig build のエラー: `src/airpods.zig:296:23: error: expected pointer type, found 'cimport.__CONST_SOCKADDR_ARG'`
   - 影響: glibc 2.36 以降のヘッダでは `connect` の第 2 引数が transparent union 型になり `@ptrCast` が通らない。Chimera(musl)・FreeBSD では顕在化しないと思われるが、glibc 系 Linux では `zig build` が ame-shell 本体で失敗する
   - 修正案: `std.posix.connect(fd, @ptrCast(&sa), @sizeOf(SockaddrL2))` を使う（ipc_path.zig:11-13 と同じ方針。glibc/musl/FreeBSD で同じに書ける）

2. **FreeBSD: Wi-Fi パスワードがプロセスのコマンドラインに乗る** — src/frame/netpanel.zig:717-718
   - 証拠: `const q_pw = std.fmt.bufPrint(&pb, "\"{s}\"", .{st.pend_pw[0..st.pend_pw_len]}) ...; wpa(st, .wifi_radio, &.{ "set_network", ids, "psk", q_pw }, "");` → `wpa()` は argv0="wpa_cli" のジョブを `sys.spawnReaderAll`（execv, platform/sys.zig:427）で実行
   - 影響: シェル注入はないが、wpa_cli 実行中は psk が `ps`/procfs から同一マシンの他ユーザーに見える（短い時間だが接続処理中ずっと）。Linux 側は nmcli を D-Bus に横取りしておりコマンドラインには出ない（netpanel.zig:163, netdbus.zig:47-51）
   - 修正案: wpa_cli の対話モード（標準入力からコマンドを渡す）や `wpa_cli -a` のアクションスクリプト経由にする、あるいは psk を環境変数ではなく stdin で渡せる形に変える

### 重大度 低

3. **試験用バックドア** — src/lock.zig:424-426
   - 証拠: `const fake = std.posix.getenv("AME_LOCK_FAKE") != null and std.mem.eql(u8, std.posix.getenv("AME_SESSION_NESTED") orelse "", "1");` のときパスワード "ame" で解除
   - 影響: 両方の環境変数が設定された環境で ame-shell を動かしているとロック解除がパスワード "ame" で通る。ネストした試験セッション専用のつもりだが、環境変数はセッション全体に伝播するので本番セッションで誤設定すると致命的
   - 修正案: ビルド時フラグ（-Dtest-fake など）か、ネスト起動時にだけ有効な一時マジックファイルなど、環境変数以外のゲートにする

4. **PAM のユーザー名を環境変数で決定** — src/lock.zig:879-881
   - 証拠: `fn currentUser(buf) { const u = std.posix.getenv("USER") orelse std.posix.getenv("LOGNAME") ... }` → `pam_start(service, user, ...)`
   - 影響: セッション環境の USER/LOGNAME が細工されていると、入力パスワードはその別ユーザーのものとして照合される（そのユーザーの正しいパスワードが必要なので権限昇格にはならない）。sddmshare.zig:28 も同様に env の USER で書き出し先を決めるが access(W_OK) でゲートされている
   - 修正案: `std.posix.getuid()` + getpwuid で実 UID からユーザー名を取る（auth_helper.zig と同じ方針）

5. **`/bin/sh -c` 経由の spawnDetached に環境由来パスを埋め込む** — src/platform/sys.zig:384-396, src/frame/side.zig:518-519, src/shot.zig:746
   - 証拠: `spawnDetached` は `/bin/sh -c cmdline`。side.zig:518 は `-f '{s}'` に `$HOME/Videos/rec_*.mp4` を、shot.zig:746 は `D='{s}'` に `$HOME/Pictures/Screenshots` をシングルクォートで埋め込む
   - 影響: HOME にシングルクォートが含まれるとシェル構文が壊れて自己注入になるが、実行権限は呼び出しユーザーと同じなので権限昇格にはならない
   - 修正案: これらは argv 配列の execv 版（spawnReader 系）に置き換える。wf-recorder 起動は引数を分けて exec できる

6. **IPC ソケットに接続元 UID 検査がない** — src/ipc.zig:23-45
   - 証拠: bind 後 `c.chmod(p.ptr, 0o600)` はあるが、accept 時に SO_PEERCRED で uid を確認していない
   - 影響: XDG_RUNTIME_DIR は 0700 なので他ユーザーはそもそもソケットに到達できず実害は限定的。深層防御として
   - 修正案: accept 直後に getsockopt(SO_PEERCRED) で uid==getuid() を確認して閉じる

7. **zig fmt --check が 4 ファイルで失敗** — src/lyrics.zig, src/frame/vbar.zig, src/shot.zig, tools/cursorgen.zig
   - 影響: CI 等で書式検査をしている場合に失敗する
   - 修正案: `zig fmt` を適用するだけ

8. **shellcheck が install.sh:321-322 でパース不能** — SC1009/SC1072/SC1073/SC1126
   - 証拠: 複数行の if 条件の途中（`&&` の後）に `# shellcheck disable=SC2086` コメントがある
   - 影響: shellcheck がそのファイルの以降の検査を打ち切る。`sh -n` は通るので実行時の構文エラーではない
   - 修正案: ディレクティブを if 文の前に移動する

9. **ハンド認識モデルはハッシュ固定されていない** — src/hand/hand.zig:50, 1357-1390
   - 証拠: `MODEL_URL = "https://storage.googleapis.com/.../hand_landmarker.task"` を curl で取得し `.part`→rename。検証は `zip.isHandModel`（形式のみ）。対して顔モデルは SHA-256 検証あり（ame-face core.zig の readModel）
   - 影響: TLS が破られた場合や配信元が改ざんされた場合に悪性モデルが推論に使われる。README はハンド側にハッシュ検証を主張していないので仕様逸脱ではない
   - 修正案: 顔モデルと同様に SHA-256 を build 時にピン留めして検証する

### 参考（仕様どおり実装されていた項目）

- 顔認証: cos≥0.6（DEFAULT_THRESHOLD, MIN 0.5 でクランプ）・近い 2 つの平均・3 コマ連続・最大 6 秒・赤外線のみ — ame-face core.zig:9-10, 25-28, 123-137, 219-275。3 回失敗で無効 — src/lock.zig:33（MAX_FACE_FAILS=3）
- face.bin は .part に 0600 で書いて rename（src/face/unlock.zig:300-312）。PAM 側は NOFOLLOW＋所有者 uid＋group/other 書込不可＋サイズ上限で検査（ame-face core.zig:52-66）。root の顔認証はしない（pam_face.zig）。
- ai-keys は 0600 で原子的に書き換え（src/ai.zig:319-358）。API キーは curl の `-K -`（標準入力の設定）で渡しコマンドラインに出さず、使用後にバッファを消去（src/ai.zig:784-797）。送信本文の一時ファイルも 0600 で完了時削除
- 歌詞サイドカーのパスはプレーヤー名を英数・`_-.` のみに制限（`/` が弾かれるので遡及不可）— src/lyrics.zig:611-614
- WASM: メモリ 1MiB 固定・WASI 無効・import は ame.action のみ。ホストはコマンド配列の長さ・文字列ポインタ・state のいずれもメモリ長で検査し、トラップ時はウィジェットを停止 — src/wasm.zig:139-144, 176-192, 215-219
- ロック解除はロック画面のスナップをオーバーレイに出してから unlock_and_destroy（ripple）。コンポジタが finished を送った場合は unlock せず破棄のみ — src/lock.zig:417-460, 895-900
- WM はアニメーション中のみ River へ manage を送る — src/wm/wm.zig:1143（「止まっているとき通信 0」の仕様どおり）

## 確認できなかったこと

- **ame-shell 本体のフルビルドと実行**: この環境（glibc）では src/airpods.zig:296 のコンパイルエラーで `zig build` が失敗するため、リンク成功・起動・実行時の挙動は未確認。ame-ctl・ame-auth・vptr・vkbd・テストはビルド成功。pam_ame_face.so のビルドも ame-shell exe の失敗に巻き込まれ未確認（依存 ame-face 自体は取得済みで中身は読んだ）
- **実機でのセキュリティ挙動**: ロック解除アニメーション中にデスクトップが一瞬見える隙間があるか、顔認証の誤受理率、WASM ウィジェットの実地サンドボックス脱出耐性などは、Wayland セッションが必要なため机上確認のみ
- **マルチユーザー環境での ps 露見（所見 2）**: 実際に他ユーザーから見えるかはこの単一ユーザー環境では検証できなかった
- **odin check anim の素のエラー**: `-no-entry-point` 無しだと main 未定義で error になるが、build.zig が `-no-entry-point` でビルドするため想定内と判断。`-no-entry-point` 付きでは exit 0
- **shellcheck の install.sh パースエラー**: shellcheck 側のパーサ制限によるもので、`sh -n` は全スクリプト OK だった
- **wayland-scanner が devShell の PATH に無い点**: flake.nix は `wayland` パッケージで賄われる想定だが、この nixpkgs では別パッケージ（wayland-scanner）に分離されていた。環境の問題でありリポジトリの問題ではない
