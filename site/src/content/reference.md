# リファレンス

## キー操作(River 0.5 のセッション) {#keys}

| キー | 動作 |
|---|---|
| Super(単独で押して離す)/ Super+D | ランチャー |
| Super+Return / Super+T | 端末(foot) |
| Super+A / Super+N / Super+U | ダッシュボード / 通知センター / ユーティリティ |
| Super+Escape | セッション(ロック・ログアウト・再起動・電源オフ。危険な操作は 2 回押し) |
| Super+L | ロック |
| Super+Shift+W | 壁紙ピッカー |
| Super+Q / Super+F / Super+Space | 閉じる / 全画面 / 浮かせる |
| Super+J・K / Super+Shift+J・K | フォーカスの移動 / 窓の入れ替え |
| Super+Ctrl+H・L | 左右の比率 |
| Super+1〜9 / Super+Shift+1〜9 / Super+Alt+1〜9 | ワークスペースの切り替え / 窓を移動 / 窓を移動して自分も移る |
| Super+Ctrl+1〜9 | ワークスペースの表示を足す |
| Super+P / Super+Shift+P | スクラッチパッド |
| Super+ドラッグ(左 / 右)/ Super+中クリック | 移動 / 大きさの変更 / 浮かせる |
| Print / Shift+Print | 範囲 / 全画面のスクリーンショット(`~/Pictures/Screenshots` とクリップボード) |
| 音量・明るさ・メディアキー | OSD つき |
| Super+Shift+E | セッションを終了 |

## 設定ファイル {#config}

`~/.config/ame-shell/config.ame`(無ければ `share/ame-shell/config.ame`)。**保存した瞬間に反映**されます。

文法は `セクション { キー 値 }` の形です。値には、数値・`"文字列"`・単語・`#RRGGBB`・`on` / `off` を書けます。`//` から行末まではコメントです。書き間違えても止まらず、その行だけを無視して、ログに警告を出します。

```
shell {
  layout caelestia          // caelestia(枠とドロワー)| classic(横バー)
  ui-scale 1.25
  super-launcher on         // Super を単独で押して離すとランチャー
  tap-to-click on           // タッチパッドのタップでクリック
  // weather-location "Sapporo"
}
theme {
  accent #7ab8ff            // アクセント色(auto-color on なら壁紙から)
  tint #0b1730              // ガラスの色
  tint-strength 0.42
  text #eaf2ff
  subtext #9fb4d6
  radius 18
  blur 3                    // 1〜4
  refraction 10             // 縁の屈折(px)
  sparkle 0.7               // きらめき(0 で無効)
  anim-speed 1.0            // 全部のアニメーションの速さの倍率
  media-accent on           // 再生中はアルバムアートの色に
}
bar {
  height 38
  margin 8
  position top              // top | bottom
  clock-24h on
  show-seconds off
}
wallpaper {
  mode aurora               // aurora | rain | image
  // image "~/Pictures/wallpaper.jpg"   画像・GIF・動画
  animate on                // off で完全に静止
  fps 30
  battery-fps 12
  scale 0.5                 // ライブ壁紙の内部解像度
  transition random         // ripple | circle | slant | shards | random
  aurora-a #29d6b0
  aurora-b #3d7bff
  aurora-c #9a5cff
}
font {
  ui "Noto Sans CJK JP"
  icon "JetBrainsMono Nerd Font Propo"
}
apps { terminal foot }
notifications { timeout 6000 }
lock { enabled on }
```

## ame-ctl {#ctl}

動いている ame-shell を外から操作するコマンドです(Unix ソケット経由)。キーバインドやスクリプトから使えます。

```
ame-ctl launcher toggle|open [検索語]|close
ame-ctl dashboard toggle|open|close|dashboard|media|performance|workspaces
ame-ctl network | bluetooth | wallpaper-picker | session | sidebar | utilities | close-all
ame-ctl volume up|down|mute|<0-100>      ame-ctl brightness up|down
ame-ctl wallpaper aurora|rain|<画像・GIF・動画のパス>
ame-ctl accent '#ff88aa'|reset           ame-ctl notify <テキスト>
ame-ctl workspace <1-9>
ame-ctl window close|fullscreen|float|focus-next|focus-prev|swap-next|swap-prev   (River 0.5)
ame-ctl lock | reload | widgets reload | stats | restart | quit
```

- `ame-ctl restart`: 新しい版に入れ替えます。**窓とワークスペースはそのまま**です(River 0.5 の WM の状態を引き継ぎます)。
- `ame-ctl stats`: 稼働時間・CPU 時間・RSS・フレーム数・平均と最大の描画時間。

## 環境変数 {#env}

| 変数 | 意味 |
|---|---|
| `AME_CONFIG` | 設定ファイルの場所を変える |
| `AME_SHARE_DIR` | 既定の設定・ウィジェット・データの場所 |
| `AME_VIDEO_BACKEND=ffmpeg` | 動画の壁紙を libmpv ではなく ffmpeg で再生する |
| `AME_OUTPUT_SCALE` | 画面の拡大率(`1.5` や `eDP-1 1.5`、`off` で自動設定なし) |
| `AME_FASTFETCH=0` | 端末を開いたときの fastfetch を出さない |
| `AME_OS_ID` | バーのロゴを決める OS の ID を上書き(試験用) |
| `AME_RIVER5` | River 0.5 の場所 |
| `AME_SOURCE` | `ame-update` が使うソースの場所 |
| `AME_WALLPAPERS_REPO` | `ame-update` が取ってくる追加の壁紙のリポジトリ(空で無効) |
| `AME_SESSION_NESTED=1` | 今のセッションの中に窓として起動する(試験用) |
| `AME_DEBUG=1` / `AME_DEBUG_FRAMES=ミリ秒` / `AME_DEBUG_MEM=1` | 試験用のコマンド / 遅いフレームの内訳 / 起動の段階ごとのメモリ |

## ファイルの場所 {#files}

| 場所 | 中身 |
|---|---|
| `~/.config/ame-shell/config.ame` | 設定 |
| `~/.config/ame-shell/widgets/*.wasm` | 自分のウィジェット(同じ名前なら既定のものより優先) |
| `~/.config/ame-shell/avatar` | ダッシュボードの自分の写真(画像のパスを 1 行。無ければ `~/.face`) |
| `~/.config/ame-shell/output-scale` | 画面の拡大率の指定 |
| `~/.config/ame-shell/xkb-layout` | キーボード配列(例: `jp`) |
| `~/.config/ame-shell/river5-extra.sh` | River 0.5 のセッションの開始時に読む追加の設定 |
| `~/.local/state/ame-shell/session.log` | セッションのログ |
| `~/.local/state/ame-shell/wallpaper` | 壁紙ピッカーで最後に選んだ壁紙 |
| `~/Pictures/wallpapers`・`~/.local/share/ame-shell/wallpapers` | 壁紙のフォルダ |
| `$XDG_RUNTIME_DIR/lyrics/<プレーヤー名>.lrc` | プレーヤーから渡す同期歌詞 |
