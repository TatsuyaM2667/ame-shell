# pins.sh: 取ってくるものの版と、その中身を確かめる値(SHA-256 / git のコミット)。POSIX sh。
# install.sh・scripts/install-apps.sh・scripts/install-freebsd.sh が「. pins.sh」で読む。
#
# 取ってきたものは、ここに書いた値と合わなければ使わない(配布元やつなぐ途中で書き換えられても気づけるように)。
# 値を変えるときは、Zig は公式の一覧(https://ziglang.org/download/index.json の shasum)、
# git は公式のタグ(git ls-remote <URL> refs/tags/<タグ>)で確かめてから書き換える。
# AME_NO_VERIFY=1 で確かめずに使う(値がまだ書かれていない arch などのため。勧めない)。

# ---- 版 ----
ZIG_VER=0.13.0          # ame-shell と道具(Zig 0.13)
ZIG_RIVER_VER=0.16.0    # River 0.5 のビルド
ZIG17_VER=0.17.0        # seoritsu の tree-sitter・ghostty のビルド
GHOSTTY_VER=1.4.0
ODIN_TAG=dev-2026-08

# ---- Zig の配布物(https://ziglang.org/download/<版>/…)----
# zig_sha256 <版> <名前>   名前: x86_64-linux・aarch64-linux・x86_64-freebsd・aarch64-freebsd・src
zig_sha256() {
    case "$1/$2" in
    0.13.0/x86_64-linux) echo d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea ;;
    0.13.0/aarch64-linux) echo 041ac42323837eb5624068acd8b00cd5777dac4cf91179e8dad7a7e90dd0c556 ;;
    0.13.0/x86_64-freebsd) echo adc1ffc9be56533b2f1c7191f9e435ad55db00414ff2829d951ef63d95aaad8c ;;
    0.13.0/src) echo 06c73596beeccb71cc073805bdb9c0e05764128f16478fa53bf17dfabc1d4318 ;;
    0.16.0/x86_64-linux) echo 70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
    0.16.0/aarch64-linux) echo ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
    0.17.0/x86_64-linux) echo 1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
    0.17.0/aarch64-linux) echo 9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
    0.17.0/x86_64-freebsd) echo a314f1cc92d098bd39caf9e5607a0de2a8fd0d00064776cb3fd5b3bee38a67c9 ;;
    0.17.0/aarch64-freebsd) echo 3cf53d07b3587a26727b196a6eb7918704b907d951520daa68e4e1820fc6f48e ;;
    0.17.0/src) echo b6c7f1728f043700d6529bac980800792f824256a9d2f1839b3d62beed0b8abd ;;
    esac
}

# ---- ほかの配布物 ----
GHOSTTY_SHA256=cb188ac6c3a8278d5fd7bfef15d8c017104c87f638b5560eb38024a71ae0f005 # ghostty-1.4.0.tar.gz

# ---- git(タグ・ブランチと、その時のコミット)----
ODIN_COMMIT=8412dc37aa91def0c2fa90f89eade29056b4e608   # odin-lang/Odin の dev-2026-08
RIVER_COMMIT=cc4a291b2b9375fe3d5fe5a64b6f510b463f888b  # codeberg.org/river/river の v0.5.0
ZSH_AUTOSUGGEST_COMMIT=85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5 # zsh-users/zsh-autosuggestions
# ame のアプリ(scripts/install-apps.sh。--latest なら最新を取ってきて、この値は見ない)
APP_COMMIT_ame_filemanager=47f207d1ca038a7648926b0fe9aa00af426b1cf8
APP_COMMIT_kuraokami=3adae222335df7c6368aec9d7f98a85943fa7178
APP_COMMIT_seoritsu=1e35415fe15e92c4c44fbae026574d88b0557d6c

# ---- 確かめる道具 ----
sha256_of() { # sha256_of <ファイル>
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v sha256 >/dev/null 2>&1; then sha256 -q "$1"           # FreeBSD
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r "$1" | cut -d' ' -f1
    fi
}

# fetch_verified <URL> <保存先> <SHA-256>: 取ってきて確かめる。保存先が既にあって合っていれば取り直さない。
# 合わなければ消して 1 を返す(呼ぶ側が止める)
fetch_verified() {
    if [ -z "$3" ] && [ "${AME_NO_VERIFY:-0}" != 1 ]; then
        echo "確かめる値(SHA-256)が分からないため使いません: $1(AME_NO_VERIFY=1 で確かめずに使えます)" >&2
        return 1
    fi
    if [ -f "$2" ] && { [ -z "$3" ] || [ "$(sha256_of "$2")" = "$3" ]; }; then return 0; fi
    rm -f "$2.part"
    if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 -o "$2.part" "$1" || return 1
    elif command -v fetch >/dev/null 2>&1; then fetch -o "$2.part" "$1" || return 1
    elif command -v wget >/dev/null 2>&1; then wget -O "$2.part" "$1" || return 1
    else echo "curl / fetch / wget のどれかが必要です" >&2; return 1; fi
    if [ -n "$3" ] && [ "$(sha256_of "$2.part")" != "$3" ]; then
        echo "取ってきたものの SHA-256 が合いません(書き換えられたか、壊れています): $1" >&2
        rm -f "$2.part"
        return 1
    fi
    mv -f "$2.part" "$2"
}

# git_at <URL> <タグ・ブランチ(空ならコミットで直に)> <コミット> <置き場>: そのコミットのソースを置き場に用意する。
# タグを付け替えられていたら(コミットが違えば)消して 1 を返す
git_at() {
    if [ -d "$4/.git" ] && [ "$(git -C "$4" rev-parse HEAD 2>/dev/null)" = "$3" ]; then return 0; fi
    rm -rf "${4:?}"
    if [ -n "$2" ]; then
        git clone -q --depth 1 --branch "$2" "$1" "$4" || return 1
    else
        git init -q "$4" && git -C "$4" fetch -q --depth 1 "$1" "$3" && git -C "$4" checkout -q FETCH_HEAD || { rm -rf "${4:?}"; return 1; }
    fi
    if [ "$(git -C "$4" rev-parse HEAD)" != "$3" ] && [ "${AME_NO_VERIFY:-0}" != 1 ]; then
        echo "取ってきたソースのコミットが合いません(タグが付け替えられた可能性): $1 $2" >&2
        rm -rf "${4:?}"
        return 1
    fi
}
