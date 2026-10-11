# "the performace notification should only apply to select projects defined in pbt"

# Ground's own latency is ground's to work on, so this is the project that asks
# to hear about a breach. An install that declares no such control never sees
# the notice, however far over budget its hooks run.
scope {
  event: "Stop"
  path: "/teranos/ground"

  control {
    name: "ground-timing"
    timing: "true"
  }
}
