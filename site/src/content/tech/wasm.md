# WebAssembly ウィジェット

<p class="file">対象: src/wasm.zig(223 行)/ src/widget_abi.zig(71 行)/ widgets/ame.zig(SDK、193 行)/ widgets/*.zig(5 つ)</p>

ダッシュボードの時計・メディア・クイックコントロール・システムモニタ・カレンダーは、**Zig で書いて wasm32 にビルドしたウィジェット**です。ame-shell の中の [wasm3](https://github.com/wasm3/wasm3) で動きます。

## なぜ WebAssembly にするか {#why}

| 求めたもの | WebAssembly で得られること |
|---|---|
| シェルを止めずに部品を差し替えたい | `.wasm` を保存すると、**状態を保ったまま**入れ替わる(ホットリロード)。ame-shell の再起動もビルドも不要 |
| 部品のバグでシェルを落としたくない | ウィジェットは自分のメモリの中でしか動けない。範囲外アクセスはトラップになり、そのウィジェットだけが止まる |
| 部品に余計なことをさせたくない | ファイル・ネットワーク・時計に触る手段(WASI)を与えない。外への出口は 1 つだけ |
| 好きな言語で書けるように | 約束(ABI)はメモリの並びと 6 つの関数だけ。wasm32 に出力できる言語なら書ける |

## ランタイム: wasm3 {#runtime}

```zig
// src/wasm.zig
// wasm3 を選んだ理由: 純 C で依存なし、musl でもそのままビルドでき、
// インタプリタでも十分速い(ウィジェットは1フレーム数十命令〜数千命令程度)。WAMR は JIT/AOT
// を使うと速いが、ビルド構成が大きく CMake 前提なので「zig build 一発」の方針に合わない。
//
// サンドボックス: ウィジェットに与える import は "ame.action" だけ。WASI は有効にしないので
// ファイル・ネットワーク・時計にも触れられない(時刻はホストがストアに書き込む)。
// メモリは 1MiB 固定(ビルド時に max_memory で制限)。
```

| ランタイム | 判断 |
|---|---|
| **wasm3** | ✓ 純 C・依存なし。`zig build` に C のソースとして入る。インタプリタだが、ウィジェットの 1 フレームは描画命令を数十個作るだけなので十分速い |
| WAMR | JIT / AOT で速いが、ビルドの構成が大きく CMake が前提 |
| wasmtime | 速く高機能だが Rust で書かれていて巨大 |
| 自分でインタプリタを書く | 仕様の正しさを確かめる手間が大きすぎる |

wasm3 は**関数を初めて呼んだときに内部形式へ変換**します。そのため、最初にダッシュボードを開いたときにその時間がかからないよう、起動後のアイドル時間に全ウィジェットを 1 回動かしておきます([先読み](#/tech-loop))。

## 約束(ABI): 1 つのファイルを両側が import {#abi}

```zig
// src/widget_abi.zig
// ホスト(ame-shell)と WASM ウィジェットが共有するメモリレイアウト。
// 両側がこの1ファイルを import するので、構造体の食い違いが起きない。
// 非網羅的(_)にしておく: 壊れた/悪意あるウィジェットが未知の値を書いてもホストは無視するだけ
pub const CmdKind = enum(u32) { rect = 1, grad = 2, border = 3, glass = 4, shadow = 5, text = 6, arc = 7, art = 8, clip = 9, wrap = 10, _ };

pub const Cmd = extern struct {
    kind: u32,
    x: f32, y: f32, w: f32, h: f32, r: f32,
    col: u32, // 0xRRGGBBAA
    col2: u32,
    a: f32, b: f32,
    str_ptr: u32, // ウィジェットのリニアメモリ上のアドレス
    str_len: u32,
    flags: u32, // text: bit0=bold, bit1-2=align(0左,1中,2右)
    _pad: [3]u32 = .{ 0, 0, 0 },
};

pub const Store = extern struct {
    year: i32 = 0, month: i32 = 1, …           // 時刻(ホストが書く)
    cpu: f32 = 0, mem: f32 = 0, temp: f32 = -1,  // システム
    volume: f32 = 0, muted: u32 = 0, …           // 音・明るさ・電池・Wi-Fi・Bluetooth・通知停止
    media_status: u32 = 0, media_pos: f32 = 0, … // 再生中の曲
    accent: u32 = 0x7ab8ff, text: u32 = 0xeaf2ff, subtext: u32 = 0x9fb4d6,  // 配色
    title: [160]u8 = …, artist: [160]u8 = …, player: [48]u8 = …,
};
```

- **`widget_abi.zig` をホストもウィジェットも import します**。構造体の定義が 1 か所なので、片方だけ変えて並びが食い違う、ということが起きません。
- **`enum(u32) { …, _ }`(非網羅的な列挙)**: ウィジェットが知らない番号を書いても、ホストの `switch` は `else` で無視するだけです。網羅的な列挙にすると、不正な値は未定義動作になります。
- **時刻もホストが書きます**。ウィジェットは時計に触れないので、時刻を知る手段はストアだけです(WASI を与えない結果)。

### ウィジェットが外に出す 6 つの関数 {#exports}

```zig
// widgets/ame.zig(SDK)
pub fn exportWidget(comptime W: type) void {
    const S = struct {
        fn ame_cmds() callconv(.C) u32 { return @intFromPtr(&cmds); }        // 描画命令の配列の場所
        fn ame_store() callconv(.C) u32 { return @intFromPtr(&store); }      // ストアの場所
        fn ame_state() callconv(.C) u32 { return @intFromPtr(&W.state); }    // 状態(ホットリロードで保つ)
        fn ame_state_size() callconv(.C) u32 { return @sizeOf(@TypeOf(W.state)); }
        fn ame_height(w: f32) callconv(.C) f32 { return W.height(w); }
        fn ame_frame(dt: f32, w: f32, h: f32) callconv(.C) u32 {
            begin();
            const animating = W.frame(dt, w, h);
            return (n_cmds << 1) | @intFromBool(animating);                  // 命令の数 と まだ動いているか
        }
        …
    };
    …
}
```

ウィジェットを書く人は、`state`・`height`・`frame`・`pointer` を持つ型を書いて `exportWidget` に渡すだけです。

## 1 フレームの流れ: コピーしない {#frame}

```zig
pub fn frame(self: *Widget, dt: f32, w: f32, h: f32) FrameResult {
    if (self.failed) return .{ .cmds = &.{}, .animating = false };
    …
    if (c.m3_Call(self.f_frame, 3, @ptrCast(@constCast(&args)))) |err| {
        std.log.err("wasm: {s}.frame がトラップ: {s}(このウィジェットを停止)", …);
        self.failed = true;
        return .{ .cmds = &.{}, .animating = false };
    }
    …
    const n = ret >> 1;
    const mem = self.memory();
    const bytes = @as(usize, n) * @sizeOf(abi.Cmd);
    if (@as(usize, self.cmds_off) + bytes > mem.len) return .{ .cmds = &.{}, .animating = false };
    // ウィジェットのメモリ上のコマンド配列をそのまま参照する(ゼロコピー)
    const ptr: [*]align(1) const abi.Cmd = @ptrCast(mem.ptr + self.cmds_off);
    return .{ .cmds = ptr[0..n], .animating = (ret & 1) != 0 };
}
```

1. ホストがストアに今の値(時刻・CPU・曲…)を書く。
2. `ame_frame(dt, 幅, 高さ)` を呼ぶ。ウィジェットは自分のメモリの配列に描画命令を書き、その数を返す。
3. ホストは**ウィジェットのメモリをそのまま**命令の配列として読み、[GPU レンダラ](#/tech-gpu)の四角形に変換する。

- **コピーしない**: 命令の配列の場所はウィジェットが最初に教える(`ame_cmds`)ので、ホストは毎フレーム、そこを直接読みます。
- **境界チェック**: 命令の配列がメモリの外にはみ出していれば、何も描きません。文字列(`str_ptr` / `str_len`)も、メモリの範囲内かを確かめてから読みます。

```zig
/// コマンドが指す文字列を、ウィジェットのメモリから境界チェック付きで取り出す
pub fn str(self: *Widget, ptr: u32, len: u32) []const u8 {
    const mem = self.memory();
    if (@as(usize, ptr) + len > mem.len) return "";
    return mem[ptr .. ptr + len];
}
```

- **トラップしたら止める**: ウィジェットの中で範囲外アクセスやゼロ除算が起きると、wasm3 がトラップを返します。そのウィジェットだけを `failed` にして描かなくなり、シェルは動き続けます。修正して `.wasm` を保存し直せば、再び読み込みます。
- **ウィジェットも同じばね**: ウィジェットには Odin の `anim.odin` が wasm32 としてリンクされていて、ホストと同じ `ame_spring_step` が使えます。返り値の「まだ動いているか」のビットで、ホストは次のフレームを頼むかを決めます。

## 外への出口は 1 つ {#action}

```zig
pub const Action = enum(u32) {
    media_toggle = 1, media_next = 2, media_prev = 3,
    set_volume = 4, set_brightness = 5,
    toggle_wifi = 6, toggle_bt = 7, toggle_dnd = 8,
    open_launcher = 9, mute = 10,
    _,
};
```

ウィジェットが外の世界に影響を与える手段は、`ame.action(番号, 値)` の 1 つだけです。できることは、この 10 種類に限られます。ファイルを読む・コマンドを実行する・ネットワークにつなぐ、といったことは**原理的にできません**。

## ホットリロード: 状態を保って入れ替える {#reload}

```zig
pub fn reload(self: *Widget) void {
    var saved: [4096]u8 = undefined;
    var saved_len: usize = 0;
    if (!self.failed) {
        if (self.stateSlice()) |st| if (st.len <= saved.len) {
            @memcpy(saved[0..st.len], st);            // 1. 今の状態を退避
            saved_len = st.len;
        };
    }
    self.release();
    self.instantiate() catch { … self.failed = true; return; };   // 2. 新しい .wasm を読む
    if (self.stateSlice()) |st| {
        if (st.len == saved_len) {
            @memcpy(st, saved[0..saved_len]);         // 3. 大きさが同じなら書き戻す
            std.log.info("wasm: {s} を再読込(状態を引き継ぎ)", .{self.nameStr()});
        } else std.log.info("wasm: {s} を再読込(状態の形が変わったので初期化)", .{self.nameStr()});
    }
}
```

- `.wasm` の保存は [inotify](#/tech-config) で知ります(エディタが「別名で書いて名前を変える」保存のしかたをしても拾えるよう、ディレクトリを監視)。
- ウィジェットの状態(`state`:ばねの位置・選んでいるタブなど)を退避し、新しいモジュールを読み、**状態の大きさが同じなら書き戻します**。見た目を直して保存すると、アニメーションの途中の位置まで保ったまま新しい見た目になります。
- 状態の形(構造体)を変えた場合は、大きさが変わるので初期化します。違う形のデータを書き戻して壊すことはありません。
- 読み込みに失敗したら、そのウィジェットだけを止めます。直して保存し直せば、もう一度読み込みます。

## 結果 {#result}

| 項目 | 値 |
|---|---|
| ウィジェット 1 つの大きさ | 8〜11 KB(Odin のばねを含む) |
| メモリ | 1 MiB に固定(リンク時の `max_memory`) |
| 外への出口 | `ame.action` の 1 つ(10 種類) |
| ファイル・ネットワーク・時計 | 触れない(WASI をコンパイル時点で除外) |
| 差し替え | 保存した瞬間、状態を保って |
