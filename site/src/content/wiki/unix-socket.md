# Unix ドメインソケット

::infobox Unix ドメインソケット
種類 | 同じ機械の中のプロセス間通信
場所 | ファイルシステムの上のパス(例: $XDG_RUNTIME_DIR/wayland-1)
権限 | ファイルの権限で、誰がつなげるかを決められる
ame-shell | Wayland の接続、ame-ctl、D-Bus

**Unix ドメインソケット**は、同じ機械の中のプロセス同士が話すための通り道です。ネットワークのソケットと同じ API で使えますが、ネットワークには出ません。

## ame-shell での使われ方 {#ame}

- [[wayland|Wayland]]: コンポジタとの接続そのもの。
- **ame-ctl**: `$XDG_RUNTIME_DIR/ame-shell-<ディスプレイ>.sock` に 1 行のコマンドを書いて、1 行の返事を読む。モード 0600 なので本人しか使えません。名前にディスプレイ名を含めるので、試験用の入れ子のセッションと本物が混ざりません([設定と ame-ctl](#/tech-config))。
- [[dbus|D-Bus]]: 通知のサーバの接続。

## 関連項目 {#see}

- [[xdg-runtime-dir]] / [[dbus]] / [[pipe]]
