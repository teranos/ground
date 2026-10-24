"""The CTFE benchmark: build what ground ships, say what it cost, and attest it.

The measurement is the Makefile's own: the production build, timed, with its
peak resident size. Here it is a forced rebuild, so a cached object cannot
stand in for the work. The result is one attestation row, bench-ctfe.json,
appended on the node, never replaced, so the series is every run.

On a hosted runner the row travels as the run's artifact: ground attests the
push, sky streams that row to the node, and the node's ci.watch takes the
bench-ctfe artifact of the concluded run (teranos/QNTX#1390). A node named by
QNTX_URL and QNTX_TOKEN is posted to as well, from a machine that reaches one.
"""
import json
import os
import platform
import resource
import subprocess
import sys
import time
import urllib.error
import urllib.request


def out(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def main():
    url, token = os.environ.get("QNTX_URL", ""), os.environ.get("QNTX_TOKEN", "")
    # On a runner the token is a secret in the environment; on a machine it is
    # the file ground itself reads, named so the secret never crosses a command line.
    if not token and os.environ.get("QNTX_TOKEN_FILE"):
        token = open(os.path.expanduser(os.environ["QNTX_TOKEN_FILE"])).read().strip()
    if bool(url) != bool(token):
        print("bench: QNTX_URL and QNTX_TOKEN (or QNTX_TOKEN_FILE) name a node together; one is missing", file=sys.stderr)
        return 1
    subprocess.run(["make", "wind"], check=True)
    ldc = out(["ldc2", "--version"]).splitlines()[0]
    sha = out(["git", "rev-parse", "HEAD"])
    version = open(".version").read().strip()
    runner = os.environ.get("RUNNER_OS", platform.system()).lower()
    # A hosted runner is the same machine every time; a host is whichever ran it.
    where = ("github:" if os.environ.get("GITHUB_ACTIONS") else "host:") + runner
    build = ["dub", "build", "--build=release", "--config=production", "--force"]
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    rc = subprocess.run(build).returncode
    seconds = round(time.monotonic() - start, 2)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    # ru_maxrss is the largest child so far: bytes on macOS, KiB on Linux.
    peak = after.ru_maxrss if platform.system() == "Linux" else after.ru_maxrss // 1024
    if rc != 0:
        print("bench: the build failed with %d after %.2fs" % (rc, seconds), file=sys.stderr)
        return rc
    # One id per measurement, so a POST that timed out and is sent again is
    # the same row: k took 90 s to answer once and the retry made a second.
    ran = os.environ.get("GITHUB_RUN_ID") or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    row = {
        "id": "ground:bench:ctfe:" + sha[:12] + ":" + runner + ":" + ran,
        "subjects": ["ground:" + version],
        "predicates": ["bench:ctfe"],
        "contexts": [where],
        "actors": ["ground-ci"],
        "source": "ground-ci",
        "attributes": {
            "seconds": seconds,
            "peak_kib": peak,
            "ldc": ldc,
            "sha": sha,
            "version": version,
            "runner": runner,
        },
    }
    if os.environ.get("GITHUB_RUN_ID"):  # the run this row came from; a machine has none
        row["attributes"]["run"] = "%s/%s/actions/runs/%s" % (
            os.environ["GITHUB_SERVER_URL"], os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_RUN_ID"])
    print(json.dumps(row, indent=1))
    # The row is also a file, so a run's artifact holds it for a node that
    # pulls rather than one that is posted to (ADR-043's shape).
    with open("bench-ctfe.json", "w") as f:
        json.dump(row, f)
    if not url:
        print("bench: no node named; the row is bench-ctfe.json, the run's artifact, for ci.watch to take")
        return 0
    req = urllib.request.Request(url.rstrip("/") + "/api/attestations", data=json.dumps(row).encode(),
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            print("bench: %d %s" % (r.status, r.read().decode()))
    except urllib.error.HTTPError as e:
        print("bench: the node refused the row: %d %s" % (e.code, e.read().decode()), file=sys.stderr)
        return 1
    except (urllib.error.URLError, OSError) as e:
        print("bench: the node was not reached at %s: %s" % (url, e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
