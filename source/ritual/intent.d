module ritual.intent;

// "ALL RITUALS SHOULD SHOW UP IN THE PARENT SSESSION"

import watch : buildGroundPath;

extern (C) {
    import core.stdc.stdio : FILE;
    FILE* fopen(const(char)* path, const(char)* mode);
    int fclose(FILE* f);
    size_t fread(void* ptr, size_t size, size_t nmemb, FILE* stream);
    size_t fwrite(const(void)* ptr, size_t size, size_t nmemb, FILE* stream);
    int remove(const(char)* path);
}

bool nameable(const(char)[] name) {
    if (name.length == 0 || name.length > 64) return false;
    foreach (c; name) {
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
               || (c >= '0' && c <= '9') || c == '-' || c == '_';
        if (!ok) return false;
    }
    return true;
}

void writeIntent(const(char)[] ritual, const(char)[] sessionId) {
    if (!nameable(ritual) || sessionId.length == 0) return;

    __gshared char[512] path = 0;
    if (buildGroundPath(path, "ritual-intent-", ritual, ".id") == 0) return;

    auto f = fopen(&path[0], "w");
    if (f is null) return;
    fwrite(sessionId.ptr, 1, sessionId.length, f);
    fclose(f);
}

const(char)[] takeIntent(const(char)[] ritual) {
    if (!nameable(ritual)) return null;

    __gshared char[512] path = 0;
    if (buildGroundPath(path, "ritual-intent-", ritual, ".id") == 0) return null;

    auto f = fopen(&path[0], "r");
    if (f is null) return null;

    __gshared char[128] buf = 0;
    auto n = fread(&buf[0], 1, buf.length - 1, f);
    fclose(f);
    remove(&path[0]);

    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' ')) n--;
    if (n == 0) return null;
    return buf[0 .. n];
}
