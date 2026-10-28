<section class="hero">
<div class="hero-text">
<p class="eyebrow">Wayland デスクトップシェル + ウィンドウマネージャ</p>
<h1 class="hero-title">ame<span>-shell</span></h1>
<p class="hero-lead">すべてが<strong>ばねの物理</strong>で動く、ガラスのデスクトップ。<br>バー・ランチャー・ダッシュボード・通知・ロック画面・壁紙・ウィンドウ管理までを、<strong>Zig と Odin で書いた 1 つのプロセス</strong>にまとめました。Qt も GTK も Electron も使いません。</p>
<p class="hero-cta"><a class="btn primary" href="#/install">インストール</a><a class="btn" href="#/animation">アニメーションを試す</a><a class="btn ghost" href="https://github.com/TatsuyaM2667/ame-shell" target="_blank" rel="noopener">GitHub</a></p>
</div>
<figure class="hero-video"><video src="media/windows.mp4" poster="media/windows.jpg" muted loop playsinline autoplay></video></figure>
</section>

::stats
92〜160 ms | 起動してからバーが映るまで
0.0〜0.1 % | 待機時の CPU(壁紙を止めたとき)
約 1 ms | 1 回の描画にかかる CPU 時間
69〜75 MB | 待機時のメモリ(PSS)
2 KB | アニメーションの中核(Odin)を WebAssembly にした大きさ
1 プロセス | シェル全体 + ウィンドウマネージャ

## ame-shell とは {#about}

ame-shell(雨シェル)は、[River](https://codeberg.org/river/river) の上で動く Wayland のデスクトップシェルです。River 0.5 のセッションでは、ame-shell 自身が**ウィンドウマネージャ**も兼ねます。窓の配置(dwindle タイリング)・開閉のアニメーション・キー操作・ワークスペースを、シェルと同じプロセス・同じアニメーションの仕組みで動かします。

ふつうの Wayland 環境は「コンポジタ + バー + ランチャー + 通知 + ロック + 壁紙 + …」と、別々のプログラムを組み合わせて作ります。ame-shell はそれを**1 つのプログラム・1 つの GPU 描画・1 つのばねのエンジン**にまとめています。そのため、どの部品も同じ動き方・同じガラス・同じ配色になります。

::cards
🌧 | すべてがばねで動く | 窓・パネル・通知・歌詞・トーンアームまで、Odin で書いた**同じばねの物理**で動きます。途中で目標が変わっても速度が途切れません。[試す](#/animation)
🪟 | ウィンドウマネージャ内蔵 | River 0.5 の上で dwindle タイリング・窓の開閉アニメーション・スクラッチパッド・ワークスペース。シェルと 1 つのプロセス。
💎 | 本物のガラス | 壁紙を dual Kawase でぼかし、縁で屈折・色収差・ハイライト。パネルは自分の真後ろの壁紙を映します。[仕組み](#/tech-glass)
🎨 | 壁紙から配色 | 壁紙(動画でも)の印象的な色からアクセント・ガラス・文字色を作り、なめらかに移り変わります。再生中はアルバムアートの色に。
🎵 | 音楽が主役のダッシュボード | 回るレコード・トーンアーム・cava のスペクトラム・1 行ずつ弾んで出る同期歌詞・アルバム名。
⚡ | 軽い | 描画は画面の更新(フレームコールバック)に合わせるだけ。定期的に起きて調べるタイマーは使いません。待機中はほぼ 0%。[数字](#/performance)
🧩 | WebAssembly ウィジェット | Zig で書いたウィジェットを wasm にして、シェルの中で安全に動かします。保存すると状態を保ったまま差し替わります。
🐡 | FreeBSD でも | Linux(Chimera / Arch など)と FreeBSD に対応。FreeBSD は完全自動のインストーラ付き。

## 見てみる {#tour}

::video dashboard | ダッシュボード: 天気・カレンダー・システム情報・メディア。タブはばねで切り替わります

::video media | メディア: 回るレコード、再生中は針が溝に乗るトーンアーム、1 行ずつポンと出る同期歌詞

::video wallpaper | 壁紙ピッカー: 斜めのカードから選ぶと、カードの位置から波紋・円・斜めワイプ・短冊で切り替わり、配色も壁紙に合わせて変わります

::video launcher | ランチャー: Odin のあいまい検索で、打った瞬間に並び替わります

::img shot-lock.jpg | ロック画面(Super+L)。ログイン画面(SDDM)も同じ見た目のテーマを入れられます

## 技術者の方へ {#engineers}

[技術解説](#/tech)では、ame-shell を**コードの単位で**説明しています。各ページで、実際のコードを引用しながら、**何をしているか・なぜその方法にしたか・どんな結果が出たか・ほかの方法とどう違うか**を書いています。

| 読みどころ | ページ |
|---|---|
| ばねを解析解ではなく半陰的オイラー + 1 ms の刻みで積分する理由(wasm で libm が使えない、フレームレートに依存させない) | [ばねとアニメーションの中核](#/tech-anim) |
| 1 種類の四角形(28 個の float)と SDF だけで、角丸・影・ガラス・文字を 1 回の描画命令で描く | [GPU レンダラ](#/tech-gpu) |
| 枠とドロワーを smooth-min で 1 つの形に溶かす / 排他領域のための 1px のサーフェス | [枠とドロワー](#/tech-frame) |
| 窓の中身を拡大せず clip box を広げる WM のアニメーション、再起動をまたいで窓を保つ方法 | [ウィンドウマネージャ](#/tech-wm) |
| FreeBSD で起動直後に SIGSYS で落ちた原因と、逆アセンブルで再発を防ぐ仕組み | [起動とイベントループ](#/tech-loop) |
| ロックで閉じ込めないための 4 つの事前確認と、PAM を子プロセスで呼ぶ理由 | [通知とロック画面](#/tech-notify-lock) |
| 配色だけはばねではなく時間の関数にした理由 / アクセントの色相を 8 つの色に寄せる規則 | [ガラス・壁紙・配色](#/tech-glass) |

## 3 行でインストール {#quick}

```sh
git clone https://github.com/TatsuyaM2667/ame-shell && cd ame-shell
sh install.sh          # Chimera Linux・Arch Linux・FreeBSD は依存パッケージまで全自動
ame-update             # 以後の更新(パッケージ + ame-shell 本体)
```

> このサイトも ame-shell と同じ考え方で作っています。ページの本文は **Zig で書いた WebAssembly** が HTML にし、[アニメーション](#/animation)のデモは ame-shell 本体と**同じ Odin のコード**を WebAssembly にしてブラウザで動かしています。
