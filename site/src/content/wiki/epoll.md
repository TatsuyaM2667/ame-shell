# epoll

::infobox epoll
OS | Linux(2.5.44 以降)
主な呼び出し | epoll_create1, epoll_ctl, epoll_wait
計算量 | 準備できた fd の数に比例(登録した数には比例しない)
FreeBSD | kqueue(epoll は libepoll-shim で再現)
ame-shell | イベントループのすべて

**epoll** は、たくさんのファイル記述子(fd)を同時に見張り、「読める・書ける状態になったものだけ」を効率よく教えてくれる、Linux の仕組みです。

## 概要 {#overview}

ame-shell は、画面(Wayland)、時計、音量の変化、通知、設定ファイルの変更、ame-ctl…と、たくさんのものを同時に待っています。1 つずつ「何か来た?」と聞いて回る(ポーリング)と、何も来ていなくても CPU を使い続けます。epoll に全部を登録して `epoll_wait` を呼ぶと、**何かが起きるまでカーネルの中で眠り**、起きたら「これとこれが準備できた」と教えてくれます。

## 仕組み {#how}

```c
int ep = epoll_create1(EPOLL_CLOEXEC);
struct epoll_event ev = { .events = EPOLLIN, .data.fd = fd };
epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);     // 見張る fd を登録
int n = epoll_wait(ep, evs, 32, -1);       // -1 = 何か起きるまで待つ
```

- **レベルトリガ**(既定): 読めるデータが残っている限り、毎回知らせる。
- **エッジトリガ**(`EPOLLET`): 状態が変わった瞬間だけ知らせる。

## ame-shell での使われ方 {#ame}

ame-shell のイベントループは、96 行の `loop.zig` で、すべての fd を 1 つの epoll に入れています。タイマーも [[timerfd]] として、ファイルの変更も [[inotify]] として、子プロセスの結果も [[pipe|パイプ]]として、全部 fd になるので、1 か所で待てます。待機時の CPU 使用率は 0.0〜0.1% です([起動とイベントループ](#/tech-loop))。

>! レベルトリガでは、読み終わった(EOF の)パイプを登録したままにすると、epoll が起き続けて CPU が空回りします。ame-shell でも動画の再生に失敗したときにこの不具合があり、失敗したパイプをすぐ外すようにして直しました。

## 理論と研究 {#theory}

:::research select・poll との違い
`select` と `poll` は、呼ぶたびに見張る fd の一覧全体をカーネルに渡し、カーネルは全部を調べるので、計算量は**登録した fd の数 n** に比例します(O(n))。epoll は、登録をカーネルの中に持ち続け(赤黒木)、準備ができた fd を「準備済みリスト」に追加していくので、`epoll_wait` のコストは**準備できた数 k** に比例します(O(k))。数万の接続を扱うサーバで差が出る、C10K 問題への答えの 1 つです。

ame-shell の fd は数十個なので、計算量の差は小さいですが、「1 つの仕組みで全部を待てる」ことと、FreeBSD の [[kqueue]] と考え方が近いことが利点です。
:::

## 関連項目 {#see}

- [[kqueue]] / [[timerfd]] / [[inotify]] / [[pipe]]

## 参考文献 {#refs}

- `man 7 epoll`
- D. Kegel, [The C10K problem](http://www.kegel.com/c10k.html)
