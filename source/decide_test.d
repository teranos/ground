module decide_test;

import decide : combine;
import permission : Decision;

// A deny from either side is a deny.
static assert(combine("deny", Decision.none) == "deny");
static assert(combine("", Decision.deny) == "deny");
static assert(combine("ask", Decision.deny) == "deny");
static assert(combine("allow", Decision.deny) == "deny");
static assert(combine("deny", Decision.allow) == "deny");

// "a control can't invalidate a permission"
static assert(combine("ask", Decision.allow) == "allow");
static assert(combine("", Decision.allow) == "allow");

// With nothing granted, the control's decision stands.
static assert(combine("ask", Decision.none) == "ask");
static assert(combine("allow", Decision.none) == "allow");
static assert(combine("", Decision.none) == "");

// A permission ask is an ask when no control said more.
static assert(combine("", Decision.ask) == "ask");
static assert(combine("allow", Decision.ask) == "ask");

// A control ask and a permission ask agree.
static assert(combine("ask", Decision.ask) == "ask");
