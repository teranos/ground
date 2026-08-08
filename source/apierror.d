module apierror;

// "it is the error code that is holding the mic"
// "and it is angry"

import mic : Mic;

// https://code.claude.com/docs/en/hooks — StopFailure, matcher values
enum ApiError {
    RateLimit,
    Overloaded,
    AuthenticationFailed,
    OauthOrgNotAllowed,
    BillingError,
    InvalidRequest,
    ModelNotFound,
    ServerError,
    MaxOutputTokens,
    Unknown,
}

immutable string[10] ERROR_WORD = [
    "rate_limit",
    "overloaded",
    "authentication_failed",
    "oauth_org_not_allowed",
    "billing_error",
    "invalid_request",
    "model_not_found",
    "server_error",
    "max_output_tokens",
    "unknown",
];

// "you always get one of these with the ZALGO retained"
immutable string[10] ERROR_ANGRY = [
    "R̶A̸T̵E̵_̴L̸I̵M̸I̷T̶",
    "O̶V̸E̴R̷L̸O̵A̷D̶E̸D̵",
    "A̷U̷T̴H̶E̴N̴T̷I̸C̵A̵T̴I̵O̸N̶_̸F̸A̵I̴L̷E̸D̴",
    "O̵A̸U̸T̶H̶_̷O̵R̸G̴_̵N̷O̸T̴_̵A̴L̷L̸O̴W̷E̸D̴",
    "B̶I̷L̷L̵I̶N̶G̵_̶E̷R̷R̷O̸R̶",
    "I̷N̴V̴A̵L̶I̷D̴_̴R̸E̶Q̵U̴E̸S̷T̷",
    "M̷O̸D̸E̷L̴_̵N̶O̷T̷_̷F̷O̸U̵N̴D̶",
    "̵S̵E̸R̴V̷E̴R̸_̴E̸R̷R̸O̷R̸",
    "M̷A̴X̶_̸O̵U̸T̶P̶U̵T̵_̸T̴O̵K̵E̶N̸S̵",
    "U̴N̶K̶N̶O̷W̷N̸",
];

string errorWord(ApiError e) { return ERROR_WORD[cast(size_t) e]; }

// "the mic needs to speak its exact error"
string angry(ApiError e) { return ERROR_ANGRY[cast(size_t) e]; }

struct ErrorRead { bool valid; ApiError which; }

ErrorRead apiErrorFromWord(const(char)[] word) {
    foreach (i, w; ERROR_WORD)
        if (word == w) return ErrorRead(true, cast(ApiError) i);
    return ErrorRead(false);
}

// "rate limit just means retry not now but in incremental backoff"
bool retryable(ApiError e) {
    return e == ApiError.RateLimit
        || e == ApiError.Overloaded
        || e == ApiError.ServerError;
}

// "it is the error code that is holding the mic"
Mic holderFor(ApiError e) {
    return retryable(e) ? Mic.Error : Mic.Human;
}
