# Wayland

::infobox Wayland
種類 | 表示サーバのプロトコル
登場 | 2008 年(Kristian Høgsberg)
置き換えるもの | X Window System(X11)
通信 | Unix ドメインソケット上のメッセージ
ame-shell | すべての画面表示と入力

**Wayland**(ウェイランド)は、アプリと「画面を合成するプログラム([[compositor|コンポジタ]])」が話すための**約束事(プロトコル)**です。Linux や FreeBSD のデスクトップで、X11 の後継として使われています。

## 概要 {#overview}

画面に窓を出すには、アプリが「この絵を出して」と誰かに頼む必要があります。X11 では、間に X サーバという大きなプログラムがいて、アプリの代わりに絵を描いたり、ほかのアプリの画面を読ませたりしていました。

Wayland では、アプリは**自分で描いた絵(バッファ)を丸ごと渡すだけ**です。コンポジタがそれを画面に並べます。ほかのアプリの画面を勝手に読むことはできません。そのぶん単純で、安全で、絵がちらつきません。

## 仕組み {#how}

- アプリ(クライアント)とコンポジタは [[unix-socket|Unix ドメインソケット]]でつながります。場所は `$XDG_RUNTIME_DIR/wayland-1` などです([[xdg-runtime-dir]])。
- やりとりは**オブジェクト**と、それに対する**リクエスト**(アプリ → コンポジタ)・**イベント**(コンポジタ → アプリ)で行います。例えば `wl_surface` に `attach`(バッファを付ける)・`commit`(確定する)を送ると、コンポジタは `frame` の合図([[frame-callback]])を返します。
- 機能は**プロトコルの拡張**として XML で定義されます(`xdg-shell`、[[layer-shell]]、[[session-lock|ext-session-lock]] など)。`wayland-scanner` が XML から C のコードを作ります。
- 使える拡張は、接続したときにコンポジタが「グローバル」の一覧として知らせます。アプリは自分が知っている版と、コンポジタの版の**小さいほう**でつなぎます。

## ame-shell での使われ方 {#ame}

ame-shell は Wayland のクライアントです。壁紙・枠・ランチャーなどを [[layer-shell]] のサーフェスとして出し、ロック画面は [[session-lock|ext-session-lock]]、ウィンドウの配置は [[river|River]] の `river-window-management-v1` で行います。16 個のプロトコルを使い、XML から `wayland-scanner` でコードを作っています([ビルド](#/tech-build))。

## 理論と研究 {#theory}

Wayland の設計の核は「**クライアント側で描く(client-side rendering)**」と「**すべてのフレームが完璧(every frame is perfect)**」です。クライアントはバッファを完成させてから `commit` し、コンポジタは複数のサーフェスの状態を**まとめて原子的に**適用します。X11 で起きた「描いている途中の絵が見える(tearing・flicker)」は、原理的に起きません。

一方、ほかのクライアントの画面を読めないことは、スクリーンショットや画面共有を難しくしました。これは別のプロトコル(`wlr-screencopy`、`ext-image-copy-capture`、xdg-desktop-portal)で、許可を取って行う形に整理されています。

## 関連項目 {#see}

- [[compositor]] / [[layer-shell]] / [[frame-callback]] / [[river]] / [[egl]]

## 参考文献 {#refs}

- [Wayland の公式文書](https://wayland.freedesktop.org/docs/html/)
- [Wayland Explorer(プロトコルの一覧)](https://wayland.app/protocols/)
- Kristian Høgsberg, "The Wayland display server", 2008.
