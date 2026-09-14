module attest_retry_test;

import attest : shouldRetry, backoffSeconds, RETRY_ATTEMPTS;

// Unreachable and 5xx are the node restarting.
static assert(shouldRetry(0));
static assert(shouldRetry(500));
static assert(shouldRetry(502));
static assert(shouldRetry(503));
static assert(shouldRetry(504));

// A token the node refuses is not going to be accepted by waiting.
static assert(!shouldRetry(401));
static assert(!shouldRetry(403));
static assert(!shouldRetry(400));
static assert(!shouldRetry(404));
static assert(!shouldRetry(409));

// A post that landed is not retried.
static assert(!shouldRetry(200));
static assert(!shouldRetry(201));

// The wait grows, and the whole sequence fits inside the window a restart
// takes.
static assert(backoffSeconds(0) == 2);
static assert(backoffSeconds(1) == 5);
static assert(backoffSeconds(2) == 15);
static assert(backoffSeconds(3) == 45);
static assert(backoffSeconds(4) == 90);

// Past the last attempt there is no wait to give.
static assert(backoffSeconds(RETRY_ATTEMPTS) == 0);
static assert(backoffSeconds(99) == 0);

// Five attempts, and the waits between them total under five minutes.
static assert(RETRY_ATTEMPTS == 5);
static assert(backoffSeconds(0) + backoffSeconds(1) + backoffSeconds(2)
            + backoffSeconds(3) + backoffSeconds(4) < 300);
