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

  on = {
    push.branches = [ "main" ];
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
      {
        name = "build what ships, time it, attest it";
        env = {
          QNTX_URL = "https://api.q.sbvh.nl";
          QNTX_TOKEN = "\${{ secrets.QNTX_TOKEN }}";
        };
        run = "nix develop .#default --command python3 ci/bench.py";
      }
    ];
  };
}
