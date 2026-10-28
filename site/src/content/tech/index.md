# 技術解説: 全体像

この章は、ame-shell を**コードの単位で**説明します。各ページは同じ形で書いています。

1. **何をしているか**(対象のファイルと行数)
2. **実際のコード**(リポジトリからそのまま抜き出し、途中を `…` で省略)
3. **なぜこの方法にしたか**(設計判断と、その根拠になった計測や事故)
4. **得られた結果**(計測値・挙動)
5. **ほかの方法との違い**(採らなかった案と、その理由)

> 引用しているコードと数値は、すべて 2026 年 10 月時点の `master` のものです。計測は Ryzen 7 7735HS / Radeon 680M / Mesa 26.2 / Chimera Linux(musl)、ReleaseFast ビルドで行っています。

## 設計の原則 {#principles}

ame-shell のコードは、次の 6 つの原則で一貫しています。各ページの判断は、ほぼすべてこのどれかから導かれています。

| 原則 | 中身 | 現れるところ |
|---|---|---|
| **待つ、調べない** | 状態の変化は「起こされる」ことで知る。定期的に起きて調べる(ポーリング)ことはしない | 1 つの epoll に全部の fd を入れる / タイマーは「次に変わる時刻」だけ / `playerctl --follow`・`pactl subscribe`・inotify |
| **動いている間だけ描く** | 描画は Wayland のフレームコールバックに合わせ、ばねが止まったら次を頼まない | `surface.zig` の `schedule` と `render` / WM の 8ms タイマーもアニメーション中だけ |
| **1 つにまとめる** | 1 プロセス・1 EGL コンテキスト・1 種類の四角形・1 つのばね | グリフアトラスとぼけた壁紙を全部品で共有 / 描画は 1 回の命令 |
| **重い仕事は描画の外へ** | 画像のデコード・外部コマンド・認証は、スレッドか子プロセスで行い、終わったら pipe で知らせる | アイコン・アバター・pactl・PAM・curl・nmcli |
| **無ければ、その機能だけ止める** | 依存するライブラリやコマンドが無くても、シェル全体は動き続ける | libmpv・libpam は dlopen / cava・nmcli・bluetoothctl・wpctl は見つからなければ「不明」 |
| **OS の違いは端に閉じ込める** | Linux と FreeBSD の違いは `src/platform/` と `build.zig` だけで吸収する | `bsd.zig`(sysctl)/ `loop.zig` の timerfd / ioctl の型 |

## ファイルの地図 {#map}

本体は Zig 約 17,600 行、Odin 192 行です。

| 層 | ファイル(行数) | 役割 | 解説 |
|---|---|---|---|
| 入口 | `main.zig`(80)・`app.zig`(1090) | 起動・Wayland のグローバル・出力・入力の配送・メインループ | [起動とイベントループ](#/tech-loop)・[Wayland](#/tech-wayland) |
| 基盤 | `platform/loop.zig`(96) | epoll + timerfd | [起動とイベントループ](#/tech-loop) |
| 基盤 | `surface.zig`(307) | layer-shell / session-lock のサーフェス、フレーム駆動の描画 | [Wayland](#/tech-wayland) |
| 描画 | `gfx.zig`(1181) | GLES3 の 2D レンダラ、ガラス、枠、壁紙のシェーダ | [GPU レンダラ](#/tech-gpu)・[ガラス](#/tech-glass) |
| 描画 | `text.zig`(363) | fontconfig → HarfBuzz → FreeType → SDF アトラス | [文字](#/tech-text) |
| 動き | `anim/anim.odin`(192)・`anim.zig`(126) | ばね・あいまい検索・主色抽出(Odin)と Zig 側の型 | [ばね](#/tech-anim) |
| 配色 | `theme.zig`(310) | 壁紙・アルバムアートから配色、エラーの赤い光 | [ガラス・壁紙・配色](#/tech-glass) |
| WM | `wm/wm.zig`(1233)・`wm/binds.zig`(98) | River 0.5 のウィンドウマネージャ、キー割り当て | [ウィンドウマネージャ](#/tech-wm) |
| UI | `frame/*.zig`(約 4,000) | 枠・縦バー・ドロワー・ダッシュボード・ネットワークのパネル | [枠とドロワー](#/tech-frame) |
| UI | `launcher.zig`(1219)・`icons.zig`(212)・`wallpick.zig`(383) | ランチャー・アイコン索引・壁紙ピッカー | [ランチャー](#/tech-launcher) |
| UI | `wallpaper.zig`(463)・`video.zig`(501) | 壁紙(シェーダ・画像・動画)と切り替え | [ガラス・壁紙](#/tech-glass)・[メディア](#/tech-media) |
| データ | `media.zig`(331)・`lyrics.zig`(319)・`audio.zig`(223) | MPRIS・同期歌詞・音の出力先 | [メディア](#/tech-media) |
| データ | `notify.zig`(589)・`lock.zig`(408) | 通知サーバ・ロック画面 | [通知とロック](#/tech-notify-lock) |
| 拡張 | `wasm.zig`(223)・`widget_abi.zig`(71)・`widgets/*.zig` | wasm3 でウィジェットを動かす | [WebAssembly](#/tech-wasm) |
| OS | `platform/sys.zig`(409)・`platform/bsd.zig`(159)・`platform/supertap.zig`(151) | システム情報・電源・Super 単独の検出 | [OS 対応](#/tech-platform) |
| 操作 | `config.zig`(345)・`ipc.zig`(242)・`ctl.zig`(59) | 設定の言語・Unix ソケット・ame-ctl | [設定と ame-ctl](#/tech-config) |
| 起動 | `session/*`(POSIX sh) | ame-session・ame-river5-init・ame-update・インストーラ | [セッション](#/tech-session) |

## 全体の構成 {#overview}

```
                       ┌──────────────── ame-shell(1 プロセス・1 EGL コンテキスト)───────────────┐
 River ◀─Wayland──▶   │ app.zig        グローバル / 出力 / seat / River の状態 / 入力の配送          │
 (layer-shell,        │ wm/wm.zig      ウィンドウマネージャ(river-window-management-v1、dwindle)   │
  session-lock,       │ surface.zig    layer / lock サーフェス。wl_surface.frame に合わせて描く         │
  window-mgmt,        │ gfx.zig        GLES3 の 2D レンダラ(インスタンス描画の四角形 1 種類 + SDF)     │
  xkb-bindings)       │ text.zig       fontconfig → HarfBuzz → FreeType → SDF → 共有グリフアトラス       │
                       │ anim.zig ────▶ anim/anim.odin(Odin: ばね / あいまい検索 / 主色抽出、C ABI)    │
                       │ frame/* bar wallpaper osd launcher notify dashboard lock media video ...       │
                       │ wasm.zig ────▶ wasm3(C)── widgets/*.wasm(Zig + Odin を wasm32 に)          │
                       │ ipc.zig        Unix ソケット ◀── ame-ctl                                       │
                       │ platform/      loop.zig(epoll + timerfd) / sys.zig / bsd.zig / supertap.zig   │
                       └────────────────────────────────────────────────────────────────────────────────┘
       子プロセス(pipe で結果だけ受け取る): playerctl --follow / pactl subscribe / curl / nmcli /
       bluetoothctl / cava / ffmpeg / PAM の認証 / ワーカースレッド: アイコン・アバター・サムネイル・pactl
```

## 1 フレームの流れ {#frame}

ある出来事(例: 音量キー)が画面に出るまでを追うと、全体のつながりが分かります。

1. River がキーを WM(ame-shell 自身)に知らせる → `binds.zig` の割り当て `.{ .ame = "volume up" }` が、ame-ctl と同じ処理(`ipc.zig` の `runCommand`)を**プロセスを起動せずに**直接呼ぶ。
2. `sys.setVolumeDelta(5)` が `wpctl` で音量を変え、値を読み直す。ほかのアプリが音量を変えたときは、常駐させている `pactl subscribe` の行が pipe に届いて epoll が起き、同じように読み直す。
3. OSD のばねの目標を変え、`surface.schedule()` で**そのサーフェスだけ**フレームコールバックを頼む。
4. コンポジタが次の画面更新で `done` を送る → `render(dt)` が呼ばれる。ばねを `dt` だけ進め、四角形の配列を積み、1 回の `glDrawArraysInstanced` で描く。
5. ばねがまだ動いていれば、`eglSwapBuffers` のコミットに次のフレームの要求を相乗りさせる。止まったら何もしない → epoll_wait で完全に眠る。

この流れの中に、決まった間隔で起きるものは 1 つもありません。それが待機時 CPU 0.0〜0.1% の理由です。
