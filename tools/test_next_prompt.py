"""Run python3 tools/test_next_prompt.py /path/to/ground_hook.

Uses an isolated store to check the persisted queue -> prompt -> receipt path.
"""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="ground-prompt-") as directory:
    env = dict(os.environ, HOME=directory)
    env.pop("GROUND_SAND", None)

    def hook(event, session="owner", **fields):
        payload = dict(hook_event_name=event, session_id=session, cwd=directory)
        payload.update(fields)
        r = subprocess.run([binary], input=json.dumps(payload), text=True,
                           capture_output=True, env=env, timeout=15)
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout) if r.stdout.strip() else {}

    hook("TestInit")
    db = sqlite3.connect(Path(directory) / ".local/share/ground/ground.db")
    detail = 'Background "context"\nfor your next request.'
    db.execute("INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, attributes) VALUES (?, ?, ?, ?, ?, datetime('now'), ?)",
               ("test-prompt", '["ground"]', '["prompt:note"]', '["session:owner"]',
                '["ground"]', json.dumps(dict(detail=detail, after=0, delivery="next_user_prompt"))))
    db.commit()
    assert not hook("UserPromptSubmit", session="other", prompt="hello")
    assert not hook("UserPromptSubmit", prompt="")
    result = hook("UserPromptSubmit", prompt="hello")
    assert result["hookSpecificOutput"]["additionalContext"] == detail, result
    assert "decision" not in result and "systemMessage" not in result, result
    assert not hook("UserPromptSubmit", prompt="hello again")
    receipts = db.execute("SELECT COUNT(*) FROM attestations WHERE json_extract(predicates, '$[0]')='delivered:test-prompt'").fetchone()[0]
    assert receipts == 1, receipts
    db.close()
print("Prompt delivery: session isolated, empty prompt retained, context delivered once with receipt.")
