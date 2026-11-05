module push_test;

import push : hasPathStartingWith, parsePushOutput, PushInfo;

// --- parsePushOutput: extract repo + branch + SHA from git push stdout ---
// Source of truth: the push's own output. Lets ground identify which CI run
// the user just triggered without ever touching cwd.

// Plain SSH remote, fast-forward push
enum sshOut = "To github.com:acme/widget.git\n   1111111..2222222  main -> main\n";
static assert(parsePushOutput(sshOut).repo == "acme/widget");
static assert(parsePushOutput(sshOut).branch == "main");
static assert(parsePushOutput(sshOut).sha == "2222222");

// HTTPS remote
enum httpsOut = "To https://github.com/acme/widget.git\n   1111111..2222222  main -> main\n";
static assert(parsePushOutput(httpsOut).repo == "acme/widget");

// SSH remote without trailing .git
enum noGitOut = "To git@github.com:acme/widget\n   3333333..4444444  main -> main\n";
static assert(parsePushOutput(noGitOut).repo == "acme/widget");
static assert(parsePushOutput(noGitOut).branch == "main");

// New-branch push (no SHAs to compare)
enum newBranchOut = "To github.com:acme/widget.git\n * [new branch]      feature -> feature\n";
static assert(parsePushOutput(newBranchOut).repo == "acme/widget");
static assert(parsePushOutput(newBranchOut).branch == "feature");

// Branch with different local/remote name
enum renamedOut = "To github.com:owner/repo.git\n   aaa1111..bbb2222  local-name -> remote-name\n";
static assert(parsePushOutput(renamedOut).branch == "local-name");
static assert(parsePushOutput(renamedOut).repo == "owner/repo");

// Forced push: three dots, and the sha is what follows the last of them.
// Read as ".b9c08f8f", the node asked github for a sha that is not one and
// the statusline showed the refusal.
enum forcedOut = "To github.com:teranos/QNTX.git\n + bec31583...b9c08f8f a-canvas-lives-in-its-namespace -> a-canvas-lives-in-its-namespace (forced update)\n";
static assert(parsePushOutput(forcedOut).repo == "teranos/QNTX");
static assert(parsePushOutput(forcedOut).branch == "a-canvas-lives-in-its-namespace");
static assert(parsePushOutput(forcedOut).sha == "b9c08f8f");

// Empty / non-push output — returns empty PushInfo
static assert(parsePushOutput("").repo.length == 0);
static assert(parsePushOutput("some random text\n").repo.length == 0);

// Empty input — no match.
static assert(!hasPathStartingWith("", "universe/"));

// Single-line match at line start.
static assert(hasPathStartingWith("universe/src/lib.rs\n", "universe/"));

// Single-line no match.
static assert(!hasPathStartingWith("roam/Cargo.toml\n", "universe/"));

// Multi-line — match anywhere in the list.
static assert(hasPathStartingWith("universe/src/lib.rs\nroam/Cargo.toml\n", "universe/"));
static assert(hasPathStartingWith("roam/Cargo.toml\nuniverse/src/lib.rs\n", "universe/"));

// Multi-line — none match.
static assert(!hasPathStartingWith("roam/Cargo.toml\nccg/x.rs\n", "universe/"));

// Substring inside path — must NOT match (prefix is line-anchored).
static assert(!hasPathStartingWith("docs/universe/about.md\n", "universe/"));

// No trailing newline on last line still works.
static assert(hasPathStartingWith("roam/Cargo.toml\nuniverse/src/lib.rs", "universe/"));

// All four monorepo subdirs.
static assert(hasPathStartingWith("relayer/src/main.rs\n", "relayer/"));
static assert(hasPathStartingWith("ccg/src/lib.rs\n", "ccg/"));
static assert(hasPathStartingWith("roam/src/lib.rs\n", "roam/"));
static assert(hasPathStartingWith("universe/src/lib.rs\n", "universe/"));

// --- deletesOnly: a push that removes refs carries no line to check ---
import push : deletesOnly;
static assert(deletesOnly("git push origin --delete old-branch"));
static assert(deletesOnly("git -C /srv/app push -q origin --delete a b"));
static assert(deletesOnly("git push origin -d old-branch"));
static assert(deletesOnly("git push origin :old-branch"));
static assert(!deletesOnly("git push origin main"));
static assert(!deletesOnly("git push -u origin feature"));
static assert(!deletesOnly("git push origin main :old-branch"));
static assert(!deletesOnly("git status"));

// 「[Opus 5.5] --- pushedBranch: the remote branch a push lands on, when its one refspec names it ---」
// 「[Opus 5.5] A push of HEAD:libacp from a detached worktree was read against origin/main:」
// 「[Opus 5.5] every commit libacp holds, two seconds, for a push carrying a few.」
import push : pushedBranch;
static assert(pushedBranch("git push -q origin HEAD:libacp 2>&1") == "libacp");
static assert(pushedBranch("git push origin +HEAD:libacp") == "libacp");
static assert(pushedBranch("git push origin HEAD:refs/heads/libacp") == "libacp");
static assert(pushedBranch("git push --force-with-lease=libacp:abc origin HEAD:libacp") == "libacp");
static assert(pushedBranch("git -C /srv/app push origin local-name:remote-name") == "remote-name");
static assert(pushedBranch("git push -u origin feature") == "feature");
static assert(pushedBranch("git push origin refs/heads/feature") == "feature");
// 「[Opus 5.5] Nothing named: the branch checked out answers, as it did.」
static assert(pushedBranch("git push") == "");
static assert(pushedBranch("git push origin") == "");
static assert(pushedBranch("git push -q -u origin HEAD") == "");
static assert(pushedBranch("git push -q origin HEAD 2>&1") == "");
// 「[Opus 5.5] More than one landing place is not one range.」
static assert(pushedBranch("git push origin a b") == "");
static assert(pushedBranch("git status") == "");
