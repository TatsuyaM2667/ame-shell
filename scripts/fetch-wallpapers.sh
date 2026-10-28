#!/bin/sh
# fetch-wallpapers.sh [--quiet]: 追加の壁紙(画像・動画)を git で ~/.local/share/ame-shell/wallpapers に取ってくる。
# POSIX sh。壁紙の置き場は非公開リポジトリなので、GitHub にログインしていないと取れない(そのときは案内だけして終わる)。
#   リポジトリは AME_WALLPAPERS_REPO で変えられる。空にすると何もしない。
# install.sh / install-freebsd.sh / ame-update から、壁紙を使う本人の権限で呼ばれる。

REPO_URL="${AME_WALLPAPERS_REPO-https://github.com/TatsuyaM2667/ame-wallpapers}"
DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ame-shell/wallpapers"
QUIET=0
[ "$1" = --quiet ] && QUIET=1

info() { printf '    %s\n' "$*"; }
[ -n "$REPO_URL" ] || exit 0
command -v git >/dev/null 2>&1 || { info "(git が無いため追加の壁紙は取りません)"; exit 0; }

# パスワードを聞かれて止まらないように(ログインしていなければすぐ失敗させる)
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT

hint() {
    [ "$QUIET" = 1 ] && return
    info "(追加の壁紙は非公開リポジトリにあるため取れませんでした。使う場合は GitHub にログインしてから ame-update を実行してください:"
    if [ "$(uname -s)" = FreeBSD ]; then
        info "   pkg install gh && gh auth login && gh auth setup-git)"
    else
        info "   gh auth login && gh auth setup-git)"
    fi
}

if [ -d "$DIR/.git" ]; then
    if git -C "$DIR" pull --ff-only -q >/dev/null 2>&1; then
        info "追加の壁紙: 最新にしました($DIR)"
    else
        info "(追加の壁紙の更新に失敗しました。今のものをそのまま使います)"
    fi
elif [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
    info "(追加の壁紙: $DIR に git 管理ではないファイルがあるため、取ってきません)"
else
    mkdir -p "$(dirname "$DIR")"
    rmdir "$DIR" 2>/dev/null
    if git clone -q --depth 1 "$REPO_URL" "$DIR" >/dev/null 2>&1; then
        info "追加の壁紙を取ってきました($DIR)"
    else
        rm -rf "$DIR"
        hint
    fi
fi
exit 0
