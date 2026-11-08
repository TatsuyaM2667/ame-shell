{
  # Mistral Large（codestral ランナー経由）で ame-shell を検査させるための devShell。
  # 使い方: ame-shell のクローンのルートに置いて `nix develop`。
  # （リポジトリ自体は Nix でビルドせず、zig build がそのまま使える環境だけを用意する）

  description = "DevShell for inspecting ame-shell (zig 0.13 + odin + wayland)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # リポジトリの想定は Odin dev-2026-08（install.sh の ODIN_TAG）。
          # nixpkgs の odin で anim/ がビルドできなかったら、下のコメントを参考に揃える:
          #
          # odin = pkgs.odin.overrideAttrs (old: {
          #   version = "dev-2026-08";
          #   src = pkgs.fetchFromGitHub {
          #     owner = "odin-lang";
          #     repo = "Odin";
          #     rev = "dev-2026-08";
          #     hash = ""; # nix-prefetch-github odin-lang Odin --rev dev-2026-08 で取得して記入
          #   };
          # });
          odin = pkgs.odin;
        in
        {
          default = pkgs.mkShell {
            pname = "ame-shell-inspect";

            packages = with pkgs; [
              # --- ツールチェーン ---
              zig_0_13          # build.zig.zon: minimum_zig_version = 0.13.0
              odin              # anim/（アニメ・FFT・主色抽出）を obj と wasm32 の両方にビルド
              # zls             # 必要なら（エディタ/LSP 用）

              # --- ビルドに必要な外部ツール ---
              pkg-config        # build.zig の linkSystemLibrary が pkg-config で解決する
              wayland            # wayland-client 等のライブラリ本体
              wayland-scanner    # protocol/*.xml → C（最近の nixpkgs では wayland から分離している）
              wayland-protocols

              # --- リンクされるライブラリ（build.zig の linkSystemLibrary と同じ並び）---
              libxkbcommon
              freetype
              harfbuzz
              fontconfig
              dbus
              mesa              # EGL / GLESv2 / wayland-egl（実装側）
              libglvnd          # egl.pc / glesv2.pc（pkg-config の解決はこっちにある。検査時に不足した分）
              # linux-pam      # pam_ame_face.so は shlib undefined でリンクし、
              #                # PAM のヘッダも使わないので不要（動かすときだけ手元の PAM）

              # --- 検査の補助 ---
              git               # 依存取得（build.zig.zon）と差分確認
              ripgrep
              shellcheck        # install.sh / scripts/*.sh / session/*.sh（POSIX sh）の検査
              curl              # Mistral API（mistral-large-latest）を直接叩くランナー用
              jq                # API の応答処理やレポートの結合に便利
            ];

            shellHook = ''
              echo "== ame-shell 検査環境 =="
              echo "zig:  $(zig version)"
              odin version
              echo "wayland-scanner: $(wayland-scanner --version)"
              echo ""
              echo "  ビルド:   zig build"
              echo "  テスト:   zig build test        (src/pure_tests.zig)"
              echo "  書式:     zig fmt --check ."
              echo "  Odin:     odin check anim"
              echo "  試験道具: zig build tools       (vptr / vkbd)"
              echo ""
              echo "  API キー(MISTRAL_API_KEY)はランナー側で export しておくこと"
            '';
          };
        });
    };
}

# 補足:
# - zig_0_13 が手元のチャンネルに無い場合は inputs に github:mitchellh/zig-overlay
#   を足して zig.packages.${system}."0.13.0" を使う。
# - build.zig は Linux 向けに /usr/include/freetype2 等の絶対パスを include に足すが、
#   存在しないパスが混ざってもエラーにはならない。実物は pkg-config 経由で
#   この devShell のライブラリが解決する（NixOS でも可）。
# - build.zig.zon の ame-hand / ame-face は初回の zig build が GitHub から
#   取ってくる（devshell 内ならネットワークは使える）。