module exec;

// Merged env for the exec child. 24 = 8 (control) + 16 (project) — the
// max possible if both are full with disjoint keys. Runtime never sees
// more than this.
struct MergedEnv {
    string[24] keys;
    string[24] values;
    ubyte count;
}

// Layer control-env on top of project-env. Control wins on collision;
// non-colliding pairs union together. Position is stable: project pairs
// first (in arrival order), then non-collision control pairs. Colliding
// control values overwrite in place — the key does not move.
//
// GROUND_-prefixed vars (session_id, cwd, tool_input) are prepended at
// runtime dispatch time, not by this function. This function stays pure
// so the precedence rule can be locked in via CTFE tests.
MergedEnv mergeEnv(
    const(string)[] controlKeys, const(string)[] controlValues,
    const(string)[] projectKeys, const(string)[] projectValues,
) {
    MergedEnv result;

    foreach (i; 0 .. projectKeys.length) {
        if (projectKeys[i] is null || projectKeys[i].length == 0) continue;
        result.keys[result.count] = projectKeys[i];
        result.values[result.count] = projectValues[i];
        result.count++;
    }

    foreach (i; 0 .. controlKeys.length) {
        if (controlKeys[i] is null || controlKeys[i].length == 0) continue;
        bool overwritten = false;
        foreach (j; 0 .. result.count) {
            if (result.keys[j] == controlKeys[i]) {
                result.values[j] = controlValues[i];
                overwritten = true;
                break;
            }
        }
        if (!overwritten) {
            result.keys[result.count] = controlKeys[i];
            result.values[result.count] = controlValues[i];
            result.count++;
        }
    }

    return result;
}
