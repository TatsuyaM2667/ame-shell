// ame-shell のビルド定義。`zig build` 一発で完結させる(CMake/Make/Meson を使わない)。
//
// 生成物:
//   zig-out/bin/ame-shell   … シェル本体(デーモン)
//   zig-out/bin/ame-ctl     … 制御CLI(Unixソケット経由)
//   zig-out/share/ame-shell/widgets/*.wasm … WASMウィジェット
//   zig-out/share/icons/ame/              … マウスカーソルのテーマ(tools/cursorgen.zig)
//
// 外部ツール: wayland-scanner(プロトコルXML→C), odin(アニメーションコア)。
const std = @import("std");

const protocols = [_][]const u8{
    "protocol/wlr-layer-shell-unstable-v1.xml",
    "protocol/river-status-unstable-v1.xml",
    "protocol/river-control-unstable-v1.xml",
    "protocol/xdg-shell.xml",
    "protocol/ext-session-lock-v1.xml",
    "protocol/cursor-shape-v1.xml",
    "protocol/tablet-unstable-v2.xml",
    "protocol/idle-inhibit-unstable-v1.xml",
    "protocol/wlr-virtual-pointer-unstable-v1.xml",
    "protocol/virtual-keyboard-unstable-v1.xml",
    "protocol/river-window-management-v1.xml",
    "protocol/river-xkb-bindings-v1.xml",
    "protocol/river-layer-shell-v1.xml",
    "protocol/river-input-management-v1.xml",
    "protocol/river-libinput-config-v1.xml",
    "protocol/wlr-foreign-toplevel-management-unstable-v1.xml",
    "protocol/ext-foreign-toplevel-list-v1.xml",
    "protocol/ext-image-capture-source-v1.xml",
    "protocol/ext-image-copy-capture-v1.xml",
    "protocol/ext-data-control-v1.xml",
    "protocol/viewporter.xml",
    "protocol/single-pixel-buffer-v1.xml",
    "protocol/text-input-unstable-v3.xml",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // -Dstrip=false で、リリースでもデバッグ情報(関数名)を残す(クラッシュのバックトレース用)
    const strip = b.option(bool, "strip", "Strip debug info (default: true except Debug)") orelse (optimize != .Debug);

    // --- Wayland プロトコル: XML から C のヘッダと glue コードを生成 ---
    // 生成物は全て1つのディレクトリに集め、そこを include パスにする。
    const gen = b.addWriteFiles();
    var proto_c = std.ArrayList(std.Build.LazyPath).init(b.allocator);
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

    // --- Odin: アニメーション/ファジー/主色抽出のコアをオブジェクトにする ---
    const bsd = target.result.os.tag == .freebsd;
    const odin_target = if (bsd)
        (if (target.result.cpu.arch == .aarch64) "-target:freebsd_arm64" else "-target:freebsd_amd64")
    else switch (target.result.cpu.arch) {
        .aarch64 => "-target:linux_arm64",
        else => "-target:linux_amd64",
    };
    const anim_obj = addOdinObject(b, "anim.o", &.{
        "-build-mode:obj",  "-no-entry-point",           "-o:speed",
        "-no-bounds-check", "-default-to-nil-allocator", "-no-thread-local",
        "-reloc-mode:pic",  odin_target,
    });

    // --- wasm3: WASM ウィジェットの実行ランタイム(C, MIT) ---
    const wasm3_files = [_][]const u8{
        "m3_bind.c", "m3_code.c",     "m3_compile.c", "m3_core.c",   "m3_emit.c",     "m3_env.c",
        "m3_exec.c", "m3_function.c", "m3_info.c",    "m3_module.c", "m3_optimize.c", "m3_parse.c",
    };

    // --- シェル本体 ---
    const exe = b.addExecutable(.{
        .name = "ame-shell",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip, // リリースはデバッグ情報を落として小さく
    });
    exe.linkLibC();
    exe.addIncludePath(gen.getDirectory());
    // 手の認識(ame-hand)と顔認証(ame-face)は別のリポジトリ(build.zig.zon)
    const hand_dep = b.dependency("ame_hand", .{ .target = target, .optimize = optimize });
    const face_dep = b.dependency("ame_face", .{ .target = target, .optimize = optimize });
    // 画面にも OS にも依存しない部品(src/lib/)。ame-shell と小さな道具(src/cmd/)とテストで共有
    const lib_mod = b.createModule(.{ .root_source_file = b.path("src/lib/lib.zig") });
    exe.root_module.addImport("ame_lib", lib_mod);
    exe.root_module.addImport("ame-hand", hand_dep.module("ame-hand"));
    exe.root_module.addImport("ame-face", face_dep.module("ame-face"));
    // ライブラリのヘッダの場所: Linux は /usr、FreeBSD は /usr/local(パッケージ)。
    // FreeBSD では epoll / timerfd / signalfd を libepoll-shim、inotify を libinotify で補う。
    // --sysroot を付けると、その下の同じパスを使う(Linux から FreeBSD 向けに試しビルドするとき)
    const sr = b.sysroot orelse "";
    const pre = if (bsd) "/usr/local" else "/usr";
    for ([_][]const u8{ "/include/freetype2", "/include/harfbuzz", "/include/dbus-1.0", "/lib/dbus-1.0/include" }) |p| {
        exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}{s}{s}", .{ sr, pre, p }) });
    }
    if (bsd) {
        exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/local/include/libepoll-shim", .{sr}) });
        exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/local/include", .{sr}) });
        exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/local/lib", .{sr}) });
        if (sr.len > 0) {
            exe.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sr}) });
            exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sr}) });
            exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{sr}) });
        }
    }
    exe.addIncludePath(b.path("third_party/wasm3/source"));
    exe.addIncludePath(b.path("third_party"));
    for (proto_c.items) |c_file| {
        exe.addCSourceFile(.{ .file = c_file, .flags = &.{"-std=c11"} });
    }
    for (wasm3_files) |f| {
        exe.addCSourceFile(.{
            .file = b.path(b.fmt("third_party/wasm3/source/{s}", .{f})),
            // d_m3HasWASI 等は無効(ウィジェットにファイル/ネットワークを触らせない)。
            .flags = &.{ "-std=gnu11", "-O2", "-Dd_m3HasWASI=0", "-Dd_m3HasUVWASI=0", "-Dd_m3HasMetaWASI=0", "-Dd_m3LogOutput=0", "-fno-sanitize=undefined" },
        });
    }
    exe.addCSourceFile(.{ .file = b.path("third_party/stb_image_impl.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
    exe.addCSourceFile(.{ .file = b.path("third_party/nanosvg_impl.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
    exe.addObjectFile(anim_obj);
    for ([_][]const u8{ "wayland-client", "wayland-egl", "EGL", "GLESv2", "xkbcommon", "freetype", "harfbuzz", "fontconfig", "dbus-1" }) |lib| {
        // FreeBSD はパスを上で指定済みなので pkg-config を使わない(--sysroot の試しビルドで手元の Linux のライブラリを拾わないように)
        if (bsd) exe.linkSystemLibrary2(lib, .{ .use_pkg_config = .no }) else exe.linkSystemLibrary(lib);
    }
    if (bsd) {
        exe.linkSystemLibrary2("epoll-shim", .{ .use_pkg_config = .no });
        exe.linkSystemLibrary2("inotify", .{ .use_pkg_config = .no });
    }
    b.installArtifact(exe);

    // --- ログイン画面(greetd)の顔認証の PAM モジュール(ame-face の pam_ame_face.so)。Linux と FreeBSD ---
    // ame-face が ReleaseSafe(境界の検査あり)で作る。zig-out/lib に入れて install-session.sh が配る
    if (target.result.os.tag == .linux or bsd) b.installArtifact(face_dep.artifact("pam_ame_face"));

    // --- 試験用ツール(zig build tools): 仮想ポインタでホバー等を自動試験する ---
    const vptr = b.addExecutable(.{ .name = "vptr", .root_source_file = b.path("tools/vptr.zig"), .target = target, .optimize = optimize });
    vptr.linkLibC();
    vptr.addIncludePath(gen.getDirectory());
    for (proto_c.items) |c_file| vptr.addCSourceFile(.{ .file = c_file, .flags = &.{"-std=c11"} });
    vptr.linkSystemLibrary("wayland-client");
    const vkbd = b.addExecutable(.{ .name = "vkbd", .root_source_file = b.path("tools/vkbd.zig"), .target = target, .optimize = optimize });
    vkbd.linkLibC();
    vkbd.addIncludePath(gen.getDirectory());
    for (proto_c.items) |c_file| vkbd.addCSourceFile(.{ .file = c_file, .flags = &.{"-std=c11"} });
    vkbd.linkSystemLibrary("wayland-client");
    vkbd.linkSystemLibrary("xkbcommon");
    // 偽の音楽プレイヤー(MPRIS)。再生中の画面を試す
    const vmpris = b.addExecutable(.{ .name = "vmpris", .root_source_file = b.path("tools/vmpris.zig"), .target = target, .optimize = optimize });
    useDbus(b, vmpris, sr, pre, bsd);
    vmpris.linkLibC();
    const tools = b.step("tools", "試験用ツール");
    tools.dependOn(&b.addInstallArtifact(vptr, .{}).step);
    tools.dependOn(&b.addInstallArtifact(vkbd, .{}).step);
    tools.dependOn(&b.addInstallArtifact(vmpris, .{}).step);

    // --- クリップボード(ame-copy / ame-paste。1 つの実行ファイルを 2 つの名前で入れる。src/cmd/ame-clip.zig)---
    const clip = b.addExecutable(.{ .name = "ame-copy", .root_source_file = b.path("src/cmd/ame-clip.zig"), .target = target, .optimize = optimize, .strip = strip });
    clip.linkLibC();
    clip.addIncludePath(gen.getDirectory());
    for (proto_c.items) |c_file| clip.addCSourceFile(.{ .file = c_file, .flags = &.{"-std=c11"} });
    clip.linkSystemLibrary("wayland-client");
    b.installArtifact(clip);
    b.getInstallStep().dependOn(&b.addInstallBinFile(clip.getEmittedBin(), "ame-paste").step);

    // --- 録画(ame-rec。画面を撮って ffmpeg に渡す。src/cmd/ame-rec.zig)---
    const rec = b.addExecutable(.{ .name = "ame-rec", .root_source_file = b.path("src/cmd/ame-rec.zig"), .target = target, .optimize = optimize, .strip = strip });
    rec.linkLibC();
    rec.addIncludePath(gen.getDirectory());
    for (proto_c.items) |c_file| rec.addCSourceFile(.{ .file = c_file, .flags = &.{"-std=c11"} });
    rec.linkSystemLibrary("wayland-client");
    b.installArtifact(rec);

    // --- ロック(ame-iwato。単体のロック画面。src/cmd/ame-iwato.zig)---
    const iwato = b.addExecutable(.{ .name = "ame-iwato", .root_source_file = b.path("src/cmd/ame-iwato.zig"), .target = target, .optimize = optimize, .strip = strip });
    iwato.linkLibC();
    iwato.addIncludePath(gen.getDirectory());
    for (proto_c.items) |c_file| iwato.addCSourceFile(.{ .file = c_file, .flags = &.{"-std=c11"} });
    iwato.linkSystemLibrary("wayland-client");
    iwato.linkSystemLibrary("xkbcommon");
    b.installArtifact(iwato);

    // --- 制御CLI(libc のみ。軽量に保つ) ---
    const ctl = b.addExecutable(.{
        .name = "ame-ctl",
        .root_source_file = b.path("src/ctl.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    ctl.linkLibC();
    if (bsd and sr.len > 0) {
        ctl.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sr}) });
        ctl.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sr}) });
        ctl.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{sr}) });
    }
    b.installArtifact(ctl);

    const cmds = [_][]const u8{ "ame-lyrics", "ame-ai", "ame-agent", "ame-config", "ame-weather", "ame-airpods", "ame-handtrack", "ame-keyring", "amaterasu", "ame-tajikara", "ame-yatagarasu" };
    // --- 画面を持たない小さな道具(標準入出力でやりとりする。src/cmd/。libc だけ)---
    for (cmds) |name| {
        const t = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("src/cmd/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        });
        t.root_module.addImport("ame_lib", lib_mod);
        // ame-handtrack だけは手の認識(ame-hand)を使う
        if (std.mem.eql(u8, name, "ame-handtrack")) t.root_module.addImport("ame-hand", hand_dep.module("ame-hand"));
        // D-Bus(libdbus。ame-shell 本体と同じもの)を使う道具
        if (usesDbus(name)) useDbus(b, t, sr, pre, bsd);
        // ame-yatagarasu は暗号(TLS)だけ OpenSSL に任せる
        if (std.mem.eql(u8, name, "ame-yatagarasu")) {
            t.linkSystemLibrary("ssl");
            t.linkSystemLibrary("crypto");
        }
        t.linkLibC();
        b.installArtifact(t);
    }

    // --- Odin で書いた小さな道具(odin/<名前>/。標準入出力でやりとりする)---
    // 別の OS 向けに作るとき(FreeBSD の試しビルドなど)は Odin のリンクに相手の sysroot が要るので作らない
    const odin_cmds = [_][]const u8{ "ame-uzume", "ame-hamon" };
    const native = target.query.isNativeOs() and target.query.isNativeCpu();
    for (odin_cmds) |name| {
        if (!native) break;
        b.getInstallStep().dependOn(&b.addInstallBinFile(addOdinExe(b, name), name).step);
    }

    // --- ロック画面のパスワード照合の補助(FreeBSD で root の setuid として入れる。src/auth_helper.zig) ---
    const auth = b.addExecutable(.{
        .name = "ame-auth",
        .root_source_file = b.path("src/auth_helper.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    auth.linkLibC();
    if (bsd and sr.len > 0) {
        auth.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sr}) });
        auth.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sr}) });
        auth.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{sr}) });
    }
    b.installArtifact(auth);

    // --- WASM ウィジェット(Zig → wasm32-freestanding) ---
    // アニメーションコアは同じ Odin ソースを wasm32 にもビルドしてウィジェットへリンクする。
    const anim_wasm = addOdinObject(b, "anim_wasm.o", &.{
        "-build-mode:obj",           "-no-entry-point",             "-o:size", "-no-bounds-check",
        "-default-to-nil-allocator", "-target:freestanding_wasm32",
    });
    const abi_mod = b.createModule(.{ .root_source_file = b.path("src/widget/widget_abi.zig") });
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    for ([_][]const u8{ "clock", "sysmon", "media", "calendar", "controls" }) |name| {
        const w = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("widgets/{s}.zig", .{name})),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        w.entry = .disabled;
        w.rdynamic = true;
        // ホストと共有するリニアメモリは小さく固定(1MiB)。ウィジェットに巨大確保させない。
        w.initial_memory = 1 << 20;
        w.max_memory = 1 << 20;
        w.stack_size = 64 << 10;
        w.addObjectFile(anim_wasm);
        w.root_module.addImport("abi", abi_mod);
        const inst = b.addInstallFile(w.getEmittedBin(), b.fmt("share/ame-shell/widgets/{s}.wasm", .{name}));
        b.getInstallStep().dependOn(&inst.step);
    }

    // --- ドキュメントサイト(zig build site → zig-out/site。公開は site/deploy.sh)---
    // 本文を HTML にするのは Zig の wasm(site/src/main.zig)、デモは同じ anim/anim.odin を wasm にしたもの。
    const site_step = b.step("site", "ドキュメントサイトを zig-out/site に作る");
    const site_wasm = b.addExecutable(.{
        .name = "site",
        .root_source_file = b.path("site/src/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    site_wasm.entry = .disabled;
    site_wasm.rdynamic = true;
    // 関数リファレンス: ソース(src・anim・widgets)を読んで、関数・型・定数のページを生成して埋め込む
    const refgen = b.addExecutable(.{ .name = "refgen", .root_source_file = b.path("site/gen/refgen.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const refgen_run = b.addRunArtifact(refgen);
    const ref_out = refgen_run.addOutputFileArg("refpages.zig");
    {
        var files = std.ArrayList([]const u8).init(b.allocator);
        for ([_][]const u8{ "src", "widgets" }) |dir_name| {
            var dir = std.fs.cwd().openDir(b.pathFromRoot(dir_name), .{ .iterate = true }) catch continue;
            defer dir.close();
            var walker = dir.walk(b.allocator) catch continue;
            defer walker.deinit();
            while (walker.next() catch null) |ent| {
                if (ent.kind != .file or !std.mem.endsWith(u8, ent.path, ".zig")) continue;
                files.append(b.fmt("{s}/{s}", .{ dir_name, ent.path })) catch {};
            }
        }
        files.append("anim/anim.odin") catch {};
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (files.items) |f| {
            refgen_run.addArg(f);
            refgen_run.addFileArg(b.path(f));
        }
    }
    site_wasm.root_module.addAnonymousImport("refpages", .{ .root_source_file = ref_out });
    // 学ぶページ(site/src/content/learn)は公開前なので、-Dlearn=true のときだけ入れる
    const site_opts = b.addOptions();
    site_opts.addOption(bool, "learn", b.option(bool, "learn", "サイトに学ぶページを入れる(公開前。既定は入れない)") orelse false);
    site_wasm.root_module.addOptions("site_options", site_opts);
    site_step.dependOn(&b.addInstallFile(site_wasm.getEmittedBin(), "site/site.wasm").step);
    const odin_site = b.addSystemCommand(&.{ "odin", "build" });
    odin_site.addDirectoryArg(b.path("anim"));
    odin_site.addArgs(&.{ "-target:freestanding_wasm32", "-build-mode:shared", "-no-entry-point", "-o:speed", "-no-bounds-check", "-default-to-nil-allocator" });
    const anim_site = odin_site.addPrefixedOutputFileArg("-out:", "anim.wasm");
    odin_site.addFileInput(b.path("anim/anim.odin"));
    site_step.dependOn(&b.addInstallFile(anim_site, "site/anim.wasm").step);
    site_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("site/static"), .install_dir = .prefix, .install_subdir = "site" }).step);
    site_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("site/media"), .install_dir = .prefix, .install_subdir = "site/media" }).step);

    // 既定設定・テーマを share に配置
    b.installDirectory(.{ .source_dir = b.path("data"), .install_dir = .{ .custom = "share/ame-shell" }, .install_subdir = "" });

    // --- マウスカーソルのテーマ "ame"(tools/cursorgen.zig が SVG を nanosvg で描いて Xcursor を書く)---
    // 古い名前は同じファイルへのシンボリックリンクなので、installDirectory(リンクを実体にして写す)を通さず
    // 生成器が share/icons/ame に直接書く(0.2 秒ほど。毎回作り直す)
    // 別の OS 向けに --libc を付けて試しビルドするときは作らない(--libc は手元で動かす生成器にも効いてしまい、
    // 生成器がリンクできない。その OS の上でビルドすれば作られる)
    const cross_libc = b.libc_file != null and target.result.os.tag != b.graph.host.result.os.tag;
    if (!cross_libc) {
        const cursorgen = b.addExecutable(.{ .name = "cursorgen", .root_source_file = b.path("tools/cursorgen.zig"), .target = b.graph.host, .optimize = .ReleaseFast });
        cursorgen.linkLibC();
        cursorgen.addIncludePath(b.path("third_party"));
        cursorgen.addCSourceFile(.{ .file = b.path("third_party/nanosvg_impl.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
        const cursor_run = b.addRunArtifact(cursorgen);
        cursor_run.addArg(b.getInstallPath(.prefix, "share/icons/ame"));
        b.getInstallStep().dependOn(&cursor_run.step);
    }

    // --- 実行とテスト ---
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "ame-shell を起動").dependOn(&run.step);

    const tests = b.addTest(.{ .root_source_file = b.path("src/pure_tests.zig"), .target = target, .optimize = optimize });
    tests.addObjectFile(anim_obj);
    tests.root_module.addImport("ame_lib", lib_mod);
    tests.linkLibC();
    const test_step = b.step("test", "純粋ロジックのテスト");
    // 書式もそろっているか(zig fmt --check)。そろっていなければ zig fmt <ファイル> で直す
    test_step.dependOn(&b.addFmt(.{ .paths = &.{ "src", "tools", "widgets", "site/src", "site/gen", "build.zig" }, .check = true }).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // 部品(src/lib)のテスト。名前付きのモジュールのテストは読み込む側からは走らないので、別に走らせる
    const lt = b.addTest(.{ .root_source_file = b.path("src/lib/lib.zig"), .target = target, .optimize = optimize });
    lt.linkLibC();
    test_step.dependOn(&b.addRunArtifact(lt).step);
    // クリップボードの道具のテスト
    const clip_t = b.addTest(.{ .root_source_file = b.path("src/cmd/ame-clip.zig"), .target = target, .optimize = optimize });
    clip_t.linkLibC();
    clip_t.addIncludePath(gen.getDirectory());
    for (proto_c.items) |c_file| clip_t.addCSourceFile(.{ .file = c_file, .flags = &.{"-std=c11"} });
    clip_t.linkSystemLibrary("wayland-client");
    test_step.dependOn(&b.addRunArtifact(clip_t).step);
    const rec_t = b.addTest(.{ .root_source_file = b.path("src/cmd/ame-rec.zig"), .target = target, .optimize = optimize });
    rec_t.linkLibC();
    rec_t.addIncludePath(gen.getDirectory());
    for (proto_c.items) |c_file| rec_t.addCSourceFile(.{ .file = c_file, .flags = &.{"-std=c11"} });
    rec_t.linkSystemLibrary("wayland-client");
    test_step.dependOn(&b.addRunArtifact(rec_t).step);
    const iwato_t = b.addTest(.{ .root_source_file = b.path("src/cmd/ame-iwato.zig"), .target = target, .optimize = optimize });
    iwato_t.linkLibC();
    iwato_t.addIncludePath(gen.getDirectory());
    for (proto_c.items) |c_file| iwato_t.addCSourceFile(.{ .file = c_file, .flags = &.{"-std=c11"} });
    iwato_t.linkSystemLibrary("wayland-client");
    iwato_t.linkSystemLibrary("xkbcommon");
    test_step.dependOn(&b.addRunArtifact(iwato_t).step);
    // Odin の道具のテスト(odin test)
    for (odin_cmds) |name| {
        if (!native) break;
        const ot = b.addSystemCommand(&.{ "odin", "test" });
        ot.addDirectoryArg(b.path(b.fmt("odin/{s}", .{name})));
        ot.addArg("-define:ODIN_TEST_LOG_LEVEL=warning");
        addOdinInputs(b, ot, name);
        test_step.dependOn(&ot.step);
    }
    // 小さな道具のテスト(引数の読み方など)
    for (cmds) |name| {
        const ct = b.addTest(.{ .root_source_file = b.path(b.fmt("src/cmd/{s}.zig", .{name})), .target = target, .optimize = optimize });
        ct.root_module.addImport("ame_lib", lib_mod);
        if (std.mem.eql(u8, name, "ame-handtrack")) ct.root_module.addImport("ame-hand", hand_dep.module("ame-hand"));
        if (usesDbus(name)) useDbus(b, ct, sr, pre, bsd);
        // ame-yatagarasu は暗号(TLS)だけ OpenSSL に任せる
        if (std.mem.eql(u8, name, "ame-yatagarasu")) {
            ct.linkSystemLibrary("ssl");
            ct.linkSystemLibrary("crypto");
        }
        ct.linkLibC();
        test_step.dependOn(&b.addRunArtifact(ct).step);
    }
}

/// anim/ を Odin でオブジェクトにし、Zig が読める `out_name` を返す。
/// Odin の dev-2026-07 nightly は `-out:anim.o` と渡しても `anim.obj` を書く
/// (出力先をディレクトリと誤認して拡張子を .obj に固定する不具合。dev-2026-08 で修正済み)。
/// どちらの Odin でも同じ名前にそろうよう、sh で包んで .obj を .o に直す。
fn addOdinObject(b: *std.Build, out_name: []const u8, flags: []const []const u8) std.Build.LazyPath {
    const odin = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -e
        \\out=$1
        \\dir=$2
        \\shift 2
        \\rm -f "$out" "${out%.*}.obj"
        \\odin build "$dir" "$@" -out:"$out"
        \\if [ ! -f "$out" ]; then
        \\    mv "${out%.*}.obj" "$out"
        \\fi
        ,
        "sh",
    });
    const out = odin.addOutputFileArg(out_name);
    odin.addDirectoryArg(b.path("anim"));
    odin.addArgs(flags);
    // ディレクトリ引数は中身の変更を追跡しないため、ソースを明示的に入力に加える。
    odin.addFileInput(b.path("anim/anim.odin"));
    odin.addFileInput(b.path("anim/fft.odin"));
    odin.addFileInput(b.path("anim/image.odin"));
    return out;
}

/// odin/<name>/ を Odin で実行ファイルにする
fn addOdinExe(b: *std.Build, name: []const u8) std.Build.LazyPath {
    const odin = b.addSystemCommand(&.{ "sh", "-c", "exec odin build \"$2\" -out:\"$1\" -o:speed", "sh" });
    const out = odin.addOutputFileArg(name);
    odin.addDirectoryArg(b.path(b.fmt("odin/{s}", .{name})));
    addOdinInputs(b, odin, name);
    return out;
}

/// ディレクトリ引数は中身の変更を追跡しないので、.odin を 1 つずつ入力に加える(道具が import する anim/ も)
fn addOdinInputs(b: *std.Build, run: *std.Build.Step.Run, name: []const u8) void {
    for ([_][]const u8{ b.fmt("odin/{s}", .{name}), "anim" }) |rel| {
        var dir = b.build_root.handle.openDir(rel, .{ .iterate = true }) catch @panic("Odin のフォルダが開けない");
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (std.mem.endsWith(u8, e.name, ".odin")) run.addFileInput(b.path(b.fmt("{s}/{s}", .{ rel, e.name })));
        }
    }
}

/// D-Bus を使う小さな道具(鍵束・明るさ・電源プロファイル)
fn usesDbus(name: []const u8) bool {
    for ([_][]const u8{ "ame-keyring", "amaterasu", "ame-tajikara" }) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// libdbus を使う(ヘッダの場所は ame-shell 本体と同じ。FreeBSD は pkg-config を使わない)
fn useDbus(b: *std.Build, step: *std.Build.Step.Compile, sr: []const u8, pre: []const u8, bsd: bool) void {
    for ([_][]const u8{ "/include/dbus-1.0", "/lib/dbus-1.0/include" }) |p| {
        step.addIncludePath(.{ .cwd_relative = b.fmt("{s}{s}{s}", .{ sr, pre, p }) });
    }
    if (bsd) {
        step.addIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/local/include", .{sr}) });
        step.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/local/lib", .{sr}) });
        if (sr.len > 0) {
            step.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sr}) });
            step.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sr}) });
            step.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{sr}) });
        }
        step.linkSystemLibrary2("dbus-1", .{ .use_pkg_config = .no });
    } else step.linkSystemLibrary("dbus-1");
}
