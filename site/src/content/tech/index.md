# 技術解説: 全体像

この章は、ame-shell を**コードの単位で**説明します。各ページは同じ形で書いています。

1. **何をしているか**(対象のファイルと行数)
2. **実際のコード**(リポジトリからそのまま抜き出し、途中を `…` で省略)
3. **なぜこの方法にしたか**(設計判断と、その根拠になった計測や事故)
4. **得られた結果**(計測値・挙動)
5. **ほかの方法との違い**(採らなかった案と、その理由)

> 引用しているコードと数値は、特に書いていなければ 2026 年 10〜11 月の `master` のものです。計測は Ryzen 7 7735HS / Radeon 680M / Mesa 26.2 / Chimera Linux(musl)、ReleaseFast ビルドで行っています。

:::easy このページを読む前に
デスクトップの画面は、たくさんの部品(バー・壁紙・通知・窓)でできています。ふつうは、部品ごとに別々のプログラムが動いています。ame-shell は、それを**1 つのプログラム**にまとめ、全部を同じ方法で描き、同じ方法で動かしています。

このページは、その全体の地図です。分からない言葉は、[[wayland]]・[[compositor]]・[[epoll]] のように点線の下線が付いていれば、押すと Wiki で説明が開きます。
:::

## 設計の原則 {#principles}

ame-shell のコードは、次の 6 つの原則で一貫しています。各ページの判断は、ほぼすべてこのどれかから導かれています。

| 原則 | 中身 | 現れるところ |
|---|---|---|
| **待つ、調べない** | 状態の変化は「起こされる」ことで知る。定期的に起きて調べる(ポーリング)ことはしない | 1 つの epoll に全部の fd を入れる / タイマーは「次に変わる時刻」だけ / MPRIS・NetworkManager・BlueZ の D-Bus の信号・`ame-uzume watch`・inotify |
| **動いている間だけ描く** | 描画は Wayland のフレームコールバックに合わせ、ばねが止まったら次を頼まない | `surface.zig` の `schedule` と `render` / WM の 8ms タイマーもアニメーション中だけ |
| **1 つにまとめる** | 1 プロセス・1 EGL コンテキスト・1 種類の四角形・1 つのばね | グリフアトラスとぼけた壁紙を全部品で共有 / 描画は 1 回の命令 |
| **重い仕事は描画の外へ** | 画像のデコード・外部コマンド・認証は、スレッドか子プロセスで行い、終わったら pipe で知らせる | アイコン・アバター・ame-uzume・PAM・ame-yatagarasu・ame-hamon |
| **無ければ、その機能だけ止める** | 依存するライブラリやコマンドが無くても、シェル全体は動き続ける | libmpv・libpam・libpulse は dlopen / NetworkManager・BlueZ・ame-uzume は見つからなければ「不明」 |
| **OS の違いは端に閉じ込める** | Linux と FreeBSD の違いは `src/platform/` と `build.zig` だけで吸収する | `bsd.zig`(sysctl)/ `loop.zig` の timerfd / ioctl の型 |

## ファイルの地図 {#map}

本体は Zig 約 42,700 行、Odin 369 行です(2026 年 11 月)。`src/` は役割ごとのフォルダに分けています。

| フォルダ(行数) | 役割 | 解説 |
|---|---|---|
| `main.zig`・`core/`(2,263) | 起動・Wayland のグローバル・出力・入力の配送・ame-ctl の口・サーフェス | [起動とイベントループ](#/tech-loop)・[Wayland](#/tech-wayland)・[設定と ame-ctl](#/tech-config) |
| `platform/`(2,566) | epoll + timerfd・OS ごとの違い・D-Bus(NetworkManager / BlueZ)・malloc の差し替え | [OS 対応](#/tech-platform)・[メモリ](#/tech-memory) |
| `gfx/`(2,830) | GLES3 の 2D レンダラ・文字・アイコン・配色・波紋 | [GPU レンダラ](#/tech-gpu)・[文字](#/tech-text)・[ガラス](#/tech-glass) |
| `frame/`(7,543) | 枠・縦バー・ドロワー・ダッシュボード・島・AI とネットワークのパネル | [枠とドロワー](#/tech-frame) |
| `desktop/`(8,361) | ランチャー・通知・壁紙と動画・OSD・スクショ・日本語入力・システムの変化・メモリの見張り | [ランチャー](#/tech-launcher)・[通知とロック](#/tech-notify-lock)・[メモリ](#/tech-memory) |
| `lock/`(1,966) | ロック画面とログイン画面 | [通知とロック](#/tech-notify-lock) |
| `media/`(2,420) | 再生中の曲(MPRIS)・歌詞・音の出力先・曲のウィジェット | [メディア](#/tech-media) |
| `ai/`(2,065) | AI チャット・コーディング CLI・MCP | [小さな道具](#/tech-tools) |
| `wm/`(2,520) | River 0.5 のウィンドウマネージャ | [ウィンドウマネージャ](#/tech-wm) |
| `widget/`(294)・`widgets/` | wasm3 でウィジェットを動かす | [WebAssembly](#/tech-wasm) |
| `device/`・`hand/`・`face/`(4,012) | AirPods・手の操作・顔の認証 | — |
| `lib/`(3,019) | 画面にも OS にも依存しない部品(試験つき) | [小さな道具](#/tech-tools) |
| `cmd/`(2,456) | 小さな道具(ame-lyrics・ame-ai・ame-agent・ame-config・ame-weather・ame-airpods・ame-handtrack・ame-keyring) | [小さな道具](#/tech-tools) |
| `anim/*.odin`(369) | ばね・あいまい検索・主色抽出・FFT・画像の縮小 | [ばね](#/tech-anim) |
| `session/*`(POSIX sh) | ame-session・ame-river5-init・インストーラ | [セッション](#/tech-session) |

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
       子プロセス(pipe で結果だけ受け取る): ame-uzume watch / ame-hamon / ame-yatagarasu /
       ffmpeg / PAM の認証 / ワーカースレッド: アイコン・アバター・サムネイル・音の出力先(ame-uzume)・PNG・Wi-Fi / Bluetooth の D-Bus
```

## 1 フレームの流れ {#frame}

ある出来事(例: 音量キー)が画面に出るまでを追うと、全体のつながりが分かります。

1. River がキーを WM(ame-shell 自身)に知らせる → `binds.zig` の割り当て `.{ .ame = "volume up" }` が、ame-ctl と同じ処理(`ipc.zig` の `runCommand`)を**プロセスを起動せずに**直接呼ぶ。
2. `sys.setVolumeDelta(5)` が小さな道具 `ame-uzume set +5` で音量を変え、値を読み直す。ほかのアプリが音量を変えたときは、常駐させている `ame-uzume watch` が新しい音量の 1 行(「45」/「45 muted」)を pipe に書き、epoll が起きてそれをそのまま使う。
3. OSD のばねの目標を変え、`surface.schedule()` で**そのサーフェスだけ**フレームコールバックを頼む。
4. コンポジタが次の画面更新で `done` を送る → `render(dt)` が呼ばれる。ばねを `dt` だけ進め、四角形の配列を積み、1 回の `glDrawArraysInstanced` で描く。
5. ばねがまだ動いていれば、`eglSwapBuffers` のコミットに次のフレームの要求を相乗りさせる。止まったら何もしない → epoll_wait で完全に眠る。

この流れの中に、決まった間隔で起きるものは 1 つもありません。それが待機時 CPU 0.0〜0.1% の理由です。

## 研究者向けの補足 {#research}

:::research 設計の位置づけ
ame-shell のアーキテクチャは、**イベント駆動・単一スレッド・単一 GL 文脈**の古典的な構成(reactor パターン)です。並行性は「ブロックする仕事をスレッドか子プロセスに出し、完了を fd で受ける」形に限り、共有状態のロックをほぼ不要にしています(例外はアイコンのワーカーの結果のリスト 1 つ)。

描画はリアクティブ(状態が変わったサーフェスだけを [[frame-callback]] で描く)で、即時モード(毎フレーム命令を積み直す)の API です。保持モードのシーングラフ(Qt Quick・GTK4)に比べて差分の管理が無い代わりに、「動いているものが無ければ何もしない」ことを、ばねの収束判定という 1 つの条件で保証しています。

関連: D. C. Schmidt, "Reactor: An Object Behavioral Pattern for Demultiplexing and Dispatching Handles for Synchronous Events", Pattern Languages of Program Design, 1995.
:::

## 関連する用語 {#terms}

- [[wayland]]
- [[compositor]]
- [[layer-shell]]
- [[epoll]]
- [[frame-callback]]
- [[spring]]
- [[sdf]]
- [[webassembly]]
