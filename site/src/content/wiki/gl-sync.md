# GL の同期オブジェクト(fence)

::infobox 同期オブジェクト
規格 | OpenGL 3.2 / OpenGL ES 3.0
作る | glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0)
待つ | glClientWaitSync / glWaitSync
消す | glDeleteSync
ame-shell | libmpv に渡す関数を包んで数を抑える

**同期オブジェクト**(sync object、fence)は、「ここまでに出した GPU の命令が終わったか」を CPU から知るための OpenGL の仕組みです。

## 概要 {#overview}

GPU は CPU から受け取った命令を後からまとめて実行します。`glFenceSync` を呼ぶと、それまでの命令の後ろに「目印」を置いたオブジェクトが返ります。`glClientWaitSync` でその目印まで GPU が進むのを待てます。使い終わったら `glDeleteSync` で消します。消さないと、ドライバの中(と、カーネルの同期の仕組み)に残り続けます。

## ame-shell での使われ方 {#ame}

動画の壁紙に使う [[libmpv]](0.41)は、描画 API で 1 コマごとに同期オブジェクトを作り、消していませんでした(30fps で 1 分に約 1,800 個)。mpv は GL の関数を ame-shell が渡す `get_proc_address` から手に入れるので、ame-shell は `glFenceSync` / `glDeleteSync` / `glClientWaitSync` を包み、最近の 8 個だけを残して古いものを消しています([メモリ](#/tech-memory))。

## 関連項目 {#see}

- [[opengl-es]]
- [[libmpv]]
- [[egl]]
