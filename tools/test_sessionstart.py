"""Run with python3 tools/test_sessionstart.py /path/to/ground_hook."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="ground-start-") as directory:
    home = Path(directory)
    env = dict(os.environ, HOME=directory)
    bindir = home / "bin"
    bindir.mkdir()
    marker = home / "claude-called"
    claude = bindir / "claude"
    claude.write_text("""#!/bin/sh
touch "$HOME/claude-called"
echo '{"subscriptionType":"max"}'
""")
    claude.chmod(0o755)
    env["PATH"] = str(bindir) + os.pathsep + env["PATH"]

    def hook(source=None, **fields):
        payload = dict(session_id="ground-start-test", cwd=directory,
                       hook_event_name="SessionStart" if source else "TestInit")
        if source:
            payload["source"] = source
        payload.update(fields)
        result = subprocess.run([binary], input=json.dumps(payload), text=True,
                                capture_output=True, env=env, timeout=15)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout) if result.stdout.strip() else {}

    hook()
    db = sqlite3.connect(home / ".local/share/ground/ground.db")

    def seed(kind, value, age=0):
        db.execute("DELETE FROM attestations WHERE subjects = ? AND predicates = ?",
                   (json.dumps([kind]), '["check"]'))
        db.execute("INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES (?, ?, ?, ?, ?, datetime('now'), ?, ?)",
                   ("test:" + kind, json.dumps([kind]), '["check"]', '["ground"]',
                    '["ground"]', 'test', json.dumps(dict(value=value, exit=0, checked_at=int(time.time())-age))))
        db.commit()

    seed("release", "v0.0.0")
    seed("plan", "max")
    for source in ("startup", "resume", "compact", "clear"):
        # Codex SessionStart has no turn_id; tools' detection cannot be used here.
        output = hook(source, scratchpad_dir=str(home / "scratch"), model="gpt-5")
        assert "plan" not in output["systemMessage"], output
        assert output["systemMessage"].startswith("up "), output
        output = hook(source, permission_mode="default", model="claude-test")
        assert "plan max" in output["systemMessage"], output
    assert not marker.exists(), "cached checks should not invoke Claude"

    seed("plan", "max", age=172800)
    output = hook("compact", scratchpad_dir=str(home / "scratch"))
    assert "plan" not in output["systemMessage"], output
    assert not marker.exists(), "Codex must not refresh Claude's plan"
    output = hook("compact", permission_mode="bypassPermissions")
    assert "plan max" in output["systemMessage"], output
    assert marker.exists(), "Claude should still refresh its own stale plan"
    db.close()
print("SessionStart: Codex has no Claude plan; Claude retains cached and refreshed plans.")
