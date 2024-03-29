{
  description = "An experiment in terminal multiplexing";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = inputs:
    let
      system = "x86_64-linux";
      pkgs = import inputs.nixpkgs {
        inherit system;
      };
      zig = pkgs.stdenv.mkDerivation {
        name = "zig";
        src = fetchTarball {
          url = "https://ziglang.org/builds/zig-linux-x86_64-0.10.0-dev.4176+6d7b0690a.tar.xz";
          sha256 = "sha256:1s3cb5i9f6xg4w1snd0afxnf64vhjh5phjmk8myyi0qcy1761h9w";
        };
        dontConfigure = true;
        dontBuild = true;
        installPhase = ''
          mkdir -p $out
          mv ./lib $out/
          mkdir -p $out/bin
          mv ./zig $out/bin
        '';
      };
    in
      {
         devShell.${system} = pkgs.mkShell {
           nativeBuildInputs = [ zig ] ++ (with pkgs; [
             bashInteractive
             zls
             gdb
             cargo
           ]);
         };
      };
}
