# VA-API

::infobox VA-API
正式名 | Video Acceleration API
提案 | Intel
ドライバ | Mesa(radeonsi・nouveau)、intel-media-driver ほか
役割 | 動画の復号・符号化を GPU で行う
ame-shell | 動画の壁紙(libmpv と ffmpeg の両方)

**VA-API** は、動画の復号(デコード)を、CPU ではなく GPU の専用の回路で行うための API です。

## ame-shell での使われ方 {#ame}

- [[libmpv]] の経路では `hwdec=auto-safe` で使います。
- ffmpeg の経路では、`-hwaccel vaapi` で復号し、`scale_vaapi` で**縮小まで GPU で**行ってから、小さくなった画像だけを CPU に下ろします。4K の動画を CPU で縮小すると重いからです。
- 作者の環境(Radeon 680M、4K の動画)での実測: VA-API の経路で CPU 約 39%、VA-API を使わない CPU の復号で約 135%。
- VA-API が使えない(ドライバが無い)ときは、自動で CPU の復号に切り替えます([メディア](#/tech-media))。

## 関連項目 {#see}

- [[libmpv]] / [[pipewire]]
