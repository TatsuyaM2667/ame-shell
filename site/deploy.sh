#!/bin/sh
# deploy.sh: ドキュメントサイトをビルドして Cloudflare Pages に公開する。POSIX sh。
#   sh site/deploy.sh                 本番(https://<プロジェクト名>.pages.dev)
#   sh site/deploy.sh --preview       プレビュー用のブランチに公開(本番は変えない)
# 必要なもの: zig 0.13・odin(ビルド)、npx(wrangler を実行するため。サイト自体は Node を使わない)
# 初回は Cloudflare へのログインが必要: npx wrangler login
#   プロジェクト名は AME_PAGES_PROJECT(既定 ame-shell)。無ければ作る。

set -eu
case "$0" in */*) HERE=$(cd "$(dirname "$0")" && pwd) ;; *) HERE=$(pwd) ;; esac
REPO=$(cd "$HERE/.." && pwd)
PROJECT="${AME_PAGES_PROJECT:-ame-shell}"
BRANCH=main
[ "${1:-}" = --preview ] && BRANCH=preview
WRANGLER="npx --yes wrangler@4"

command -v npx >/dev/null 2>&1 || { echo "npx がありません(wrangler の実行に使います)" >&2; exit 1; }

echo "==> ビルド(zig build site)"
(cd "$REPO" && zig build site)
OUT="$REPO/zig-out/site"
ls -l "$OUT/site.wasm" "$OUT/anim.wasm" | awk '{print "    " $NF ": " $5 " バイト"}'

echo "==> Cloudflare のアカウント"
if ! $WRANGLER whoami 2>/dev/null | grep -qi 'logged in'; then
    echo "    ログインしていません。先に実行してください: npx wrangler login" >&2
    exit 1
fi

echo "==> Pages のプロジェクト: $PROJECT"
if ! $WRANGLER pages project list 2>/dev/null | grep -q " $PROJECT "; then
    $WRANGLER pages project create "$PROJECT" --production-branch main
fi

echo "==> 公開($BRANCH)"
$WRANGLER pages deploy "$OUT" --project-name "$PROJECT" --branch "$BRANCH" --commit-dirty=true
