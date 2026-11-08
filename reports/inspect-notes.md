# ame-shell コード検査メモ

## フェーズ 0: 全体把握

### 環境（`nix develop` 内で確認）
- zig 0.13.0（build.zig.zon の minimum_zig_version と一致）
- odin dev-2026-10（flake は dev-2026-08 を想定も nixpkgs 版で代替）
- pkg-config 0.29.2 / shellcheck 0.11.0 / ripgrep 15.2.0
- wayland-scanner は devShell の PATH に無い（別途確認予定。ビルド時に必要なら build.zig が解決するか確認）

### ファイル一覧（rg --files: 計 612 ファイル）
- src/: 約 50 ファイル。主要: main.zig, ctl.zig, lockui.zig, auth_helper.zig, lock.zig,
  ipc.zig, ipc_path.zig, widget_abi.zig, wasm.zig, wm/（wm.zig, binds.zig, touchpad.zig, wobble.zig）,
  hand/（hand.zig, poses.zig, posegui.zig, custom.zig）, face/unlock.zig, frame/（data.zig, dash.zig,
  island.zig, side.zig, vbar.zig, aipanel.zig, netpanel.zig, frame.zig, warm_strings.zig）,
  platform/（loop.zig, bsd.zig, sys.zig, netdbus.zig, supertap.zig）, その他多数
  （lyrics.zig, mpris.zig, ai.zig, mcp.zig, clipboard.zig, shot.zig, wallpaper.zig, wallpick.zig,
  video.zig, png.zig, audio.zig, notify.zig, portal.zig, greeter.zig, sddmshare.zig, config.zig 等）
- anim/: anim.odin, fft.odin
- widgets/: sysmon.zig, clock.zig, controls.zig, media.zig, ame.zig, calendar.zig（WASM ウィジェット）
- protocol/: river 系 + wlr/ext 系 Wayland プロトコル XML（26 本）
- session/: ame-session, ame-shell.desktop 等のセッションスクリプト
- scripts/: install-*.sh, freebsd-*.sh 等
- tools/: vptr.zig, vkbd.zig, cursorgen.zig（試験道具）
- third_party/: wasm3, stb_image, nanosvg（vendored）
- site/: ドキュメントサイト（zig 製ジェネレータ）
- docs/: architecture.md 等の開発ドキュメント

### 次に読むもの（優先順）
1. README.md（仕様の主張）
2. build.zig / build.zig.zon（成果物と依存）
3. docs/architecture.md
4. src/main.zig → ctl.zig, lockui.zig, auth_helper.zig, ipc.zig, widget_abi.zig, wm/, hand/, face/

### アーキテクチャ要約（README.md + docs/architecture.md + build.zig から確認）
- プロセス構成: ame-shell(1プロセス・1EGLコンテキストのデーモン) + ame-ctl(制御CLI, libcのみ) +
  ame-auth(FreeBSD で setuid root の PAM 照合補助) + pam_ame_face.so(greetd 用 PAM, root で動く) +
  WASM ウィジェット(wasm3, WASI無効, 1MiB固定メモリ)
- IPC: Unix ソケット経由の ame-ctl → ipc.zig（ソケットパスは src/ipc_path.zig）
- 描画: Wayland layer-shell / session-lock サーフェスを GLES3 2D レンダラ(gfx.zig)で描画。
  wl_surface.frame 駆動、止まっていれば通信 0。anim/anim.odin がスプリング等のコア
- 認証フロー: ロック画面(ext-session-lock + PAM。src/lockui.zig)→ パスワード or 顔認証。
  顔: cos ≥ 0.6・3コマ一致・3回失敗で無効、登録特徴は ~/.local/share/ame-shell/face.bin。
  FreeBSD は ame-auth(setuid) に照合を委譲。greetd では pam_ame_face.so
- 外部データ: 同期歌詞(プレーヤーLRC → キャッシュ → music-tui → LRCLIB → NetEase → 酷狗)、
  MPRIS メタデータ、AI応答、WASMウィジェット入力、スクショ(ext-image-copy-capture, 自前PNG)、
  クリップボード(ext-data-control)、動画壁紙(libmpv dlopen → ffmpeg フォールバック)
- 成果物: zig-out/bin/{ame-shell,ame-ctl,ame-auth}, zig-out/lib/pam_ame_face.so,
  zig-out/share/ame-shell/widgets/*.wasm。依存 ame-hand/ame-face は build.zig.zon 経由で GitHub から取得
- バー/パネル: frame/ が枠・縦バー・ダッシュボード・ダイナミックアイランド等を描画
- WM: src/wm/ が River 0.5 のウィンドウマネージャ(dwindle, スプリングアニメーション)

## フェーズ 1: 機械検査（完了）

環境: `nix develop` (zig 0.13.0, odin dev-2026-10, shellcheck 0.11.0, rg 15.2.0)。
wayland-scanner は devShell の PATH に無かったため nix store の
/nix/store/hdqa5pkvhfz2j48psb2d5axr81xc5gnq-wayland-scanner-1.26.0-bin/bin を PATH に足した。
また EGL/GLESv2 の pkg-config は libglvnd-dev にあり devShell の PKG_CONFIG_PATH に無いため
/nix/store/pdcwbw6z36grx39dfhb4y0g9p00i2ajf-libglvnd-1.7.0-dev を足して実行（環境側の問題、リポジトリ外）。

| コマンド | 結果 | 要約 |
|---|---|---|
| zig fmt --check . | exit 1（失敗） | 4 ファイルが未整形: src/lyrics.zig, src/frame/vbar.zig, src/shot.zig, tools/cursorgen.zig |
| zig build (Debug) | 失敗 | 依存 ame-hand/ame-face は取得成功。コンパイルで `src/airpods.zig:296:23: error: expected pointer type, found 'cimport.__CONST_SOCKADDR_ARG'`（c.connect の第2引数。glibc 2.36+ で connect の型が union になったため。標的の Chimera(musl) では出ない可能性あり） |
| zig build test | 成功 (4/4 steps, exit 0) | pure_tests.zig は 3 test、全 pass |
| odin check anim | 単体では error「Undefined entry point procedure 'main'」（anim は -no-entry-point でビルドするため想定内）。`odin check anim -no-entry-point` は exit 0 |
| zig build tools | 成功 exit 0 | zig-out/bin に vptr・vkbd が生成（ame-ctl・ame-auth も前回の部分ビルドで生成済み） |
| shellcheck install.sh scripts/*.sh session/*.sh | exit 1 | error 4 件: install.sh:321-322 の複数行 if 条件の途中にある `# shellcheck disable=SC2086` コメントでパース不能 (SC1009/SC1072/SC1073/SC1126)。`sh -n` は全ファイル OK なので実害は小さい。info 6 件: SC2009×2, SC2012×2, SC2015, SC2016 |

## フェーズ 2: セキュリティレビュー（完了）

優先順: lockui.zig → auth_helper.zig → face/unlock.zig → ipc.zig/ipc_path.zig/ctl.zig →
widget_abi.zig/wasm.zig → lyrics.zig → ai.zig/mcp.zig → shot.zig/clipboard.zig →
video.zig/wallpaper.zig → wallpick.zig/avatar.zig → platform/netdbus.zig → notify.zig → audio.zig → wm/

### 確認結果（所見候補）
- 認証・権限:
  - lock.zig: パスワードは子プロセスで PAM 照合、親子とも @memset で消去 (lock.zig:404, 432)。
    ロック前 preflight で ext-session-lock 対応・PAM サービス・unix_chkpwd(setuid) を確認 (lock.zig:172-207)。
    コンポジタが finished を送れば finish(false) で unlock せず描画だけ破棄 (lock.zig:895-900)。
    解除はロック画面のスナップをオーバーレイに出してから unlock_and_destroy (ripple) — 解除アニメ中にデスクトップが透ける隙間はなさそう。
  - 注意: `currentUser()` は環境変数 USER/LOGNAME を信用して PAM のユーザー名にする (lock.zig:875-878)。
    セッション環境が改変されていると別アカウントのパスワード照合になる（当人のパスワードが still 必要なので昇格ではない）。低。
  - 試験用バックドア: AME_LOCK_FAKE と AME_SESSION_NESTED=1 が両方ある子プロセス環境でパスワード "ame" が通る (lock.zig:387-390)。ネストした試験セッション専用。低（本番環境でその env が設定されているとロックが破られる）。
  - auth_helper.zig: 実 UID=getpwuid(getuid()) のみ照合、引数/環境不読、stdin からパスワード、失敗 2 秒ディレイ、終了コード 0/1/2。堅実。install-session.sh:405 で 4755 root:wheel に setuid される。
  - 顔認証: しきい値は ame-face 側 core.zig で DEFAULT_THRESHOLD=0.6, NEED_HITS=3, 近い2つの平均 score()、MIN_THRESHOLD=0.5 でクランプ、max 6000ms・0.15s間隔、IR のみ (core.zig:9-10, 25-28, 123-137, 219-275)。README の仕様どおり。3 回失敗で無効は lock.zig の MAX_FACE_FAILS=3 + face_fails (lock.zig:33, 457-461, 538-541)。
  - face.bin: saveEnrolled で .part に 0600 で書いて rename (face/unlock.zig:300-312)。PAM 側は readRegular が NOFOLLOW + regular file + サイズ上限 + 所有者 uid と group/other 書き込み不可を検査 (ame-face core.zig:52-66)。堅実。
  - pam_ame_face.so: root で動くが root の顔認証はしない (pw_uid==0 → PAM_IGNORE)、threshold 引数は [0.5,0.95] にクランプ。モデルは SHA-256 検証 (core.zig readModel)。
- 秘密情報:
  - ai-keys: saveKey は .new を 0600 で作成→rename→既存も chmod 0600 (ai.zig:319-358)。validKey で保存時にキー文字種を制限。送信は curl `-K -`（設定を標準入力から渡しコマンドラインに出さない。ai.zig:9-10, 784-786）、発行後に cfg とキーバッファを @memset。本文の一時ファイルは $XDG_RUNTIME_DIR に 0600、完了時 removeBody (ai.zig:767, 800-804, 1093-1099)。概ね良好。
  - mcp.json / ~/.claude.json: ユーザー自身の設定を読み stdio サーバを起動（ユーザー権限、仕様どおり）。ツール名は英数_- 64文字に正規化。
- IPC: ソケットは $XDG_RUNTIME_DIR/ame-shell-<display>.sock、bind 後 chmod 0600 (ipc.zig:28)、XDG_RUNTIME_DIR は 0700 なので他ユーザーは接続不可。SO_PEERCRED による接続元 UID 検査は未実装（深層防御としては追加余地あり）。コマンドは 512B に制限、未知コマンドはエラー。debug-* は AME_DEBUG 環境変数でゲート。ame-ctl 側も libc のみで最長 512B に切り詰め (ctl.zig:15-24)。
- 外部データ:
  - 歌詞サイドカー: プレーヤー名を英数・_・-・. のみに制限してから $XDG_RUNTIME_DIR/lyrics/<name>.lrc を組み立て (lyrics.zig:611-614)。'/' が弾かれるのでパス遡及は不可（".." だけなら "...lrc" という無害なファイル名）。読み取りは 1MiB 上限、LRC パースは行ごとの数値パースで逸脱時 continue。ネット取得は curl の argv + --data-urlencode（シェル不使用）。
  - MPRIS メタデータ: 固定長バッファへ @min で切り詰め＋UTF-8 境界調整 (mpris.zig:24-31)。
  - 通知: app_name 64 / summary 256 / body 512 の固定長に copyTo で切り詰め (notify.zig:34-82)。
  - WASM: import は ame.action のみ、WASI 無効・1MiB 固定 (build.zig の wasm3 flags と widget の initial/max_memory)。ホスト側は cmds 個数からのバイト長を mem.len で検査 (wasm.zig:176-184)、文字列は str() で境界チェック (wasm.zig:189-192)、state も off+size 検査 (wasm.zig:139-144)、action id は非網羅 enum で @enumFromInt (wasm.zig:215-219)。トラップ時は failed にして停止。概ね良好。
- 画面・クリップボード:
  - shot.zig: バッファサイズはコンポジタの buffer_size に従い mmap、region 選択は px_w/px_h にクランプしてから startEncode (shot.zig:399-405)。自前 PNG (png.zig) は書き出し専用で外部入力を解釈しない。ロック中の撮影はロック面のみが見える。
  - clipboard.zig: ext-data-control の貼り付けは 1MiB までに制限して受信 (clipboard.zig:143-147)。
- 動的ロード・外部プロセス:
  - libmpv は dlopen で解決、必須関数が無ければ警告して ffmpeg へ (video.zig:87-111)。ffmpeg は argv 配列で直叩き（ファイル名に危険文字があっても安全。video.zig:507-508）。
  - spawnDetached は /bin/sh -c 経由 (platform/sys.zig:384-396)。動的データが混ざる呼び出し: side.zig:488 は $HOME/.local/bin/toggle-record.sh（本人のスクリプト）、side.zig:519 と shot.zig:746 は $HOME 由来のパスをシングルクォートで埋め込み（HOME に ' があれば自己注入になるが同一ユーザー内）、app.zig:766 と wm/wm.zig:540 は .desktop の Exec やキーバインド設定（同一ユーザーの設定）。権限昇格にはならない。低（execv 形式への置き換えが望ましい）。
  - FreeBSD の Wi-Fi: wpa_cli に psk を argv で渡す (netpanel.zig:717-718 → spawnReaderAll=execv)。シェル注入はないが、短命とはいえプロセスのコマンドライン（ps で他ユーザーに見える）にパスワードが乗る。中〜低。Linux 側は D-Bus 直叩きでコマンドラインには出ない (netdbus.handles が nmcli/bluetoothctl を横取り、netpanel.zig:163)。
- その他:
  - sddmshare.zig: /var/lib/ame-shell/greeter/<USER env>/ へ書き出し。パスは環境変数 USER 由来だが access(W_OK) でゲートされ、インストーラがユーザー別ディレクトリを chown+755 にするので他ユーザーの領域には書けない (greeter-setup.sh:153-158)。
  - hand.zig のモデル: HTTPS で取得し .part→rename、zip.isHandModel で形式検証のみ（SHA-256 固定は face 側のみ。README も hand 側にはハッシュを主張していない）。
  - greeter.zig: パスワードは greetd ソケットへ JSON で送信後 @memset。AME_GREETER_FAKE は試験用。

## フェーズ 3: 正当性・品質レビュー（完了）

- Zig 0.13 流儀: `catch {}` は mostly fire-and-forget の UI/ログ処理（ai.zig に 36 件など）で致命傷ではない。
  `unreachable` は計 5 件のみで、lyrics.zig:297 は while 条件で保護され妥当。`@intCast` は safe モードでパニック止まり。
  main.zig は Debug のみ GPA（リーク検査なし・deinit 無し。軽微）。
- C 境界: build.zig で wasm3/stb_image/nanosvg に `-fno-sanitize=undefined` を付与 — vendored C の意図的な UB（符号付きオーバーフロー等）を UBSan から除くためで、ホスト側(Zig)が境界を検査しているので妥当と判断。
- Odin ↔ Zig: anim.odin は `-no-bounds-check` でビルドされるため Odin 側に境界検査は無い。Zig 側ラッパ（anim.zig）は長さをそのまま渡すので、呼び出し元のバッファサイズが正しいことが前提（theme.zig の schemeFromPixels は w*h*4 のバッファと一致、frame/data.zig の spectrum は固定長 FFT_N+mutex）。現状の呼び出しは整合している。
- Wayland: app.zig でプロトコルエラーを検出して disconnected→exit 1（app.zig:341-346）。global_remove は出力単位で全サブシステムに伝播（app.zig:878-911）。描画は wl_surface.frame 駆動で、止まっていれば frame 要求を出さない（surface.zig:154-211）。WM も animating の間だけ requestManage（wm/wm.zig:1143）—「止まっているときは River との通信も 0」は実装どおり。
- 並行性: spectrum は録音スレッド→pipe→メインループで ring を mutex 保護（frame/data.zig:314, 405-409, 441-443）。ロック画面の認証は fork 子プロセス＋pipe（lock.zig）で UI をブロックしない。
- リソース: 動画は stop で rc_free/terminate_destroy と front/back バッファ解放（video.zig:182-233, 483-484）。spectrum.stop は fd を閉じる（data.zig:372-380）。WM 状態は 0600 で保存（wm/wm.zig:1252）。

## フェーズ 4: レポート作成へ

## 再検査（2 回目）
- git diff HEAD で src/anim/widgets/protocol/build.zig に変更なしを確認（未変更のため前回の机上確認は有効）
- 機械検査を再実行し同一結果を再現: zig fmt --check exit 1（同 4 ファイル）／ zig build test exit 0／
  odin check anim -no-entry-point exit 0／ shellcheck exit 1（同コード構成）／
  zig build は src/airpods.zig:296:23 の __CONST_SOCKADDR_ARG エラーで失敗（BUILD_EXIT=1）
- REPORT.md 記載の全引用を rg -n で再検証。lyrics.zig のフィルタ行が 611 だったため引用を 614-617 → 611-614 に修正。他は一致
- 所見の変更なし
