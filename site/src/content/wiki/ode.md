# 常微分方程式

::infobox 常微分方程式
英語 | Ordinary Differential Equation(ODE)
例 | ẍ = −k(x − x*) − c·ẋ(ばね-ダンパ系)
解き方 | 解析解、数値積分(オイラー法・ルンゲ=クッタ法など)

**常微分方程式**は、ある量と、その量の時間による変化(微分)の関係を表した式です。

## 概要 {#overview}

「速さが分かれば、少し後の位置が分かる」「力が分かれば、少し後の速さが分かる」。この関係を式にしたものが微分方程式です。ボールの軌道、ばねの揺れ、人口の増え方など、時間とともに変わるものの多くを表せます。

## 仕組み {#how}

[[spring|ばね-ダンパ系]]の式は、2 階の微分(加速度)を含みます。速度 v = ẋ を別の変数にすると、1 階の連立方程式になります。

```
ẋ = v
v̇ = −k(x − x*) − c·v
```

これを、短い時間 h ずつ進める(数値積分)のが、コンピュータでの解き方です。

## ame-shell での使われ方 {#ame}

ame-shell のアニメーションは、上の連立方程式を、1 ミリ秒の刻みで [[symplectic|半陰的オイラー法]]で解いています。解析解(式で答えを出す方法)を使わない理由は、[[spring]] の解析解が `sin`・`cos`・`exp` を必要とし、[[webassembly|WebAssembly]] の freestanding 環境で使えないためです([ばね](#/tech-anim))。

## 関連項目 {#see}

- [[spring]] / [[euler-method]] / [[symplectic]]

## 参考文献 {#refs}

- E. Hairer, S. P. Nørsett, G. Wanner, "Solving Ordinary Differential Equations I: Nonstiff Problems", Springer, 1993.
