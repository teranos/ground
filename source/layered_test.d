module layered_test;

// "i want FLOOR+LOCALSAND+COMET"

import sand.layered : layer;
import sand.view : Sand;
import hooks : Scope;
import sand.builtin : builtinSand;

// Every sand starts from the floor, so the floor held three times is seen once.
unittest {
    Sand local = builtinSand;
    Sand comet = builtinSand;
    auto s = layer(&builtinSand, &local, &comet);
    assert(s.preToolUse.length == builtinSand.preToolUse.length);
    assert(s.permission.length == builtinSand.permission.length);
    assert(s.stropPool.length == 3 * builtinSand.stropPool.length);
}

// What only the local sand holds and what only the comet holds both stand, beside the floor.
unittest {
    assert(builtinSand.preToolUse.length > 0);
    __gshared Scope[1] onlyLocal;
    __gshared Scope[1] onlyComet;
    onlyLocal[0] = builtinSand.preToolUse[0];
    onlyLocal[0].paths[0] = "/only/local";
    onlyLocal[0].pathCount = 1;
    onlyComet[0] = builtinSand.preToolUse[0];
    onlyComet[0].paths[0] = "/only/comet";
    onlyComet[0].pathCount = 1;

    Sand local = builtinSand;
    local.preToolUse = onlyLocal[];
    Sand comet = builtinSand;
    comet.preToolUse = onlyComet[];
    auto s = layer(&builtinSand, &local, &comet);
    assert(s.preToolUse.length == builtinSand.preToolUse.length + 2);
    bool sawLocal, sawComet;
    foreach (ref sc; s.preToolUse) {
        if (sc.pathCount == 1 && sc.paths[0] == "/only/local") sawLocal = true;
        if (sc.pathCount == 1 && sc.paths[0] == "/only/comet") sawComet = true;
    }
    assert(sawLocal && sawComet);
}

// What names one thing comes from the most specific sand held.
unittest {
    Sand local = builtinSand;
    local.abi = builtinSand.abi;
    auto onlyLocal = layer(&builtinSand, &local, null);
    assert(onlyLocal.abi == local.abi);
    auto floorOnly = layer(&builtinSand, null, null);
    assert(floorOnly.preToolUse.length == builtinSand.preToolUse.length);
}
