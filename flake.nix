{
  description = "Graunde — Ground Control for Claude Code";

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

          graunde = pkgs.stdenv.mkDerivation {
            pname = "graunde";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.ldc pkgs.dub pkgs.git ];
            buildInputs = [ pkgs.sqlite ];

            buildPhase = ''
              export HOME=$(mktemp -d)
              echo "${version}" > .version
              ${pkgs.dub}/bin/dub build --build=release
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp graunde $out/bin/
            '';
          };
        in {
          default = graunde;
          inherit graunde;
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
