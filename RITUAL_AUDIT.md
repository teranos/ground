# RITUAL_AUDIT

Every file this branch touches, against every rule. A cell is marked when that
file has been read against that rule and holds.

- **narrative** — factual, or gone. No "used to", "which is how", "before this".
- **incident** — no twenty minutes, no 987, no war stories.
- **the** — a node, a deployment. Never the node, the box, the deployment.
- **inversions** — "a grammatical slot", not "not a scope".
- **refs** — no line-number references. Name the thing.
- **leaks** — no account, no host, no operational posture.
- **dup** — what an ADR says is linked, not repeated.
- **meta** — nothing about the change itself.
- **hedges** — no caveats, no unsure language.

| file | narrative | incident | the | inversions | refs | leaks | dup | meta | hedges | done |
|---|---|---|---|---|---|---|---|---|---|---|
| `.github/workflows/long-coin.yml` | | | | | | | | | | |
| `.github/workflows/medium-sun.yml` | | | | | | | | | | |
| `.github/workflows/short-moon.yml` | | | | | | | | | | |
| `.gitignore` | | | | | | | | | | |
| `AGENT.md` | | | | | | | | | | |
| `CLAUDE.md` | | | | | | | | | | |
| `ERROR.md` | | | | | | | | | | |
| `INTERRUPT.md` | | | | | | | | | | |
| `README.md` | | | | | | | | | | |
| `RITUAL.md` | | | | | | | | | | |
| `SUBAGENT.md` | | | | | | | | | | |
| `controls/controls.pbt` | | | | | | | | | | |
| `controls/permissions.pbt` | | | | | | | | | | |
| `grove/MOON.md` | | | | | | | | | | |
| `grove/README.md` | | | | | | | | | | |
| `grove/WILLOW.md` | | | | | | | | | | |
| `grove/controls/2goto.pbt` | | | | | | | | | | |
| `grove/controls/chapters.pbt` | | | | | | | | | | |
| `grove/controls/coinflip.pbt` | | | | | | | | | | |
| `grove/controls/grove.pbt` | | | | | | | | | | |
| `grove/controls/moon.pbt` | | | | | | | | | | |
| `grove/controls/perpetuity.pbt` | | | | | | | | | | |
| `grove/controls/ritual-of-control.pbt` | | | | | | | | | | |
| `grove/controls/sun.pbt` | | | | | | | | | | |
| `plugin/hooks/hooks.json` | | | | | | | | | | |
| `source/advance_test.d` | | | | | | | | | | |
| `source/apierror.d` | | | | | | | | | | |
| `source/apierror_test.d` | | | | | | | | | | |
| `source/binary.d` | | | | | | | | | | |
| `source/binary_test.d` | | | | | | | | | | |
| `source/briefing_test.d` | | | | | | | | | | |
| `source/choose_test.d` | | | | | | | | | | |
| `source/consent_test.d` | | | | | | | | | | |
| `source/contend_test.d` | | | | | | | | | | |
| `source/control_handlers.d` | | | | | | | | | | |
| `source/control_handlers_test.d` | | | | | | | | | | |
| `source/control_ritual_test.d` | | | | | | | | | | |
| `source/controls.d` | | | | | | | | | | |
| `source/count.d` | | | | | | | | | | |
| `source/db.d` | | | | | | | | | | |
| `source/db_schema_test.d` | | | | | | | | | | |
| `source/deferred.d` | | | | | | | | | | |
| `source/delivery_test.d` | | | | | | | | | | |
| `source/dispatch.d` | | | | | | | | | | |
| `source/dispatch_test.d` | | | | | | | | | | |
| `source/drive_test.d` | | | | | | | | | | |
| `source/exec.d` | | | | | | | | | | |
| `source/hooks.d` | | | | | | | | | | |
| `source/immediate.d` | | | | | | | | | | |
| `source/intent_test.d` | | | | | | | | | | |
| `source/main.d` | | | | | | | | | | |
| `source/matcher.d` | | | | | | | | | | |
| `source/matcher_test.d` | | | | | | | | | | |
| `source/messagedisplay.d` | | | | | | | | | | |
| `source/messagedisplay_test.d` | | | | | | | | | | |
| `source/mic.d` | | | | | | | | | | |
| `source/mic_test.d` | | | | | | | | | | |
| `source/notification.d` | | | | | | | | | | |
| `source/notification_test.d` | | | | | | | | | | |
| `source/parent_test.d` | | | | | | | | | | |
| `source/posttooluse.d` | | | | | | | | | | |
| `source/pretooluse.d` | | | | | | | | | | |
| `source/proto.d` | | | | | | | | | | |
| `source/proto_ritual_test.d` | | | | | | | | | | |
| `source/reap_test.d` | | | | | | | | | | |
| `source/reaper_test.d` | | | | | | | | | | |
| `source/receiver.d` | | | | | | | | | | |
| `source/rite.d` | | | | | | | | | | |
| `source/rite_attest_test.d` | | | | | | | | | | |
| `source/rite_error_test.d` | | | | | | | | | | |
| `source/rite_script_test.d` | | | | | | | | | | |
| `source/rite_test.d` | | | | | | | | | | |
| `source/ritual/command.d` | | | | | | | | | | |
| `source/ritual/consent.d` | | | | | | | | | | |
| `source/ritual/delivery.d` | | | | | | | | | | |
| `source/ritual/drive.d` | | | | | | | | | | |
| `source/ritual/intent.d` | | | | | | | | | | |
| `source/ritual/package.d` | | | | | | | | | | |
| `source/ritual/position.d` | | | | | | | | | | |
| `source/ritual/record.d` | | | | | | | | | | |
| `source/ritual/resolve.d` | | | | | | | | | | |
| `source/ritual/run.d` | | | | | | | | | | |
| `source/ritual/store.d` | | | | | | | | | | |
| `source/ritual_resolve_test.d` | | | | | | | | | | |
| `source/ritual_test.d` | | | | | | | | | | |
| `source/sentences.d` | | | | | | | | | | |
| `source/sentences_test.d` | | | | | | | | | | |
| `source/session_bind_test.d` | | | | | | | | | | |
| `source/sessionstart.d` | | | | | | | | | | |
| `source/shortid_test.d` | | | | | | | | | | |
| `source/spawn_test.d` | | | | | | | | | | |
| `source/stop.d` | | | | | | | | | | |
| `source/stopfailure.d` | | | | | | | | | | |
| `source/substitute.d` | | | | | | | | | | |
| `source/substitute_test.d` | | | | | | | | | | |
| `source/watch.d` | | | | | | | | | | |
| `source/watch_test.d` | | | | | | | | | | |
| `source/wiring_test.d` | | | | | | | | | | |
| `source/worktree.d` | | | | | | | | | | |
| `source/worktree_test.d` | | | | | | | | | | |
| `tools/wind.d` | | | | | | | | | | |
