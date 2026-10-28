# translate-c

::infobox translate-c
種類 | Zig の機能(C のヘッダを Zig の宣言に変換)
使い方 | @cImport({ @cInclude("wayland-client.h"); })
限界 | 一部のマクロ・ビットフィールド・不完全な型は扱えない
ame-shell | すべての C のライブラリの取り込み

**translate-c** は、C のヘッダファイルを読んで、Zig の宣言(型・関数・定数)に変換する、[[zig|Zig]] の機能です。`@cImport` の中身はこれで処理されます。

## ame-shell での使われ方と、つまずき {#ame}

ame-shell は、全部の C のライブラリを `src/c.zig` の 1 か所で取り込んでいます(2 か所で取り込むと、同じ C の型が Zig では別の型になるため)。

translate-c が扱えなかったもの:

| C の書き方 | 結果 | ame-shell の回避策 |
|---|---|---|
| [[musl]] の `struct timespec` | 中身の見えない型(opaque) | Linux では Zig 標準の型でシステムコールを呼ぶ(FreeBSD では libc の関数) |
| libdbus の `DBusError`(ビットフィールドを含む) | 中身の見えない型 | 同じ並びの `extern struct` を自分で定義 |
| musl の `SIG_IGN`(関数ポインタへのキャストのマクロ) | 変換できない | `std.posix.SIG.IGN` を使う |
| musl の `struct statvfs` | 中身の見えない型 | 64 bit の整数の並びとして読み、OS ごとの位置を表にする |

最初の回避策が、FreeBSD での [[sigsys|SIGSYS]] の原因になりました([言語とツールチェイン](#/tech-lang))。

## 関連項目 {#see}

- [[zig]] / [[musl]] / [[sigsys]]
