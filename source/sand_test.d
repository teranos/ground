module sand_test;

// "only the compiled controls being their own thing shipped to the user"

import controls : sand, allScopes, permissionScopes, stopScopes, parsedOnce, qntxNode;
import sand.view : SAND_ABI, Sand;

// The engine answers from a sand, the built-in one until one lands, and every name reads from it.
unittest {
    assert(sand.abi == SAND_ABI);
    assert(allScopes.ptr is sand.preToolUse.ptr);
    assert(permissionScopes.length == sand.permission.length);
    assert(stopScopes.length == sand.stop.length);
    assert(parsedOnce.ritualCount == sand.parsed.ritualCount);
    assert(parsedOnce.rituals.length == parsedOnce.ritualCount);
    assert(qntxNode.url == sand.parsed.qntx.url);
}

// A sand is read the same whatever controls it was built from: no part of it is sized by them.
unittest {
    import std.traits : isStaticArray;
    import hooks : Scope;
    static foreach (field; Sand.tupleof)
        static assert(!isStaticArray!(typeof(field)), "a Sand holds an array sized by its controls");
}
