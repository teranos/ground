module codex_policy_sand;

import proto : parsePbt;
import sand.view : Sand, viewOf, SAND_ABI;

// A separate compiled sand proves the installed hook reads PBT policy from
// a loaded library, including an override that disables all network work.
private immutable parsed = parsePbt(`
scope {
  path: "/custom"
  event: ["PreModelRequest", "PostModelRequest"]
  control {
    name: "codex-effort"
    interval: "90"
    handler_params { medium_below: "70" low_below: "30" }
  }
}
scope {
  path: "/disabled"
  event: ["PreModelRequest", "PostModelRequest"]
  control { name: "codex-effort" handler_params { enabled: "false" } }
}
`);

private immutable compiled = Sand(SAND_ABI, viewOf(parsed));
export extern(C) const(Sand)* ground_sand() { return &compiled; }
