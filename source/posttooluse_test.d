module posttooluse_test;

import posttooluse : postToolUseMatch, modeMatches, isGitPushCommand,
                     toolSegment, sessionSegment, sessionMatches;
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

// --- the session axis ---

// A second dot segment names the session mode. Tool letters stop at the dot.
static assert(toolSegment("w") == "w");
static assert(toolSegment("rw.pa") == "rw");
static assert(toolSegment("w.auto") == "w");

static assert(sessionSegment("w") == "");
static assert(sessionSegment("rw.pa") == "pa");
static assert(sessionSegment("w.auto") == "auto");

// Iterating the whole string let the `a` in acceptEdits match Agent, so every
// session-qualified rule silently widened to a tool it never named.
static assert(modeMatches("w.acceptEdits", "Write"));
static assert(!modeMatches("w.acceptEdits", "Agent"));
static assert(modeMatches("rw.pa", "Read"));
static assert(modeMatches("rw.pa", "Edit"));
static assert(!modeMatches("rw.pa", "Agent"));

// An absent session segment is every mode, which is what every block written
// before today means.
static assert(sessionMatches("", "default"));
static assert(sessionMatches("", "acceptEdits"));
static assert(sessionMatches("", "bypassPermissions"));

// Manual arrives as default and never as manual.
static assert(sessionMatches("m", "default"));
static assert(!sessionMatches("m", "acceptEdits"));
static assert(sessionMatches("p", "plan"));
static assert(sessionMatches("d", "dontAsk"));
static assert(sessionMatches("b", "bypassPermissions"));

// `a` is both permissive modes: a rule written for one almost always means
// the other.
static assert(sessionMatches("a", "acceptEdits"));
static assert(sessionMatches("a", "auto"));
static assert(!sessionMatches("a", "default"));

// Letters combine, the way rw does on the tool side.
static assert(sessionMatches("pa", "plan"));
static assert(sessionMatches("pa", "acceptEdits"));
static assert(sessionMatches("pa", "auto"));
static assert(!sessionMatches("pa", "default"));
static assert(sessionMatches("mb", "default"));
static assert(sessionMatches("mb", "bypassPermissions"));
static assert(!sessionMatches("mb", "plan"));

// A full name is exact where a letter is broad.
static assert(sessionMatches("auto", "auto"));
static assert(!sessionMatches("auto", "acceptEdits"));
static assert(sessionMatches("acceptEdits", "acceptEdits"));
static assert(!sessionMatches("acceptEdits", "auto"));
static assert(sessionMatches("default", "default"));
static assert(sessionMatches("dontAsk", "dontAsk"));
static assert(sessionMatches("bypassPermissions", "bypassPermissions"));

// Each name carries a character outside {m,p,a,d,b}, so no name reads as a
// letter set.
static assert(!sessionMatches("default", "plan"));
static assert(!sessionMatches("plan", "default"));
static assert(!sessionMatches("dontAsk", "default"));
static assert(!sessionMatches("bypassPermissions", "plan"));

// A mode ground does not recognise matches nothing rather than everything.
static assert(!sessionMatches("m", "sideways"));
static assert(!sessionMatches("acceptEdits", ""));
