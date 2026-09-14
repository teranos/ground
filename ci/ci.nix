# The CI workflow. .github/workflows/ci.yml is emitted from this and is never
# edited by hand:
#
#   nix eval --json --file ci/ci.nix | jq . > .github/workflows/ci.yml
#
# JSON is YAML, so GitHub reads the emitted file as it is.
let
  checkout = {
    uses = "actions/checkout@v6";
    "with".fetch-depth = 0;
  };
  installNix.uses = "cachix/install-nix-action@v30";
  tagged = "startsWith(github.ref, 'refs/tags/')";
in
{
  name = "CI";

  on = {
    push = {
      branches = [ "main" "count-one" ];
      tags = [ "*" ];
    };
    pull_request = null;
  };

  jobs = {
    test = {
      runs-on = "ubuntu-latest";
      steps = [
        checkout
        installNix
        { run = "nix build .#ground"; }
        # The Makefile's wind rule is the one list of wind's files. A copy of
        # it here fell behind and CI linked wind without openapi.d.
        { run = "nix develop .#default --command sh -c 'make wind && dub test'"; }
      ];
    };

    release = {
      "if" = tagged;
      needs = "test";
      strategy.matrix.include = [
        {
          os = "ubuntu-latest";
          target = "x86_64-linux";
        }
        {
          os = "macos-latest";
          target = "aarch64-darwin";
        }
      ];
      runs-on = "\${{ matrix.os }}";
      steps = [
        checkout
        installNix
        { run = "nix build .#ground"; }
        { run = "cp result/bin/ground ground-\${{ matrix.target }}"; }
        {
          uses = "actions/upload-artifact@v7";
          "with" = {
            name = "ground-\${{ matrix.target }}";
            path = "ground-\${{ matrix.target }}";
          };
        }
      ];
    };

    github-release = {
      "if" = tagged;
      needs = "release";
      runs-on = "ubuntu-latest";
      permissions.contents = "write";
      steps = [
        { uses = "actions/download-artifact@v8"; }
        { run = "ls -R"; }
        {
          uses = "softprops/action-gh-release@v2";
          "with".files = ''
            ground-*/ground-*
          '';
        }
      ];
    };
  };
}
