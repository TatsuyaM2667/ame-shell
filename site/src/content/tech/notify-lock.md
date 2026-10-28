# 通知とロック画面

<p class="file">対象: src/notify.zig(589 行)/ src/lock.zig(408 行)</p>

:::easy このページを読む前に
アプリが「お知らせ」を出したいとき、決まった宛先([[dbus|D-Bus]] の `org.freedesktop.Notifications`)にメッセージを送ります。ame-shell はその宛先になって、お知らせをガラスのカードとして出します。

画面のロックでは「パスワードが正しいか」を OS の仕組み([[pam|PAM]])に確かめてもらいます。一番大事なのは、**ロックしたのに二度と解除できない**ことを防ぐことです。そのため、ロックする前に「ちゃんと確かめられる状態か」をチェックしています([[session-lock]])。
:::

## 通知サーバを内蔵する {#notify}

```zig
// src/notify.zig
// 通知: org.freedesktop.Notifications を内蔵実装し、右上にガラスのカードを積む。
//
// D-Bus は libdbus を private 接続で使い、その fd を epoll に載せる(スレッド不要)。
// すでに別の通知デーモン(swaync, mako 等)が名前を持っている場合は奪わず、
// D-Bus 側だけ無効にする(ame-ctl notify によるローカル通知は引き続き表示できる)。
const conn = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, errp) orelse { … };
const r = c.dbus_bus_request_name(conn, "org.freedesktop.Notifications", c.DBUS_NAME_FLAG_DO_NOT_QUEUE, errp);
…
if (c.dbus_connection_get_unix_fd(conn, &fd) != 0 and fd >= 0) {
    self.app.loop.add(fd, c.EPOLLIN, self, onDbus) catch {};
}
```

| 判断 | 理由 |
|---|---|
| **通知サーバを自分で持つ** | 通知のカードも ame-shell の他の部品と同じガラス・同じばねで描ける。mako や dunst を別に設定して見た目を合わせる必要がない |
| **libdbus の private 接続** | 共有の接続(`dbus_bus_get`)は、同じプロセスの他のライブラリ(EGL のドライバなど)と混ざる可能性がある。自分専用の接続にすれば、メッセージの取り合いが起きない |
| **接続の fd を epoll に入れる** | D-Bus 用のスレッドが要らない。通知が来たときだけ起きる |
| **`DO_NOT_QUEUE` で名前を取る** | すでに別の通知デーモンが動いていたら、名前を奪わず、待ち行列にも並ばない。ほかの環境と共存できる |
| **GDBus・sd-bus を使わない** | GDBus は GLib のメインループを前提にしている。sd-bus は systemd の一部で、Chimera や FreeBSD には無い |

```zig
fn onDbus(ctx: *anyopaque, _: c_int, events: u32) void {
    …
    _ = c.dbus_connection_read_write(conn, 0);           // 0 = 待たない
    while (c.dbus_connection_pop_message(conn)) |msg| {
        defer c.dbus_message_unref(msg);
        self.handleMessage(msg);
    }
    c.dbus_connection_flush(conn);
}
```

epoll で起きたら、たまっているメッセージを**待たずに**全部取り出して処理します。対応しているメソッド: `Notify`・`CloseNotification`・`GetCapabilities`(`body`・`actions`・`persistence`)・`GetServerInformation`・introspection。シグナル `NotificationClosed`・`ActionInvoked` を送ります。

**translate-c の問題**: libdbus の `DBusError` はビットフィールドを含むので、Zig の translate-c では中身の見えない型になります。そこで、同じ並びの `extern struct` を自分で定義しています。

### カードの動き {#cards}

- 右上にガラスのカードとして**右から滑り込みます**。
- 上のカードが消えると、下のカードが**ばねで詰めます**。
- 消えるときは右へ流れながら薄くなります。
- `urgency = 2`(緊急)の通知は期限で消えず、枠の縁が**赤く光ります**([エラーの光](#/tech-glass))。
- アクションの中に `default` があれば、カードのクリックで `ActionInvoked` を送ります。
- 通知を停止(Do Not Disturb)している間は、カードを出さずに通知センターの履歴にだけ残します。ただし**緊急の通知だけは**停止中でも出します。

## ロック画面: 閉じ込めないことを最優先に {#lock}

```zig
// src/lock.zig
// ロック画面: ext-session-lock-v1 + PAM。
//
// 閉じ込め防止のため、ロックする「前」に認証が成立し得る構成かを確認する:
//   1. コンポジタが ext_session_lock_manager_v1 を持つ
//   2. libpam.so を dlopen でき、必要な関数がある
//   3. PAM サービス "ame-shell"(無ければ同じ目的の "swaylock")の設定ファイルが存在する
//   4. pam_unix の補助プログラム unix_chkpwd が setuid で存在する(一般ユーザーが照合できる)
// どれかが欠けていればロックせず、OSD と通知で理由を出す。
```

画面ロックで一番怖いのは「**ロックしたのに、正しいパスワードでも解除できない**」状態です。ext-session-lock では、ロック中に ame-shell が落ちてもコンポジタは画面を見せません(それがこのプロトコルの安全性です)。つまり、認証が絶対に通らない構成でロックすると、再起動するしかなくなります。

そこで、ロックする**前**に 4 つを確かめ、どれかが欠けていればロックせず、理由を表示します。

| 確認 | 欠けているときに起きること |
|---|---|
| コンポジタが ext-session-lock に対応 | そもそもロックできない |
| libpam を読み込めて、必要な 4 つの関数がある | 認証を呼べない |
| PAM のサービス設定(`ame-shell`、無ければ `swaylock`)がある | PAM が設定を見つけられず、必ず失敗する |
| `unix_chkpwd` が setuid で存在する | 一般ユーザーのプロセスは `/etc/shadow` を読めないので、pam_unix はこの補助プログラムに照合を頼む。無いと必ず失敗する |

### PAM は dlopen、認証は子プロセスで {#pam}

```zig
fn startAuth(self: *Lock) void {
    …
    const pid = c.fork();
    if (pid == 0) {
        _ = c.close(fds[0]);
        const ok = self.pamCheck();                 // 子プロセスで PAM を呼ぶ
        const b: u8 = if (ok) 1 else 0;
        _ = c.write(fds[1], &b, 1);                 // 結果を 1 バイトだけ返す
        c._exit(0);
    }
    _ = c.close(fds[1]);
    // 親は自分のコピーを消す(子は自分のメモリで使い終わる)
    @memset(&self.pw, 0);
    self.auth_fd = fds[0];
    self.busy = true;
    self.setMsg("確認しています…");
    self.app.loop.add(fds[0], c.EPOLLIN | c.EPOLLHUP, self, onAuthDone) catch {};
}
```

| 判断 | 理由 |
|---|---|
| **PAM を dlopen** | ヘッダが要らない。libpam が無い環境でも ame-shell は起動できる(ロックだけが使えない) |
| **認証は fork した子プロセスで** | PAM はパスワードを間違えると数秒待つ(総当たり対策)。メインスレッドでやると、その間 UI が止まる。子プロセスなら、待っている間も「確認しています…」の表示や揺れのアニメーションが動く |
| **PAM のモジュールの事故を隔離** | PAM のモジュールが落ちても、落ちるのは子プロセスだけ。ロック画面(親)は残る |
| **親のパスワードはすぐ消す** | fork した時点で子が自分のコピーを持つので、親のメモリの文字列は `@memset` で 0 にする |
| **結果は 1 バイトの pipe** | 成功なら 1、失敗なら 0。子が異常終了したら EOF(失敗扱い) |

`pam_acct_mgmt` も呼ぶので、パスワードは合っていてもアカウントが期限切れ・無効の場合は解除しません。

**FreeBSD では swaylock に任せます**。FreeBSD の pam_unix は、パスワードの照合に root の権限を必要とし(Linux の `unix_chkpwd` に当たる補助プログラムが無い)、一般ユーザーのプロセスからは照合できません。FreeBSD の swaylock のパッケージは setuid で入るので、照合できます。swaylock が無ければロックせず、`pkg install swaylock` を案内します。

### ロック画面の動き {#lock-anim}

```zig
shake: Spring = Spring.init(0, 0.35, 0.25), // 失敗時に横に震える(減衰の弱いバネ)
dots: [32]Spring = [_]Spring{Spring.init(0, 0.25, 0.55)} ** 32,
```

- パスワードを間違えると、入力欄が**減衰の弱いばね**(0.25)で左右に震えます。速度を与えるだけで、何回か揺れて自然に止まります。
- 入力した文字の点は、1 つずつ弾んで現れます(32 個のばね)。
- 自動の試験で間違ったパスワードを試すことは**しません**。pam_faillock などで、本物のアカウントがロックされる危険があるためです。

## 研究者向けの補足 {#research}

:::research 脅威モデルと、安全側への倒れ方
ext-session-lock の安全性は「ロッカーが落ちたら画面を隠したままにする」(fail-closed)ことにあります。これは機密性を守る一方で、**可用性**(正当な利用者が解除できること)を損なう危険を持ちます。ame-shell の事前確認(PAM の設定・libpam の関数・setuid の照合の補助プログラム)は、「認証の経路が少なくとも存在する」ことを、ロックの前に検証する可用性の保護です。

認証を子プロセスで行うのは、(1) PAM の失敗時の遅延(総当たりへの対策)による UI の停止を防ぐ、(2) PAM のモジュール(任意のコードを読み込む)の故障を隔離する、(3) パスワードの平文が親のメモリに残る時間を最小にする(fork の直後に親のコピーを消す)、の 3 点のためです。自動の試験で誤ったパスワードを試さないのは、pam_faillock などの**アカウントのロック**という副作用が、試験の環境の外(本物のアカウント)に及ぶためです。

参考: V. Samar, R. Schemers, "Unified Login with Pluggable Authentication Modules (PAM)", OSF RFC 86.0, 1995。
:::

## 関連する用語 {#terms}

- [[dbus]]
- [[pam]]
- [[setuid]]
- [[session-lock]]
- [[fork-exec]]
