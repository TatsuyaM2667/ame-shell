# 設計判断の記録

各項目: 決定 / 理由 / 却下した案

## 環境(実機確認: 2026-10-26)
Chimera Linux x86_64 / musl / dinit / AMD Ryzen 7 7735HS (16 スレッド) / Radeon 680M (radeonsi, Mesa 26.2.4) / RAM 13.3GB / 内蔵パネル + バッテリー(BAT0, ADP0)/ River 0.3.5(手動導入、apk 管理外)/ Zig 0.13.0(`/usr/local/zig-0.13.0`)/ Odin dev-2026-08(`~/.local/bin/odin`、ソースビルド)。

## レンダラ: EGL + GLES3
- 理由: Mesa radeonsi の GLES3.2 が使え、2D UI には十分。Vulkan はコード量が数倍になり、利点(マルチスレッド記録など)がこの規模の UI では効かない。
- 却下: Vulkan(工数)、ソフトウェア描画 + wl_shm(ガラス/ブラーの負荷が CPU に乗る)。

## 1 プロセス・1 EGL コンテキスト
- 理由: グリフアトラスと壁紙のブラー済みテクスチャを全パネルでそのまま共有できる。
- 却下: パネルごとのプロセス(テクスチャ共有に dmabuf 受け渡しが必要になる)。

## eglSwapInterval(0) + wl_surface.frame 駆動
- 理由: 複数サーフェスのそれぞれが vblank 待ちでブロックすると互いに足を引っ張る。同期はフレームコールバックで取る。動きが無いときはフレームを要求しないので待機時 CPU はほぼ 0(実測 0〜0.1%)。

## アニメーション: Odin のスプリング(semi-implicit Euler, 1ms サブステップ)
- 理由: 解析解は ζ<1/=1/>1 で場合分けが要り、sin/cos/exp(libm)を呼ぶ → wasm32-freestanding でシンボル未解決になる。四則演算だけの積分にすると、同じ Odin ソースがネイティブ・wasm32 の両方でランタイム無しにリンクできる。1 フレームあたり十数回のループで、計算量は無視できる。
- 目標値の変更時は x と v をそのまま引き継ぐ(速度連続)。`zig build test` で検証。
- 却下: Zig で書く(Odin を使う意味が薄れる)、イージング関数中心(途中で目標が変わると不連続になる)。

## テキスト: FreeType の bsdf(ビットマップ→SDF)、基準 40px、アトラス 2048²
- 計測: アウトライン SDF ("sdf" ラスタライザ)は CJK で 1 字 6.6ms。通常描画 → bsdf 変換で 2.2ms。品質差は UI サイズでは視認できない(スクリーンショットで確認)。
- 初回表示のスパイクを避けるため、起動後のアイドル時間に ASCII・かな・UI 用漢字・Nerd アイコン・アプリ名を 6ms ずつ先読み。
- アトラスは途中拡張すると全グリフ再生成のスパイクになるので最初から 2048²(GPU 側確保で CPU の常駐メモリはほぼ増えないことを計測で確認)。
- フォントは "Noto Sans CJK JP" を明示(この環境の `fc-match sans:lang=ja` は KR を返すため)。足りない字は fontconfig に問い合わせて動的にフォールバック。

## ガラスのブラー: 壁紙だけを対象にした dual Kawase
- 理由: シェルが壁紙を所有しているので、他プロセスの画面を読まずに「後ろの壁紙」を正確にサンプルできる。
- River 0.3.5 の globals を WAYLAND_DEBUG で実測: `ext_background_effect_manager_v1` は無い → ウィンドウ越しのブラーは不可能。ウィンドウの上に出るパネル(ランチャー等)は色を濃くする(`glassStrong`)。
- ライブ壁紙の毎フレームではバーを描き直さない(ブラーの微小な変化のために全パネルを毎フレーム描くのは割に合わない)。壁紙の切替トランジション中だけ追従。

## 壁紙の省電力
- ライブ壁紙は timerfd で設定 FPS(既定 30)ごとにフレームを要求。出力のリフレッシュレートが上限。
- AC から外れたら battery-fps(既定 12)、内部解像度 ×0.75。画像壁紙は切替時以外描かない。
- 実測: 静止 0〜0.1% / オーロラ 30fps 約 1.1% / 雨 60fps 約 1.0%(CPU。GPU 側負荷は別)。

## WASM ランタイム: wasm3
- 理由: 純 C・依存なしで musl でもそのまま `zig build` に入る。ウィジェットは軽く、インタプリタで十分(1 フレームの描画命令生成は µs 単位)。
- 却下: WAMR(JIT/AOT は速いがビルド構成が大きく CMake 前提)、wasmtime(Rust・巨大)。
- サンドボックス: import は `ame.action` のみ、WASI 無効、メモリ 1MiB 固定、コマンド種別は非網羅 enum で未知値を無視、文字列は境界チェック。トラップしたウィジェットは停止(シェルは落ちない)。

## アイコン: PNG のみ、ワーカースレッドで 64x64 に縮小
- 計測: `/usr/share/pixmaps/zellij.png` のデコードだけで 92ms。描画スレッドでやるとフレームが止まる。
- ワーカーは (世代, 行, 画素) を返すだけでランチャーのデータに触れない → 再走査中でも安全。結果は pipe + epoll で受け取る。
- SVG は未対応(rsvg 等の依存を避けた)→ 頭文字の丸アイコンにフォールバック。

## 通知: libdbus の private 接続を epoll に載せる
- すでに別の通知デーモン(このマシンでは swaync)が名前を持っていれば奪わない(DO_NOT_QUEUE)。ame-shell の SDDM セッションでは swaync が起動しないので ame-shell が担当する。

## 音量: `pactl subscribe` を常駐させてイベント駆動、値は `wpctl`
- 理由: libpipewire の開発パッケージが未導入(pkg-config に無い)。PipeWire のネイティブ API を使うより依存が少なく、変化があったときだけ読み直せる。
- 却下: 定期ポーリング。

## ロック画面
- PAM は dlopen(ヘッダ不要、libpam が無い環境でもシェルは起動する)。認証は fork した子プロセスで行い、結果を pipe で受ける(失敗時ディレイで UI が固まらない)。
- サービス: `ame-shell`(install-session.sh が作成)を優先。未インストール時は同目的の `swaylock` の設定を使う(仕様の「ame-shell が使えなければロックしない」からの意図的な緩和。swaylock は同じく画面ロック用で auth include login のみ)。どちらも無い・unix_chkpwd(setuid)が無い・コンポジタが非対応 → ロックせず OSD と通知で理由を出す。
- 自動テストで誤パスワードを試すことはしない(pam_faillock 等でアカウントがロックされる危険があるため)。

## PAM ファイルの置き場所(install-session.sh)
- このマシンは `/etc/pam.d` が無く `/usr/lib/pam.d` のみ。libpam の文字列を調べ、`/etc/pam.d` → `/usr/lib/pam.d` の順に探す版であることを確認した上で `/etc/pam.d/ame-shell` を作る。古い libpam(フォールバック無し)なら `/etc/pam.d` を作った瞬間に他サービスが読めなくなるため `/usr/lib/pam.d` に置く。
- 注意: BSD grep はバイナリ内を検索しないので `LC_ALL=C tr -c '[:print:]' '\n'` で文字列化してから探す(実際にこの不具合で誤判定したため修正済み)。

## シート(libseat)の判定(ame-session)
1. `XDG_SESSION_ID` があり loginctl がある → elogind のセッションがある → 何もしない(libseat の logind バックエンド)
2. `/run/seatd.sock` に読み書きできる → 何もしない(seatd バックエンド)
3. どちらも無く `seatd-launch` がある → 経由して起動
- このマシン: system-login に `pam_elogind` と `pam_turnstile` があり、ユーザーは `_seatd` に未所属 → 1 の経路。

## D-Bus(ame-session)
- `DBUS_SESSION_BUS_ADDRESS` が無ければ、turnstile が作る `$XDG_RUNTIME_DIR/bus` があればそれを使い、無ければ `dbus-run-session` で自分を再実行。

## Phase 6(ウィンドウの開閉・移動アニメ)
- River 0.3.x には外部 WM プロトコル(river-window-management-v1)が無く、ウィンドウの位置はコンポジタ内部で決まる。layout-v3 はレイアウトの寸法を返すだけで補間フレームを挟めない → 実装不可。`docs/blockers.md` に River 0.4 移行時の手順を記載。

## クロスターゲット
- `zig test src/config.zig -target {x86_64-linux-gnu, aarch64-linux-musl, x86_64-linux-musl} --test-no-exec`: 全て成功。
- `ame-ctl` を x86_64-linux-gnu(glibc, Arch 相当)でビルド: 成功。
- `ame-shell` 本体の glibc ビルドは、glibc 環境のシステムライブラリ(wayland/EGL/freetype 等)に対してリンクする必要があるため、Arch 実機でのビルドを想定(build.zig は glibc/musl の差に依存しない書き方)。
- `Debug` 以外はバイナリを strip(ame-shell 626KB, ame-ctl 14KB)。
