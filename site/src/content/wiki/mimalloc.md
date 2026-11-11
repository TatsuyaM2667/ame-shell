# mimalloc

::infobox mimalloc
作者 | Microsoft Research(Daan Leijen ほか)
種類 | 汎用のメモリアロケータ(malloc の実装)
特徴 | スレッドごとのヒープ・ページ単位の空きリスト
Chimera Linux | libc(musl)の malloc として組み込み
ame-shell | 大きい確保は自前(src/platform/malloc.zig)に回す

**mimalloc** は、Microsoft Research が作った汎用のメモリアロケータです。`malloc` / `free` の速さとメモリの断片化の少なさで知られ、Chimera Linux は [[musl]] の標準の割り当て(mallocng)の代わりに、これを libc に組み込んでいます。

## 仕組み {#how}

- **スレッドごとのヒープ**: 各スレッドが自分の「ページ」(同じ大きさのブロックを並べた領域)を持ち、ロックなしで割り当てます。
- **セグメント**: ページは数 MB 単位のセグメントにまとめて OS から借ります。
- **返却(purge)**: 空いたページは、しばらく使われなければ `madvise` などで OS に返す設計です。返すかどうか・いつ返すかは設定(`purge_delay` など)で決まります。

## ame-shell での使われ方 {#ame}

ame-shell の動く Chimera の libc では、**解放したメモリが OS に返りませんでした**(590 MB を確保して全部 free しても、私有メモリは 590 MB のまま)。libc は `mi_collect` などの関数を出しておらず、環境変数の設定も読まないため、外から調整できません。そこで ame-shell は、16 KB 以上の確保を自前の割り当て(`mmap` / `munmap`)に回し、小さいものだけを mimalloc に任せています。詳しくは[メモリ](#/tech-memory)。

## 関連項目 {#see}

- [[musl]]
- [[zram]]
