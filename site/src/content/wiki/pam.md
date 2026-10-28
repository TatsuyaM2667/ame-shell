# PAM

::infobox PAM
正式名 | Pluggable Authentication Modules
提案 | Sun Microsystems(Samar, Schemers, 1995)
実装 | Linux-PAM、OpenPAM(FreeBSD)
設定 | /etc/pam.d/<サービス名>
ame-shell | ロック画面のパスワードの確認

**PAM** は、「ユーザーが本人かどうか」を確かめる方法を、アプリから切り離して、**設定で差し替えられる**ようにした仕組みです。

## 概要 {#overview}

パスワードで確認するか、指紋で確認するか、2 段階の認証にするか。それを各アプリが作り込むのではなく、PAM の設定ファイルで決めます。アプリは「このユーザーを確認して」と PAM に頼み、PAM が設定に従ってモジュール(`pam_unix` など)を順に呼びます。

## 仕組み {#how}

1. `pam_start(サービス名, ユーザー名, 会話の関数, &h)`
2. `pam_authenticate(h)` — 確認。モジュールは「会話の関数」を通してパスワードを尋ねる。
3. `pam_acct_mgmt(h)` — アカウントが有効か(期限切れなど)。
4. `pam_end(h)`

## ame-shell での使われ方 {#ame}

- libpam を **dlopen** で読み込みます。ヘッダが要らず、libpam が無い環境でも ame-shell は起動できます。
- 認証は **fork した子プロセス**で行い、結果をパイプで受けます。失敗したときの PAM の待ち時間(総当たり対策)の間も、画面が止まりません。
- ロックする前に、PAM のサービスの設定と、`unix_chkpwd` が [[setuid]] で存在することを確かめます。認証が通らない状態でロックすると、二度と解除できないからです([ロック](#/tech-notify-lock))。
- サービスの設定ファイルの置き場所は、libpam の版によって `/etc/pam.d` と `/usr/lib/pam.d` を使い分けます([セッション](#/tech-session))。

## 関連項目 {#see}

- [[setuid]] / [[session-lock]] / [[fork-exec]]

## 参考文献 {#refs}

- V. Samar, R. Schemers, "Unified Login with Pluggable Authentication Modules (PAM)", Open Software Foundation RFC 86.0, 1995.
- [Linux-PAM の文書](https://github.com/linux-pam/linux-pam)
