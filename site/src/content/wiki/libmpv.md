# libmpv

::infobox libmpv
種類 | 動画プレーヤー mpv のライブラリ版(C)
描画の API | mpv_render_context(OpenGL など)
ame-shell | 動画の壁紙(dlopen で読み込む)

**libmpv** は、動画プレーヤー mpv を、ほかのプログラムに組み込むためのライブラリです。

## ame-shell での使われ方 {#ame}

- **描画の API**(`vo=libmpv`)で、mpv が復号した動画のコマを、ame-shell の OpenGL の[[fbo|フレームバッファ]]に**直接**描かせます。CPU にコピーしないので軽く、[[va-api|VA-API]] のハードウェア復号も使えます。
- **dlopen** で読み込むので、libmpv が無い環境でも ame-shell は起動します(動画の壁紙だけが使えない)。その場合や、再生できない・5 秒たっても映らない場合は、ffmpeg で再生します。
- mpv のコールバックは mpv のスレッドで呼ばれるので、そこでは[[pipe|パイプ]]に 1 バイト書くだけにして、GL の操作はメインのスレッドで行います。
- Wayland の接続を mpv に渡すと、VA-API が別の場所で Wayland の往復をして、ame-shell のイベントループと噛み合って固まったため、渡していません([メディア](#/tech-media))。

## 関連項目 {#see}

- [[va-api]] / [[fbo]] / [[pipe]]

## 参考文献 {#refs}

- [mpv の render API(client API の文書)](https://mpv.io/manual/master/#embedding-into-other-programs-libmpv)
