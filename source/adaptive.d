module adaptive;

// Pick the next poll interval (seconds) based on elapsed time since the
// push and the historical p50/p90 of past CI durations for this repo+branch.
//
//   elapsed < p50          : CI very unlikely done yet → 30s (quiet)
//   p50 <= elapsed < p90   : likely-done window         → 5s  (active)
//   elapsed >= p90         : overdue                    → 2s  (urgent)
//
// If percentiles are missing (p50 == 0), fall back to the constant 2s
// the watcher used before adaptive polling existed.
int pickAdaptiveSleep(long elapsed, long p50, long p90) {
    if (p50 <= 0) return 2;
    if (elapsed < p50) return 30;
    if (p90 <= 0 || elapsed < p90) return 5;
    return 2;
}
