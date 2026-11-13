#!/bin/sh
# 小さな道具(src/cmd/)を、それぞれ単独でビルドできるリポジトリとして切り出して push する。
# 正本は ame-shell(全部入り)。道具のリポジトリは ame-shell から生成するだけなので、直すときは ame-shell を直してから
# これを実行し直す(同期の commit には元の ame-shell の commit を書く)。
#
#   sh scripts/split-repos.sh [--dry-run] [道具の名前 ...]
#     --dry-run  作ってビルド・テストするだけ(push しない。作ったものは表示する場所に残る)
#   GitHub のリポジトリが無ければ gh で作る(公開)。要るもの: git, gh(ログイン済み), zig 0.13, odin
set -eu

OWNER=TatsuyaM2667
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Zig は 0.13(ame-shell と同じ)。ame-shell の install.sh が入れる場所にあればそれを使う
ZIG013=$HOME/.cache/ame-shell/toolchain/zig-linux-x86_64-0.13.0/zig
if [ -z "${ZIG:-}" ]; then
	if [ -x "$ZIG013" ]; then ZIG=$ZIG013; else ZIG=zig; fi
fi
DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi

# 名前|使う部品(src/lib のファイル名、空白区切り)|外部コマンド|ほかに要るもの(dbus = libdbus / ame-hand = 手の認識)|説明
COMPONENTS='ame-lyrics|lrc|curl||曲の同期歌詞(LRC)を探す小さなコマンド(LRCLIB・NetEase・Kugou、キャッシュつき)
ame-ai|ai mcp|ame-yatagarasu||いろいろな会社の AI と標準入出力で話す小さなコマンド(MCP のツール呼び出しつき)
ame-agent|agentfmt|||コーディング CLI(Claude Code・Gemini・Codex・OpenCode・Kimi)の出力を共通の JSON の行に直すフィルタ
ame-config|config|||ame-shell の設定ファイル(config.ame)の文法と値を確かめる小さなコマンド
ame-kuraokami|weather|ame-yatagarasu||今の天気を wttr.in から取ってくる小さなコマンド(文字 / JSON)
ame-airpods|aap|bluetoothctl||AirPods の頭の動き・電池を Bluetooth(AAP)で読む小さなコマンド(Linux)
ame-handtrack||ame-yatagarasu|ame-hand|カメラに映った手の形と位置・関節 21 点を JSON の行で流し続ける小さなコマンド(Linux)
ame-keyring|secretstore||dbus|鍵束(org.freedesktop.secrets)。アプリが API キー・パスワードをしまう Secret Service(gnome-keyring の代わり)
amaterasu|||dbus|画面の明るさを読む・変える・覚えて戻す小さなコマンド(brightnessctl の代わり。root なしで logind 経由)
ame-tajikara|||dbus|電源プロファイル(省電力・バランス・高性能)を読む・変える小さなコマンド(powerprofilesctl の代わり)
ame-uzume||libpulse||音量を読む・変える・消音・見張る小さなコマンド(Odin。wpctl・pactl subscribe の代わり)
ame-hamon|fft|libpulse-simple||今鳴っている音のスペクトラムを 1 行ずつ流す小さなコマンド(Odin。cava の代わり)
ame-yatagarasu|||ssl|URL の中身を取ってくる小さなコマンド(curl の代わり。curl と同じオプションを読む。暗号は OpenSSL)
ame-clip|ext-data-control-v1||wayland|Wayland のクリップボードに入れる・出す小さなコマンド ame-copy / ame-paste(wl-copy・wl-paste の代わり)
ame-emaki|ext-foreign-toplevel-list-v1 ext-image-capture-source-v1 ext-image-copy-capture-v1|ffmpeg|wayland|画面を動画に録る小さなコマンド(wf-recorder の代わり。名前は絵巻から)
ame-iwato|ext-session-lock-v1|libpam|wayland-xkb|画面をロックする小さなコマンド(swaylock の代わり。名前は天岩戸から)'

REV=$(git -C "$ROOT" rev-parse --short HEAD)
if [ -n "$(git -C "$ROOT" status --porcelain -- src/cmd src/lib odin anim)" ]; then
	echo "src/cmd・src/lib・odin・anim に commit していない変更があります。先に commit してください" >&2
	exit 1
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ame-split.XXXXXX")
[ "$DRY" = 1 ] || trap 'rm -rf "${WORK:?}"' EXIT

gen_build() { # $1 = 名前 $2 = ほかに要るもの
	x_dep=""
	x_exe=""
	x_test=""
	case "$2" in
	dbus)
		x_exe='
    exe.linkSystemLibrary("dbus-1");'
		x_test='
    t_main.linkSystemLibrary("dbus-1");'
		;;
	ssl)
		x_exe='
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");'
		x_test='
    t_main.linkSystemLibrary("ssl");
    t_main.linkSystemLibrary("crypto");'
		;;
	ame-hand)
		x_dep='
    const hand = b.dependency("ame_hand", .{ .target = target, .optimize = optimize });'
		x_exe='
    exe.root_module.addImport("ame-hand", hand.module("ame-hand"));'
		x_test='
    t_main.root_module.addImport("ame-hand", hand.module("ame-hand"));'
		;;
	esac
	cat <<EOF
// ame-shell(https://github.com/$OWNER/ame-shell)の src/cmd/$1.zig から生成。直すときは ame-shell の方を直す
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.createModule(.{ .root_source_file = b.path("src/lib/lib.zig") });$x_dep

    const exe = b.addExecutable(.{ .name = "$1", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe.root_module.addImport("ame_lib", lib);
    exe.linkLibC();$x_exe
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "$1 を実行する").dependOn(&run.step);

    const t_main = b.addTest(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    t_main.root_module.addImport("ame_lib", lib);
    t_main.linkLibC();$x_test
    const t_lib = b.addTest(.{ .root_source_file = b.path("src/lib/lib.zig"), .target = target, .optimize = optimize });
    t_lib.linkLibC();
    const ts = b.step("test", "テスト");
    ts.dependOn(&b.addRunArtifact(t_main).step);
    ts.dependOn(&b.addRunArtifact(t_lib).step);
}
EOF
}

gen_build_wayland() { # $1 = 名前 $2 = wayland / wayland-xkb $3 = プロトコルの XML("…", の並び)
	x_link='
    exe.linkSystemLibrary("wayland-client");'
	[ "$2" = wayland-xkb ] && x_link="$x_link
    exe.linkSystemLibrary(\"xkbcommon\");"
	exe=$1
	x_extra=""
	# ame-clip は ame-copy として入れ、同じものを ame-paste の名前でも入れる(呼ばれた名前で動きを変える)
	if [ "$1" = ame-clip ]; then
		exe=ame-copy
		x_extra='
            b.getInstallStep().dependOn(&b.addInstallBinFile(exe.getEmittedBin(), "ame-paste").step);'
	fi
	cat <<EOF
// ame-shell(https://github.com/$OWNER/ame-shell)の src/cmd/$1.zig から生成。直すときは ame-shell の方を直す
const std = @import("std");

const protocols = [_][]const u8{$3 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // プロトコルの XML から C のヘッダと glue を作り、1 つのフォルダに集める
    const gen = b.addWriteFiles();
    var proto_c = std.ArrayList(std.Build.LazyPath).init(b.allocator);
    for (protocols) |xml| {
        const base = std.fs.path.stem(xml);
        const hdr = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        hdr.addFileArg(b.path(xml));
        _ = gen.addCopyFile(hdr.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{base})), b.fmt("{s}-client-protocol.h", .{base}));
        const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code.addFileArg(b.path(xml));
        proto_c.append(code.addOutputFileArg(b.fmt("{s}-protocol.c", .{base}))) catch @panic("oom");
    }
    for ([_]bool{ false, true }) |is_test| {
        const exe = if (is_test)
            b.addTest(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize })
        else
            b.addExecutable(.{ .name = "$exe", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
        exe.linkLibC();
        exe.addIncludePath(gen.getDirectory());
        for (proto_c.items) |f| exe.addCSourceFile(.{ .file = f, .flags = &.{"-std=c11"} });$x_link
        if (is_test) {
            b.step("test", "テスト").dependOn(&b.addRunArtifact(exe).step);
        } else {
            b.installArtifact(exe);$x_extra
        }
    }
}
EOF
}

gen_zon() { # $1 = 名前 $2 = ほかに要るもの
	deps=".{}"
	# 手の認識(ame-hand)は ame-shell と同じ版を使う
	if [ "$2" = ame-hand ]; then
		deps=".{
$(awk '/\.ame_hand = \.\{/,/\},/' "$ROOT/build.zig.zon")
    }"
	fi
	cat <<EOF
.{
    .name = "$1",
    .version = "0.1.0",
    .minimum_zig_version = "0.13.0",
    .dependencies = $deps,
    .paths = .{ "build.zig", "build.zig.zon", "src", "LICENSE", "README.md" },
}
EOF
}

gen_lib() { # $@ = 部品
	echo "// ame-shell の src/lib から、この道具が使う部品だけを持ってきたもの(生成。直すときは ame-shell の方を直す)"
	for m in "$@"; do echo "pub const $m = @import(\"$m.zig\");"; done
	echo
	echo "test {"
	for m in "$@"; do echo "    _ = $m;"; done
	echo "}"
}

gen_readme() { # $1 名前 $2 説明 $3 外部コマンド $4 ほかに要るもの
	echo "# $1"
	echo
	echo "$2。"
	echo
	echo "[ame-shell](https://github.com/$OWNER/ame-shell)(Wayland のデスクトップシェル)の一部を、単独で使えるように切り出したものです。"
	echo "ame-shell は画面の要らない仕事を、1 つのことをして標準入出力でやりとりする小さなコマンドに分けています。これはその 1 つです。"
	echo
	echo "## 使い方"
	echo
	echo '```text'
	# 道具のファイルの先頭の説明(// の行)をそのまま
	sed -n '/^\/\//!q; s|^// \{0,1\}||p' "$5"
	echo '```'
	echo
	echo "## ビルド"
	echo
	echo '```sh'
	case "$4" in
	odin) echo "sh build.sh   # ./$1(Odin dev-2026-08 以降。libpulse などは実行時に読むので、ヘッダも -dev パッケージも要らない)" ;;
	wayland) echo "zig build -Doptimize=ReleaseSafe   # zig-out/bin(Zig 0.13、libc・wayland-client・wayland-scanner)" ;;
	wayland-xkb) echo "zig build -Doptimize=ReleaseSafe   # zig-out/bin/$1(Zig 0.13、libc・wayland-client・xkbcommon・wayland-scanner)" ;;
	dbus) echo "zig build -Doptimize=ReleaseSafe   # zig-out/bin/$1(Zig 0.13、libc と libdbus)" ;;
	ssl) echo "zig build -Doptimize=ReleaseSafe   # zig-out/bin/$1(Zig 0.13、libc と OpenSSL の libssl)" ;;
	ame-hand) echo "zig build -Doptimize=ReleaseSafe   # zig-out/bin/$1(Zig 0.13、libc。手の認識の ame-hand は初回に取ってくる)" ;;
	*) echo "zig build -Doptimize=ReleaseSafe   # zig-out/bin/$1(Zig 0.13、libc だけ)" ;;
	esac
	if [ "$4" = odin ]; then echo "odin test ."; else echo "zig build test"; fi
	echo '```'
	if [ -n "$3" ]; then
		echo
		echo "実行に要るもの: \`$3\`"
	fi
	echo
	echo "## このリポジトリについて"
	echo
	echo "正本は ame-shell の \`${5#"$ROOT"/}\` です。このリポジトリは \`scripts/split-repos.sh\` が生成して同期しています。"
	echo "直したいところがあれば ame-shell の方へお願いします。"
	echo
	echo "ライセンス: GPL-3.0(ame-shell と同じ)"
}

echo "$COMPONENTS" | while IFS='|' read -r name mods needs extra desc; do
	if [ $# -gt 0 ]; then
		want=0
		for x in "$@"; do [ "$x" = "$name" ] && want=1; done
		[ "$want" = 1 ] || continue
	fi
	echo "== $name"
	dir="$WORK/$name"
	url="https://github.com/$OWNER/$name.git"
	exists=0
	if gh repo view "$OWNER/$name" >/dev/null 2>&1; then exists=1; fi
	if [ "$exists" = 1 ]; then
		git clone -q "$url" "$dir"
		# 生成するものは全部作り直す(.git 以外を消す)
		find "$dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
	else
		mkdir -p "$dir"
		git -C "$dir" init -q -b master
	fi
	if [ -d "$ROOT/odin/$name" ]; then
		# Odin の道具(odin/<名前>/)。使う部品(fft など)は anim/ から anim/ へ写し、import の場所を直す
		cp "$ROOT/odin/$name"/*.odin "$dir/"
		if [ -n "$mods" ]; then
			mkdir -p "$dir/anim"
			for m in $mods; do cp "$ROOT/anim/$m.odin" "$dir/anim/$m.odin"; done
			sed 's|import anim "../../anim"|import anim "anim"|' "$dir/main.odin" > "$dir/main.odin.tmp" && mv "$dir/main.odin.tmp" "$dir/main.odin"
		fi
		printf '#!/bin/sh\n# %s をビルドする(POSIX sh。Odin dev-2026-08 以降)\nset -eu\ncd "$(dirname "$0")"\nexec odin build . -out:%s -o:speed "$@"\n' "$name" "$name" > "$dir/build.sh"
		chmod +x "$dir/build.sh"
		gen_readme "$name" "$desc" "$needs" odin "$ROOT/odin/$name/main.odin" > "$dir/README.md"
		printf '%s\n' "$name" > "$dir/.gitignore"
		check="sh build.sh && odin test . -define:ODIN_TEST_LOG_LEVEL=warning"
		clean="$name"
	elif [ "$extra" = wayland ] || [ "$extra" = wayland-xkb ]; then
		# Wayland の道具: 使うプロトコルの XML を写し、ビルドのときに wayland-scanner で C にする(部品の欄 = プロトコル)
		src="$ROOT/src/cmd/$name.zig"
		[ "$name" = ame-clip ] || [ -f "$src" ] || { echo "$name: $src がありません" >&2; exit 1; }
		mkdir -p "$dir/src" "$dir/protocol"
		cp "$src" "$dir/src/main.zig"
		plist=""
		for m in $mods; do cp "$ROOT/protocol/$m.xml" "$dir/protocol/$m.xml"; plist="$plist \"protocol/$m.xml\","; done
		gen_build_wayland "$name" "$extra" "$plist" > "$dir/build.zig"
		gen_zon "$name" "" > "$dir/build.zig.zon"
		sed 's/"build.zig", "build.zig.zon", "src",/"build.zig", "build.zig.zon", "src", "protocol",/' "$dir/build.zig.zon" > "$dir/zon.tmp" && mv "$dir/zon.tmp" "$dir/build.zig.zon"
		gen_readme "$name" "$desc" "$needs" "$extra" "$src" > "$dir/README.md"
		printf '.zig-cache/\nzig-out/\n' > "$dir/.gitignore"
		check='"$ZIG" build && "$ZIG" build test'
		clean=".zig-cache zig-out"
	else
		mkdir -p "$dir/src/lib"
		cp "$ROOT/src/cmd/$name.zig" "$dir/src/main.zig"
		# D-Bus の道具は共通の包み(sysbus.zig)も
		if grep -q '@import("sysbus.zig")' "$ROOT/src/cmd/$name.zig"; then cp "$ROOT/src/cmd/sysbus.zig" "$dir/src/sysbus.zig"; fi
		# shellcheck disable=SC2086
		for m in $mods; do cp "$ROOT/src/lib/$m.zig" "$dir/src/lib/$m.zig"; done
		# shellcheck disable=SC2086
		gen_lib $mods > "$dir/src/lib/lib.zig"
		gen_build "$name" "$extra" > "$dir/build.zig"
		gen_zon "$name" "$extra" > "$dir/build.zig.zon"
		gen_readme "$name" "$desc" "$needs" "$extra" "$ROOT/src/cmd/$name.zig" > "$dir/README.md"
		printf '.zig-cache/\nzig-out/\n' > "$dir/.gitignore"
		check='"$ZIG" build && "$ZIG" build test'
		clean=".zig-cache zig-out"
	fi
	cp "$ROOT/LICENSE" "$dir/LICENSE"

	# 単独でビルド・テストできることを確かめてから
	(cd "$dir" && eval "$check") || { echo "$name: ビルドかテストに失敗しました" >&2; exit 1; }
	for x in $clean; do rm -rf "${dir:?}/$x"; done

	git -C "$dir" add -A
	if git -C "$dir" diff --cached --quiet; then
		echo "$name: 変更なし"
		continue
	fi
	git -C "$dir" commit -q -m "ame-shell $REV と同期

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
	if [ "$DRY" = 1 ]; then
		echo "$name: $dir に作りました(--dry-run なので push しません)"
		continue
	fi
	if [ "$exists" = 0 ]; then
		gh repo create "$OWNER/$name" --public --description "$desc(ame-shell から切り出し)" --source "$dir" --push
	else
		git -C "$dir" push -q origin HEAD:master
	fi
	echo "$name: https://github.com/$OWNER/$name"
done
