{
  description = "Ground Control for Agentic AI";

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
            buildInputs = [ pkgs.sqlite pkgs.curl pkgs.libgit2 ];

            buildPhase = ''
              export HOME=$(mktemp -d)
              echo "${version}" > .version
              date -u +%Y-%m-%dT%H:%M:%SZ > .builddate
              mkdir -p tools
              # The Makefile's wind rule is the one list of wind's files. A copy
              # of it here fell behind and CI linked wind without openapi.d.
              make wind
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
          # The agents ground answers, at the versions it is held to: the vendor's
          # binary at the vendor's published sha256. The binary carries the hook
          # schemas parity is measured against; the docs page has no version.
          claudePlatform = {
            aarch64-darwin = "darwin-arm64";
            x86_64-darwin = "darwin-x64";
            aarch64-linux = "linux-arm64";
            x86_64-linux = "linux-x64";
          }.${system};

          # downloads.claude.ai/claude-code-releases/<version>/manifest.json
          claude = version: sha256: pkgs.fetchurl {
            name = "claude-${version}";
            url = "https://downloads.claude.ai/claude-code-releases/${version}/${claudePlatform}/claude";
            # Flat, as the manifest hashes it: executable = true hashes the NAR.
            sha256 = sha256.${claudePlatform};
          };

          codexTarget = {
            aarch64-darwin = "aarch64-apple-darwin";
            x86_64-darwin = "x86_64-apple-darwin";
            aarch64-linux = "aarch64-unknown-linux-musl";
            x86_64-linux = "x86_64-unknown-linux-musl";
          }.${system};

          # tarball: the release's asset digest, github.com/openai/codex rust-v<version>.
          # binary: what it unpacks to, the hash ground parity checks a binary against.
          codex = version: sha256: pkgs.runCommand "codex-${version}" {
            src = pkgs.fetchurl {
              url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${codexTarget}.tar.gz";
              sha256 = sha256.${codexTarget}.tarball;
            };
          } ''
            mkdir -p $out/bin
            tar -xzf $src -C $out/bin
            mv $out/bin/codex-${codexTarget} $out/bin/codex
            echo "${sha256.${codexTarget}.binary}  $out/bin/codex" | sha256sum -c -
          '';

          agyTarget = {
            aarch64-darwin = "mac_arm64";
            x86_64-darwin = "mac_x64";
            aarch64-linux = "linux_arm64_musl";
            x86_64-linux = "linux_x64_musl";
          }.${system};

          # tarball: the release's asset digest, github.com/google-antigravity/antigravity-cli <version>.
          # binary: the antigravity it unpacks to, which agy's installer puts at ~/.local/bin/agy.
          agy = version: sha256: pkgs.runCommand "agy-${version}" {
            src = pkgs.fetchurl {
              url = "https://github.com/google-antigravity/antigravity-cli/releases/download/${version}/agy_cli_${agyTarget}.tar.gz";
              sha256 = sha256.${agyTarget}.tarball;
            };
          } ''
            mkdir -p $out/bin
            tar -xzf $src -C $out/bin antigravity
            mv $out/bin/antigravity $out/bin/agy
            echo "${sha256.${agyTarget}.binary}  $out/bin/agy" | sha256sum -c -
          '';

          # The protocol ground code answers an ACP client in, at the schema it is
          # held to: github.com/agentclientprotocol/agent-client-protocol
          # schema-v<version>, the release's schema.json. It is the tag's
          # schema/v1/schema.json byte for byte, and it names every method and the
          # side that handles it. One file, the same on every platform.
          acp = version: sha256: pkgs.fetchurl {
            name = "acp-${version}-schema.json";
            url = "https://github.com/agentclientprotocol/agent-client-protocol/releases/download/schema-v${version}/schema.json";
            sha256 = sha256.schema;
          };
        in {
          default = ground;
          inherit ground;

          claude-2_1_303 = claude "2.1.303" {
            darwin-arm64 = "d2da3b003dc08b88b7230469014fe3e1dc6fe94bc8f648e89b34175d30269370";
            darwin-x64 = "6c5d63b43568c5d60963d40f05b0087cb03ba44a90740d27adc505f4157806db";
            linux-arm64 = "f384f49826336d4ac0484ac6ac9d8d16f64d244d186ce227cbd7cc088c03315d";
            linux-x64 = "375988f457756524234695cf2d8f64ace99c5f68682e47ea24862a843c191450";
          };

          claude-2_1_304 = claude "2.1.304" {
            darwin-arm64 = "b9ac5374839f14abf3f1f45610637c332b5daee5ce0d1634726cef87aab78e6a";
            darwin-x64 = "f2ae409b46b1bdc1dec7afa12c6a094ff64e7d4ca272ca09f69dd0080c846703";
            linux-arm64 = "c487117526509ab6d2ee6013e14f181faf68d6d6afe6bb0d4b2b4a9feca5ecb3";
            linux-x64 = "ea0f135784631619a7a409d07322ecec964f9cc4fd377508ed1ba3f141f27912";
          };

          codex-0_163_0 = codex "0.163.0" {
            aarch64-apple-darwin = {
              tarball = "61c4d9a92521bdb42b0c1d9f87c673f6da628a06de5945cbdd9a0010632f6d10";
              binary = "8813367285524ac798dd96d1b071aea30d58708c7226fd236cd275cf1cfdee31";
            };
            x86_64-apple-darwin = {
              tarball = "562a1aea0e5686283a467687d268ae33705f02fd4d40f1bc4110a415c5c1c7b1";
              binary = "73697f229103f463acaafd8659976caaa4892ec11e2c246c7fa97f93d523f90e";
            };
            aarch64-unknown-linux-musl = {
              tarball = "a7261e65f4a96d8f4ca65a069c6cf2dc2c33defc341e48078acefda9461fffe4";
              binary = "8a96f66d059d653e68bfd5f3c79337e6f1d7d170d80bf705eb7d0249b34c0ece";
            };
            x86_64-unknown-linux-musl = {
              tarball = "beb339e8ecd9ba057a6bb2dc81ad8ca474812edfbf0fc5056ca818797648dde4";
              binary = "399ff69c431c066e40de318fba45c2b07f45a76b19939d247ee4828fc70c4215";
            };
          };

          agy-1_4_4 = agy "1.4.4" {
            mac_arm64 = {
              tarball = "85482aa8969300183f71c9653d9f581248fba7f506342a8eb087f3d2503203bd";
              binary = "9abb478686dc08d48699ba1604c14d15819ef6a2542d5d32173acbd5f02d712d";
            };
            mac_x64 = {
              tarball = "12c96c065ac50d36e087c1fda1bba8d6fb4fa7af232d1ef2a44499c2481a52bf";
              binary = "f6b17956d07e7021841a66e63cc9949bdddff36049c1dbba27e05c4d203b4253";
            };
            linux_arm64_musl = {
              tarball = "4900f50954ad6fb3747c2d80fe29b5986ae861d0f8ea04c2a5bd9cb1781507dc";
              binary = "03ac1122a12a479a5110da1fcdfeb718988a323e0eaa3d2ccf96e98956b2ed9f";
            };
            linux_x64_musl = {
              tarball = "f85f39bf74b6ff5f7f45da768ba52b39318a7e528811df65f394995959cbcc2c";
              binary = "9caa302d10c42c698fb72ebda71910a2032b01a2ec99c391e8cd6fdc03ed31fd";
            };
          };

          acp-1_26_0 = acp "1.26.0" {
            schema = "4bcd1d2051ff7ed379bd9b234fb9b09c5ab9245478698e9fab805bd9b52a33a6";
          };

          # Every acp pin above, a directory per release, for make install to link
          # where ground parity reads them. A new pin joins without being named here.
          acp-schemas = pkgs.linkFarm "acp-schemas" (pkgs.lib.mapAttrsToList
            (name: schema: {
              name = "${pkgs.lib.replaceStrings [ "acp-" "_" ] [ "" "." ] name}/schema.json";
              path = schema;
            })
            (pkgs.lib.filterAttrs (name: _: builtins.match "acp-[0-9_]+" name != null) self.packages.${system}));
        }
      );

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            # dub asks pkg-config for each lib. Without the pinned one in the
            # shell it asked Homebrew's, which named an x86_64 libgit2.
            buildInputs = [ pkgs.ldc pkgs.sqlite pkgs.curl pkgs.libgit2 pkgs.dub pkgs.pkg-config ];
          };
        }
      );
    };
}
