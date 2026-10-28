# frecency

::infobox frecency
語源 | frequency(回数)+ recency(最近さ)
使われている所 | Firefox のアドレスバー、ランチャー
ame-shell | ランチャーの並べ方

**frecency** は、「よく使うもの」と「最近使ったもの」の両方を考えて、点数を付ける方法です。

## 概要 {#overview}

使った回数だけで並べると、昔たくさん使ったけれど今は使わないアプリが、ずっと上に残ります。最近使った順だけだと、1 回だけ試したアプリが上に来ます。frecency は、回数に「最近さの重み」を掛けて、両方のいいところを取ります。

## ame-shell での式 {#ame}

```zig
const w: f32 = if (e.last_used == 0) 0.5 else if (age < day) 1.0 else if (age < 7 * day) 0.75 else if (age < 30 * day) 0.5 else 0.25;
return @intFromFloat(@min(@as(f32, @floatFromInt(e.uses)), 200) * w * 6);
```

「使った回数(上限 200)× 最近さの重み × 6」。今日使ったものは 1.0、今週は 0.75、今月は 0.5、それより前は 0.25 です([ランチャー](#/tech-launcher))。

## 理論と研究 {#theory}

:::research 時間減衰のモデル
frecency は、各使用に時間とともに減る重みを付けて足す「時間減衰の合計」の簡略版です。より滑らかには、指数減衰 `Σ exp(−(今 − 使った時刻)/τ)` を使います(各使用の記録が要らないよう、合計値と最後の時刻だけを持って更新できる)。ame-shell の段階的な重みは、使用の記録を 1 件ずつ持たずに済む、もっとも単純な近似です。
:::

## 関連項目 {#see}

- [[fuzzy-matching]]

## 参考文献 {#refs}

- Mozilla Firefox の frecency(Places データベースのアドレスバーの並べ方)
