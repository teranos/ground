{
  description = "libmcp: a C11 MCP stdio and Streamable HTTP client with a C ABI";

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

      # nixpkgs' json-c 0.18 rejects valid UTF-8 in strict mode (upstream #875).
      # The parser stays strict and the fix is applied here, once, for every
      # consumer that links this library.
      jsonC = pkgs: pkgs.json_c.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./json-c-strict-utf8.patch ];
      });
    in {
      overlays.default = final: prev: { json_c = jsonC prev; };

      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          libmcp = pkgs.stdenv.mkDerivation {
            pname = "libmcp";
            version = self.shortRev or "dirty";
            src = ./.;

            # The archive merges the validator in with libtool on Darwin, and the
            # build sandbox has none until cctools is named.
            nativeBuildInputs = [ pkgs.pkg-config pkgs.python3 pkgs.cargo pkgs.rustc ]
              ++ pkgs.lib.optional pkgs.stdenv.isDarwin pkgs.cctools;
            buildInputs = [ (jsonC pkgs) pkgs.curl ];

            buildPhase = "export CARGO_HOME=$TMPDIR/cargo; make";
            doCheck = true;
            checkPhase = "make test";
            installPhase = "make install PREFIX=$out";
          };
        in {
          default = libmcp;
          inherit libmcp;
          json-c = jsonC pkgs;
        });

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.pkg-config pkgs.python3 pkgs.cargo pkgs.rustc (jsonC pkgs) pkgs.curl ]
              ++ pkgs.lib.optional pkgs.stdenv.isDarwin pkgs.cctools;
          };
        });
    };
}
