# ame-shell の zsh の設定(ログイン時。ame-term-shell が zsh -l で起動する)
# zsh は /etc/profile と ~/.profile を読まないので、sh として読み込む(PATH の追加 ~/.local/bin などが
# 効くように。読まないと、bash では動くコマンドが zsh では見つからなくなる)
[[ -r /etc/profile ]] && emulate sh -c '. /etc/profile'
[[ -r "$HOME/.profile" ]] && emulate sh -c '. "$HOME/.profile"'
# 自分のコマンドの置き場(無ければ足さない)
for _d in "$HOME/.local/bin" "$HOME/bin"; do
    [[ -d "$_d" && ":$PATH:" != *":$_d:"* ]] && PATH="$_d:$PATH"
done
unset _d
export PATH
