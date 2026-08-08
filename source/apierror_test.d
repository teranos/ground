module apierror_test;

// "it is the error code that is holding the mic"
// "and it is angry"

import apierror;
import mic : Mic, micWord;

// The matcher filters on error type, so the word is what arrives.
static assert(errorWord(ApiError.RateLimit) == "rate_limit");
static assert(errorWord(ApiError.OauthOrgNotAllowed) == "oauth_org_not_allowed");
static assert(errorWord(ApiError.MaxOutputTokens) == "max_output_tokens");

static assert(apiErrorFromWord("rate_limit").valid);
static assert(apiErrorFromWord("rate_limit").which == ApiError.RateLimit);
static assert(apiErrorFromWord("server_error").which == ApiError.ServerError);

// A type this build cannot read is not Unknown. Unknown is a type the API
// sends; an unreadable one is ground failing to keep up with the API.
static assert(!apiErrorFromWord("").valid);
static assert(!apiErrorFromWord("teapot").valid);

// "you always get one of these with the ZALGO retained"
static assert(angry(ApiError.RateLimit)            == "R̶A̸T̵E̵_̴L̸I̵M̸I̷T̶");
static assert(angry(ApiError.Overloaded)           == "O̶V̸E̴R̷L̸O̵A̷D̶E̸D̵");
static assert(angry(ApiError.AuthenticationFailed) == "A̷U̷T̴H̶E̴N̴T̷I̸C̵A̵T̴I̵O̸N̶_̸F̸A̵I̴L̷E̸D̴");
static assert(angry(ApiError.OauthOrgNotAllowed)   == "O̵A̸U̸T̶H̶_̷O̵R̸G̴_̵N̷O̸T̴_̵A̴L̷L̸O̴W̷E̸D̴");
static assert(angry(ApiError.BillingError)         == "B̶I̷L̷L̵I̶N̶G̵_̶E̷R̷R̷O̸R̶");
static assert(angry(ApiError.ModelNotFound)        == "M̷O̸D̸E̷L̴_̵N̶O̷T̷_̷F̷O̸U̵N̴D̶");
static assert(angry(ApiError.InvalidRequest)       == "I̷N̴V̴A̵L̶I̷D̴_̴R̸E̶Q̵U̴E̸S̷T̷");
static assert(angry(ApiError.MaxOutputTokens)      == "M̷A̴X̶_̸O̵U̸T̶P̶U̵T̵_̸T̴O̵K̵E̶N̸S̵");
static assert(angry(ApiError.Unknown)              == "U̴N̶K̶N̶O̷W̷N̸");

static assert(angry(ApiError.ServerError)          == "̵S̵E̸R̴V̷E̴R̸_̴E̸R̷R̸O̷R̸");

// "it is the error code that is holding the mic"
static assert(holderFor(ApiError.RateLimit) == Mic.Error);
static assert(holderFor(ApiError.Overloaded) == Mic.Error);
static assert(holderFor(ApiError.ServerError) == Mic.Error);

// No amount of waiting pays a bill or renews a credential.
static assert(holderFor(ApiError.AuthenticationFailed) == Mic.Human);
static assert(holderFor(ApiError.OauthOrgNotAllowed) == Mic.Human);
static assert(holderFor(ApiError.BillingError) == Mic.Human);
static assert(holderFor(ApiError.ModelNotFound) == Mic.Human);
static assert(holderFor(ApiError.InvalidRequest) == Mic.Human);
static assert(holderFor(ApiError.MaxOutputTokens) == Mic.Human);

// "Halt is the refusal to guess"
static assert(holderFor(ApiError.Unknown) == Mic.Human);

// "rate limit just means retry not now but in incremental backoff"
static assert(retryable(ApiError.RateLimit));
static assert(retryable(ApiError.Overloaded));
static assert(retryable(ApiError.ServerError));
static assert(!retryable(ApiError.BillingError));
static assert(!retryable(ApiError.MaxOutputTokens));
static assert(!retryable(ApiError.Unknown));

// The row reads without a decoder, same as the other four.
static assert(micWord(Mic.Error) == "error");
