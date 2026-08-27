module decide;

import permission : Decision;

const(char)[] combine(const(char)[] control, Decision perm) {
    if (control == "deny" || perm == Decision.deny) return "deny";
    if (perm == Decision.allow) return "allow";
    if (perm == Decision.ask) return "ask";
    return control;
}
