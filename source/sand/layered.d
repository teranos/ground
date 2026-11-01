module sand.layered;

// "i want FLOOR+LOCALSAND+COMET"
// The three held together: every scope of each, once. What names one thing (the node, the orgs,
// the rituals) comes from the most specific sand held: the comet, else the local sand, else the floor.

import sand.view : Sand;
import hooks : Scope, Control;
import permission : PermissionScope;
import strop : Strop;

// floor, local and comet layered into one Sand. A null layer is not held. The result lives until exit.
const(Sand)* layer(const(Sand)* floor, const(Sand)* local, const(Sand)* comet) {
    import core.stdc.stdlib : malloc;
    import core.stdc.string : memcpy;

    const(Sand)*[3] held = [floor, local, comet];
    const(Sand)* top = floor;
    foreach (s; held) if (s !is null) top = s;

    auto out_ = cast(Sand*) malloc(Sand.sizeof);
    memcpy(out_, top, Sand.sizeof);

    // The strop pools, end to end: a control's stropIdx is moved by where its own pool begins.
    size_t[3] base;
    size_t poolLen = 0;
    foreach (i, s; held) {
        base[i] = poolLen;
        if (s !is null) poolLen += s.stropPool.length;
    }
    auto pool = cast(Strop*) malloc(Strop.sizeof * (poolLen == 0 ? 1 : poolLen));
    size_t at = 0;
    foreach (s; held) {
        if (s is null) continue;
        foreach (ref st; s.stropPool) memcpy(&pool[at++], &st, Strop.sizeof);
    }
    out_.stropPool = cast(const(Strop)[]) pool[0 .. poolLen];

    static foreach (field; ["preToolUse", "userPrompt", "stop", "sessionStart", "postToolUse",
                            "postToolUseDeferred", "postToolUseFailure", "preCompact"]) {{
        const(Scope)[][3] parts;
        foreach (i, s; held) if (s !is null) parts[i] = __traits(getMember, s, field);
        __traits(getMember, out_, field) = scopesOf(parts, base);
    }}

    const(PermissionScope)[][3] perms;
    foreach (i, s; held) if (s !is null) perms[i] = s.permission;
    out_.permission = permissionsOf(perms);

    const(string)[][3] files;
    foreach (i, s; held) if (s !is null) files[i] = s.projectFiles;
    out_.projectFiles = stringsOf(files);
    return out_;
}

// Every scope of each layer, the first time it is seen, its controls moved onto the joined pool.
private const(Scope)[] scopesOf(const(Scope)[][3] parts, size_t[3] base) {
    import core.stdc.stdlib : malloc;
    import core.stdc.string : memcpy;
    size_t total = 0;
    foreach (p; parts) total += p.length;
    auto out_ = cast(Scope*) malloc(Scope.sizeof * (total == 0 ? 1 : total));
    size_t n = 0;
    foreach (i, p; parts) {
        foreach (ref sc; p) {
            bool seen = false;
            foreach (k; 0 .. n) if (sameScope(out_[k], sc)) { seen = true; break; }
            if (seen) continue;
            memcpy(&out_[n], &sc, Scope.sizeof);
            if (base[i] != 0 && sc.controls.length > 0) {
                auto cs = cast(Control*) malloc(Control.sizeof * sc.controls.length);
                foreach (j, ref c; sc.controls) {
                    memcpy(&cs[j], &c, Control.sizeof);
                    if (cs[j].stropIdx != 0) cs[j].stropIdx += base[i];
                }
                out_[n].controls = cast(const(Control)[]) cs[0 .. sc.controls.length];
            }
            n++;
        }
    }
    return cast(const(Scope)[]) out_[0 .. n];
}

private const(PermissionScope)[] permissionsOf(const(PermissionScope)[][3] parts) {
    import core.stdc.stdlib : malloc;
    import core.stdc.string : memcpy;
    size_t total = 0;
    foreach (p; parts) total += p.length;
    auto out_ = cast(PermissionScope*) malloc(PermissionScope.sizeof * (total == 0 ? 1 : total));
    size_t n = 0;
    foreach (p; parts) {
        foreach (ref ps; p) {
            bool seen = false;
            foreach (k; 0 .. n) if (samePermissions(out_[k], ps)) { seen = true; break; }
            if (seen) continue;
            memcpy(&out_[n++], &ps, PermissionScope.sizeof);
        }
    }
    return cast(const(PermissionScope)[]) out_[0 .. n];
}

private const(string)[] stringsOf(const(string)[][3] parts) {
    import core.stdc.stdlib : malloc;
    size_t total = 0;
    foreach (p; parts) total += p.length;
    auto out_ = cast(string*) malloc(string.sizeof * (total == 0 ? 1 : total));
    size_t n = 0;
    foreach (p; parts) {
        foreach (s; p) {
            bool seen = false;
            foreach (k; 0 .. n) if (out_[k] == s) { seen = true; break; }
            if (!seen) out_[n++] = s;
        }
    }
    return cast(const(string)[]) out_[0 .. n];
}

// One scope is another when it stands at the same paths and holds the same controls by name.
bool sameScope(ref const Scope a, ref const Scope b) {
    if (a.pathCount != b.pathCount || a.cmdCount != b.cmdCount || a.editedCount != b.editedCount) return false;
    foreach (i; 0 .. a.pathCount) if (a.paths[i] != b.paths[i]) return false;
    foreach (i; 0 .. a.cmdCount) if (a.cmds[i] != b.cmds[i]) return false;
    foreach (i; 0 .. a.editedCount) if (a.edited[i] != b.edited[i]) return false;
    if (a.decision != b.decision || a.mcpTool != b.mcpTool || a.publicOnly != b.publicOnly) return false;
    if (a.controls.length != b.controls.length) return false;
    foreach (i; 0 .. a.controls.length) if (a.controls[i].name != b.controls[i].name) return false;
    return true;
}

bool samePermissions(ref const PermissionScope a, ref const PermissionScope b) {
    if (a.pathCount != b.pathCount) return false;
    foreach (i; 0 .. a.pathCount) if (a.paths[i] != b.paths[i]) return false;
    if (a.permissions.length != b.permissions.length) return false;
    foreach (i; 0 .. a.permissions.length) {
        if (a.permissions[i].name != b.permissions[i].name) return false;
        if (a.permissions[i].mode != b.permissions[i].mode) return false;
        if (a.permissions[i].msg != b.permissions[i].msg) return false;
    }
    return true;
}
