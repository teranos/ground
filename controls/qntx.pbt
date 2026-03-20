# QNTX — commands
# TODO: catch entity IDs used as subjects — IDs belong in attributes, not subjects
scope {
  path: "/QNTX"
  decision: "allow"
  event: "PreToolUse"

  control {
    name: "go-test-args"
    cmd: "go test"
    arg: `-tags "rustsqlite,qntxwasm" -short`
    msg: "Build tags and -short are required for go test in QNTX"
  }

  control {
    name: "sqlite-db-path"
    cmd: "sqlite3"
    msg: "The db path is in am.toml in the project root. Check it before guessing."
  }
}

# QNTX — file-path controls
scope {
  path: "/QNTX"
  decision: "allow"
  event: "PreToolUseFile"

  control {
    name: "web-docs-reminder"
    filepath: "/web/"
    msg: "Read web/CLAUDE.md before editing frontend files."
  }

  control {
    name: "web-ts-banned"
    filepath: "/web/ts/"
    msg: "BANNED in frontend: alert(), confirm(), prompt(), toast(). Button component has built-in error handling (throw from onClick). Check component APIs before implementing."
  }

  control {
    name: "plugin-install"
    filepath: "/qntx-plugins/"
    msg: "The user prefers not having to run make <plugin-name>-plugin every time you finish working on one, do it for them."
  }

  control {
    name: "web-testing-docs"
    filepath: ".test.ts"
    msg: "Read web/TESTING.md before writing or editing tests. CI uses USE_JSDOM=1. .dom.test.ts files use JSDOM skip pattern. happy-dom is the local default."
  }

  control {
    name: "no-dotqntx-home"
    filepath: "/Users/s.b.vanhouten/.qntx"
    msg: "STOP. am.toml is in the project root. Never read from ~/.qntx/ — stay in the repo directory."
  }
}

# QNTX — UserPromptSubmit
scope {
  path: "/QNTX"
  decision: "allow"
  event: "UserPromptSubmit"

  control {
    name: "ax-reminder"
    userprompt: "ax"
    msg: "AX — attestation query, a natural-language-like syntax (Tim is tester of QNTX by attestor)"
  }

  control {
    name: "adr-reminder"
    userprompt: "ADR"
    msg: "ADRs are in docs/adr/ in the QNTX repo"
  }
}

# QNTX — PreCompact
scope {
  path: "/QNTX"
  decision: "allow"
  event: "PreCompact"

  control {
    name: "qntx-am-toml"
    msg: "am.toml in the project root has the db path and node configuration. Check it before assuming database locations."
  }
}
