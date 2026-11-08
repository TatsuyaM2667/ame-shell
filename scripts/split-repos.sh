#!/bin/sh
# 小さな道具(src/cmd/)を、それぞれ単独でビルドできるリポジトリとして切り出して push する。
# 正本は ame-shell(全部入り)。道具のリポジトリは ame-shell から生成するだけなので、直すときは ame-shell を直してから
# これを実行し直す(同期の commit には元の ame-shell の commit を書く)。
#
#   sh scripts/split-repos.sh [--dry-run] [道具の名前 ...]
#     --dry-run  作ってビルド・テストするだけ(push しない。作ったものは表示する場所に残る)
#   GitHub のリポジトリが無ければ gh で作る(公開)。要るもの: git, gh(ログイン済み), zig
set -eu

OWNER=TatsuyaM2667
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi

# 名前|使う部品(src/lib のファイル名、空白区切り)|外部コマンド|説明
COMPONENTS='ame-lyrics|lrc|curl|曲の同期歌詞(LRC)を探す小さなコマンド(LRCLIB・NetEase・Kugou、キャッシュつき)
ame-ai|ai mcp|curl|いろいろな会社の AI と標準入出力で話す小さなコマンド(MCP のツール呼び出しつき)
ame-agent|agentfmt||コーディング CLI(Claude Code・Gemini・Codex・OpenCode・Kimi)の出力を共通の JSON の行に直すフィルタ
ame-config|config||ame-shell の設定ファイル(config.ame)の文法と値を確かめる小さなコマンド'

REV=$(git -C "$ROOT" rev-parse --short HEAD)
if [ -n "$(git -C "$ROOT" status --porcelain -- src/cmd src/lib)" ]; then
	echo "src/cmd か src/lib に commit していない変更があります。先に commit してください" >&2
	exit 1
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ame-split.XXXXXX")
[ "$DRY" = 1 ] || trap 'rm -rf "${WORK:?}"' EXIT

gen_build() { # $1 = 名前
	cat <<EOF
// ame-shell(https://github.com/$OWNER/ame-shell)の src/cmd/$1.zig から生成。直すときは ame-shell の方を直す
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.createModule(.{ .root_source_file = b.path("src/lib/lib.zig") });

    const exe = b.addExecutable(.{ .name = "$1", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe.root_module.addImport("ame_lib", lib);
    exe.linkLibC();
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "$1 を実行する").dependOn(&run.step);

    const t_main = b.addTest(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    t_main.root_module.addImport("ame_lib", lib);
    t_main.linkLibC();
    const t_lib = b.addTest(.{ .root_source_file = b.path("src/lib/lib.zig"), .target = target, .optimize = optimize });
    t_lib.linkLibC();
    const ts = b.step("test", "テスト");
    ts.dependOn(&b.addRunArtifact(t_main).step);
    ts.dependOn(&b.addRunArtifact(t_lib).step);
}
EOF
}

gen_zon() {
	cat <<EOF
.{
    .name = "$1",
    .version = "0.1.0",
    .minimum_zig_version = "0.13.0",
    .dependencies = .{},
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

gen_readme() { # $1 名前 $2 説明 $3 外部コマンド
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
	sed -n '/^\/\//!q; s|^// \{0,1\}||p' "$ROOT/src/cmd/$1.zig"
	echo '```'
	echo
	echo "## ビルド"
	echo
	echo '```sh'
	echo "zig build -Doptimize=ReleaseSafe   # zig-out/bin/$1(Zig 0.13、libc だけ)"
	echo "zig build test"
	echo '```'
	if [ -n "$3" ]; then
		echo
		echo "実行に要るもの: \`$3\`"
	fi
	echo
	echo "## このリポジトリについて"
	echo
	echo "正本は ame-shell の \`src/cmd/$1.zig\` と \`src/lib/\` です。このリポジトリは \`scripts/split-repos.sh\` が生成して同期しています。"
	echo "直したいところがあれば ame-shell の方へお願いします。"
	echo
	echo "ライセンス: GPL-3.0(ame-shell と同じ)"
}

echo "$COMPONENTS" | while IFS='|' read -r name mods needs desc; do
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
	mkdir -p "$dir/src/lib"
	cp "$ROOT/src/cmd/$name.zig" "$dir/src/main.zig"
	# shellcheck disable=SC2086
	for m in $mods; do cp "$ROOT/src/lib/$m.zig" "$dir/src/lib/$m.zig"; done
	# shellcheck disable=SC2086
	gen_lib $mods > "$dir/src/lib/lib.zig"
	gen_build "$name" > "$dir/build.zig"
	gen_zon "$name" > "$dir/build.zig.zon"
	gen_readme "$name" "$desc" "$needs" > "$dir/README.md"
	cp "$ROOT/LICENSE" "$dir/LICENSE"
	printf '.zig-cache/\nzig-out/\n' > "$dir/.gitignore"

	# 単独でビルド・テストできることを確かめてから
	(cd "$dir" && zig build && zig build test) || { echo "$name: ビルドかテストに失敗しました" >&2; exit 1; }
	rm -rf "${dir:?}/.zig-cache" "${dir:?}/zig-out"

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
