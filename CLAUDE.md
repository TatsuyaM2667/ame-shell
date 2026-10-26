# ame-shell 作業ルール(要約)

## 絶対ルール
- 使ってよい: Zig(本体・ビルド)、Odin(anim/: スプリング・ファジー・主色抽出)、C(既存ライブラリのバインドと third_party の wasm3 / stb_image)、WebAssembly(widgets/)。
- 禁止: Python, C++, Qt, GTK, Electron, Node.js, QML(補助スクリプトにも使わない)。シェルスクリプトは POSIX sh のみ(bash/GNU 拡張禁止: `sed -i`, `readlink -f`, `date -d`, `find -printf`)。Chimera は chimerautils(BSD 系)なので `grep` はバイナリ内を検索しない・`tr` は `LC_ALL=C` が必要。
- ビルドは `zig build` のみ。OS 依存は `src/platform/` に閉じ込める。
- sudo/doas・/usr・/etc への書き込みはしない(導入は `session/install-session.sh` を人が root で実行)。`~/.config` の既存設定は読むだけ。実セッションの River(pid は `pgrep -x river` で最初のもの)や waybar/swaync に触れない。

## 環境
Chimera Linux / musl / dinit / Ryzen 7 7735HS / Radeon 680M (radeonsi) / River 0.3.5(+ River 0.5.0 を ~/.local/opt/river-0.5、Zig 0.16 でビルド)/ Zig 0.13 / Odin dev-2026-08。詳細 `docs/decisions.md`。

## 性能バジェット(docs/perf.md)
待機 CPU < 0.5%(壁紙静止)/ < 2%(ライブ壁紙)、PSS < 80MB・私有 < 60MB、起動 → バー < 300ms、描画 < 16.6ms。
描画は必ず wl_surface.frame 駆動。ポーリング用タイマー禁止(timerfd は「次に変わる時刻」にだけ使う)。

## ビルドとテスト
```sh
zig build -Doptimize=ReleaseFast && zig build test
# ヘッドレスのネスト River で試す(実画面に影響しない)
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1 \
  AME_BIN=$PWD/zig-out/bin/ame-shell AME_LOG=/tmp/ame.log river -c run/test-init &
WAYLAND_DISPLAY=wayland-N grim shot.png; WAYLAND_DISPLAY=wayland-N zig-out/bin/ame-ctl stats
# 遅いフレームの内訳: AME_DEBUG_FRAMES=8 / 起動時メモリ: AME_DEBUG_MEM=1
```
注意: `pkill -f` は自分のシェルのコマンドラインにも一致するので使わない(pid ファイルで管理)。

## セッション
`session/`: ame-session / ame-river-init / *.desktop / install-session.sh。River 0.5 用は `ame-session --river5` + `ame-river5-init`(ame-shell が WM を兼ねる、`src/wm/`)。River 0.5 は "riverctl" の文字列を含む init を拒否する。キー操作の試験は `zig build tools` の vkbd。検証は `sh -n`、`--destdir` で疑似 root、`AME_SESSION_NESTED=1`。全部合格したときだけ `session/.ready`。
