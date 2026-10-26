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
