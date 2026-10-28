# ビルド(build.zig)

<p class="file">対象: build.zig(224 行)</p>

`zig build` 1 回で、次のものを全部作ります。CMake・Make・Meson・pkg-config の生成スクリプトなどは使いません。

| 成果物 | 中身 |
|---|---|
| `zig-out/bin/ame-shell` | 本体(Zig + C:wasm3・stb_image・nanosvg・Wayland のプロトコル + Odin のオブジェクト) |
| `zig-out/bin/ame-ctl` | 操作用の CLI(libc だけ) |
| `zig-out/share/ame-shell/widgets/*.wasm` | WebAssembly のウィジェット 5 つ(Zig + Odin を wasm32 に) |
| `zig-out/share/ame-shell/*` | 既定の設定・foot / fastfetch の設定・SDDM のテーマなど(`data/` をそのまま) |
| `zig-out/site/`(`zig build site`) | このサイト |
| `zig-out/bin/vptr`・`vkbd`(`zig build tools`) | 試験用の仮想ポインタ・仮想キーボード |

## Wayland のプロトコルを XML から作る {#protocols}

ame-shell は 16 個の Wayland プロトコル(layer-shell・session-lock・River のウィンドウ管理・xkb-bindings・libinput の設定など)を使います。各 XML から `wayland-scanner` で C のヘッダとコードを作ります。

```zig
// build.zig
const gen = b.addWriteFiles();
for (protocols) |xml| {
    const base = std.fs.path.stem(xml);
    const hdr = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    hdr.addFileArg(b.path(xml));
    const hdr_out = hdr.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{base}));
    _ = gen.addCopyFile(hdr_out, b.fmt("{s}-client-protocol.h", .{base}));

    const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    code.addFileArg(b.path(xml));
    const code_out = code.addOutputFileArg(b.fmt("{s}-protocol.c", .{base}));
    proto_c.append(code_out) catch @panic("oom");
}
```

- **ヘッダは 1 つのディレクトリに集め**(`addWriteFiles`)、そこを include パスにします。生成物の場所はハッシュ付きのキャッシュの中なので、こうしないとヘッダ同士の `#include` が解決できません。
- `private-code` は、プロトコルの記述をそのライブラリの中だけに閉じた記号として出力します。ほかのライブラリが同じプロトコルを持っていても衝突しません。
- XML は `protocol/` にリポジトリとして持っています。システムに wayland-protocols や River の開発ファイルが入っていなくてもビルドできます。

**結果**: プロトコルを 1 つ足すのは、配列に 1 行足して `c.zig` に `@cInclude` を 1 行足すだけです。タッチパッドのタップ(`river-libinput-config-v1`)はこの 2 行で使えるようになりました。

## Odin を「外部コマンド」としてつなぐ {#odin}

```zig
const odin = b.addSystemCommand(&.{ "odin", "build" });
odin.addDirectoryArg(b.path("anim"));
odin.addArgs(&.{
    "-build-mode:obj",   "-no-entry-point",           "-o:speed",
    "-no-bounds-check",  "-default-to-nil-allocator", "-no-thread-local",
    "-reloc-mode:pic",   odin_target,
});
const anim_obj = odin.addPrefixedOutputFileArg("-out:", "anim.o");
// ディレクトリ引数は中身の変更を追跡しないため、ソースを明示的に入力に加える。
odin.addFileInput(b.path("anim/anim.odin"));
```

| オプション | 理由 |
|---|---|
| `-build-mode:obj` | 実行ファイルではなく `.o` を作り、Zig がリンクする |
| `-no-entry-point` | `main` を持たないライブラリとして作る |
| `-default-to-nil-allocator` | Odin のランタイムのアロケータを使わない(使ったらすぐ分かるように) |
| `-no-thread-local` | スレッドローカル変数を使わない(wasm32 の freestanding と同じ前提にそろえる) |
| `-reloc-mode:pic` | PIE の実行ファイルにリンクできる位置独立コードにする |
| `-target:freebsd_amd64` など | Zig の `target` から Odin のターゲット名に変換(Linux / FreeBSD × amd64 / arm64) |

**`addFileInput` が必要な理由**: `addDirectoryArg` はディレクトリの「場所」しか依存に入れません。そのため `anim.odin` を書き換えても、Zig のキャッシュが古い `.o` を使い続けてしまいます。ソースを入力として明示すると、変更したときだけ Odin を呼び直します。

## wasm3 を C のソースとして入れる {#wasm3}

```zig
for (wasm3_files) |f| {
    exe.addCSourceFile(.{
        .file = b.path(b.fmt("third_party/wasm3/source/{s}", .{f})),
        // d_m3HasWASI 等は無効(ウィジェットにファイル/ネットワークを触らせない)。
        .flags = &.{ "-std=gnu11", "-O2", "-Dd_m3HasWASI=0", "-Dd_m3HasUVWASI=0", "-Dd_m3HasMetaWASI=0", "-Dd_m3LogOutput=0", "-fno-sanitize=undefined" },
    });
}
```

- **WASI をコンパイルの時点で外して**います。設定で無効にするのではなく、コードそのものが入らないので、ウィジェットからファイルやネットワークに触れる道は最初から存在しません。
- `-fno-sanitize=undefined`: Zig は C のコードを Debug 系でコンパイルすると、未定義動作の検査(UBSan)を入れます。同梱した外部の C コード(wasm3・stb_image・nanosvg)ではこの検査を外し、どのビルドでも同じ動きにそろえています。

## ライブラリの探し方: Linux は pkg-config、FreeBSD は使わない {#libs}

```zig
for ([_][]const u8{ "wayland-client", "wayland-egl", "EGL", "GLESv2", "xkbcommon", "freetype", "harfbuzz", "fontconfig", "dbus-1" }) |lib| {
    // FreeBSD はパスを上で指定済みなので pkg-config を使わない(--sysroot の試しビルドで手元の Linux のライブラリを拾わないように)
    if (bsd) exe.linkSystemLibrary2(lib, .{ .use_pkg_config = .no }) else exe.linkSystemLibrary(lib);
}
if (bsd) {
    exe.linkSystemLibrary2("epoll-shim", .{ .use_pkg_config = .no });
    exe.linkSystemLibrary2("inotify", .{ .use_pkg_config = .no });
}
```

FreeBSD 向けには `/usr/local`(pkg が入れる場所)を include・ライブラリのパスに足し、Linux の API(epoll・timerfd・inotify)を **libepoll-shim** と **libinotify** で補います。`--sysroot` を付けると、そのパスの下を見ます。

### Linux 上で FreeBSD 向けにビルドして検査する {#cross}

FreeBSD の `base.txz` と、必要なパッケージ(wayland・mesa・libglvnd・xkbcommon・freetype・harfbuzz・fontconfig・dbus・libepoll-shim・libinotify と依存)を展開して sysroot を作り、次のようにビルドします。

```sh
zig build -Dtarget=x86_64-freebsd --sysroot $ROOT --libc libc.txt --prefix /tmp/out
llvm-objdump -d /tmp/out/bin/ame-shell | grep -cE '\ssyscall\s*$|<os\.linux\.'   # → 0
```

`--prefix` を必ず付けるのは、普段の `zig-out` を FreeBSD のバイナリで上書きしないためです。最後の行は、**Linux の直接のシステムコール**(`syscall` 命令、Zig の `std.os.linux.*`)が 1 つも残っていないかを逆アセンブルで数えています。これを 0 に保つ理由は [起動とイベントループ](#/tech-loop) の SIGSYS の件です。

## strip とデバッグ情報 {#strip}

```zig
// -Dstrip=false で、リリースでもデバッグ情報(関数名)を残す(クラッシュのバックトレース用)
const strip = b.option(bool, "strip", "Strip debug info (default: true except Debug)") orelse (optimize != .Debug);
```

- 普段は ReleaseFast + strip(1.8 MB)。
- 原因の分からないクラッシュを調べるときは `-Doptimize=ReleaseSafe -Dstrip=false`。安全検査が有効になり、落ちたときに関数名つきのスタックトレースが出ます。インストーラの `--debug` がこれです。

## ウィジェットのメモリを固定する {#widgets}

```zig
w.entry = .disabled;
w.rdynamic = true;
// ホストと共有するリニアメモリは小さく固定(1MiB)。ウィジェットに巨大確保させない。
w.initial_memory = 1 << 20;
w.max_memory = 1 << 20;
w.stack_size = 64 << 10;
w.addObjectFile(anim_wasm);
```

`max_memory` をリンクの時点で 1 MiB に決めるので、ウィジェットが `memory.grow` で際限なく大きくなることはありません。`rdynamic` で `export fn` をすべて外から呼べるようにし、`entry = .disabled` で `_start` を持たないモジュールにしています。

## ほかの方法との比較 {#vs}

| 方法 | 採らなかった理由 |
|---|---|
| CMake / Meson | 2 つ目の言語と道具が増える。Odin・wayland-scanner・wasm のビルドをつなぐ記述が長くなる |
| システムの wasm3・stb を使う | ディストリによって入っていない・版が違う。ソースを同梱すれば常に同じものが入る |
| pkg-config を常に使う | クロスビルドのときに手元(Linux)のライブラリを拾ってしまう |
| 生成した C のコードをリポジトリに入れる | wayland-scanner の版が変わると古くなる。XML から毎回作るほうが確実 |
