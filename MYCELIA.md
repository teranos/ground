### 「[Opus 5.5] mycelia」

"so, why would the part that asks the node, not be able to be its own tiny binary"

「[Opus 5.5] mycelia is the one process on a machine that asks the node. What it learns it」
「[Opus 5.5] keeps under `~/.local/state/ug/`, or writes into ground's store, and every」
「[Opus 5.5] surface reads it there:」

```
「[Opus 5.5] ag           above the prompt, per session」
             the prompt
「[Opus 5.5] ug           the statusline, per session」
「[Opus 5.5] ground_tmux  the tmux row」
「[Opus 5.5] mycelia      asks the node, writes the store」
```

「[Opus 5.5] It asks the node for:」

- 「[Opus 5.5] the node's row, with each plugin's deploy, kept in `mycelia`」
- 「[Opus 5.5] what the node left on its status row as news, written into ground's store,」
  「[Opus 5.5] which sky hands to the session」
- 「[Opus 5.5] what is collected for an agent (QNTX `server/collected.go`), kept whole in」
  「[Opus 5.5] `collected`: what waits for each session, and what each session said that」
  「[Opus 5.5] waits for another」

"i see, so the tmux row, would just be named like, ground_tmux"

「[Opus 5.5] ground_tmux draws the row from the store and asks the node nothing.」

"yeah, I guess this is the clean way"

"i want both incomign and outgoing"

「[Opus 5.5] `ground collected` reads what mycelia kept for the session it runs in, by the」
「[Opus 5.5] DID of the session's own key: one line a message, due on this machine's clock,」
「[Opus 5.5] `<--` for what comes in and `-->` for what goes out. `ground collected json`」
「[Opus 5.5] is the same for ag, which draws it above the prompt.」

"kept. kept bro, i want to put my finger on, and then not have to thing about it anymore"

"next reboot i expect to have to put my finger again."

「[Opus 5.5] What a person does with what waits (release, hold, later, cancel, edit) is the」
「[Opus 5.5] person's to say. The node takes it from a session made with the passkey, and」
「[Opus 5.5] refuses it from any key, ground's own or one the person said yes to: a key is」
「[Opus 5.5] an agent's (QNTX `itsOwnDID`, ADR-060). So mycelia is a door onto the node, as」
「[Opus 5.5] the app is, and holds the person's session:」

- 「[Opus 5.5] `mycelia://door` is named in the node's `auth.rp_origins`.」
- 「[Opus 5.5] `mycelia connect` opens the browser at the node's `/auth/door/home`, where」
  「[Opus 5.5] the passkey is done. The node sends the browser back to `mycelia://door`」
  「[Opus 5.5] with a ticket; the system starts `Mycelia.app` for it, which hands the url」
  「[Opus 5.5] to the mycelia that is running. That one spends the ticket at」
  「[Opus 5.5] `/auth/door/home/result` for the session, keeps it in the Keychain,」
  「[Opus 5.5] readable once the Mac is unlocked after it starts (the finger at the login),」
  「[Opus 5.5] and says what happened in `~/.local/state/ug/session`, which」
  「[Opus 5.5] `mycelia connect` reads back. The session lasts as long as the node's」
  「[Opus 5.5] `session_expiry_hours`.」
- 「[Opus 5.5] A press is handed to mycelia over `~/.local/state/ug/mycelia.sock`, which」
  「[Opus 5.5] only the person's user opens. On the first press since it started, mycelia」
  「[Opus 5.5] takes the session out and holds it until it stops; no touch is asked, so a」
  「[Opus 5.5] restart costs none. It makes」
  「[Opus 5.5] only what a person does with what is collected in it, as a bearer.」

"i want to get past it"

「[Opus 5.5] Only a binary signed with the team's profile and its Keychain group sees the」
「[Opus 5.5] session, so mycelia is built as `Mycelia.app` and signed: `make ug/Mycelia.app`,」
「[Opus 5.5] with how this machine signs in `~/.config/mycelia/signing.mk`, outside the」
「[Opus 5.5] repository. `~/.local/bin/mycelia` points into it, and `make install-ug`」
「[Opus 5.5] registers the app for `mycelia://`.」
