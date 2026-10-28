# kqueue

::infobox kqueue
OS | FreeBSD(4.1 以降)、macOS、ほかの BSD
設計 | Jonathan Lemon(2000)
主な呼び出し | kqueue(), kevent()
特徴 | fd 以外(プロセス・シグナル・タイマー・ファイルの変更)も同じ仕組みで待てる

**kqueue** は、BSD 系の OS の、イベントを待つための汎用の仕組みです。Linux の [[epoll]] に当たりますが、より多くの種類の出来事を扱えます。

## 概要 {#overview}

kqueue には「フィルタ」という種類があり、fd の読み書き(`EVFILT_READ`)だけでなく、タイマー(`EVFILT_TIMER`)、ファイルの変更(`EVFILT_VNODE`)、プロセスの終了(`EVFILT_PROC`)、シグナル(`EVFILT_SIGNAL`)なども、同じ `kevent()` で待てます。

## ame-shell での使われ方 {#ame}

ame-shell のイベントループは [[epoll]] と [[timerfd]] と [[inotify]] で書いています。FreeBSD では、**libepoll-shim**(kqueue の上に epoll と timerfd を作るライブラリ)と **libinotify** を使って、同じコードを動かしています。Wayland のライブラリ自身も、FreeBSD では epoll-shim を使っています([OS 対応](#/tech-platform))。

## 理論と研究 {#theory}

:::research 設計の比較
Lemon(2001)は、select・poll の O(n) の問題と、Linux の初期の RT シグナルによる方式の欠点(キューのあふれ)を分析し、「変更の一覧と、結果の一覧を 1 回の呼び出しで渡す」kevent の設計を提案しました。epoll は登録(`epoll_ctl`)と待機(`epoll_wait`)が別の呼び出しですが、kevent はまとめて行えるので、システムコールの回数を減らせます。
:::

## 関連項目 {#see}

- [[epoll]] / [[sysctl]]

## 参考文献 {#refs}

- J. Lemon, "Kqueue: A generic and scalable event notification facility", USENIX Annual Technical Conference, FREENIX Track, 2001.
