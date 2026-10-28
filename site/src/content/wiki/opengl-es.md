# OpenGL ES

::infobox OpenGL ES
策定 | Khronos Group
版 | 2.0(2007)、3.0(2012)、3.2(2015)
ame-shell | 3.0 以降(GLSL ES 3.00)
後継の流れ | Vulkan

**OpenGL ES** は、GPU に絵を描かせるための API です。もともとは携帯機器向けに OpenGL を小さくしたもので、今は Linux のデスクトップでも広く使われています。

## 概要 {#overview}

GPU は、たくさんの小さな計算を同時に行うのが得意な装置です。OpenGL ES は「三角形をこの位置に、このプログラム([[shader|シェーダ]])で塗って」と GPU に頼むための言葉です。

## 仕組み {#how}

- **頂点**(三角形の角)を頂点シェーダで画面の位置に変換する。
- 三角形が覆う**ピクセル**ごとに、フラグメントシェーダが色を決める。
- 色を描画先([[fbo|フレームバッファ]])に**混ぜる**(ブレンド)。

## ame-shell での使われ方 {#ame}

ame-shell の UI は GLES 3 で描いています。描くのは「[[instancing|インスタンス描画]]した四角形」1 種類だけで、角丸・影・ガラス・文字の形は、フラグメントシェーダの中の[[sdf|距離場]]で決めます。

**Vulkan を使わない理由**: コードの量が数倍になり、利点(複数のスレッドから描画の命令を作れる、など)が、この規模の 2D の UI では効かないからです([GPU レンダラ](#/tech-gpu))。

## 関連項目 {#see}

- [[shader]] / [[egl]] / [[fbo]] / [[instancing]] / [[sdf]]

## 参考文献 {#refs}

- [OpenGL ES 3.0 の仕様(Khronos)](https://registry.khronos.org/OpenGL/specs/es/3.0/es_spec_3.0.pdf)
