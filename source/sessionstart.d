module sessionstart;

import core.stdc.stdio : stdout, fputs;
import matcher : contains;

// Only arch — Claude already receives Platform and OS Version from the environment.
version (X86_64) enum ARCH = "x86_64";
else version (AArch64) enum ARCH = "aarch64";
else enum ARCH = "unknown";

enum SESSION_CONTEXT = `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"arch: ` ~ ARCH ~ `"}}` ~ "\n";

int handleSessionStart(const(char)[] source) {
    // Arch context on fresh starts only
    if (source is null || contains(source, "startup") || contains(source, "clear")) {
        fputs(SESSION_CONTEXT.ptr, stdout);
        return 0;
    }

    // TODO(#23): compact — re-inject session awareness lost in compaction
    // TODO(#24): resume — stale branch awareness after time away
    return 0;
}
