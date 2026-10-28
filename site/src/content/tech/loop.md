# 起動とイベントループ

<p class="file">対象: src/main.zig(80 行)/ src/platform/loop.zig(96 行)/ src/app.zig の run・onWarmTimer</p>

## イベントループ: すべてを 1 つの epoll で待つ {#epoll}

```zig
// src/platform/loop.zig
// 方針: 全てのデータ源(Wayland, タイマー, IPCソケット, inotify, 子プロセスのパイプ)を
// fd として1つの epoll に登録し、カーネルに待たせる。アニメーション中以外は
// epoll_wait で完全にブロックするので、待機時の CPU 使用率はほぼ 0 になる。
pub const Loop = struct {
    epfd: c_int,
    entries: std.AutoHashMap(c_int, Entry),

    /// 1回待って、準備できた fd のコールバックを呼ぶ。timeout_ms=-1 で無期限。
    pub fn dispatch(self: *Loop, timeout_ms: c_int) void {
        var evs: [32]c.struct_epoll_event = undefined;
        const n = c.epoll_wait(self.epfd, &evs, evs.len, timeout_ms);
        if (n <= 0) return;
        for (evs[0..@intCast(n)]) |ev| {
            // コールバック内で他の fd が remove されることがあるので毎回引き直す。
            const e = self.entries.get(ev.data.fd) orelse continue;
            e.cb(e.ctx, ev.data.fd, ev.events);
        }
    }
};
```

**設計のポイント**

- 登録するのは「fd・コールバック・文脈ポインタ」の 3 つだけ。96 行で、ライブラリに依存しません。
- **コールバックの中で別の fd が外されることがある**(例: 動画の再生に失敗して、そのパイプを片付ける)ので、配列の `data.ptr` を直接呼ばず、毎回ハッシュ表から引き直します。外された fd のイベントは `orelse continue` で読み飛ばします。
- `epoll_wait` のタイムアウトはメインループでは常に `-1`(無期限)。**何も起きなければ、カーネルの中で眠ったまま**です。

この 1 つの epoll に入っているもの:

| fd | 起きるとき |
|---|---|
| Wayland の接続 | 入力・フレームの合図・configure・River の状態 |
| timerfd(時計・システム・壁紙・OSD・通知の期限・キーリピート・グリフの先読み・WM のアニメーション) | 「次に何かが変わる時刻」だけ |
| `playerctl --follow` / `pactl subscribe` / `cava` の stdout | 曲・音量・スペクトラムが変わったとき |
| D-Bus の接続 | 通知が来たとき |
| inotify | 設定ファイル・`.wasm`・`/dev/input` の変化 |
| Unix ソケット | ame-ctl |
| 子プロセス・ワーカースレッドからの pipe | curl・nmcli・PAM・アイコンのデコードなどが終わったとき |
| libmpv / ffmpeg からの pipe | 動画の新しいコマ |

### ほかの方法との違い {#vs-loop}

| 方法 | 違い |
|---|---|
| **一定間隔のポーリング**(例: 1 秒ごとに電池・音量・曲を調べる) | 何も変わらなくても起き続ける。ame-shell は「変わったときに起こされる」形にしたので、待機時は 10 秒間で CPU 時間 0〜1 tick |
| **GLib のメインループ**(GTK のアプリ) | 機能は多いが、GLib(とその上のライブラリ)を引き込む。ame-shell の必要は fd とタイマーだけ |
| **スレッドを部品ごとに**(バー・通知・メディアがそれぞれ待つ) | 状態の共有にロックが要る。描画は 1 つの GL コンテキストからしかできないので、結局メインスレッドに集める必要がある |
| **libuv / tokio のような汎用ランタイム** | 依存が大きい。ame-shell は非同期の I/O を「pipe の EOF を待つ」だけで済ませている |

## タイマーは「次に変わる時刻」にだけ {#timer}

```zig
/// timerfd の薄いラッパ。CLOCK_MONOTONIC。ポーリングではなく「次に何かが変わる時刻」
/// (時計の分の変わり目、OSD の自動非表示など)にだけ起こすために使う。
pub const Timer = struct {
    fd: c_int,
    /// first_ms 後に1回、interval_ms>0 ならその後周期的に発火。first_ms=0 で停止。
    pub fn arm(self: Timer, first_ms: u64, interval_ms: u64) void { … }
    /// 発火回数を読み捨てる(読まないと epoll がずっと readable を返す)。
    pub fn ack(self: Timer) void { … }
};
```

例:

- **時計**: 今の秒から「次の分の 0 秒」までのミリ秒を計算して 1 回だけ。秒を表示する設定のときだけ毎秒。
- **OSD**: 音量を変えたら「表示から 1.4 秒後」(お知らせなら 2.6 秒後)に 1 回。
- **ライブ壁紙**: 設定の fps ごと(AC 電源で 30、バッテリーで 12)。静止画の壁紙では止める。
- **WM**: 窓が動いている間だけ 8 ms 後に 1 回(River の render sequence を回すため)。止まったら張らない。

`CLOCK_MONOTONIC` を使うのは、時計合わせ(NTP)で時刻が飛んでもタイマーがずれないためです。

## FreeBSD で起動直後に落ちた件(SIGSYS) {#sigsys}

FreeBSD 15.1 の実機で、ame-shell が**起動してすぐ SIGSYS で落ちる**という報告がありました。SIGSYS は「この OS に無いシステムコールを呼んだ」という意味です。原因は `Timer.arm` でした。

- musl の `struct timespec` は Zig の translate-c で不透明型になります。そこで Linux 版では `std.os.linux.timerfd_settime`(Zig の標準ライブラリが**システムコール番号を直接**呼ぶ関数)を使っていました。
- このコードは FreeBSD 向けにもコンパイルされます。番号 286 は Linux の `timerfd_settime` ですが、FreeBSD には存在しません。そのため、ウィンドウマネージャがキーバインドを登録した直後の最初のアニメーションで SIGSYS になっていました。

```zig
pub fn arm(self: Timer, first_ms: u64, interval_ms: u64) void {
    if (@import("builtin").os.tag != .linux) {
        // FreeBSD 14 以降は timerfd が libc にある(std.os.linux の直接のシステムコールは番号が違い SIGSYS で落ちる)
        var spec = std.mem.zeroes(c.struct_itimerspec);
        …
        if (c.timerfd_settime(self.fd, 0, &spec, null) != 0) std.log.warn("timerfd_settime failed (fd={d})", .{self.fd});
        return;
    }
    // musl の struct timespec は translate-c で不透明型になるため、std の定義でシステムコールを直接呼ぶ(Linux 専用)
    const linux = std.os.linux;
    …
}
```

**再発を防ぐ仕組み**: FreeBSD 向けのバイナリを逆アセンブルして、`syscall` 命令と `os.linux.*` の記号が **0 個**であることを毎回確かめています([ビルド](#/tech-build))。コンパイルは通るのに実行すると落ちる、という種類の間違いを機械的に見つけるためです。

## 起動(main.zig) {#main}

```zig
pub fn main() !u8 {
    // 日本語ロケール(xkb の compose / strftime 等のため)
    _ = c.setlocale(c.LC_ALL, "");
    // 子プロセス(ランチャーから起動したアプリ)のゾンビを残さない
    // (musl の SIG_IGN マクロは translate-c できないので std.posix を使う)
    const ign = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, … };
    std.posix.sigaction(std.posix.SIG.CHLD, &ign, null) catch {};
    std.posix.sigaction(std.posix.SIG.PIPE, &ign, null) catch {};
    installFatalSignalHandlers();
    …
}
```

| 処理 | 理由 |
|---|---|
| `setlocale(LC_ALL, "")` | 曜日の日本語表示(strftime)や、xkb の compose(合成キー)がロケールに依存するため |
| `SIGCHLD` を無視 | ランチャーから起動したアプリが終わったときに、ゾンビプロセスを残さないため(カーネルが自動で回収する)。待つ必要がある子(PAM など)は `waitpid` で個別に待つ |
| `SIGPIPE` を無視 | 子プロセスやクライアントが先に閉じたパイプ・ソケットに書いても、ame-shell 全体が落ちないようにするため |
| 致命的なシグナルのハンドラ | 下を参照 |

### 落ちたときに「何で落ちたか」を必ず残す {#fatal}

```zig
fn onFatalSignal(sig: c_int) callconv(.C) void {
    const name: []const u8 = switch (sig) {
        std.posix.SIG.SYS => "SIGSYS (bad system call: a system call this OS does not have)",
        std.posix.SIG.SEGV => "SIGSEGV (invalid memory access)",
        …
    };
    // シグナルハンドラの中なので write(2) だけを使う
    const pre = "ame-shell: crashed with ";
    _ = std.c.write(2, pre, pre.len);
    _ = std.c.write(2, name.ptr, name.len);
    const tip = " -- rebuild with: zig build -Doptimize=ReleaseSafe -Dstrip=false for a backtrace\n";
    _ = std.c.write(2, tip, tip.len);
    // 既定の動作に戻して、同じシグナルを送り直す(コアダンプと終了コードはそのまま)
    …
    _ = std.c.raise(sig);
}
```

- メッセージは **ASCII** です。TTY のコンソールでは日本語が表示できないことがあるからです(SIGSYS の報告は TTY のログでした)。
- シグナルハンドラの中では、async-signal-safe な `write(2)` だけを使います(`printf` や Zig のログはメモリ確保やロックをしうるので使いません)。
- 最後に既定の動作に戻して同じシグナルを送り直すので、終了コードとコアダンプは普通に落ちたときと同じになります。監督しているスクリプト(`ame-river5-init`)が、終了コードからシグナル名をログに出します([セッション](#/tech-session))。

### 自分自身を入れ替える(`ame-ctl restart`) {#restart}

```zig
if (app.restart_requested) {
    // /proc/self/exe は、ビルドで実行ファイルが置き換わると "… (deleted)" になって exec できないので、
    // 起動時の argv[0](シンボリックリンク経由なら新しいビルドを指す)を PATH 検索付きで使う。
    const arg0 = std.os.argv[0];
    const argv = [_:null]?[*:0]const u8{ arg0, null };
    _ = c.execvp(arg0, @ptrCast(&argv));
    …
    return 1; // 監督ループが再起動するよう、異常終了として返す
}
```

`ame-update` はビルドしてから `ame-ctl restart` を送ります。`execvp` でプロセスを入れ替えるので、**PID と Wayland の接続はいったん切れますが、River 0.5 の窓はそのまま**残ります。新しい ame-shell は、River が付けた窓の識別子から元のタグや浮き状態を戻します([ウィンドウマネージャ](#/tech-wm))。

## メインループ(app.zig) {#run}

```zig
pub fn run(self: *App) void {
    const fd = c.wl_display_get_fd(self.display);
    self.loop.add(fd, c.EPOLLIN, self, onWaylandFd) catch {};
    while (self.running) {
        // Wayland のイベントキューを空にしてから待つ(取りこぼし防止の定石)
        while (c.wl_display_prepare_read(self.display) != 0) _ = c.wl_display_dispatch_pending(self.display);
        _ = c.wl_display_flush(self.display);
        self.loop.dispatch(-1);
        // onWaylandFd で読んでいなければ読み取り予約を取り消す
        if (!self.read_done) c.wl_display_cancel_read(self.display);
        self.read_done = false;
        if (c.wl_display_dispatch_pending(self.display) < 0) { … 接続が切れた … }
        …
    }
}
```

`wl_display_prepare_read` → `flush` → 待つ → `read_events` → `dispatch_pending` は、libwayland が推奨している「自前のイベントループに Wayland を組み込む」手順です。

- **prepare_read の前にキューを空にする**: すでに読み込まれて処理待ちのイベントが残っていると、`epoll_wait` で眠ってしまい、そのイベントの処理が次の何かまで遅れます。
- **待つ前に flush**: 送信バッファに残ったリクエスト(フレームの要求など)をコンポジタへ送ってから眠ります。送らずに眠ると、コンポジタは要求を知らないままで、フレームの合図が来ません。
- **Wayland 以外の fd で起きたときは cancel_read**: 予約したままだと、ほかのスレッド(EGL の内部など)が読めなくなります。

## アイドル時間の先読み {#warm}

```zig
/// 起動後のアイドル時間にグリフを先読みする(6ms ずつ、12ms おき。数秒で終わる)。
fn onWarmTimer(ctx: *anyopaque, _: c_int, _: u32) void {
    …
    self.warmer.step(self.fonts, 6000);
    …
    if (self.warmer.pending()) {
        self.warm_timer.arm(12, 0);
    } else if (!self.dashboard.loaded) {
        // 最後に WASM ウィジェットを読み、1回実行しておく(wasm3 は関数を初回呼び出し時にコンパイルする)
        self.dashboard.prewarm();
    }
}
```

起動 400 ms 後から、よく使う文字(ASCII・かな・UI の漢字・Nerd Font のアイコン・インストールされているアプリ名)のグリフを、**1 回 6 ms まで、12 ms おき**に作っておきます。1 回の作業を 1 フレーム(16.6 ms)より十分短くしているので、先読み中に操作しても引っかかりません。

**結果**: 初めてランチャーを開いたときに 1 フレームが 525 ms かかっていたのが、**開くときに作るグリフ 0 字**になりました([文字](#/tech-text))。
