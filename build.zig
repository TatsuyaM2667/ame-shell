// ame-shell のビルド定義。`zig build` 一発で完結させる(CMake/Make/Meson を使わない)。
//
// 生成物:
//   zig-out/bin/ame-shell   … シェル本体(デーモン)
//   zig-out/bin/ame-ctl     … 制御CLI(Unixソケット経由)
//   zig-out/share/ame-shell/widgets/*.wasm … WASMウィジェット
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
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const odin_target = switch (target.result.cpu.arch) {
        .aarch64 => "-target:linux_arm64",
        else => "-target:linux_amd64",
    };
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

    // --- wasm3: WASM ウィジェットの実行ランタイム(C, MIT) ---
    const wasm3_files = [_][]const u8{
        "m3_bind.c", "m3_code.c",   "m3_compile.c", "m3_core.c",     "m3_emit.c",  "m3_env.c",
        "m3_exec.c", "m3_function.c", "m3_info.c",  "m3_module.c", "m3_optimize.c", "m3_parse.c",
    };

    // --- シェル本体 ---
    const exe = b.addExecutable(.{
        .name = "ame-shell",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug, // リリースはデバッグ情報を落として小さく
    });
    exe.linkLibC();
    exe.addIncludePath(gen.getDirectory());
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/dbus-1.0" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/lib/dbus-1.0/include" });
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
    exe.addObjectFile(anim_obj);
    for ([_][]const u8{ "wayland-client", "wayland-egl", "EGL", "GLESv2", "xkbcommon", "freetype", "harfbuzz", "fontconfig", "dbus-1" }) |lib| {
        exe.linkSystemLibrary(lib);
    }
    b.installArtifact(exe);

    // --- 制御CLI(libc のみ。軽量に保つ) ---
    const ctl = b.addExecutable(.{
        .name = "ame-ctl",
        .root_source_file = b.path("src/ctl.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    ctl.linkLibC();
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

    // 既定設定・テーマを share に配置
    b.installDirectory(.{ .source_dir = b.path("data"), .install_dir = .{ .custom = "share/ame-shell" }, .install_subdir = "" });

    // --- 実行とテスト ---
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "ame-shell を起動").dependOn(&run.step);

    const tests = b.addTest(.{ .root_source_file = b.path("src/pure_tests.zig"), .target = target, .optimize = optimize });
    tests.addObjectFile(anim_obj);
    tests.linkLibC();
    b.step("test", "純粋ロジックのテスト").dependOn(&b.addRunArtifact(tests).step);
}
