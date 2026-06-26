module adaptive_test;

import adaptive : pickAdaptiveSleep;

// elapsed < p50 → 30s (quiet, CI very unlikely done)
static assert(pickAdaptiveSleep(0, 100, 200) == 30);
static assert(pickAdaptiveSleep(50, 100, 200) == 30);
static assert(pickAdaptiveSleep(99, 100, 200) == 30);

// p50 <= elapsed < p90 → 5s (likely-done window)
static assert(pickAdaptiveSleep(100, 100, 200) == 5);
static assert(pickAdaptiveSleep(150, 100, 200) == 5);
static assert(pickAdaptiveSleep(199, 100, 200) == 5);

// elapsed >= p90 → 2s (overdue, check often)
static assert(pickAdaptiveSleep(200, 100, 200) == 2);
static assert(pickAdaptiveSleep(500, 100, 200) == 2);

// Missing percentiles (legacy rows or no history) → fall back to 2s
static assert(pickAdaptiveSleep(50, 0, 0) == 2);
static assert(pickAdaptiveSleep(50, 0, 200) == 2);

// p50 set but no p90 → never escalate past 5s after p50
static assert(pickAdaptiveSleep(50, 100, 0) == 30);
static assert(pickAdaptiveSleep(150, 100, 0) == 5);
