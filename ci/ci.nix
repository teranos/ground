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
    # Both systems ground is released for, so a link that only one of them
    # refuses is seen before a tag is cut.
    test = {
      strategy.matrix.os = [ "ubuntu-latest" "macos-latest" ];
      runs-on = "\${{ matrix.os }}";
      permissions = {
        contents = "read";
        id-token = "write";
      };
      steps = [
        checkout
        installNix
        # 「[Opus 5.5] -L: each derivation's build log as it runs, so a build that hangs shows where.」
        { run = "nix build -L .#ground"; }
        # libacp: its build, and its checkPhase's tests, plain and under ASan/UBSan.
        { run = "nix build -L .#libacp"; }
        # ground's side of libmcp, against the input's library and test server.
        { run = "nix develop .#default --command make test-mcp"; }
        # The Makefile's wind rule is the one list of wind's files. A copy of
        # it here fell behind and CI linked wind without openapi.d. sandload's
        # test loads the library make sand builds, as an engine loads a comet.
        { run = "nix develop .#default --command sh -c 'make wind sand && dub test'"; }
        # ug is built by ldc2 rather than dub, so `dub test` compiles no line of
        # it. `make ug` is here too because test-ug never links.
        { run = "nix develop .#default --command sh -c 'make ug && make test-ug'"; }
        # press, concept and cases are built by ldc2 too, so `dub test` runs
        # none of the book's tests.
        { run = "nix develop .#default --command sh -c 'make test-tools'"; }
        # "i expect to edit the book of ground by linking it via obsidia"
        # The book's prose is doc/book/, edited in the vault and returned by a
        # pull request. press joins every note to its case or stops naming the
        # file and line, so a pull request whose notes cannot be set is red.
        { run = "nix develop .#default --command sh -c 'make press && ./tools/press'"; }
        {
          name = "Upload coverage to Repowise";
          "if" = "always()";
          continue-on-error = true;
          shell = "bash";
          env = {
            REPORTS = "coverage.xml";
            HEAD_SHA = "\${{ github.event.pull_request.head.sha || github.sha }}";
            PR_NUMBER = "\${{ github.event.pull_request.number }}";
            RUN_URL = "\${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_id }}";
          };
          run = ''
            shopt -s globstar nullglob
            files=()
            for pattern in $REPORTS; do for f in $pattern; do [ -f "$f" ] && files+=(-F "report=@$f"); done; done
            if [ ''${#files[@]} -eq 0 ]; then echo "::warning::Repowise: no coverage report found at: $REPORTS"; exit 0; fi
            auth=()
            if [ -n "''${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
              token=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=repowise" | jq -r '.value // empty' || true)
              [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
            fi
            curl -sS --fail-with-body --max-time 60 "''${auth[@]}" "''${files[@]}" \
              -F "repository=$GITHUB_REPOSITORY" -F "head_sha=$HEAD_SHA" -F "pr_number=$PR_NUMBER" \
              -F "event=$GITHUB_EVENT_NAME" -F "run_url=$RUN_URL" -F "workspace=$GITHUB_WORKSPACE" \
              https://api.repowise.dev/ci/coverage \
              || echo "::warning::Repowise: coverage upload failed; see the message above."
          '';
        }
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
        { run = "nix build -L .#ground"; }
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
