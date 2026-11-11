# メモリ

<p class="file">対象: src/platform/malloc.zig / src/desktop/memguard.zig / src/desktop/video.zig(sync)/ scripts/zram-setup.sh</p>

ame-shell は描画・動画・文字・GPU のドライバを 1 つのプロセスに入れているので、メモリの使い方がそのまま機械全体の軽さに響きます。このページは、2026 年 11 月に「メモリが高止まりする」「急に固まる」を調べて直したことの記録です。

:::easy このページを読む前に
プログラムは使うメモリを OS から借ります(`malloc`)。使い終わったら返します(`free`)。ところが「返したつもり」でも、間に入っている仕組み(メモリアロケータ)が手元に取っておいて、OS には返さないことがあります。すると、一時的にたくさん使っただけなのに、その量が使ったままに見えます。これが「高止まり」です。

もう 1 つ、Linux はメモリが本当に尽きると、プロセスを止める前に「ディスクから読み直す」のを延々と繰り返して、画面ごと固まることがあります。スワップ(溢れた分の置き場)が無い機械ほど起きやすいです。
:::

## 返したメモリが返らない: libc の mimalloc {#mimalloc}

Chimera Linux の libc は musl ですが、メモリの割り当ては [[mimalloc]] に置き換えてあります。調べると、**解放したメモリを OS に返していませんでした**。

```text
590 MB を 300 KB ずつ確保 → 全部 free
Pss_Anon(私有メモリ): 590 MB のまま / LazyFree: 0
```

libc は `mi_collect` も `malloc_trim` も出しておらず、環境変数の設定も読みません。外からは調整できません。そのため、シェーダのコンパイル(起動時)、画像や動画の復号のような**一時的な山がそのまま常駐**し、私有メモリが 150〜280 MB になっていました。自作のトレーサ(`LD_PRELOAD` で malloc 一式を差し替え、呼び出し元ごとに「今生きているバイト数」を数える)で測ると、実際に生きている確保は約 42 MB しかありませんでした。

### malloc 一式を差し替える {#replace}

実行ファイルが `malloc` を定義すると、ELF の動的リンクの決まりで、読み込んだ共有ライブラリ(Mesa・LLVM・mpv・FreeType)もそちらを使います。`src/platform/malloc.zig` はこれを使い:

- **16 KB 以上**は `mmap` で直に取り、`free` で `munmap` して即座に返します(glibc の mmap しきい値と同じ考え方)。同じ大きさを毎フレーム取り直す動画のコマのために、解放したマッピングを 8 個・16 MB まで 3 秒だけ取っておきます。大きくするときは `mremap` で中身を写さずに伸ばします。
- **16 KB 未満**は libc に任せます(速さが要り、山も小さいので)。
- 利用者のポインタの直前 16 バイトに見出し `{tag, base}` を置いて、どちらで取ったかを見分けます。大きいブロックの中身は **64 バイト境界**にそろえます(16 バイトずれだと動画の転送が遅い道に落ち、CPU が 1.6 倍になりました)。
- musl は malloc を差し替えると自分の `posix_memalign` / `aligned_alloc` を断るので、それらも実装します。
- `fork` の瞬間に別のスレッドがキャッシュのロックを持っていると、`exec` せずに働く子(ロック画面の PAM)が永久に待つので、`pthread_atfork` で fork の間だけロックを持ちます。

| しきい値 | 動画壁紙のときの私有メモリ | CPU |
|---|---|---|
| 差し替えなし | 210 MB | 基準 |
| 64 KB | 148 MB | 同じ |
| 32 KB | 135 MB | 同じ |
| **16 KB(採用)** | **115 MB** | 同じ |
| 8 KB | 107 MB | 同じ(マッピングの数が増えすぎるので見送り) |

## 動画壁紙の同期オブジェクトが溜まる {#fence}

それでも動画壁紙のとき、私有メモリが **1 分に約 1.3 MB** ずつ増え続けていました(何時間かで数百 MB)。トレーサで「生きている確保」を 40 秒と 160 秒の 2 回取り、増えた呼び出し元だけを並べると、どれも `mpv_render_context_render` の中から Mesa の同じ場所で、1 コマにつき 3 個ずつ増えていました。libmpv の呼び出し元を逆アセンブルすると、引数が `0x9117`(`GL_SYNC_GPU_COMMANDS_COMPLETE`)、つまり **`glFenceSync`** でした。

libmpv 0.41 の描画 API は、1 コマごとに [[gl-sync|同期オブジェクト]]を作って消していませんでした。mpv は ame-shell が渡す `get_proc_address` で GL の関数を手に入れるので、ame-shell の側で包みます:

```zig
// src/desktop/video.zig(要約)
if (eql(name, "glFenceSync")) return &sync.fence;        // 作るたびに、8 個前のものを消す
if (eql(name, "glDeleteSync")) return &sync.delete;      // 消し済みなら何もしない
if (eql(name, "glClientWaitSync")) return &sync.clientWait; // 消し済みなら「もう終わっている」
```

`glFenceSync` を渡さないだけにすると、mpv は「OpenGL を初期化できない」として動画を諦めてしまうので、包んで数を抑えています。直したあとは、5 分見ても私有メモリは約 117 MB のまま増えなくなりました。

## メモリが尽きる前に: PSI の見張り {#guard}

スワップの無い機械でメモリが尽きると、OOM キラーが動く前にページの追い出しと読み直しを繰り返し、River も ame-shell も D 状態(ディスク待ち)のまま何分も止まりました。`src/desktop/memguard.zig` は、カーネルのメモリ圧力([[psi|PSI]])の知らせを待ちます(定期的には調べません):

```zig
const fd = open("/proc/pressure/memory", O_RDWR | O_NONBLOCK);
write(fd, "some 300000 2000000");      // 2 秒のうち 0.3 秒以上メモリ待ちなら知らせて
loop.add(fd, EPOLLPRI, …);             // 一般ユーザーは窓が 2 秒の倍数でないといけない
```

知らせが来たら `MemAvailable` を見て、**10% 未満**で通知(いちばん使っているアプリと量)、**3% 未満**で、使っているメモリ(常駐 + スワップ)が最大の自分のプロセスを止めます。River・Xwayland・ame-* などは選びません。

最初はカーネルと同じ `oom_score` で選んでいましたが、ブラウザは小さなタブのプロセスに高い `oom_score_adj` を付けるので、数 MB のプロセスばかり止めて、実際に食っていた**ブラウザの動画の復号プロセス(5.9 GB)**が最後まで残りました。今は実際の量で選びます。`shell { memory-guard off }` で通知だけにできます。

## スワップは zram で {#zram}

根本的には、溢れた分の逃げ場があれば固まりません。`scripts/zram-setup.sh` は、RAM の中に圧縮したスワップ([[zram]])を作ります(Chimera の dinit の `zram-device@zram0`、zstd、RAM の半分)。ディスクに書かないので速く、溢れた分を 1/3 ほどに縮められます。

```sh
doas sh scripts/zram-setup.sh            # 有効にする
doas sh scripts/zram-setup.sh --remove   # やめる
```

## 研究者向けの補足 {#research}

:::research 割り当ての差し替えと、外部ライブラリのリソースの漏れ
ELF の記号の解決は実行ファイル → 読み込んだ順の共有ライブラリなので、実行ファイルで `malloc` 系を定義すれば、プロセス全体の割り当てを差し替えられます(`LD_PRELOAD` と同じ仕組みを、ビルドに組み込んだもの)。ただし libc の内部(`__libc_malloc` で確保したもの)と混ざらないよう、見出しの印(タグ)で持ち主を見分け、印の無いものは libc の `free` に返しています。

外部ライブラリが GPU の資源を漏らす場合、その資源はプロセスの malloc にも出にくく(ドライバのオブジェクトやカーネルの同期オブジェクト)、RSS では見えないことがあります。関数表(`get_proc_address`)を差し出す側に立てるなら、そこで包んで数を抑えるのが、ライブラリを直さずにできる最小の対処です。
:::

## 関連する用語 {#terms}

- [[mimalloc]]
- [[psi]]
- [[zram]]
- [[gl-sync]]
- [[libmpv]]
- [[musl]]
- [[fork-exec]]
