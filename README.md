# ame-shell(雨)

River(Wayland コンポジタ)の上で動く、アニメーション重視のガラス調デスクトップシェル。
Quickshell / QML / Qt / Python / C++ を使わず、**Zig・Odin・C・WebAssembly** だけで書いています。
Chimera Linux(musl + dinit)向け。SDDM から選んでログインできるセッションつき。

| | |
|---|---|
| ![ランチャーと通知](docs/screenshots/launcher-notify.png) | ![ダッシュボード](docs/screenshots/dashboard.png) |
| ![ロック画面](docs/screenshots/lock.png) | ![液体のように伸びるタグ表示](docs/screenshots/liquid-tags.png) |

## 何が入っているか

- **バー**: River のタグ 1〜9。選択インジケータは 2 本のスプリングで両端を動かし、移動中は液体のように伸びる。ウィンドウタイトルのクロスフェード、ネット/音量/バッテリー/時計。クリック・ホイールで操作。
- **ライブ壁紙**: シェーダで描くオーロラ / 雨(街のボケ + 雨筋 + 水たまりの波紋)/ 画像。切り替えは中心から広がる波紋のトランジション。バッテリー時は自動で FPS と解像度を下げる。
- **ガラス**: 壁紙を dual Kawase でぼかし、パネルは真後ろをサンプル。縁で屈折・色収差・ハイライト、微細なノイズとスパークル。
- **ランチャー**(Super+D): .desktop を Odin 製ファジーマッチで検索、結果は連鎖スプリングで順に出現。`>` で始めるとコマンド実行。よく使うアプリが上に来る。
- **通知**: `org.freedesktop.Notifications` を内蔵(他のデーモンが動いていれば譲る)。右上にカードが積まれ、ホバー中は消えない。
- **ダッシュボード**(Super+A / 時計クリック): **WASM ウィジェット**(時計・メディア・音量/明るさ/Wi-Fi/Bluetooth/通知停止・CPU/メモリ/温度・カレンダー)+ 通知センター。ウィジェットは保存すると状態を保ったままホットリロード。
- **メディア**: MPRIS。アルバムアートから Odin で主色を抽出し、テーマのアクセント色がその色へなめらかに変わる。
- **OSD**: 音量・明るさ。
- **ロック画面**(Super+L): ext-session-lock-v1 + PAM。認証できない構成ではロックしない(閉じ込め防止)。
- **ame-ctl**: Unix ソケットでシェルを操作する CLI。

## ビルド

必要: zig 0.13、odin、wayland-scanner、wayland / EGL / GLESv2 / xkbcommon / freetype / harfbuzz / fontconfig / dbus の開発ファイル(詳細は `docs/deps.md`)。

```sh
zig build -Doptimize=ReleaseFast     # zig-out/bin/{ame-shell,ame-ctl}, zig-out/share/ame-shell/
zig build test                       # スプリング・ファジー・主色抽出・設定パーサのテスト
```

## インストール(SDDM セッション)

```sh
zig build -Doptimize=ReleaseFast
doas sh session/install-session.sh --prefix /usr/local     # --dry-run で内容確認だけもできる
```

入るもの(全て `/usr/local/share/ame-shell/installed-files` に記録):
`/usr/local/bin/{ame-shell,ame-ctl,ame-session}`、`/usr/local/share/ame-shell/`(ウィジェット・既定設定・River 用 init)、
`/usr/local/share/wayland-sessions/ame-shell{,-safe}.desktop`(SDDM の SessionDir を読んで決定)、`/etc/pam.d/ame-shell`(ロック画面用)。
既存ファイルを上書きする場合は `.ame-bak` に退避します。

元に戻す:
```sh
doas sh session/install-session.sh --uninstall --prefix /usr/local
```

### システム前提(Chimera)
- `sddm`・`dbus`・`elogind`(または `seatd`)の dinit サービスが有効: `doas dinitctl enable sddm` など
- PAM の `system-login` に `pam_turnstile`(XDG_RUNTIME_DIR)と `pam_elogind` がある(Chimera の既定)
- seatd を使う場合はユーザーを `_seatd` グループへ
- River がシステムにインストールされていること(`river -version`)

## SDDM での初回ログイン手順

1. SDDM のセッション選択で **「Ame Shell (Safe Mode)」** を選んでログイン → River と foot だけが起動することを確認(ame-shell は起動しない)。
2. Super+Shift+E で River を終了して SDDM に戻る。
3. **「Ame Shell」** を選んでログイン → バーと壁紙が出れば成功。
4. うまくいかない場合: Ctrl+Alt+F2 などで TTY に切り替えてログを確認し、必要なら `--uninstall` で元に戻す。

ログ: `~/.local/state/ame-shell/session.log`(River と ame-shell の出力、各プロセスの終了コードと時間)。
起動直後に 3 回続けて落ちると `~/.local/state/ame-shell/crashloop` が作られ、次回は自動でセーフモードになります(正常に 60 秒以上動けば解除、手動なら `rm` で)。

インストールせずに試す(今のセッション内にウィンドウとして開く):
```sh
PATH=$PWD/zig-out/bin:$PATH AME_SESSION_NESTED=1 session/ame-session
```

## River のキーバインド(`session/ame-river-init`)

| キー | 動作 |
|---|---|
| Super+Return | foot |
| Super+D | ランチャー(`ame-ctl launcher toggle`) |
| Super+A | ダッシュボード |
| Super+N | 通知センター |
| Super+Q | ウィンドウを閉じる |
| Super+L | ロック |
| Super+Shift+E | River を終了(脱出口) |
| Super+Shift+R | ame-shell を再起動 |
| Super+1..9 / Super+Shift+1..9 / Super+Ctrl+1..9 | タグ切替 / ウィンドウを移動 / タグの表示を足す |
| Super+J/K, Super+Shift+J/K | フォーカス / 入れ替え |
| Super+F / Super+Space | 全画面 / フロート |
| 音量・明るさ・メディアキー | OSD 付き(ロック中も有効) |

自分用の追加設定は `~/.config/ame-shell/river-extra.sh`(あれば最後に読み込まれます)。
今使っている River 用のキーバインドから呼ぶ例:
```sh
riverctl map normal Super D spawn "ame-ctl launcher toggle"
riverctl map normal None XF86AudioRaiseVolume spawn "ame-ctl volume up"
```

## 設定

`~/.config/ame-shell/config.ame`(無ければ `share/ame-shell/config.ame`)。**保存した瞬間に反映**されます。

```
theme {
  accent #7ab8ff
  tint-strength 0.42
  radius 18
  blur 3
  sparkle 0.7
  anim-speed 1.0
  media-accent on
}
bar { height 38; position top; show-seconds off }
wallpaper {
  mode rain                 // aurora | rain | image
  // image "~/Pictures/wall.jpg"
  fps 30
  battery-fps 12
}
font { ui "Noto Sans CJK JP" }
```
全項目は `data/config.ame` を参照。

## ame-ctl

```
ame-ctl launcher toggle|open [検索語]|close
ame-ctl dashboard toggle
ame-ctl volume up|down|mute|<0-100>      ame-ctl brightness up|down
ame-ctl wallpaper aurora|rain|<画像パス>  ame-ctl accent '#ff88aa'|reset
ame-ctl notify <テキスト>                  ame-ctl notifications toggle|clear
ame-ctl lock | reload | widgets reload | stats | restart | quit
```

## WASM ウィジェットを書く

`widgets/*.zig` を参照。`widgets/ame.zig`(SDK)の `rect/grad/glass/text/arc/art` で描画命令を積み、`ame.store` から時刻・システム・メディアの値を読みます。`zig build` で `share/ame-shell/widgets/*.wasm` に出力され、`~/.config/ame-shell/widgets/` に同名の `.wasm` を置くとそちらが優先されます。保存すると状態を保ったまま差し替わります。

## 既知の問題

- River 0.3.5 にはウィンドウ越しのブラー(ext-background-effect)と外部 WM プロトコルが無いため、ウィンドウの開閉アニメ(Phase 6)とウィンドウ越しのガラスは未対応。
- ランチャーの日本語入力(IME)未対応。アイコンは PNG のみ(SVG は頭文字アイコン)。トレイ未実装。
- RSS は約 130MB(うち約 70MB は Mesa/LLVM の共有ライブラリ。PSS は約 75MB)。
- 詳細は `docs/blockers.md`、計測値は `docs/perf.md`。

## ドキュメント
`docs/architecture.md`(構成)・`docs/decisions.md`(設計判断と理由)・`docs/perf.md`(実測)・`docs/reference-analysis.md`(参考シェルの分析)・`docs/progress.md`(進捗)
