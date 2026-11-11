# ばね(spring_step)

<div class="lhead" data-lesson="spring">
<p><b>時間</b> 約 45 分(6 ステップ。1 回に 1 ステップでよい)</p>
<p><b>できるようになること</b> ame-shell のばねを、白紙から書いて試験を通せる</p>
<p><b>前提</b> 足し算・かけ算。<code>zig test</code> を打てる(L0)</p>
</div>

**3 行で**: ame-shell の動きは、全部 1 つのばねの関数で作っています。
ばねは「目標からのずれ」に引っぱられ、「速さ」にブレーキをかけられます。
それを 1 ミリ秒ずつ足し算で進めるだけです。

<div class="steps" data-lesson="spring">
<label class="chk"><input type="checkbox" data-k="spring:1">ステップ 1: 予測する(5 分)</label>
<label class="chk"><input type="checkbox" data-k="spring:2">ステップ 2: 触って確かめる(5 分)</label>
<label class="chk"><input type="checkbox" data-k="spring:3">ステップ 3: しくみを知る(10 分)</label>
<label class="chk"><input type="checkbox" data-k="spring:4">ステップ 4: 書いてみる(15 分)</label>
<label class="chk"><input type="checkbox" data-k="spring:5">ステップ 5: 障害ラボ(10 分)</label>
<label class="chk"><input type="checkbox" data-k="spring:6">ステップ 6: 確認テスト(5 分)</label>
</div>

## ステップ 1: 予測する {#predict}

ばねを 0 から 100 へ動かします。{{response|応答。どれくらい速く動くか(秒)。小さいほど速い}} はどちらも 0.3 秒。
違うのは {{damping|減衰比。ブレーキの強さ。1 だと行き過ぎない、1 より小さいと弾む}} だけです。

| | response | damping |
|---|---|---|
| A | 0.3 | 0.3 |
| B | 0.3 | 1.0 |

**答えを見る前に**、下の欄に書いてください。

1. A と B、100 を**越える**のはどちら? 越えるなら、いくつくらいまで?
2. A と B、先に**止まる**のはどちら?

<textarea class="memo" data-k="spring:predict" rows="3" placeholder="例: A は 120 くらいまで行く。B が先に止まる"></textarea>

<details class="answer"><summary>答え(書いてから開く)</summary>

| | 最大 | 95 に届く | 止まる |
|---|---|---|---|
| A(0.3) | **136.8**(37% 行き過ぎる) | 0.100 秒 | 1.567 秒 |
| B(1.0) | **100.0**(行き過ぎない) | 0.233 秒 | 0.750 秒 |

A は先に 95 に届きますが、行き過ぎて戻るので、止まるのは B の 2 倍遅いです。
数値は `zig test learn/spring/measure_test.zig` で測り直せます(本物の Odin でも同じ値: `sh learn/check-real.sh`)。

</details>

<label class="chk"><input type="checkbox" data-k="spring:1">予測を書いて、答えと比べた</label>

## ステップ 2: 触って確かめる {#demo}

下のデモは、ame-shell の本物のコード(`anim/anim.odin` を WebAssembly にしたもの)を動かしています。
**押すまで動きません**。▶ で再生、⏭ で 1 コマずつ。

::demo spring-lab

やってみること(1 つずつ):

1. 「A」を押して ▶。次に「B」を押して ▶。前の線は灰色で残ります。
2. 再生中に「目標を -50 へ」を押す。線が**折れずに曲がる**ことを見る(速さが引き継がれる)。
3. 再生中に「2 秒止める」を押す。ばねが**飛ばない**ことを見る。

<label class="chk"><input type="checkbox" data-k="spring:2">3 つとも試した</label>

## ステップ 3: しくみを知る {#how}

### いつも成り立つこと {#invariants}

式より先に、**ばねなら必ずこうなる**という約束を 3 つ覚えます。

1. 時間が経てば目標に着いて止まる
2. 目標を途中で変えても、位置は跳ばず、速さは 0 に戻らない
3. 一時停止のあと(大きな時間)でも、画面の外へ飛ばない

ステップ 4 の試験は、この 3 つ(と 2 つの細かい約束)を確かめます。

### 直感 {#intuition}

ゴムひもで目標につながれた玉を想像します。

- 目標から**遠いほど強く**引っぱられる(ばね)
- **速いほど強く**ブレーキがかかる(ダンパー = 空気や水の抵抗)

ブレーキが弱いと行き過ぎて戻る(A)。ちょうどよいと行き過ぎずに止まる(B)。

### 1 ミリ秒ずつ足す {#euler}

玉の状態は 2 つの数だけです: **位置 x** と **速さ v**。
1 ミリ秒(h = 0.001 秒)ごとに、次の 3 行を繰り返します。

```text
a = (引っぱる力) - (ブレーキ)      ← 加速度: 速さがどれだけ変わるか
v = v + a × h                    ← 先に速さを更新
x = x + v × h                    ← 新しい速さで位置を更新
```

速さを先に、位置を後に更新するやり方を {{半陰的オイラー法|semi-implicit Euler。順番を「速さ → 位置」にするだけで、ずっと壊れにくくなる}} といいます。

### 式 {#formula}

記号は 1 つずつです。

| 記号 | 意味 | B(response 0.3、damping 1.0)のとき |
|---|---|---|
| ω(オメガ) | 1 秒あたりの揺れの速さ。ω = 2π ÷ response | 20.94 |
| k | ばねの強さ。k = ω × ω | 438.6 |
| c | ブレーキの強さ。c = 2 × damping × ω | 41.89 |
| a | 加速度。a = −k ×(x − 目標)− c × v | — |

### 手で 1 回やってみる {#hand}

B で x = 0、v = 0、目標 = 100 から 1 ミリ秒進めます。

```text
a = −438.6 × (0 − 100) − 41.89 × 0 = 43,865
v = 0 + 43,865 × 0.001            = 43.86
x = 0 + 43.86 × 0.001             = 0.0439
```

1 ミリ秒で 0.04 しか進みません。これを 1 コマ(1/60 秒)で約 17 回繰り返します。

### コードの場所 {#code}

::code anim/anim.odin:32 spring_step | 1 つのばねを dt 秒進める(ame-shell の全部の動きの元)
::code anim/anim.odin:39 omega | ω・k・c を求める(39〜41 行)
::code anim/anim.odin:45 remaining | dt を 0.1 秒までに抑える
::code anim/anim.odin:48 MAX_STEP | 1 ミリ秒ずつに刻む
::code anim/anim.odin:49 a | 加速度 → 速さ → 位置(49〜51 行)
::code anim/anim.odin:59 EPS_X | 十分近くて遅ければ、目標ちょうどで止める

### なぜ 1 ミリ秒に刻むのか {#why-substep}

刻みが大きいと、足し算が行き過ぎて止まらなくなります(数が無限大へ飛ぶ)。
1 回で進めてよい時間の上限を測りました。

| response | damping | 1 回で進めてよい最大 |
|---|---|---|
| 0.3 | 0.3 | 0.071 秒 |
| 0.3 | 1.0 | 0.039 秒 |
| 0.08 | 1.0 | **0.0105 秒**(1 コマ 0.0167 秒より短い) |

ame-shell のスクショの範囲選びは response 0.07 です(`src/desktop/shot.zig:78`)。1 コマ分を 1 回で進めると壊れます。だから 1 ミリ秒に刻みます。

<label class="chk"><input type="checkbox" data-k="spring:3">手で 1 回の計算をたどった</label>

## ステップ 4: 書いてみる {#exercise}

補助を 3 段階で減らします。1 つ通ったら次へ。

| 段階 | ファイル | やること |
|---|---|---|
| 1 穴埋め | `learn/spring/ex1_fill.zig` | `hole1`〜`hole4` を式に書き換える |
| 2 一部空白 | `learn/spring/ex2_partial.zig` | コメントの順に中身を書く |
| 3 白紙 | `learn/spring/ex3_blank.zig` | 何も見ずに書く |

確かめるコマンド(ame-shell のフォルダで):

```sh
zig test learn/spring/ex1_fill.zig
```

通ると `✓ ばねの不変条件 5 つ、すべて成り立ちました`。
通らないと `✗ 〜` が、どの約束が壊れたかを教えます。

<details class="hint"><summary>ヒント 1: 方向だけ</summary>

ステップ 3 の「式」の表を、そのまま Zig にします。`hole1` は ω だけから、`hole2` は damping と ω から作ります。

</details>

<details class="hint"><summary>ヒント 2: 関連する場所</summary>

本物は `anim/anim.odin` の 39〜51 行です。Odin の `:=` は Zig の `const … =` と同じ意味です。

</details>

<details class="hint"><summary>ヒント 3: 擬似コード</summary>

```text
k = ω × ω
c = 2 × ζ × ω
a = −k × (位置 − 目標) − c × 速さ
速さ += a × h
```

</details>

<details class="hint"><summary>ヒント 4: 答え</summary>

```zig
const k = omega * omega;
const c = 2 * s.damping * omega;
const a = -k * (s.x - s.target) - c * s.v;
s.v += a * h;
```

全体は `learn/spring/answer.zig`(白紙に挑むまで開かない)。

</details>

<label class="chk"><input type="checkbox" data-k="spring:4a">段階 1(穴埋め)が通った</label>
<label class="chk"><input type="checkbox" data-k="spring:4b">段階 2(一部空白)が通った</label>
<label class="chk"><input type="checkbox" data-k="spring:4">段階 3(白紙)が通った</label>

## ステップ 5: 障害ラボ {#lab}

**報告**: 「ノート PC を閉じて開いたら、開きかけの窓が画面の外へ消えた」

診断の型は 5 つ: **観察 → 仮説 → 切り分け → 修正 → 再発防止**。

1. **観察**: `zig test learn/spring/lab_dt.zig` を打ち、`一時停止のあと x = …` を読む(目標は 100)。
2. **仮説**: 60fps では正常。何が違うときに壊れる? 1 行で書く。
3. **切り分け**: `lab_dt.zig` の `step` と、本物(`anim/anim.odin` の 44〜53 行)を見比べる。
4. **修正**: `lab_dt.zig` の `step` を直す。
5. **再発防止**: 同じコマンドで 3 つの試験が全部通れば完了。

<textarea class="memo" data-k="spring:lab" rows="2" placeholder="仮説を 1 行で: 〜のとき、〜だから飛ぶ"></textarea>

<details class="hint"><summary>ヒント 1: 方向だけ</summary>

ふつうのコマと、一時停止のあとのコマで違うのは、`dt` の大きさだけです。

</details>

<details class="hint"><summary>ヒント 2: 関連する場所</summary>

ステップ 3 の「なぜ 1 ミリ秒に刻むのか」。`lab_dt.zig` には、刻むループと上限の 2 つが無い。

</details>

<details class="hint"><summary>ヒント 3: 擬似コード</summary>

```text
残り = dt(ただし 0.1 秒まで)
残りがある間:
    h = 残り(ただし 0.001 まで)
    a・v・x を更新
    残り -= h
```

</details>

<details class="hint"><summary>ヒント 4: 答え(守りを外したときの実測)</summary>

2 秒止めたあとの位置(目標 100。`zig test learn/spring/measure_test.zig` で再現):

| 守り | 位置 | 見え方 |
|---|---|---|
| 上限 + 刻み(本物) | 93.0 | ふつうに続く |
| 上限だけ外す | 100.0 | 途中を飛ばして目標へ**ワープ** |
| 刻みだけ外す | 286.8 | 目標の約 3 倍へ飛ぶ |
| 両方外す(このラボ) | **82,058** | 画面の外へ消える |

直し方は `answer.zig` の `while` ループと `if (remaining > 0.1)` の 2 か所。

</details>

<label class="chk"><input type="checkbox" data-k="spring:5">ラボの試験が 3 つとも通った</label>

## ステップ 6: 確認テスト {#quiz}

答えは折りたたんであります。先に頭の中で答えてください。

<details class="answer"><summary>問 1: damping を 1.0 から 0.3 にすると、何が変わる?</summary>

行き過ぎるようになる(0.3 で最大 136.8)。止まるまでの時間は長くなる(0.75 秒 → 1.57 秒)。

</details>

<details class="answer"><summary>問 2: 速さ v を先に更新するのはなぜ?</summary>

速さ → 位置の順(半陰的オイラー法)にすると、大きめの刻みでも壊れにくくなるから。

</details>

<details class="answer"><summary>問 3: dt に 0.1 秒の上限があるのはなぜ?</summary>

一時停止のあと、大きな dt を全部進めると、途中を飛ばして目標へワープするから(上限が無いと 2 秒後に 100.0)。

</details>

## 自分で確かめる {#verify}

```sh
cd ~/ame-shell
zig test learn/spring/answer.zig        # 答えが約束を全部満たす
zig test learn/spring/measure_test.zig  # このページの数値を測り直す
sh learn/check-real.sh                  # 本物の Odin でも同じか
```

## つまずいたとき {#stuck}

| 症状 | よくある原因 |
|---|---|
| `収束: 10 秒たっても止まらない(x = nan)` | 符号が逆。引っぱる力は目標へ向かう(`-k × (x − 目標)`) |
| `減衰: damping = 1 なのに行き過ぎた` | c の `2 ×` を忘れている |
| `response = 0: まだ動いている` | ω の計算(0 で割る)より前に処理していない |
| `error: unused local constant` | Zig は使わない変数をエラーにする。使うか、`_ = 名前;` |

## できた・明日の復習 {#done}

<label class="chk"><input type="checkbox" data-k="spring:6">確認テストを 3 問とも、答えを見る前に言えた</label>

明日、何も見ずに答える 3 問:

1. ばねの 3 つの約束は?
2. k と c を ω と damping から書くと?
3. 1 ミリ秒に刻むのはなぜ?(数字を 1 つ使って)

<textarea class="memo" data-k="spring:note" rows="3" placeholder="今日のメモ(この PC のブラウザにだけ残ります)"></textarea>
