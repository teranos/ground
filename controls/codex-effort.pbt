# Remaining Codex quota, strictly below each threshold. Claude is independent.
# Local or project sand can override this control, or set enabled: "false".
scope {
  event: ["PreModelRequest", "PostModelRequest"]
  control {
    name: "codex-effort"
    interval: "60"
    handler_params {
      enabled: "true"
      medium_below: "50"
      low_below: "20"
    }
  }
}
