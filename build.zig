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
    const odin = b.addSystemCommand(&.{ "odin", "build" });
    odin.addDirectoryArg(b.path("anim"));
    odin.addArgs(&.{
        "-build-mode:obj",  "-no-entry-point",           "-o:speed",
        "-no-bounds-check", "-default-to-nil-allocator", "-no-thread-local",
        "-reloc-mode:pic",  odin_target,
    });
    const anim_obj = odin.addPrefixedOutputFileArg("-out:", "anim.o");
    // ディレクトリ引数は中身の変更を追跡しないため、ソースを明示的に入力に加える。
    odin.addFileInput(b.path("anim/anim.odin"));

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
    const tools = b.step("tools", "試験用ツール");
    tools.dependOn(&b.addInstallArtifact(vptr, .{}).step);
    tools.dependOn(&b.addInstallArtifact(vkbd, .{}).step);

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

    // --- WASM ウィジェット(Zig → wasm32-freestanding) ---
    // アニメーションコアは同じ Odin ソースを wasm32 にもビルドしてウィジェットへリンクする。
    const odin_wasm = b.addSystemCommand(&.{ "odin", "build" });
    odin_wasm.addDirectoryArg(b.path("anim"));
    odin_wasm.addArgs(&.{ "-build-mode:obj", "-no-entry-point", "-o:size", "-no-bounds-check", "-default-to-nil-allocator", "-target:freestanding_wasm32" });
    const anim_wasm = odin_wasm.addPrefixedOutputFileArg("-out:", "anim_wasm.o");
    odin_wasm.addFileInput(b.path("anim/anim.odin"));
    const abi_mod = b.createModule(.{ .root_source_file = b.path("src/widget_abi.zig") });
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
    const cursorgen = b.addExecutable(.{ .name = "cursorgen", .root_source_file = b.path("tools/cursorgen.zig"), .target = b.graph.host, .optimize = .ReleaseFast });
    cursorgen.linkLibC();
    cursorgen.addIncludePath(b.path("third_party"));
    cursorgen.addCSourceFile(.{ .file = b.path("third_party/nanosvg_impl.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
    const cursor_run = b.addRunArtifact(cursorgen);
    cursor_run.addArg(b.getInstallPath(.prefix, "share/icons/ame"));
    b.getInstallStep().dependOn(&cursor_run.step);

    // --- 実行とテスト ---
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "ame-shell を起動").dependOn(&run.step);

    const tests = b.addTest(.{ .root_source_file = b.path("src/pure_tests.zig"), .target = target, .optimize = optimize });
    tests.addObjectFile(anim_obj);
    tests.linkLibC();
    b.step("test", "純粋ロジックのテスト").dependOn(&b.addRunArtifact(tests).step);
}
