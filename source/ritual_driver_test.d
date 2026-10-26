module ritual_driver_test;

// A performance's driver is the ground that started it, named by its path. On
// q the driver was `ground` from PATH, the Node Agent's own, which has no willow.

import ritual.command : driverScript;

// The driver is its own binary, built beside the one that started the performance.
static assert(driverScript("/root/.local/share/ground/comets/abcd-nl/grove/ground_hook", "willow-1792433030").text()
    == "#!/usr/bin/env bash\nexec '/root/.local/share/ground/comets/abcd-nl/grove/ground_drive' 'willow-1792433030'\n");
static assert(driverScript("/Users/x/.local/bin/ground", "grove-1").text()
    == "#!/usr/bin/env bash\nexec '/Users/x/.local/bin/ground_drive' 'grove-1'\n");
