# zram

::infobox zram
OS | Linux(3.14 以降で正式)
種類 | 圧縮した RAM のブロックデバイス
主な使い道 | スワップ
圧縮 | zstd・lz4・lzo など
ame-shell | scripts/zram-setup.sh

**zram** は、RAM の一部を圧縮したブロックデバイス(`/dev/zram0` など)として使う Linux の仕組みです。多くはスワップの置き場にします。

## 概要 {#overview}

メモリが足りなくなると、Linux は使われていないページをスワップに追い出します。スワップがディスクにあると遅く、スワップが無いと、追い出せないページの代わりにプログラムの本体(ファイルから読み直せるページ)を捨てては読み直す状態になり、画面ごと固まることがあります。

zram は追い出したページを**圧縮して RAM の中に**置きます。ディスクに書かないので速く、テキストやコードのようなデータは 1/3 ほどに縮みます。RAM を食う代わりに、溢れた分の逃げ場ができます。

## 使い方(Chimera Linux) {#chimera}

```ini
; /etc/dinit-zram.conf
[zram0]
size = 6830M
algorithm = zstd
format = mkswap -U clear %0
```

`dinitctl enable zram-device@zram0` で作り、`/etc/fstab` に `/dev/zram0 none swap defaults,pri=100 0 0` を書けば起動のたびに使われます。ame-shell の `scripts/zram-setup.sh` はこれを書きます。

## 関連項目 {#see}

- [[psi]]
- [[mimalloc]]
