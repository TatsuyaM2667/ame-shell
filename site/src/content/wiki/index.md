# ame-shell Wiki へようこそ

<p class="wsub">ame-shell の開発で使っている用語を、**はじめての人にも分かる説明**から**研究者向けの理論と文献**まで、1 項目ずつまとめた用語集です。</p>

ドキュメントや技術解説の本文の中で、点線の下線が付いた語([[epoll]]、[[sdf]] など)を押すと、この Wiki の項目が開きます。赤いリンクは、まだ項目が無い語です。

## 読み方 {#how}

各項目は、上から順に難しくなるように書いています。

1. **冒頭の 1 段落** — その語が何かを一言で。
2. **概要** — たとえ話を使った、予備知識の要らない説明。
3. **仕組み** — 実際にどう動くか。
4. **ame-shell での使われ方** — このプロジェクトのどこで、なぜ使っているか。コードへのリンクつき。
5. **理論と研究** — 数式、計算量、ほかの方法との比較、元になった論文。
6. **関連項目・参考文献**

## おすすめの順番 {#path}

- **描画を知りたい**: [[opengl-es]] → [[shader]] → [[sdf]] → [[premultiplied-alpha]] → [[kawase-blur]] → [[smooth-min]]
- **アニメーションを知りたい**: [[ode]] → [[spring]] → [[damping-ratio]] → [[euler-method]] → [[symplectic]] → [[cubic-bezier]]
- **OS の仕組みを知りたい**: [[syscall]] → [[fork-exec]] → [[pipe]] → [[epoll]] → [[timerfd]] → [[sigsys]]
- **Wayland を知りたい**: [[wayland]] → [[compositor]] → [[layer-shell]] → [[frame-callback]] → [[river]]
