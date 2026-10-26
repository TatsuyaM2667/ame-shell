# 未解決事項 / 制約

## 1. Phase 6: ウィンドウの開閉・移動アニメーション(River 0.3 では不可能)
- 症状: River 0.3.5 にはウィンドウの位置を外部プロセスが毎フレーム決めるプロトコルが無い(`river-layout-v3` はレイアウト寸法を 1 回返すだけ)。WAYLAND_DEBUG で globals を確認済み。
- 次の一手: River 0.4 以降(`river-window-management-v1`)に上げたら、Zig で最小 WM クライアントを書き、既存の Odin スプリングで各ウィンドウの矩形を補間して毎フレーム指示する。描画側(ame-shell)はそのままでよい。

## 2. 他のアプリのウィンドウ越しのブラー
- River 0.3.5 は `ext_background_effect_manager_v1` を広告していない。クライアントから他の画面を読むのは不可能なので、ランチャー等は色を濃くした「擬似ガラス」(後ろの壁紙のみブラー)。River が対応したら `surface.zig` で要求するだけで済む構造にしてある。

## 3. 私有メモリの増加(37MB → 57〜60MB)の原因未特定
- 試したこと: アトラス 1024/2048 の比較、アウトライン SDF / bsdf の比較、ライブ壁紙 ON/OFF の比較 → いずれも差は 1〜2MB 以内。0.3 秒時点(先読み・アイコン読み込み前)で既に 58MB。
- 次の一手: `git bisect` で該当コミットを特定(現在は初回コミットのため不可)。`heaptrack ame-shell`(このマシンにある)で起動直後の確保元を見る。Mesa のスレッド数(12)が CPU 数で増えている可能性もある → `MESA_GLTHREAD=false` `radeonsi_shader_threads` 等で比較。

## 4. ランチャーの日本語入力(IME)
- River は `zwp_text_input_manager_v3` を持っているが、ame-shell は未実装。現在はローマ字・英字でのファジー検索のみ(Name[ja] には かな/漢字を直接貼り付ければ一致する)。
- 次の一手: text-input-v3 の enable / preedit / commit_string を launcher に実装。

## 5. アイコンの SVG
- PNG のみ対応。SVG しか無いアプリは頭文字の丸アイコン。依存を増やさないため librsvg/resvg は入れていない。

## 6. システムトレイ(StatusNotifierItem)
- 未実装。D-Bus 基盤(notify.zig の接続)は流用できる。nm-applet / blueman はダッシュボードの Wi-Fi/Bluetooth トグルで代替。

## 7. 実機 SDDM でのログイン
- `session/install-session.sh` は疑似 root(`--destdir`)で検証済み。実際の `/usr/local` への導入と SDDM からのログインは root 権限が必要なため未実施(手順は README)。
- 注意: 前提チェックでは dinit のシステムサービス(sddm, elogind)を root でしか確認できない。一般ユーザーで実行した疑似 root 試験では確認を省略している。

## 8. Odin が無い環境
- このマシンでは `~/.local/bin/odin` が使えたため、Zig 代替実装は用意していない。Odin が無い環境では `anim/anim.odin` の 3 関数(`ame_spring_step`, `ame_fuzzy_score`, `ame_dominant_color`)を同じ C ABI で Zig に移植し、build.zig の odin ステップを差し替える(各関数 50 行程度)。

## 9. 参考シェルにあって未実装のもの
- ドック、ワークスペースのオーバービュー、オンスクリーンキーボード、設定 GUI、天気、セッションメニュー(ログアウト等。現在は Super+Shift+E)。

## 10. ネスト試験の範囲
- 検証はヘッドレス River(WLR_BACKENDS=headless)で行った。実機ディスプレイのリフレッシュレート(本機のパネル)での体感、マウスホバーやキーボード入力のアニメーションは、ヘッドレスに入力デバイスが無いため自動試験していない(ランチャーの検索は `ame-ctl launcher open <語>`、ロックは表示のみ確認)。
