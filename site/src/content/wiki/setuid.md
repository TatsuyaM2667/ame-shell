# setuid

::infobox setuid
種類 | ファイルの権限のビット
意味 | 実行した人ではなく、ファイルの持ち主(例: root)の権限で動く
例 | passwd, sudo, unix_chkpwd, swaylock(FreeBSD)
ame-shell | ロックの前の確認で、unix_chkpwd の setuid を調べる

**setuid** は、プログラムを、**実行した人ではなくファイルの持ち主の権限で**動かすための、ファイルの権限のビットです。

## 概要 {#overview}

パスワードのハッシュは `/etc/shadow` にあり、root しか読めません。でも、画面のロックを解除するには、一般ユーザーのプロセスが自分のパスワードを確かめる必要があります。そこで、「パスワードを照合するだけ」の小さなプログラム(`unix_chkpwd`)を root の持ち物にし、setuid を付けておきます。一般ユーザーが実行しても、そのプログラムは root として `/etc/shadow` を読めます。

## ame-shell での使われ方 {#ame}

- Linux: ロックする前に、`unix_chkpwd` が setuid で存在するかを `fstatat` で調べます。無ければロックしません([ロック](#/tech-notify-lock))。
- FreeBSD: FreeBSD の pam_unix には `unix_chkpwd` に当たる仕組みが無く、root でないとパスワードを照合できません。そのため、setuid で入る swaylock にロックを任せています。

## 関連項目 {#see}

- [[pam]] / [[session-lock]]
