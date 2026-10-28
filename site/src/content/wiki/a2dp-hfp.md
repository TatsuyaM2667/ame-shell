# A2DP と HFP

::infobox A2DP と HFP
A2DP | Advanced Audio Distribution Profile。音楽用の高音質(ステレオ、SBC・AAC・aptX など)
HFP | Hands-Free Profile。通話用(モノラル、8〜16 kHz、マイクつき)
問題 | 片方向の高音質と、マイクを同時に使えない(従来の Bluetooth)
ame-shell | イヤホンを A2DP にし、HFP への自動切り替えを止める

**A2DP** と **HFP** は、Bluetooth で音を送るための、2 つの違う方式(プロファイル)です。

## 概要 {#overview}

A2DP は音楽用で、ステレオの高音質ですが、マイクは使えません。HFP は通話用で、マイクが使えますが、モノラルで音質が低い(電話のような音)です。従来の Bluetooth では、同時にはどちらか一方しか使えません。

## ame-shell での事例 {#ame}

AirPods で音楽を聴いていると、ときどき電話のようなガサガサの音になる、という問題がありました。原因は、どれかのアプリがマイクを開いた瞬間に、[[pipewire|PipeWire]] の WirePlumber が**自動で HFP に切り替えて**いたことです。

ame-shell の Bluetooth の接続スクリプトは、

- `wpctl settings --save bluetooth.autoswitch-to-headset-profile false` で自動の切り替えを止め、
- つないだら A2DP(AirPods では AAC)にして、既定の出力にし、
- 既定の入力が Bluetooth のマイクなら、内蔵のマイクに戻します。

代わりに、通話でイヤホンのマイクを使うときは、手で入力を切り替える必要があります。

## 理論と研究 {#theory}

:::research LE Audio
Bluetooth LE Audio(LC3 コーデック、2020 年〜)では、低遅延・高音質の音と、マイクを同時に扱えるようになり、この「音楽か通話か」の二択は解消に向かっています。
:::

## 関連項目 {#see}

- [[pipewire]]

## 参考文献 {#refs}

- Bluetooth SIG, Advanced Audio Distribution Profile(A2DP)/ Hands-Free Profile(HFP)の仕様
