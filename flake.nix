{
  description = "Ground Control for Claude Code";

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
    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          version = self.shortRev or "dirty";

          ground = pkgs.stdenv.mkDerivation {
            pname = "ground";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.ldc pkgs.dub pkgs.git ];
            buildInputs = [ pkgs.sqlite ];

            buildPhase = ''
              export HOME=$(mktemp -d)
              echo "${version}" > .version
              date -u +%Y-%m-%dT%H:%M:%SZ > .builddate
              mkdir -p tools
              ${pkgs.ldc}/bin/ldc2 -of=tools/wind -I=tools tools/wind.d tools/filelist.d
              # --config=production must match the Makefile. Without it the
              # shipped binary is built from a source set that includes
              # source/*_test.d, whose static asserts are CTFE work the release
              # binary has no reason to do.
              ${pkgs.dub}/bin/dub build --build=release --config=production
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp ground $out/bin/
            '';
          };
        in {
          default = ground;
          inherit ground;
        }
      );

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            buildInputs = [ pkgs.ldc pkgs.sqlite pkgs.dub ];
          };
        }
      );
    };
}
