# ame-shell を Nix / NixOS で入れる(docs/nixos.md)。
#   nix build              → ./result に ame-shell と道具・セッションのスクリプト
#   nix profile install .  → 自分用に入れる
#   NixOS: imports = [ ame-shell.nixosModules.default ]; programs.ame-shell.enable = true;
# ビルドは install.sh と同じ: Zig 0.13(公式の配布物)+ Odin(nixpkgs)で zig build。
# サンドボックスでは取ってこられないので、Zig と、build.zig.zon の 2 つの依存(手の認識・顔認証)は flake の入力にする
{
  description = "ame-shell: River の Wayland シェル(Zig / Odin / WASM)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-x86_64-linux = { url = "https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz"; flake = false; };
    zig-aarch64-linux = { url = "https://ziglang.org/download/0.13.0/zig-linux-aarch64-0.13.0.tar.xz"; flake = false; };
    # build.zig.zon と同じコミット(変えるときは両方)
    ame-senju = { url = "github:TatsuyaM2667/ame-senju/cc31453eee6c24b7a99dec670f06334b4f47d111"; flake = false; };
    ame-kagami = { url = "github:TatsuyaM2667/ame-kagami/bcef91268096a48b0c64707248db08d745679c19"; flake = false; };
  };

  outputs = { self, nixpkgs, ame-senju, ame-kagami, ... }@inputs:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (system: pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "ame-shell";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = with pkgs; [ odin pkg-config wayland-scanner autoPatchelfHook git ];
          buildInputs = with pkgs; [
            wayland libGL libxkbcommon freetype harfbuzz fontconfig dbus openssl pam
          ];
          # 実行時に dlopen で読むもの(PAM・動画の壁紙の libmpv・音の道具の libpulse)。autoPatchelf が RUNPATH に足す
          runtimeDependencies = with pkgs; [ pam mpv-unwrapped libpulseaudio libGL ];

          dontConfigure = true;
          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR/p
            # build.zig.zon のハッシュの名前で置くと、zig は取りに行かずにこれを使う
            cp -r ${ame-senju} $ZIG_GLOBAL_CACHE_DIR/p/12205c717f391532a8cb22885bac03817aa98afa49efa4acbe69e7cd9a1eb62213a4
            cp -r ${ame-kagami} $ZIG_GLOBAL_CACHE_DIR/p/1220ca6670f75f1778fc331a53d57f5455e10530556e49b0a576fda8b61f61d3619b
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            ${inputs."zig-${system}"}/zig build -Doptimize=ReleaseFast
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            sh session/install-session.sh --user --prefix $out --no-setup
            rm -f $out/share/ame-shell/installed-files $out/share/ame-shell/source
            # ログイン画面(greetd・SDDM など)の一覧に出すセッション
            mkdir -p $out/share/wayland-sessions
            sed -e "s|@PREFIX@|$out|g" -e 's|^Name=.*|Name=Ame Shell|' -e 's|^Name\[ja\]=.*|Name[ja]=Ame Shell(雨)|' \
              session/ame-shell-river5.desktop > $out/share/wayland-sessions/ame-shell.desktop
            runHook postInstall
          '';
          passthru.providedSessions = [ "ame-shell" ];
          meta = {
            description = "River の Wayland シェル(Zig / Odin / WASM)";
            homepage = "https://github.com/TatsuyaM2667/ame-shell";
            platforms = systems;
            mainProgram = "ame-shell";
          };
        };
      });

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.ame-shell;
          pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        in
        {
          options.programs.ame-shell = {
            enable = lib.mkEnableOption "ame-shell(River 0.5 のセッション)";
            greeter = lib.mkEnableOption "ame-shell のログイン画面(greetd + ame-greeter)";
          };
          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ pkg ] ++ (with pkgs; [ river foot ffmpeg mpv xdg-utils wlr-randr libarchive ]);
            # セッションの一覧(ame-greeter は /run/current-system/sw/share/wayland-sessions を読む)
            services.displayManager.sessionPackages = [ pkg ];
            environment.pathsToLink = [ "/share/wayland-sessions" ];
            # ロック画面のパスワード照合(src/cmd/pam.zig が PAM サービス ame-shell を使う)
            security.pam.services.ame-shell = { };
            security.polkit.enable = true;
            services.upower.enable = true;
            services.power-profiles-daemon.enable = lib.mkDefault true;
            networking.networkmanager.enable = lib.mkDefault true;
            hardware.bluetooth.enable = lib.mkDefault true;
            services.pipewire = { enable = lib.mkDefault true; pulse.enable = lib.mkDefault true; wireplumber.enable = lib.mkDefault true; };
            xdg.portal = { enable = true; wlr.enable = true; extraPortals = [ pkgs.xdg-desktop-portal-gtk ]; config.river.default = [ "wlr" "gtk" ]; };
            fonts.packages = with pkgs; [ noto-fonts-cjk-sans nerd-fonts.jetbrains-mono nerd-fonts.symbols-only ];
            services.greetd = lib.mkIf cfg.greeter {
              enable = true;
              settings.default_session = {
                command = "env AME_RIVER5=${pkgs.river}/bin/river ${pkg}/bin/ame-greeter";
                user = "greeter";
              };
            };
          };
        };
    };
}
