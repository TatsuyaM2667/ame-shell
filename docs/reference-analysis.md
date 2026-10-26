# リファレンス分析(読むだけ。コードは一切コピーしていない)

調査日: 2026-10-26。GitHub API でリポジトリのディレクトリ構成を取得し、README と構成から「どんな部品があり、どう振る舞うか」を整理した。実装は ame-shell 側で独自に設計している。

## caelestia-dots/shell(Quickshell / QML)
`modules/` 直下: `background bar dashboard drawers launcher lock notifications osd session sidebar utilities windowinfo areapicker nexus`

- **drawers**: 画面端から引き出す「引き出し」をまとめて管理する層。バー・ランチャー・ダッシュボード等が同じ枠組みで出入りする → ame-shell では「各パネルが同じ Surface + スプリングの開閉パターンを持つ」形に置き換えた。
- **dashboard**: 時計/天気/メディア/カレンダー/性能表示をタブで切り替える大きなパネル。
- **osd**: 音量・明るさのポップアップ。**session**: ログアウト等のメニュー。**lock**: 独自ロック画面。
- 配色は壁紙由来の Material You 系パレット。

## end-4/dots-hyprland「ii」(Quickshell / QML)
`dots/.config/quickshell/ii/modules/ii/`: `background bar cheatsheet dock lock mediaControls notificationPopup onScreenDisplay onScreenKeyboard overlay overview polkit regionSelector screenCorners screenTranslator sessionScreen sidebarLeft sidebarRight verticalBar wallpaperSelector`

- 左右サイドバー(右: クイックトグル・通知・カレンダー等)、ワークスペースのオーバービュー、OSD、通知ポップアップ、メディア操作、壁紙選択、ロック、セッション画面。
- 「画面の角を丸める screenCorners」「縦バー」等、見た目のバリエーションが多い。

## ilyamiro/serpantinum(旧 imperative-dots。Quickshell / QML)
`src/quickshell/` の主なディレクトリ: `bar/modules dock lock(+redactor) media network popouts quickactions widgets/faces/{clock,usage} singletons/{system,audio,widgetcontrols} guide(設定 UI)`

- バー + ドック + ポップアウト + クイックアクション + デスクトップウィジェット(時計/使用率の「フェイス」)+ ロック画面(レイアウトを編集できる redactor 付き)。
- 「guide」というアプリ内の設定画面を持つ。

## 共通する部品と ame-shell での対応

| 部品 | 参考の振る舞い | ame-shell |
|---|---|---|
| バー | ワークスペース・時計・システム状態 | `src/bar.zig`(液体インジケータ、タイトルのクロスフェード) |
| ランチャー | アプリ検索 | `src/launcher.zig`(Odin ファジー、連鎖スプリング) |
| 通知 | ポップアップ + 履歴 | `src/notify.zig`(D-Bus 内蔵)+ ダッシュボード下部の履歴 |
| コントロールセンター/ダッシュボード | トグル・スライダー・メディア・カレンダー | `src/dashboard.zig` + WASM ウィジェット 5 種 |
| メディア | MPRIS、アートの色を配色に | `src/media.zig`(Odin で主色抽出 → アクセント遷移) |
| OSD | 音量・明るさ | `src/osd.zig` |
| ロック画面 | 独自 UI + PAM | `src/lock.zig`(ext-session-lock-v1、子プロセスで PAM) |
| アニメ壁紙 | 画像/動画壁紙 | `src/wallpaper.zig`(シェーダ: オーロラ/雨、画像の波紋トランジション) |
| サイドバー | 右サイドバー | ダッシュボードが右サイドバーを兼ねる |

参考になかった/未実装のもの(dock, overview, on-screen keyboard, 設定 GUI)は `docs/blockers.md` に記載。
