#!/bin/sh
# deploy.sh: ドキュメントサイトをビルドして Cloudflare Pages に公開する。POSIX sh + curl だけ(Node・wrangler は使わない)。
#   sh site/deploy.sh                 本番(https://<プロジェクト名>.pages.dev)
#   sh site/deploy.sh --preview       プレビュー用のブランチに公開(本番は変えない)
#   sh site/deploy.sh --dry-run       ビルドして、送るファイルの一覧(manifest)を出すだけ。通信しない
#
# 必要なもの: zig 0.13・odin(ビルド)、curl、base64、sha256sum か sha256
# Cloudflare の API トークンとアカウント ID を環境変数で渡す:
#   CLOUDFLARE_API_TOKEN   ダッシュボードの「My Profile → API Tokens → Create Token」で、
#                          権限「Account → Cloudflare Pages → Edit」を付けて作る
#   CLOUDFLARE_ACCOUNT_ID  ダッシュボードの右側(Workers & Pages の概要)に出る 32 桁の ID
#   ファイル ~/.config/ame-shell/cloudflare に `CLOUDFLARE_API_TOKEN=…` 等を書いておけば、それを読む(chmod 600 で)
# プロジェクト名は AME_PAGES_PROJECT(既定 ame-shell)。無ければ作る。
#
# 手順は wrangler の「直接アップロード」と同じ:
#   1. プロジェクトを確かめる(無ければ作る)  2. アップロード用のトークン(JWT)をもらう
#   3. まだ置かれていないファイルを聞き、それだけ送る  4. manifest(パス → ハッシュ)でデプロイを作る

set -eu
case "$0" in */*) HERE=$(cd "$(dirname "$0")" && pwd) ;; *) HERE=$(pwd) ;; esac
REPO=$(cd "$HERE/.." && pwd)
PROJECT="${AME_PAGES_PROJECT:-ame-shell}"
BRANCH=main
DRY=0
for a in "$@"; do
    case "$a" in
        --preview) BRANCH=preview ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "知らない引数: $a" >&2; exit 2 ;;
    esac
done

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ame-shell/cloudflare"
if [ -f "$CONF" ]; then . "$CONF"; fi

command -v curl >/dev/null 2>&1 || { echo "curl がありません" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
    sha() { sha256sum | cut -d' ' -f1; }
elif command -v sha256 >/dev/null 2>&1; then
    sha() { sha256 -q; }
else
    echo "sha256sum / sha256 がありません" >&2; exit 1
fi

# Zig 0.13 と Odin: PATH に無ければ、インストーラが用意した場所(ame-update と同じ)
ZIG=""
for z in "$(command -v zig 2>/dev/null)" /usr/local/ame-toolchain/zig-0.13.0/bin/zig "$HOME/.cache/ame-shell/toolchain/zig-linux-$(uname -m)-0.13.0/zig"; do
    [ -n "$z" ] && [ -x "$z" ] && [ "$("$z" version 2>/dev/null)" = 0.13.0 ] && { ZIG=$z; break; }
done
[ -n "$ZIG" ] || { echo "Zig 0.13 が見つかりません(sh install.sh で用意されます)" >&2; exit 1; }
for o in "$(command -v odin 2>/dev/null)" /usr/local/ame-toolchain/odin-dev-2026-08/odin "$HOME/.cache/ame-shell/toolchain/odin-dev-2026-08/odin"; do
    [ -n "$o" ] && [ -x "$o" ] && { PATH="$(dirname "$o"):$PATH"; export PATH; break; }
done

echo "==> ビルド(zig build site)"
(cd "$REPO" && "$ZIG" build site)
OUT="$REPO/zig-out/site"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ame-deploy.XXXXXX")
trap 'rm -rf "${TMP:?}"' EXIT INT TERM

ctype() {
    case "$1" in
        *.html) echo "text/html; charset=utf-8" ;;
        *.css) echo "text/css; charset=utf-8" ;;
        *.js) echo "application/javascript" ;;
        *.wasm) echo "application/wasm" ;;
        *.svg) echo "image/svg+xml" ;;
        *.png) echo "image/png" ;;
        *.jpg|*.jpeg) echo "image/jpeg" ;;
        *.mp4) echo "video/mp4" ;;
        *.json) echo "application/json" ;;
        *.txt|*.md) echo "text/plain; charset=utf-8" ;;
        *) echo "application/octet-stream" ;;
    esac
}

# ファイルの一覧: 「ハッシュ パス」を files に。ハッシュは中身(base64)+ 拡張子の sha256 の先頭 32 桁
# (wrangler は blake3 だが、Pages はハッシュを中身の鍵として使うだけ。同じ中身なら同じ鍵になればよい)
: > "$TMP/files"
(cd "$OUT" && find . -type f) | sed 's|^\./||' | sort | while IFS= read -r p; do
    ext=${p##*.}
    h=$({ base64 < "$OUT/$p" | tr -d '\n'; printf '%s' "$ext"; } | sha | cut -c1-32)
    printf '%s %s\n' "$h" "$p" >> "$TMP/files"
done
n=$(wc -l < "$TMP/files" | tr -d ' ')

# manifest: {"/index.html":"<hash>", …}
{
    printf '{'
    first=1
    while read -r h p; do
        [ "$first" = 1 ] || printf ','
        first=0
        printf '"/%s":"%s"' "$p" "$h"
    done < "$TMP/files"
    printf '}'
} > "$TMP/manifest.json"
echo "    $n 個のファイル"

if [ "$DRY" = 1 ]; then
    cat "$TMP/manifest.json"; echo
    echo "==> --dry-run なので送りません"
    exit 0
fi

[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "CLOUDFLARE_API_TOKEN がありません(このファイルの先頭の説明を見てください)" >&2; exit 1; }
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || { echo "CLOUDFLARE_ACCOUNT_ID がありません(このファイルの先頭の説明を見てください)" >&2; exit 1; }

API="https://api.cloudflare.com/client/v4"
ACC="$API/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects"
# トークンはコマンドラインに出さない(ps で見えるため)。ヘッダはファイルから読ませる
umask 077
printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN" > "$TMP/h_api"

# 返事が success:true でなければ、errors を出して止める
ok() {
    if tr -d ' \n' < "$1" | grep -q '"success":true'; then return 0; fi
    echo "失敗しました($2):" >&2
    tr -d '\n' < "$1" | sed 's/.*"errors":\(\[[^]]*\]\).*/\1/' >&2; echo >&2
    exit 1
}

echo "==> Pages のプロジェクト: $PROJECT"
code=$(curl -sS -o "$TMP/r" -w '%{http_code}' -H @"$TMP/h_api" "$ACC/$PROJECT")
if [ "$code" = 404 ]; then
    echo "    無いので作ります(本番のブランチ: main)"
    curl -sS -o "$TMP/r" -H @"$TMP/h_api" -H 'Content-Type: application/json' \
        --data "{\"name\":\"$PROJECT\",\"production_branch\":\"main\"}" "$ACC"
    ok "$TMP/r" "プロジェクトの作成"
else
    ok "$TMP/r" "プロジェクトの確認(HTTP $code)"
fi

echo "==> アップロード用のトークン"
curl -sS -o "$TMP/r" -H @"$TMP/h_api" "$ACC/$PROJECT/upload-token"
ok "$TMP/r" "upload-token"
jwt=$(tr -d ' \n' < "$TMP/r" | sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p')
[ -n "$jwt" ] || { echo "トークンを読めませんでした" >&2; exit 1; }
printf 'Authorization: Bearer %s\n' "$jwt" > "$TMP/h_jwt"

echo "==> まだ置かれていないファイルを確かめる"
{
    printf '{"hashes":['
    first=1
    while read -r h _; do
        [ "$first" = 1 ] || printf ','
        first=0
        printf '"%s"' "$h"
    done < "$TMP/files"
    printf ']}'
} > "$TMP/hashes.json"
curl -sS -o "$TMP/r" -H @"$TMP/h_jwt" -H 'Content-Type: application/json' \
    --data-binary @"$TMP/hashes.json" "$API/pages/assets/check-missing"
ok "$TMP/r" "check-missing"
tr -d ' \n' < "$TMP/r" | sed -n 's/.*"result":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | tr -d '"' | grep . > "$TMP/missing" || :
m=$(wc -l < "$TMP/missing" | tr -d ' ')
echo "    送るもの: $m / $n"

# 1 ファイルずつ送る(大きい動画でも 1 回の送信が Pages の上限 25MiB を超えないように)
while read -r h; do
    p=$(grep "^$h " "$TMP/files" | head -n 1 | cut -d' ' -f2-)
    [ -n "$p" ] || continue
    printf '    %s\n' "$p"
    {
        printf '[{"key":"%s","value":"' "$h"
        base64 < "$OUT/$p" | tr -d '\n'
        printf '","metadata":{"contentType":"%s"},"base64":true}]' "$(ctype "$p")"
    } > "$TMP/upload.json"
    curl -sS -o "$TMP/r" -H @"$TMP/h_jwt" -H 'Content-Type: application/json' \
        --data-binary @"$TMP/upload.json" "$API/pages/assets/upload"
    ok "$TMP/r" "upload: $p"
done < "$TMP/missing"

curl -sS -o "$TMP/r" -H @"$TMP/h_jwt" -H 'Content-Type: application/json' \
    --data-binary @"$TMP/hashes.json" "$API/pages/assets/upsert-hashes"
ok "$TMP/r" "upsert-hashes"

echo "==> 公開($BRANCH)"
hash=$(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo "")
msg=$(cd "$REPO" && git log -1 --format=%s 2>/dev/null || echo "deploy")
curl -sS -o "$TMP/r" -H @"$TMP/h_api" \
    -F "manifest=<$TMP/manifest.json" --form-string "branch=$BRANCH" \
    --form-string "commit_hash=$hash" --form-string "commit_message=$msg" --form-string "commit_dirty=true" \
    "$ACC/$PROJECT/deployments"
ok "$TMP/r" "deployments"
url=$(tr -d ' \n' < "$TMP/r" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
echo "    できました: ${url:-https://$PROJECT.pages.dev}"
[ "$BRANCH" = main ] && echo "    本番: https://$PROJECT.pages.dev"
exit 0
