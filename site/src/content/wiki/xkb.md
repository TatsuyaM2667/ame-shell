# XKB

::infobox XKB
正式名 | X Keyboard Extension
ライブラリ | libxkbcommon
役割 | キーの番号を、文字や意味(keysym)に変える
ame-shell | キーボード配列の解釈、キー割り当て

**XKB** は、キーボードの「どのキーを押したら、どの文字になるか」を決める仕組みです。もとは X11 の拡張でしたが、今は [[wayland|Wayland]] でも **libxkbcommon** というライブラリとして使われています。

## 概要 {#overview}

キーボードが送ってくるのは「左から 3 番目のキー」のような**番号(キーコード)**だけです。それが「A」なのか「ち」なのかは、キーボードの配列(日本語配列・US 配列)や、Shift を押しているかで変わります。XKB はこの対応表(keymap)を持ち、番号を **keysym**(キーの意味。例: `XKB_KEY_a`、`XKB_KEY_Return`)と文字に変えます。

## 仕組み {#how}

- keymap は「規則・モデル・配列・変種・オプション」(例: `evdev, pc105, jp, , ctrl:nocaps`)から作られる、テキストの記述です。
- `xkb_state` に押下と解放を渡すと、修飾キー(Shift・Ctrl・Super)の状態が更新され、次のキーの keysym と文字が決まります。
- [[wayland|Wayland]] では、コンポジタが keymap を fd で渡し、クライアントは `mmap` で読みます。

## ame-shell での使われ方 {#ame}

ame-shell は、コンポジタが渡す keymap をそのまま使います(配列を自分で決めない)。そのため日本語配列でも記号がずれません。River 0.5 のキー割り当ては keysym で登録する(`river-xkb-bindings-v1`)ので、配列が変わっても Super+Return は Super+Return です([Wayland とサーフェス](#/tech-wayland)、[ウィンドウマネージャ](#/tech-wm))。

## 関連項目 {#see}

- [[wayland]] / [[evdev]]
