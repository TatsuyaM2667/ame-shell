# EGL

::infobox EGL
策定 | Khronos Group
役割 | OpenGL ES などと、窓の仕組み(Wayland・X11)をつなぐ
主な関数 | eglGetDisplay, eglCreateContext, eglCreateWindowSurface, eglSwapBuffers

**EGL** は、[[opengl-es|OpenGL ES]] で描いた絵を、OS の窓の仕組み([[wayland|Wayland]] など)に渡すための「つなぎ」の API です。

## 概要 {#overview}

OpenGL ES は「GPU に絵を描かせる方法」だけを決めていて、「その絵をどの窓に出すか」は決めていません。そこをつなぐのが EGL です。EGL で「Wayland のこのサーフェスに描きます」という描画先を作り、描き終わったら `eglSwapBuffers` で渡します。

## 仕組み {#how}

1. `eglGetDisplay`(Wayland の接続から)→ `eglInitialize`
2. `eglChooseConfig` で色の形式などを選ぶ
3. `eglCreateContext` で GL の「文脈」(状態の入れ物)を作る
4. `wl_egl_window_create` + `eglCreateWindowSurface` で、Wayland のサーフェスを描画先にする
5. `eglMakeCurrent` で「今からこの描画先に、この文脈で描く」
6. `eglSwapBuffers` で描いた絵をコンポジタに渡す

## ame-shell での使われ方 {#ame}

ame-shell は**EGL の文脈を 1 つだけ**作り、全部のサーフェス(壁紙・枠・ランチャー…)で共有します。描くサーフェスを切り替えるときは `eglMakeCurrent` で描画先だけを替えます。文脈が 1 つなので、[[glyph-atlas|グリフアトラス]]や、ぼかした壁紙のテクスチャを、全部の部品が**そのまま**使えます([GPU レンダラ](#/tech-gpu))。

## 関連項目 {#see}

- [[opengl-es]] / [[vsync]] / [[fbo]] / [[wayland]]

## 参考文献 {#refs}

- [Khronos EGL の仕様](https://registry.khronos.org/EGL/)
