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
          url = "https://ziglang.org/builds/zig-linux-x86_64-0.10.0-dev.2431+0e6285c8f.tar.xz";
          sha256 = "sha256:18qnmggg5khy9bji11xb7mrxw4gj1qa9d28201737fb9hj0f1m2n";
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
           ]);
         };
      };
}
