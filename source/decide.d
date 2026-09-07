module decide;

import permission : Decision;

const(char)[] combine(const(char)[] control, Decision perm) {
    if (control == "deny" || perm == Decision.deny) return "deny";
    if (perm == Decision.allow) return "allow";
    if (perm == Decision.ask) return "ask";
    return control;
}

// "aut-accept should not litigate ever"
// A deny is ground answering, an allow is ground granting. An ask is a question
// to a person, and whether one is at the prompt is the mode's business.
const(char)[] spoken(const(char)[] decision) {
    if (decision == "deny" || decision == "allow") return decision;
    return "";
}
