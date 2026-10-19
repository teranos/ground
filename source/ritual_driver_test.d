module ritual_driver_test;

// A performance's driver is the ground that started it, named by its path. On
// q the driver was `ground` from PATH, the Node Agent's own, which has no willow.

import ritual.command : driverScript;

static assert(driverScript("/root/.local/share/ground/comets/abcd-nl/grove/ground", "willow-1792433030").text()
    == "#!/usr/bin/env bash\nexec '/root/.local/share/ground/comets/abcd-nl/grove/ground' drive 'willow-1792433030'\n");
