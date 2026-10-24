# The bench workflow. .github/workflows/bench.yml is emitted from this and is
# never edited by hand:
#   nix eval --json --file ci/bench.nix | jq . > .github/workflows/bench.yml
let
  checkout = {
    uses = "actions/checkout@v6";
    "with".fetch-depth = 0;
  };
  installNix.uses = "cachix/install-nix-action@v30";
in
{
  name = "bench";

  # On pull requests too: k's ci.watch watches the sha ground's hook attested
  # when the laptop pushed, and a merge GitHub makes is no laptop push. The
  # branch's run is the one whose artifact reaches k.
  on = {
    push.branches = [ "main" ];
    pull_request = null;
    workflow_dispatch = { };
  };

  # "can we use a github runner, hosted public one, to do ci benchmarking of the
  # CTFE, and make sure those results end up in QNTX"
  jobs.ctfe = {
    # One hosted runner, the same every time. ci/bench.py is the measurement and the row.
    runs-on = "ubuntu-latest";
    steps = [
      checkout
      installNix
      # No node is posted to from here: the Ground namespace lives on k, which a
      # hosted runner does not reach. The row is the run's artifact, and k's
      # ci.watch takes it from the run of the push it watches (QNTX#1390).
      {
        name = "build what ships, time it, write the row";
        run = "nix develop .#default --command python3 ci/bench.py";
      }
      {
        "if" = "always()";
        uses = "actions/upload-artifact@v7";
        "with" = {
          name = "bench-ctfe";
          path = "bench-ctfe.json";
          if-no-files-found = "ignore";
        };
      }
    ];
  };
}
