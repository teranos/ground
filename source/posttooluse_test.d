module posttooluse_test;

import posttooluse : postToolUseMatch, modeMatches, isGitPushCommand;
import hooks : Control, Cmd, cmd, Msg, FilePath, Mode;

// --- isGitPushCommand: detection for the CI status writer ---
// Closes the substring-match hole where `git -C <path> push` was silently
// ignored. Verified on the ground db: ~20% of historical push commands
// used the -C form and never fired writeCIStatus.

// Plain forms — must detect
static assert(isGitPushCommand("git push"));
static assert(isGitPushCommand("git push origin main"));
static assert(isGitPushCommand("git push --force-with-lease"));
static assert(isGitPushCommand("git push origin v0.1.0"));

// -C forms — the bug case
static assert(isGitPushCommand("git -C /path push"));
static assert(isGitPushCommand("git -C /Users/me/repo push"));
static assert(isGitPushCommand("git -C /path push origin main"));
static assert(isGitPushCommand(`git -C "/path with spaces" push`));

// -c <config> forms
static assert(isGitPushCommand("git -c user.email=x push"));

// Compound commands containing push
static assert(isGitPushCommand("git add . && git -C /path push"));
static assert(isGitPushCommand("cd /tmp && git push"));

// Negatives — must NOT detect
static assert(!isGitPushCommand("git status"));
static assert(!isGitPushCommand(`git commit -m "fix"`));
static assert(!isGitPushCommand(`git commit -m "run git push later"`));

// --- cmd matching ---

enum cmdCtrl = () { Control c; c.cmd = cmd("git commit"); c.msg = Msg("push follows"); return c; }();
static assert(postToolUseMatch(cmdCtrl, "git commit -m \"fix\"", null));
static assert(!postToolUseMatch(cmdCtrl, "git push", null));

// --- filepath matching ---

enum fpCtrl = () { Control c; c.filepath = FilePath(".pbt"); c.msg = Msg("Run make install"); return c; }();
static assert(postToolUseMatch(fpCtrl, null, "/Users/me/ground/controls/permissions.pbt"));
static assert(!postToolUseMatch(fpCtrl, null, "/Users/me/ground/source/main.d"));
static assert(!postToolUseMatch(fpCtrl, null, null));

// --- mode matching ---

// modeMatches basics
static assert(modeMatches("r", "Read"));
static assert(modeMatches("r", "Glob"));
static assert(modeMatches("r", "Grep"));
static assert(modeMatches("r", "LSP"));
static assert(modeMatches("w", "Edit"));
static assert(modeMatches("w", "Write"));
static assert(modeMatches("w", "NotebookEdit"));
static assert(modeMatches("x", "Bash"));
static assert(modeMatches("a", "Agent"));
static assert(!modeMatches("r", "Edit"));
static assert(!modeMatches("w", "Read"));
static assert(!modeMatches("x", "Edit"));

// combined modes
static assert(modeMatches("rw", "Read"));
static assert(modeMatches("rw", "Edit"));
static assert(!modeMatches("rw", "Bash"));
static assert(modeMatches("rwx", "Bash"));

// mode on control — control.w fires for Edit, not Read
enum modeCtrl = () { Control c; c.mode = Mode("w"); c.filepath = FilePath(".pbt"); c.msg = Msg("Rebuild"); return c; }();
static assert(postToolUseMatch(modeCtrl, null, "/Users/me/ground/controls/permissions.pbt", "Edit"));
static assert(postToolUseMatch(modeCtrl, null, "/Users/me/ground/controls/permissions.pbt", "Write"));
static assert(!postToolUseMatch(modeCtrl, null, "/Users/me/ground/controls/permissions.pbt", "Read"));

// f mode — WebFetch and WebSearch only
static assert(modeMatches("f", "WebFetch"));
static assert(modeMatches("f", "WebSearch"));
static assert(!modeMatches("f", "Read"));
static assert(!modeMatches("f", "Bash"));
static assert(!modeMatches("f", "Edit"));

// f no longer in r
static assert(!modeMatches("r", "WebFetch"));
static assert(!modeMatches("r", "WebSearch"));

// no mode, no tool — fires for any tool
static assert(postToolUseMatch(fpCtrl, null, "/Users/me/ground/controls/permissions.pbt", "Read"));
static assert(postToolUseMatch(fpCtrl, null, "/Users/me/ground/controls/permissions.pbt", "Edit"));
