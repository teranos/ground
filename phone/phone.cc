// "Let's use it."
// The C face of libphonenumber that ground links: every phone number it finds in
// text, as byte offsets into it, Dutch numbers written without a country code among them.
#include <phonenumbers/phonenumbermatch.h>
#include <phonenumbers/phonenumbermatcher.h>
#include <phonenumbers/phonenumberutil.h>

#include <cstddef>
#include <cstdint>
#include <string>

using i18n::phonenumbers::PhoneNumberMatch;
using i18n::phonenumbers::PhoneNumberMatcher;
using i18n::phonenumbers::PhoneNumberUtil;

extern "C" size_t phone_find(const char* text, size_t len, size_t* starts, size_t* ends, size_t cap) {
    const std::string searched(text, len);
    PhoneNumberMatcher matcher(*PhoneNumberUtil::GetInstance(), searched, "NL",
                               PhoneNumberMatcher::VALID, 65535);
    size_t n = 0;
    PhoneNumberMatch match;
    while (matcher.HasNext() && matcher.Next(&match)) {
        // More than fits is no answer: a number past the cap would go through as it is.
        if (n == cap) return SIZE_MAX;
        starts[n] = match.start();
        ends[n] = match.end();
        n++;
    }
    return n;
}
