{
  description = "libacp: the Agent Client Protocol, agent side, in C11 with a C ABI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      # A consumer that holds its own json-c builds libacp against that one. Clang 22.1.3 and later:
      # an older compiler-rt deadlocks ASan at start on macOS 26.4 and later (llvm/llvm-project#182943).
      libacpWith = pkgs: jsonC: pkgs.llvmPackages_22.stdenv.mkDerivation {
        pname = "libacp";
        version = self.shortRev or "dirty";
        src = ./.;
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [ jsonC ];
        buildPhase = "make";
        doCheck = true;
        checkPhase = "make test";
        installPhase = "make install PREFIX=$out";
      };
    in {
      lib = { inherit libacpWith; };

      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = libacpWith pkgs pkgs.json_c;
          libacp = libacpWith pkgs pkgs.json_c;
        });

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell.override { stdenv = pkgs.llvmPackages_22.stdenv; } {
            packages = [ pkgs.pkg-config pkgs.json_c ];
          };
        });
    };
}
