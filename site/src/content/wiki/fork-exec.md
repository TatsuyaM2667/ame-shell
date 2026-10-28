# fork と exec

::infobox fork と exec
fork | 今のプロセスを複製する
exec | 今のプロセスを、別のプログラムに置き換える
組み合わせ | Unix で新しいプログラムを起動する基本の手順
ame-shell | アプリの起動、PAM の認証、curl などの子プロセス

**fork** は自分のプロセスを丸ごと複製し、**exec** は自分を別のプログラムに置き換える、Unix の基本のシステムコールです。この 2 つを組み合わせて、新しいプログラムを起動します。

## 概要 {#overview}

fork すると、親と子の 2 つのプロセスが、同じところから動き出します。違いは fork の戻り値(子は 0、親は子の番号)だけです。子は exec で別のプログラム(例: Firefox)になります。

## ame-shell での使われ方 {#ame}

- **アプリの起動**(二重 fork + setsid): 子でさらに fork して中間のプロセスをすぐ終わらせると、孫の親は init(PID 1)になり、ame-shell が終了を待つ必要がなく、ゾンビも残りません。`setsid` で ame-shell のプロセスグループから外すので、ame-shell を再起動してもアプリは道連れになりません([ランチャー](#/tech-launcher))。
- **PAM の認証**: fork した子で [[pam|PAM]] を呼び、結果を[[pipe|パイプ]]で 1 バイト返します。PAM の待ち時間で画面が止まらず、PAM のモジュールが落ちても子だけで済みます([ロック](#/tech-notify-lock))。
- **自分の入れ替え**(`ame-ctl restart`): fork せずに exec だけをして、新しい版の ame-shell に置き換わります([起動](#/tech-loop))。

## 理論と研究 {#theory}

:::research fork のコストと、代わりの方法
fork はメモリを「書き込まれるまでコピーしない」(copy-on-write)ので、大きなプロセスでも速く、すぐ exec するなら実際にコピーされるのはわずかです。それでも、ページテーブルの複製のコストがあり、Baumann ほか(2019)は、fork が現代の OS の設計を複雑にしていると論じ、`posix_spawn` のような「作って起動する」API を勧めています。ame-shell は、子プロセスでの事前処理(シグナルのマスクの初期化、fd の付け替え)が必要なため fork を使っています。
:::

## 関連項目 {#see}

- [[pipe]] / [[pam]] / [[setuid]]

## 参考文献 {#refs}

- A. Baumann et al., "A fork() in the road", HotOS 2019.
