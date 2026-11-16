# NixOS / Nix で使う

NixOS には `/usr` が無く、`/etc` も設定から作られるので、`install.sh` ではなく flake(`flake.nix`)で入れます。
ビルドの中身は install.sh と同じです。Zig 0.13(公式の配布物)と Odin(nixpkgs)で `zig build` します。

## NixOS(おすすめ)

`/etc/nixos/flake.nix` で読み込みます。

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.ame-shell.url = "github:TatsuyaM2667/ame-shell";

  outputs = { nixpkgs, ame-shell, ... }: {
    nixosConfigurations.<ホスト名> = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ame-shell.nixosModules.default
        { programs.ame-shell.enable = true; programs.ame-shell.greeter = true; }
      ];
    };
  };
}
```

`programs.ame-shell.enable` で入るもの:

- ame-shell と小さな道具(ame-ctl・amaterasu・ame-uzume・ame-iwato など)
- River(0.5)・foot・ffmpeg・mpv
- ログイン画面の一覧に出る「Ame Shell」のセッション
- ロック画面用の PAM のサービス `ame-shell`
- upower・power-profiles-daemon・NetworkManager・Bluetooth・PipeWire
- xdg-desktop-portal(wlr・gtk)
- フォント(Noto CJK・Nerd Fonts)

サービス(NetworkManager など)は `lib.mkDefault` で有効にしているので、自分の設定のほうが優先されます。

`programs.ame-shell.greeter = true` にすると、ログイン画面が ame-shell(greetd + ame-greeter)になります。見た目はロック画面と同じです。

## 自分用に入れる(NixOS 以外の Nix も)

```sh
nix profile install github:TatsuyaM2667/ame-shell
ame-session --river5        # TTY から
```

この入れ方では、PAM のサービスを作れません(`/etc` に書けないため)。ロック画面は `/etc/pam.d/ame-shell` または `/etc/pam.d/swaylock` があるときだけ使えます。
NixOS なら、`configuration.nix` に `security.pam.services.ame-shell = {};` を書いてください。

## 更新

```sh
nix flake update ame-shell && sudo nixos-rebuild switch   # NixOS
nix profile upgrade ame-shell                             # 自分用
```

`ame-update` は NixOS では使いません。git pull して `/usr/local` に入れる作りのためです。

## 違い

- `install.sh` が入れる ame のアプリ(ame-filemanager・kuraokami・seoritsu)は flake に含まれません。今のところ、それぞれのリポジトリでビルドしてください。
- 動画の壁紙(libmpv)・PAM・音の道具(libpulse)は、ライブラリを実行時に読みます。これらは flake の中で RUNPATH に入れてあります。
