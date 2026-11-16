# ame のアプリ

ファイルマネージャ・端末・コードエディタは、SeoritsuOS と同じく **Odin** で書いた ame のアプリです。どれも別のリポジトリで、`install.sh` が GitHub から取ってきてビルドし、`~/.local` に入れます。Qt・GTK・Electron は使いません。

| アプリ | 種類 | 描き方 | SeoritsuOS での使われ方 | 置き換えたもの |
|---|---|---|---|---|
| [ame-filemanager](https://github.com/TatsuyaM2667/ame-Filemanager) | ファイルマネージャ | Wayland に直接、ソフトウェアで描く | Super+E・フォルダを開く既定のアプリ | Thunar |
| [kuraokami](https://github.com/TatsuyaM2667/kuraokami) | 端末 | SDL3 + OpenGL 3.3 | Super+Return(`ame-terminal`) | ghostty・foot |
| [seoritsu](https://github.com/TatsuyaM2667/seoritsu) | コードエディタ | Wayland に直接、ソフトウェアで描く(tree-sitter の部分だけ Zig) | 文字のファイルを開く既定のアプリ(まだ決まっていなければ) | — |

3 つとも半透明のガラスの見た目で、SeoritsuOS の窓を開くときの波紋・たわむ動きでも、透け具合を保ったまま描かれます。

## ame-filemanager {#filemanager}

GNOME Files に近い見た目の、半透明のファイルマネージャです。待っている間は CPU 0%、メモリは 20〜35MB ほどです(大半は窓の絵そのもの)。

- **見た目と操作**: サイドバー・パンくずのパスバー・アイコン表示 / 一覧表示 / ツリー表示(Ctrl+3)・ブラウザのような常時タブ(Ctrl+T / Ctrl+W)・2 画面(F3)
- **ドラッグで変換**: ファイルを Ctrl+ドラッグすると、カーソルの所に形式のドーナツメニューが渦を巻いて開きます。形式の上で離すと、隣に変換したファイルができます(ffmpeg・pandoc・LibreOffice・ImageMagick・bsdtar を、入っていれば使う)。Tab で裏返すと、回転・縮小・音声の削除などもできます
- **圧縮ファイル**: zip・tar.*・7z・rar・iso などを展開、zip・tar.gz・tar.xz・7z を作成(bsdtar)
- **見る**: スペースでクイックプレビュー。画像・PDF・動画・SVG・テキスト・Office / EPUB の本文・圧縮ファイルの中身・フォントの見本
- **音楽**: 曲をクリックすると下に再生バー。同じ名前の `.lrc` で歌詞を同期表示
- **整理**: 9 通りの並べ替え、グループ、言語・フレームワークのバッジ(package.json・Cargo.toml などから判定)、iPad のような色付きのタグ
- **その他**: ゴミ箱(GNOME と共通)、裏で動くコピー・移動と元に戻す(Ctrl+Z)、ストレージの同心円マップ、SFTP(sshfs)、USB ドライブ、Git の状態、まとめて名前変更

## kuraokami {#kuraokami}

軽くて速く、アニメーションに力を入れた GPU の端末です。本体はすべて Odin で、直接使うライブラリは SDL3・FreeType・fontconfig・libc だけです。

- **速い・軽い**: 50MB の出力を約 0.8 秒で処理。バイナリは約 1.4MB。何も起きていないときは完全に眠ります(カーソルの点滅も 30 秒で止まる)
- **アニメーション**: カーソルのスライドと残像、なめらかなスクロール、タブのスライド、Ghostty 互換のシェーダー
- **日本語**: IME の変換中の文字をその場に表示、全角の幅、フォントの自動フォールバック、カラー絵文字
- **zsh**: シェル統合・履歴からの候補・色分け・補完メニュー・git に対応したプロンプトを内蔵(設定なしで使える)。最初のタブで fastfetch を出す
- **画像・動画**: Kitty graphics protocol(`mpv --vo=kitty` で動画)と Sixel
- **見た目**: 既定は深い紺の背景を 70% の不透明度で表示

SeoritsuOS の `ame-terminal` は、kuraokami → ghostty → foot の順に探して開きます。

## seoritsu {#seoritsu}

半透明のコードエディタです。Wayland に直接描き、GTK・SDL・GPU を使いません。インストールしてある **Zed の設定と拡張**を読みます。

- **Zed から借りるもの**: `settings.json`(色・透過・フォント・autosave・format_on_save・言語サーバーの設定)、拡張の言語定義、Zed がダウンロードした言語サーバー
- **LSP**: 診断・補完・ホバー・定義へ・参照・名前の変更(複数ファイル)・コードアクション・保存時フォーマット。差分だけ送るので大きいファイルも軽い
- **編集**: マルチカーソル(Ctrl+D / Ctrl+Shift+L / Alt+クリック)、括弧の補完、行の移動・複製、IME、tree-sitter で構文単位に選択を広げる(Alt+Shift+→)
- **画面**: Zed と同じ配置(プロジェクト名と git ブランチ・プロジェクトパネル・パンくず)、ミニマップ、分割、内蔵ターミナル(Ctrl+\`)
- **軽さ**: 2,500 行のファイルで 16MB、20 万行で 43MB。待っている間の CPU はほぼ 0%

## 入れ方と更新 {#install}

```sh
sh install.sh                              # SeoritsuOS と一緒に 3 つとも入る(--no-apps で入れない)
sh scripts/install-apps.sh                 # SeoritsuOS が決めた版で入れる(名前を並べるとそれだけ)
sh scripts/install-apps.sh --latest        # GitHub の最新を入れる
sh scripts/install-apps.sh --uninstall     # この script が入れたものだけ外す
ame-update                                 # SeoritsuOS と一緒に、3 つとも GitHub の最新にする
```

- **ame-update** は、GitHub の最新(`git ls-remote` で見る)と入っている版を比べ、同じなら作り直しません。`ame-update --check` で、更新があるかだけ見られます。
- 自分で入れたもの(この script が入れた印の無いもの)は、ふだんは上書きしません。ame-update(`--latest`)のときは、ふつうのファイルなら最新に入れ替えます。開発中のフォルダへのリンク(`~/.local/bin/seoritsu -> ~/seoritsu/seoritsu` など)には触りません。
- どれかが作れなくても、ほかは続けます。作れなかったものは最後にまとめて出し、あとで `sh scripts/install-apps.sh <名前>` でやり直せます。

### OS ごとの違い {#os}

| | Odin | kuraokami の部品(kb_text_shape) | SDL3 など |
|---|---|---|---|
| Chimera Linux | ソースから `~/.cache` にビルド | Odin の置き場に作る | `/usr/lib` |
| Arch Linux | pacman の odin(`/usr/lib/odin`。root しか書けない) | 自分用の Odin の置き場(`~/.cache/ame-shell/toolchain/odin-root`。中身はリンク)に作る | `/usr/lib` |
| Fedora | ソースから `~/.cache` にビルド | Odin の置き場に作る | `/usr/lib64` |
| FreeBSD | root が `/usr/local/ame-toolchain` にビルド | 自分用の Odin の置き場に作る | `/usr/local/lib`(ビルドのときに並べる) |

以前は、Arch と FreeBSD で kuraokami だけが入りませんでした。kuraokami のビルドは、文字の整形の部品を Odin の置き場の中に作りますが、そこに書けなかったためです。今は、書けないときは自分用の置き場を作って使います(Arch はコンテナで確認済み)。
