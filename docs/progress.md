# 進捗

## 2026-10-26

### 完了
| フェーズ | 内容 | 検証 |
|---|---|---|
| 0 | build.zig(wayland-scanner/odin/wasm3 を統合)、platform 層(epoll+timerfd, sysfs)、Wayland 基盤、layer-shell | ヘッドレス River で表示 |
| 1 | GLES3 レンダラ(SDF 角丸・影・ガラス・SDF 文字・円弧・画像)、dual Kawase、Odin スプリング | スクリーンショット、`zig build test`、待機 CPU 0〜0.1% |
| 2 | バー(液体タグ・タイトル・ネット/音量/電池/時計)、OSD | タグ移動中のフレームを撮影(伸びている状態を確認) |
| 3 | ランチャー(.desktop、Odin ファジー、連鎖スプリング、履歴、アイコンのワーカー読み込み)、通知(D-Bus 内蔵・カード・履歴) | `ame-ctl launcher open fire` で Firefox が先頭、通知の積み上げを撮影 |
| 4 | ダッシュボード: WASM ウィジェット 5 種(wasm3、ゼロコピー ABI、ホットリロードで状態維持)、メディア(MPRIS、アートの主色→アクセント) | 撮影、`.wasm` 上書きで「状態を引き継ぎ」ログ |
| 5 | ロック画面(ext-session-lock + PAM 子プロセス、事前チェック)、ライブ壁紙(オーロラ/雨/画像 + 波紋トランジション、電源連動) | ロック表示を撮影。壁紙切替を設定の保存で確認 |
| 6 | **不可**(River 0.3.5 に外部 WM プロトコル無し)→ blockers.md #1 | globals を実測 |
| 7 | ame-session / ame-river-init / .desktop×2 / install-session.sh | 下記 |

### Phase 7 の検証結果
1. `sh -n`: 4 スクリプト全て OK。shellcheck は未導入(実行できず)。`desktop-file-validate`: `DesktopNames` を「X- で始まらない拡張キー」として指摘(DesktopNames は SDDM/GDM が読むセッション用のキーで、仕様上必須のため残す)。それ以外の指摘なし。
2. `AME_SESSION_NESTED=1 session/ame-session`(WLR_BACKENDS=headless): バーと壁紙の描画を grim で確認 → `riverctl exit`(Super+Shift+E と同じ動作)で rc=0 終了。`--safe`: ame-shell 無しで River + foot(画像で確認)、rc=0 終了。ヘッドレスには入力デバイスが無いため、キー押下そのものは自動試験していない。
3. `--destdir /tmp/ame-fakeroot`: 全ファイルの配置とパーミッション(bin 755 / share・pam 644)、`.desktop` の Exec が指す `/usr/local/bin/ame-session` の実在と実行権限、再インストールで余計な .ame-bak が出ないこと、既存ファイルの .ame-bak 退避と `--uninstall` での復元、アンインストール後に残骸 0 件。
4. 1〜3 合格のため `session/.ready` を作成。

### 途中で見つけて直した不具合
- BSD grep がバイナリ内を検索せず PAM の置き場所を誤判定 → `LC_ALL=C tr` で文字列化
- 非 root で `dinitctl` がユーザー用インスタンスを見て誤警告 → root 時のみ `--system` で確認
- 設定の `bar.position` 変更が反映されない → バーを作り直す
- 雨の壁紙のボケがセル境界で四角く欠ける → 半径とずれをセル内に収める
- 初回表示の長いフレーム(525ms / 92ms / 19ms)→ perf.md の表のとおり解消

## 総括
River 0.3.5 上で、Zig・Odin・C・WebAssembly だけで書いたガラス調のシェルが一通り動く。バー・ライブ壁紙・ランチャー・通知・ダッシュボード(WASM)・メディア・OSD・ロック画面を実装し、SDDM 用のセッションとインストーラを疑似 root とネスト環境で検証した。待機時 CPU はほぼ 0、描画は 1 フレーム 10ms 以内。
未解決: ウィンドウ開閉アニメ(River の制約)、ウィンドウ越しのブラー(同)、私有メモリの増加原因、IME、SVG アイコン、トレイ、実機 SDDM での最終確認 → `docs/blockers.md`。

### 次にやること
1. `doas sh session/install-session.sh` で実際に導入し、SDDM から Safe Mode → 通常の順にログインして確認
2. 私有メモリの増加を heaptrack で切り分け
3. ランチャーの text-input-v3(日本語入力)

## 2026-10-26(追記)実セッションへの適用
- 既存の River 設定に組み込み: `~/.config/ame-shell/river.sh` を `~/.config/river/init` の末尾から読み込む。waybar / swaync / awww・swaybg の起動行は `# [ame] ` でコメントアウト(バックアップ `init.pre-ame-*`)。
- 実画面で発見: ターミナルのタイトルがスピナーで頻繁に変わると、バーのタイトルのクロスフェードが毎回始まって 60fps で描き続けていた(CPU 4%)。1 秒以内の連続変化は文字だけ差し替えるよう修正 → 約 13fps(バッテリー時の壁紙 12fps 分)・CPU 1%。
- 未解明: ビルド直後の `ame-ctl restart` で 1 度だけ ame-shell が正常終了扱いで消えた。再現せず(2 回目以降は exec で同じ pid のまま再起動)。

## 2026-10-26(追記 2)caelestia 風レイアウト
- caelestia-shell のソースを読んで(コードはコピーせず)挙動を把握: 縁 10px / 角丸 25 / smoothing 20、ホバーで開くドロワー(ダッシュボード=上中央、OSD=右中央、ユーティリティ=右下)、ドラッグ(ランチャー=下から上、セッション/サイドバー=右から左)、バーのポップアウト。
- 実装: `src/frame/`(frame.zig 枠・幾何・ホバー規則 / vbar.zig 縦バー / dash.zig 4 タブ / side.zig 右側のドロワー / data.zig GPU・温度・天気・cava・電源プロファイル)。枠とドロワーは 1 つの SDF シェーダ(`frame_fs`)。各ドロワーは枠とだけ smooth-min で融合(ドロワー同士は普通の和集合。連鎖させると近いドロワー同士が細い橋でつながる不具合が出たため)。
- 試験用に仮想ポインタ `tools/vptr.zig`(`zig build tools`)を追加し、ヘッドレス River でホバー・クリックを自動試験。上の縁ホバー→ダッシュボード、離れる→閉じる、右の縁→OSD、右下→ユーティリティ、バーの時計→ポップアウト、タブのクリック切替をスクリーンショットで確認。
- 性能(ReleaseFast, ヘッドレス): 起動→最初の枠 151ms、各ドロワーを初めて開く操作を含めて最悪フレーム 4.3ms(UI の文字列とアイコンを起動時に先読み)。実画面(バッテリー時): 約 16fps(壁紙 12fps + タイトル更新)、CPU 1.2%。
- 実セッションで見つけて直した不具合: ビルド後の `ame-ctl restart` で exec 先が `… (deleted)` になり失敗→ 正常終了扱いで消えていた(argv[0] を execvp、失敗時は異常終了にして監督ループに再起動させる)。river.sh の起動判定が別セッションの ame-shell を誤検知していた(このディスプレイのソケットに応答があるかで判定)。
- 未対応(caelestia にあるもの): トレイ、ウィンドウごとのアイコン/プレビュー(River 0.3 はビューの一覧を外部に出さない)、Material You の配色自動生成(現在はアルバムアートの主色のみ)、オンスクリーンキーボード、area picker。

## 2026-10-27
- 表示倍率 `shell { ui-scale }`(既定 1.25)。枠 UI を仮想座標で組み、描画・入力・排他領域を倍率で変換。
- Super キー単体のタップでランチャー: River 0.3 の -release マッピングは組み合わせの後でも発火するため使えない → evdev(/dev/input、input グループ)を読むだけで「Super を押して他のキーを挟まず 600ms 以内に離した」ときに開く(platform/supertap.zig)。デバイスの抜き差しに追従。
- アイコン: 全テーマの索引(ユーザー設定テーマ → hicolor → breeze-dark → breeze → Adwaita → oxygen、カテゴリ問わず)+ SVG を nanosvg で描画 + "-symbolic" を明るく塗り直し(src/icons.zig)。表示できなかった Alacritty / GNOME 系 / helix 等が表示されるようになった。
- 縦バーのロゴ: /etc/os-release の LOGO=(chimera-logo)を表示。
- 壁紙ピッカー(src/wallpick.zig): ilyamiro の serpantinum を読んで(コードは使わず)、斜めの平行四辺形カード・選択カードの拡大・パララックス・時間差で飛び上がる出現を実装。切り替え演出(wallpaper シェーダ)に円(カード位置から、光るリング+屈折)/ 斜めワイプ(光の筋)/ 短冊、新しい壁紙のズーム着地を追加。選んだ壁紙は ~/.local/state/ame-shell/wallpaper に保存して次回起動時も使う。
- メディア: 歌詞(src/lyrics.zig、LRCLIB から同期歌詞を非同期取得・キャッシュ、動画タイトルの飾りを除去して検索)。メディアタブを作り直し: ぼかしたジャケットの背景、回るレコード(ジャケットがラベル)+ cava の放射スペクトラム + 再生/停止で上下するトーンアーム、シャッフル/リピート、カラオケ風に塗られていく同期歌詞(スプリングでスクロール)。ダッシュボードの小さなメディア欄にも今の一節を表示。
- 試験: `debug-media`(AME_DEBUG 時のみ)で再生中の状態を作り、ライラック(Mrs. GREEN APPLE)の同期歌詞が位置に合わせて進むことを確認。

## 2026-10-27(追記 2)
- パフォーマンス: CPU / GPU / メモリ / ストレージの 4 つの円(CPU・GPU は内側に温度の円弧)。機種(DMI)・CPU(/proc/cpuinfo)・GPU(GL_RENDERER)・ディスク型番(sysfs)を表示。ダッシュボードのユーザー欄にも機種・CPU・GPU。
- ランチャー: よく使う順(起動回数 × 最近使ったかの重み)、お気に入りの固定(Ctrl+F / 右クリック、~/.config/ame-shell/favorites)。
- 配色: 壁紙の画素から Odin で代表色 → HSL で アクセント / ガラス / 文字色 を生成し、1.1 秒かけて遷移(theme.auto-color)。再生中のアルバムアートはアクセントだけを上書き(theme.media-accent)。
- Wi-Fi / Bluetooth 設定パネル(バーのネット/Bluetooth アイコン、ame-ctl network|bluetooth): 一覧・接続・切断・パスワード入力・スキャン・電源。nmcli / bluetoothctl を非同期キューで実行。不具合修正: 画面より背の高いパネルで clamp の上下限が逆転して落ちていた。
- アプリ起動: river の default-attach-mode below(Hyprland と同じく、フォーカス中の窓の次に入る)。起動演出: ランチャーのアイコンから、ウィンドウが現れる位置(rivertile の配置から推定)へガラス板が広がり、新しい窓にフォーカスが移ると拡大しながら消える。
- 未対応: ウィンドウそのものの開閉・移動アニメーション。River 0.3 ではウィンドウを外から動かす手段が無い。River 0.4 以降(river-window-management-v1)なら、WM として毎フレーム位置とクリップを指定できるので実装可能(要: wlroots0.20-devel の導入、Zig 0.16、WM の自作)。

## 2026-10-27(追記 3)River 0.5 と内蔵ウィンドウマネージャ
- River 0.5.0(+xwayland)を Zig 0.16 で `~/.local/opt/river-0.5` にビルド(依存: wlroots0.20-devel)。既存の River 0.3 環境はそのまま。
- `src/wm/`: ame-shell が river-window-management-v1 の WM を兼ねる(同じプロセス・同じイベントループ)。
  - 配置: Hyprland の dwindle(残りの領域を長い辺で分割、最初の分割は比率 Super+H/L)。新しい窓はフォーカス中の窓の次。隙間 10 / 外側 14 / 枠線 3px(今の rivertile と River 設定と同じ)。枠線の色はテーマのアクセント(壁紙の配色の遷移に合わせて変わる)。
  - アニメーション(スプリング): 開く=提案した大きさで描かれるまで隠し、中心から clip box を広げる / 位置の変化=滑らかに移動 / ワークスペース切替=横スライド / Super+Q=中心へ縮めてから close(閉じなかったら元に戻す)。動いている間だけ manage_dirty を毎フレーム送る(止まっていれば通信 0)。
  - キー: 今の ~/.config/river/init と同じ割り当て(src/wm/binds.zig、92 個)。Super+ドラッグで移動・大きさ変更(浮かせる)、Super+中クリックで浮かせる。フォーカスはマウスに追従(窓の方がカーソルの下に来ただけでは移さない)、ワークスペースに戻ると最後に使っていた窓へ。
  - 層シェル: river-layer-shell-v1 を使い、ランチャー等がキーボードを持っている間は窓へフォーカスを返さない。
- セッション: `ame-session --river5` / `ame-river5-init` / `ame-shell-river5.desktop`(「Ame Shell (River 0.5)」)。キーボード配列は ~/.config/river/init の keyboard-layout を読んで XKB_DEFAULT_LAYOUT に渡す。ame-shell が 30 秒以内に 3 回落ちたらセッションを終えて SDDM に戻す(WM 無しでは操作できないため)。
- 注意: River 0.5 は "riverctl" という文字列を含む init を起動拒否する(コメントでも)。
- 試験: 仮想キーボード `tools/vkbd.zig` を追加。ヘッドレスの River 0.5 で ame-session --river5 を丸ごと起動し、キー操作(起動・ワークスペース・フォーカス・入れ替え・閉じる・終了)、ランチャーの入力、開く/切替/閉じるの途中フレームをスクリーンショットで確認。
- 直した不具合: 枠線の色の変換で f32 の精度により整数変換が範囲外(f64 で計算)。キーボード/マウスの capability が一度消えて戻ると古い wl_keyboard を使い続けてキー入力が届かなかった(作り直す)。
- `ame-ctl workspace <1-9>`(River 0.3 / 0.5 両方)、`ame-ctl window close|fullscreen|float|focus-next|…`(0.5 のみ)。

## 2026-10-27(追記 4)
- ダッシュボード: 開くアニメーションより速くカーソルを下ろすと「外に出た」と判定されて閉じていた → 開いている間は開き切った大きさで判定し、入力領域も開き切った範囲にする。
- ユーザーの写真: ~/.config/ame-shell/avatar(パス)→ ~/.face → AccountsService の順。ダッシュボードの丸をクリックすると ~/Pictures の写真をカードで選べる(壁紙ピッカーの写真モード)。ロック画面にも表示。
- Super+L でロック(River 0.5 の内蔵 WM と River 0.3 の river.sh の両方)。配置の比率は Super+Ctrl+H / L へ。
- 動画・GIF の壁紙(src/video.zig): libmpv を dlopen し、描画 API で FBO に描いて壁紙のシーンへ。新しいコマの通知が来たときだけ描く。サムネイルは ffmpeg で 1 コマ。注意: mpv に wl_display を渡すと VA-API のラウンドトリップとイベントループの読み込み準備が噛み合って固まる(渡さない → DRM 経由)。720p30 で CPU 約 4.7%、RSS は libmpv 分 +130MB(使うときだけ読み込む)。
- ワークスペース欄にアプリのアイコンと名前: River 0.5 は内蔵 WM、River 0.3 は wlr-foreign-toplevel で窓を知り、タグは推測(開いた時のタグ・フォーカス時に見えているタグ・窓数の増減)。
- 配色: アクセントは「一番多い色」ではなく「一番鮮やかな色」の色相から作り、見栄えの良い色相(コーラル・琥珀・ティール・空・青・ペリウィンクル・紫・ピンク)へ寄せる。黄緑〜緑は避ける。アルバムアートも同様(白地のジャケットで白くならない)。充電中の緑はアクセントに。
- エラーは theme.danger()(はっきりした赤)。Wi-Fi/Bluetooth の操作失敗・緊急通知で枠の縁が赤く光る(theme.flashError)。
- Bluetooth: 接続は data/bt-connect.sh(信頼 → 接続、失敗したら 1 回やり直し、profile-unavailable なら WirePlumber を再起動)→ イヤホンなら A2DP にして既定の出力にし、再生中の音も移す。実際には繋がっているのに bluetoothctl が失敗を出していた場合も成功扱い。AirPods の br-connection-refused 対策として session/bt-airpods-fix.sh(root: ControllerMode = bredr 等)。
- River 0.5: ame-ctl restart の前に窓のタグを $XDG_RUNTIME_DIR/ame-wm-state-<ディスプレイ> に保存し、再起動後に River の窓識別子で戻す。セッション終了要求はどこから来たかをログに出す(06:51 に起動 3 秒で終了した件の調査用)。

## 2026-10-27(追記 5)
- AirPods が Bluetooth では繋がっているのに音がスピーカーのまま: bluetoothd の再起動(bt-airpods-fix.sh)後に WirePlumber が BlueZ へ登録し直しておらず、PipeWire に音の機器(bluez_card)が現れていなかった。WirePlumber の再起動で解消。bt-connect.sh は「繋がったのに音の機器が出ない」ときに自動で WirePlumber を再起動する。接続後、既定の入力がイヤホンのマイクなら内蔵マイクに戻す(録音のたびに通話用の低音質へ切り替わるのを防ぐ)。
- 音量のポップアウト(縦バーの音量アイコン)に出力先・入力先の一覧。クリックで切り替え(再生中・録音中の音も移す)、音量バーのクリックで音量、右クリックでミュート。pactl の JSON は日本語の機器名で壊れるのでテキスト形式を読む(src/audio.zig、別スレッド)。

## 2026-10-27(追記 6)
- GitHub で公開: https://github.com/TatsuyaM2667/ame-shell(GPL-3.0)。
- メディアのジャケット(レコードのラベル)の回転を 1 周 6 秒 → 24 秒に。レコードの溝は同心円なので回転が目に入るのはジャケットだけだった。
- 同期歌詞の行をクリックするとその時間へシーク(playerctl position)。カーソルが乗った行に帯と時刻を表示。
- アクセントの候補から赤(コーラル)を外した(エラーの赤と紛らわしい。赤いジャケットではピンクか琥珀に)。

## 2026-10-27(追記 7)インストーラと FreeBSD
- `install.sh`: 依存パッケージ(apk は自動)・Zig 0.13(公式配布物を ~/.cache へ)・Odin(無ければ dev-2026-08 をソースから)・River(無ければ 0.5 をソースから)・ビルド・インストールを全自動。全ユーザー用は doas / sudo で自動昇格、無ければ `--user`(~/.local)。
- `session/install-session.sh`: `--user` モード、自動昇格、FreeBSD のパス(/usr/local/etc の sddm.conf、/usr/local/share/wayland-sessions)、River 0.4 以降しか無ければ内蔵 WM のセッションだけを「Ame Shell」として入れる、自分でビルドした River 0.5 を /usr/local/opt にコピー(全ユーザーが使える)。
- `scripts/install-freebsd.sh`: pkg・GPU ドライバ(pciconf で判別)・dbus/seatd/sddm・video グループ・入力デバイスの devfs 規則・Zig 0.13 と Odin のソースビルド(LLVM 18)・ビルドとインストールを全自動。
- FreeBSD 対応のコード: platform/bsd.zig、statvfs の並び、EVIOCGBIT の ioctl 番号(FreeBSD は IOC_OUT = 1<<30)、ioctl の request の型、ロックは swaylock(pam_unix が root 必須のため)、nmcli / bluetoothctl / pactl が無いときはパネルに表示。
- 検証: FreeBSD 14.5 の base.txz と pkg のパッケージ(wayland・mesa・libglvnd・xkbcommon・freetype・harfbuzz・fontconfig・dbus・libepoll-shim・libinotify と依存)で sysroot を作り、x86_64-freebsd 向けにビルド・リンクが通ることを確認(ELF FreeBSD 14.5、必要なライブラリは libepoll-shim / libinotify を含めて解決)。FreeBSD の実機での実行は未確認。

## 2026-10-28 FreeBSD 15.1 の不具合報告への対応
- SIGSYS で起動直後に落ちる: `Timer.arm` が `std.os.linux.timerfd_settime`(生のシステムコール 286)を使っていた。Linux 以外は libc の timerfd_settime に。FreeBSD 向けバイナリに `syscall` 命令と `os.linux.*` が 0 であることを逆アセンブルで確認。
- 診断: `-Dstrip=false`(install.sh / install-freebsd.sh の `--debug` = ReleaseSafe + 関数名つき)、致命的シグナルを ASCII でログに出すハンドラ、起動の最初に ASCII の 1 行。
- ame-river5-init: シグナルで落ちたらシグナル名をログに、3 回落ちたら(正常終了でも)River を終了してログイン画面に戻る(黒画面に閉じ込めない)。入れ子の River 0.5 で確認。
- Zig 0.13 のソースビルド: zstd を必須パッケージに、cmake に /usr/local の検索パスとリンクのパス。失敗時は root で再実行するよう案内。
- 確認手順: docs/freebsd-test.md。

## 2026-10-28(追記)FreeBSD のロゴ・foot・ame-update
- 縦バーのロゴ: /etc/os-release に LOGO= が無い OS(FreeBSD など)は、ID から Nerd Font の Font Logos の文字(FreeBSD は U+F30C、赤)。Chimera は従来どおり画像。AME_OS_ID で試せる。
- foot: ame-shell の半透明の foot.ini(data/xdg/foot/foot.ini)を ame-session が XDG_CONFIG_DIRS の先頭に置く。ユーザー自身の foot.ini があればそちらが優先。入れ子のセッションで確認。
- ame-update: パッケージ(pkg / apk)→ git pull → ビルド → この ame-update が入っている場所へ再インストール → ame-ctl restart。--check / --no-pkg / --no-self / --force / --debug。インストーラがソースの場所を share/ame-shell/source に記録。ランチャーの「アップデート」からも。
- 電源操作: loginctl の無い FreeBSD では ConsoleKit2(D-Bus)で再起動・電源オフ・スリープ。

## 2026-10-28(追記 2)壁紙・AirPods・メディア
- 壁紙: スキャン先に ~/.local/share/ame-shell/wallpapers と <prefix>/share/ame-shell/wallpapers を追加、同じファイル名は 1 つに。追加の壁紙は非公開リポジトリ(著作物のため公開リポジトリには入れない)から scripts/fetch-wallpapers.sh が取る(install.sh / install-freebsd.sh / ame-update)。未ログインなら案内のみ。
- AirPods の音がガサガサ: WirePlumber がマイクを開くアプリに反応して HFP に自動で切り替えていた。bt-connect.sh が bluetooth.autoswitch-to-headset-profile を false にして保存。
- メディア: MPRIS の xesam:album を取り、メディアタブとダッシュボードのカードにアルバム名。歌詞は $XDG_RUNTIME_DIR/lyrics/<プレーヤー名>.lrc があれば([ti:] / [ar:] が今の曲と一致するときだけ)LRCLIB より優先。入れ子のセッションで確認。
- music-tui 側(別リポジトリ): 位置と長さを MPRIS に出す(進まなかった歌詞が進む)、アルバムアートを曲ごとの別ファイルに、歌詞を上の場所に書き出し、SetPosition / Seek に対応。

## 2026-10-28(追記 3)FreeBSD の fastfetch・拡大率
- foot の既定設定に shell=ame-term-shell: fastfetch を出してから $SHELL に。シェルの設定ファイルに fastfetch があれば出さない(二重防止)、AME_FASTFETCH=0 で無効。入れ子の River で foot → ame-term-shell → シェルの順に起動することを確認。
- ame-display-scale: wlr-randr の物理サイズと解像度から、Chimera の環境(1920px / 300mm = 6.4 px/mm、拡大率 1)と同じ見た目になる拡大率(0.25 刻み、1.25 未満は 1)を設定。~/.config/ame-shell/output-scale・AME_OUTPUT_SCALE で上書き、off で無効。偽の wlr-randr で試験。
- XCURSOR_SIZE=24 / XCURSOR_THEME=Adwaita(未設定のときだけ)。FreeBSD の任意パッケージに fastfetch・wlr-randr(14 / 15 の quarterly にあることを確認)、ame-update が未導入なら入れる。
- FreeBSD: scripts/foot-config.sh で ~/.config/foot/foot.ini を ame-shell の設定に上書き(初回だけ foot.ini.ame-bak に退避、同じ内容なら何もしない)。install-freebsd.sh と ame-update から。

## 2026-10-28(追記 4)FreeBSD のタッチパッド・fastfetch
- タッチパッド: scripts/freebsd-touchpad.sh(ig4 / iichid / hmt / AMD は amdgpio を kld_list、psm の Synaptics / Elantech / TrackPoint を loader.conf、--check で診断)。install-freebsd.sh から。
- タップでクリック: river_libinput_config_v1 を wl_proxy_add_dispatcher で受け、tap_support > 0 の機器に set_tap(src/wm/touchpad.zig、設定 tap-to-click)。入れ子の River 0.5 で bind されエラーが無いことを確認(ヘッドレスには実機器が無いのでタップ自体は未確認)。
- fastfetch: 窓の大きさが決まってから表示、FreeBSD は --logo freebsd(大きいロゴ。自分の fastfetch の設定があれば任せる)。
- 追加の壁紙の取得はインストーラから外し、ame-update だけに。
- fastfetch の設定(data/xdg/fastfetch/config.jsonc: logo.type=builtin で大きいロゴ、modules は fastfetch の既定と同じ。modules を省くと情報が出ないので明記)。scripts/foot-config.sh を app-config.sh にして foot と fastfetch の両方を FreeBSD で ~/.config に上書き。
- 録画: FreeBSD の任意パッケージに wf-recorder が無く、押しても何も録れていなかった。wf-recorder を任意パッケージと ame-update に追加。無いときは録画中にせず、赤く光らせて入れ方を通知。開始・停止で保存先(~/Videos/rec_*.mp4)を通知。

## 2026-10-28(追記 5)FreeBSD の壁紙・タッチパッド・Bluetooth、rfkill
- 壁紙: 動画(mp4)を選んでも libmpv が無い・再生できないと、黙ってオーロラ(既定)に戻っていたので「変わらない」ように見えた。理由(video.last_error、mpv の END_FILE のエラー)を通知し、縁を赤く光らせる。入れ子の River 0.5 で壊れた mp4 / png を指定して通知を確認。
- タッチパッド: 作者の機種(IdeaPad Slim 3 14ARP10)は Goodix GXTP5100(I2C HID、AMD の DesignWare I2C)。iichid は GPIO 割り込み未対応で自動でポーリングになるので amdgpio は外した。設定時に今すぐ kldload も。ame-update が未設定なら root で実行(ame-shell の更新の後)。
- Bluetooth: Realtek RTL8852BE(0bda:4853)は FreeBSD の rtlbtfw の devd 設定にある。scripts/freebsd-bluetooth.sh でファームウェア pkg・ng_ubt・hcsecd / sdpd / bthidd。パネル(bluetoothctl 前提)は FreeBSD では未対応のまま。
- rfkill: ame-session(Linux)が開始時に rfkill unblock all(uaccess で本人が使える)と bluetoothctl power on。
- 動画の壁紙をどこでも動くように: libmpv が無い・END_FILE のエラー・5 秒たっても最初のコマが出ない(見張りのタイマー)ときは ffmpeg のプロセスで再生(sh -c で VA-API の scale_vaapi → だめなら CPU、画面を覆う大きさに切り抜いた RGBA をパイプで受けてテクスチャへ)。プロセスグループごと SIGKILL して回収。入れ子の River 0.5 で VA-API(CPU 約 39%)・CPU 復号(LIBVA_DRIVER_NAME を壊して確認、約 135%)・libmpv → ffmpeg → 通知の順の失敗を確認。失敗したパイプを epoll に残すと空回りする不具合も修正。ame-update が FreeBSD で mpv・ffmpeg を入れる。
- SDDM: ame-shell のオリジナルのテーマ(data/sddm/ame/Main.qml、Qt6)。ロック画面と同じく光る大きな時計・日付・ガラスの丸い入力欄、失敗で揺れて赤く、セッション切替・再起動・電源オフ。背景は scripts/sddm-theme.sh がその人の壁紙(動画は 1 秒目)から background.jpg を作る(QtQuick.Effects でぼかし、追加の Qt パッケージ不要)。QML は SDDM のテーマに限った例外(作者の了承済み。Qylock は大きすぎるため不採用)。sddm-greeter-qt6 --test-mode を入れ子の River 0.5 で表示して確認。
- メディアタブ: 同期歌詞を「今の行だけ・行が変わるたびに下から弾んで出る(前の行は上へ消える)」表示に。上/真ん中/下のクリックで前の行/今の行の頭/次の行へ。中央揃えの折り返し(gfx: textWrapOpts / wrapCount、折り返した行は省略しない)。トーンアームの角度が逆(再生中に針がラベル上、停止中に盤面上)だったのを、停止 88°(盤の外)・再生 105°→115°(溝の外周→内周、曲の進みに合わせて)に。入れ子の River 0.5(D-Bus を分けて)で確認。
- Arch: scripts/install-arch.sh(pacman で公式リポジトリから依存を入れる。River 0.5・Odin・wlroots0.20 も公式。sddm / NetworkManager / bluetooth を有効に、最後に install.sh --no-deps)。install.sh が Arch 系(ID=arch / ID_LIKE に arch)なら自動で呼ぶ。パッケージ名は core / extra の DB で確認、偽の pacman で流れを確認。

## 2026-10-28(追記 6)ドキュメントサイト
- site/: 本文(site/src/content/*.md、Markdown の部分集合 + ::video / ::img / ::demo / ::stats / ::cards)を Zig の wasm(site/src/main.zig、約 76KB)がブラウザで HTML に。デモ(ばね vs ベジェ・あいまい検索・主色抽出)は anim/anim.odin を freestanding_wasm32 にしたもの(約 2KB)を app.js から直接呼ぶ。zig build site → zig-out/site、site/deploy.sh で Cloudflare Pages(npx wrangler)。動画は入れ子の River 0.5(D-Bus とホームを分け、壁紙は ffmpeg で生成)で wf-recorder 録画。Chromium のヘッドレスで表示を確認(wrangler pages dev の workerd は musl で動かない)。
- サイトに「技術解説」の章(19 ページ)を追加: 全体像・言語・ビルド・ループ・Wayland・GPU・ガラスと配色・文字・ばね・WM・枠・ランチャー・メディア・通知とロック・WebAssembly・OS 対応・設定・セッション・このサイト。各ページで実際のコードを引用し、何を・なぜ・結果・ほかの方法との違いを書く。書きながら実装と照合し、旧ページの誤り(配色をばねと書いていた、アクセントを Odin の主色と書いていた、ウィジェットの例のコードが架空だった等)を修正。配色のデモを theme.zig と同じ計算(主色は Odin、アクセントは vividHue → accentHue を JS に移植)に。render_toc の defer が return の後に動いて閉じタグが落ちる不具合、### の {#id} を修正。
