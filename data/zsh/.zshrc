# ame-shell の zsh の設定(ame-term-shell が、自分の ~/.zshrc が無いときに ZDOTDIR でこれを読ませる)。
# 自分で書き換えたいときは: cp この ファイル ~/.zshrc(以後は ~/.zshrc だけが使われる)
#
#  - プロンプト: 2 行。場所・git のブランチと状態・実行にかかった時間・終了コード・時刻
#  - 補完: 矢印で選べるメニュー、大文字小文字を区別しない、色付き
#  - 履歴: 5 万件・重複なし・窓の間で共有、↑↓ で入力中の文字から始まる履歴をさかのぼる
#  - あれば使うもの: zsh-autosuggestions(灰色の候補)・zsh-syntax-highlighting(色分け)・
#    fzf(Ctrl+R の履歴検索)・zoxide(z で移動)・eza(アイコン付きの ls)・bat

# ---- 置き場(ZDOTDIR は読み取り専用の場所なので、書くものはホームの下へ)----
: ${XDG_STATE_HOME:=$HOME/.local/state}
: ${XDG_CACHE_HOME:=$HOME/.cache}
mkdir -p "$XDG_STATE_HOME/zsh" "$XDG_CACHE_HOME/zsh" 2>/dev/null

# ---- 履歴 ----
HISTFILE="$XDG_STATE_HOME/zsh/history"
HISTSIZE=50000
SAVEHIST=50000
setopt share_history hist_ignore_all_dups hist_ignore_space hist_reduce_blanks extended_history

# ---- 基本 ----
setopt auto_cd auto_pushd pushd_ignore_dups interactive_comments no_beep prompt_subst
bindkey -e
WORDCHARS=${WORDCHARS//[\/.-]/}

# ---- 補完 ----
autoload -Uz compinit
compinit -d "$XDG_CACHE_HOME/zsh/zcompdump-$ZSH_VERSION"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{#7ab8ff}── %d ──%f'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "$XDG_CACHE_HOME/zsh/compcache"

# ---- キー ----
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[OA' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
bindkey '^[OB' down-line-or-beginning-search
bindkey '^[[1;5C' forward-word      # Ctrl+→
bindkey '^[[1;5D' backward-word     # Ctrl+←
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[3~' delete-char
bindkey '^H' backward-kill-word     # Ctrl+Backspace

# ---- プロンプト ----
# ╭─  ~/ame-shell   main ●
# ╰─❯                                     2.3s  23:05
autoload -Uz vcs_info add-zsh-hook
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:*' check-for-changes true
zstyle ':vcs_info:*' unstagedstr '%F{#ffd58a}●%f'
zstyle ':vcs_info:*' stagedstr '%F{#7ee0a1}●%f'
zstyle ':vcs_info:git:*' formats '  %F{#c8a2ff} %b%f %u%c'
zstyle ':vcs_info:git:*' actionformats '  %F{#c8a2ff} %b%f %F{#ff7a8a}(%a)%f %u%c'

typeset -g _ame_t0=0
_ame_preexec() { _ame_t0=$EPOCHREALTIME }
_ame_precmd() {
    vcs_info
    local took=""
    if (( _ame_t0 > 0 )); then
        local d=$(( EPOCHREALTIME - _ame_t0 ))
        (( d >= 1.0 )) && took="%F{#8b97b3}$(printf '%.1fs' $d)%f  "
        _ame_t0=0
    fi
    _ame_took=$took
    # 端末の題名: いる場所
    print -Pn "\e]0;%~\a"
}
zmodload zsh/datetime 2>/dev/null
add-zsh-hook preexec _ame_preexec
add-zsh-hook precmd _ame_precmd

PROMPT=$'\n%F{#4b5675}╭─%f %F{#7ab8ff}%B %(4~|…/%3~|%~)%b%f${vcs_info_msg_0_}\n%F{#4b5675}╰─%f%(?.%F{#7ab8ff}.%F{#ff7a8a})❯%f '
RPROMPT='${_ame_took}%(?..%F{#ff7a8a}✘ %?%f  )%F{#4b5675}%*%f'
# 2 行目の右のプロンプトを、入力が終わったら消す(コピーしたときに混ざらないように)
setopt transient_rprompt

# ---- 色 ----
export CLICOLOR=1
[[ -z "$LS_COLORS" ]] && command -v dircolors >/dev/null && eval "$(dircolors -b)"

# ---- あれば使うもの ----
_ame_source_first() { local f; for f in "$@"; do [[ -r "$f" ]] && { source "$f"; return 0 }; done; return 1 }
# 灰色の候補(→ で確定)。パッケージが無い環境では install.sh が ~/.local/share/ame-shell/zsh に取ってくる
_ame_source_first \
    /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh \
    /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
    /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
    "$HOME/.local/share/ame-shell/zsh/zsh-autosuggestions/zsh-autosuggestions.zsh" &&
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#4b5675'
# fzf: Ctrl+R で履歴を、Ctrl+T でファイルをあいまい検索
if command -v fzf >/dev/null; then
    export FZF_DEFAULT_OPTS="--height=40% --layout=reverse --border=rounded --color=bg+:#1b2236,fg+:#ffffff,hl:#7ab8ff,hl+:#a3cfff,pointer:#7ab8ff,prompt:#c8a2ff,border:#4b5675"
    source <(fzf --zsh 2>/dev/null) 2>/dev/null ||
        _ame_source_first /usr/share/fzf/key-bindings.zsh /usr/share/doc/fzf/examples/key-bindings.zsh /usr/local/share/examples/fzf/shell/key-bindings.zsh
fi
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"
if command -v eza >/dev/null; then
    alias ls='eza --icons=auto --group-directories-first'
    alias ll='eza -l --icons=auto --group-directories-first --git'
    alias la='eza -la --icons=auto --group-directories-first --git'
    alias lt='eza --tree --level=2 --icons=auto'
else
    alias ls='ls --color=auto' 2>/dev/null
    alias ll='ls -l'
    alias la='ls -la'
fi
command -v bat >/dev/null && alias b='bat --style=plain'
alias ..='cd ..'
alias ...='cd ../..'
alias grep='grep --color=auto'

# ghostty の連携(プロンプトの位置・題名)。ghostty の中で、資源の場所が分かるときだけ
[[ -n "$GHOSTTY_RESOURCES_DIR" && -r "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" ]] &&
    source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"

# 色分けは最後に読む(ほかの設定のキー割り当ての後でないと効かない)
_ame_source_first \
    /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
    /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
    /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
    "$HOME/.local/share/ame-shell/zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
unfunction _ame_source_first

# 自分で足したい設定は ~/.config/ame-shell/zshrc.local に(この設定を使ったまま追加できる)
[[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/ame-shell/zshrc.local" ]] && source "${XDG_CONFIG_HOME:-$HOME/.config}/ame-shell/zshrc.local"
