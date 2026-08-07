module ritual;

// Five concerns, one import. Callers say `import ritual : x` and do not need
// to know which file x lives in.
public import ritual.position;  // where a performance is, and what it has been
public import ritual.resolve;   // name to ritual, ritual to rites, path to disk
public import ritual.store;     // the row
public import ritual.record;    // what a rite that ran leaves behind
public import ritual.run;       // running one, and what the agent is told
public import ritual.command;   // ground ritual <name>
public import ritual.consent;   // what a performance authorises
public import ritual.subagent;  // an agent started with one
public import ritual.drive;     // the loop that keeps one moving
