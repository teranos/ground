module sand_entry;

// "only the compiled controls being their own thing shipped to the user"

// The sand alone, for an engine to load: the controls this was compiled with, and nothing that runs them.
import sandview : Sand;
import builtin_sand : builtinSand;

extern (C) export const(Sand)* ground_sand() { return &builtinSand; }
