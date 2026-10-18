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
    # "i want a coment per project essentially"
    # A comet: ground's own controls and one project's, built for a Mac.
    workflow_dispatch.inputs = {
      project = {
        description = "the repository whose controls the comet folds in, owner/repo";
        required = true;
        type = "string";
      };
      rev = {
        description = "the project's rev the comet is built from";
        required = true;
        type = "string";
      };
    };
  };

  jobs = {
    # Both systems ground is released for, so a link that only one of them
    # refuses is seen before a tag is cut.
    test = {
      "if" = "github.event_name != 'workflow_dispatch'";
      strategy.matrix.os = [ "ubuntu-latest" "macos-latest" ];
      runs-on = "\${{ matrix.os }}";
      steps = [
        checkout
        installNix
        { run = "nix build .#ground"; }
        # The Makefile's wind rule is the one list of wind's files. A copy of
        # it here fell behind and CI linked wind without openapi.d.
        { run = "nix develop .#default --command sh -c 'make wind && dub test'"; }
        # ug is built by ldc2 rather than dub, so `dub test` compiles no line of
        # it. `make ug` is here too because test-ug never links.
        { run = "nix develop .#default --command sh -c 'make ug && make test-ug'"; }
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

    # wind folds what is on the disk it runs on, so the comet is built in the
    # dev shell with the project checked out beside ground, not by nix build,
    # whose sandbox holds ground's tree alone.
    comet = {
      "if" = "github.event_name == 'workflow_dispatch'";
      runs-on = "macos-latest";
      steps = [
        (checkout // { "with" = checkout."with" // { path = "ground"; }; })
        {
          uses = "actions/checkout@v6";
          "with" = {
            repository = "\${{ inputs.project }}";
            ref = "\${{ inputs.rev }}";
            path = "project";
          };
        }
        installNix
        {
          name = "The comet's one project";
          run = ''
            mkdir -p ground/controls/local
            printf 'project {\n  path: "%s"\n}\n' "$GITHUB_WORKSPACE/project" > ground/controls/local/comet.pbt
          '';
        }
        {
          name = "Built with that project's sand";
          working-directory = "ground";
          run = "nix develop .#default --command make build";
        }
        {
          name = "What it links";
          working-directory = "ground";
          run = "otool -L ground";
        }
        {
          id = "name";
          run = "echo \"artifact=ground-aarch64-darwin-$(echo '\${{ inputs.project }}' | tr / -)\" >> \"$GITHUB_OUTPUT\"";
        }
        {
          uses = "actions/upload-artifact@v7";
          "with" = {
            name = "\${{ steps.name.outputs.artifact }}";
            path = "ground/ground";
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
