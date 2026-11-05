module shipped;

// "and compare us against real shipped software instyead of comparing against a number that might not be real"

// What shipped ACP agents handle and send, read out of their source at a pinned
// commit and named through the SDK version each one pins.

// --- plain scanning ---

private bool at(const(char)[] t, size_t i, const(char)[] s) {
    return i + s.length <= t.length && t[i .. i + s.length] == s;
}

private ptrdiff_t find(const(char)[] t, const(char)[] s, size_t from = 0) {
    if (s.length == 0 || s.length > t.length) return -1;
    foreach (i; from .. t.length - s.length + 1)
        if (t[i .. i + s.length] == s) return cast(ptrdiff_t) i;
    return -1;
}

private bool identChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$';
}

// The identifier at `from`, empty when none starts there.
private const(char)[] identAt(const(char)[] t, size_t from) {
    size_t e = from;
    while (e < t.length && identChar(t[e])) e++;
    return t[from .. e];
}

private const(char)[] trimmed(const(char)[] s) {
    size_t a = 0, b = s.length;
    while (a < b && (s[a] == ' ' || s[a] == '\t')) a++;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r')) b--;
    return s[a .. b];
}

// --- the pins, read out of flake.nix, the one place they are written ---

struct ShippedPin { string name; string rev; string dir; string sdk; }

enum maxShipped = 8;

struct ShippedSet { ShippedPin[maxShipped] items; size_t count; }

// The value of `key = "…"` inside a pin's block, or null.
private string field()(string block, string key) {
    size_t from = 0;
    while (true) {
        auto i = find(block, key, from);
        if (i < 0) return null;
        from = cast(size_t) i + 1;
        if (i > 0 && identChar(block[cast(size_t) i - 1])) continue;
        if (!at(block, cast(size_t) i + key.length, ` = "`)) continue;
        auto v = cast(size_t) i + key.length + 4;
        auto end = find(block, `"`, v);
        if (end < 0) return null;
        return block[v .. cast(size_t) end];
    }
}

ShippedSet readShipped()(string flake) {
    ShippedSet found;
    enum opener = `= shipped "`;
    size_t from = 0;
    while (true) {
        auto i = find(flake, opener, from);
        if (i < 0) break;
        auto nameFrom = cast(size_t) i + opener.length;
        auto nameEnd = find(flake, `"`, nameFrom);
        if (nameEnd < 0) break;
        from = cast(size_t) nameEnd;
        auto open = find(flake, "{", cast(size_t) nameEnd);
        if (open < 0) break;
        size_t end = flake.length;
        int depth = 0;
        foreach (p; cast(size_t) open .. flake.length) {
            if (flake[p] == '{') depth++;
            else if (flake[p] == '}' && --depth == 0) { end = p + 1; break; }
        }
        auto block = flake[cast(size_t) open .. end];
        auto pin = ShippedPin(flake[nameFrom .. cast(size_t) nameEnd],
            field(block, "rev"), field(block, "dir"), field(block, "sdk"));
        if (pin.rev !is null && pin.dir !is null && pin.sdk !is null && found.count < found.items.length)
            found.items[found.count++] = pin;
    }
    return found;
}

// --- what an SDK calls each method ---

enum maxMethods = 64;
enum maxTokens = 512;
enum maxKeys = 160;

struct Method {
    char[48] text = 0;
    ubyte len;
    bool agentHandles; // the agent answers it; otherwise the agent sends it
    const(char)[] name() const return { return text[0 .. len]; }
}

// How a token names a method in an agent's source. A path is the SDK's table,
// `methods.agent.session.new`; a name an interface method, `newSession`; a weak
// name a terminal handle's, counted only where the agent made a terminal.
enum Kind : ubyte { path, name, weak }

struct Token {
    char[96] text = 0;
    ubyte len;
    Kind kind;
    ubyte method;
    const(char)[] str() const return { return text[0 .. len]; }
}

private struct Key { char[64] text = 0; ubyte len; ubyte method; bool agent; }

struct SdkMap {
    Method[maxMethods] methods;
    size_t methodCount;
    Token[maxTokens] tokens;
    size_t tokenCount;
    Key[maxKeys] keys;
    size_t keyCount;
    bool full; // a table held more than the map keeps: nothing measured is whole

    ptrdiff_t indexOf(const(char)[] method) const {
        foreach (i; 0 .. methodCount)
            if (methods[i].name == method) return cast(ptrdiff_t) i;
        return -1;
    }
}

private ptrdiff_t addMethod(ref SdkMap map, const(char)[] method, bool agent) {
    auto i = map.indexOf(method);
    if (i >= 0) return i;
    if (map.methodCount >= maxMethods || method.length > map.methods[0].text.length) { map.full = true; return -1; }
    auto m = &map.methods[map.methodCount];
    foreach (k, c; method) m.text[k] = c;
    m.len = cast(ubyte) method.length;
    m.agentHandles = agent;
    return cast(ptrdiff_t) map.methodCount++;
}

private ptrdiff_t keyMethod(ref const SdkMap map, const(char)[] key, bool agent) {
    foreach (i; 0 .. map.keyCount)
        if (map.keys[i].agent == agent && map.keys[i].text[0 .. map.keys[i].len] == key) return map.keys[i].method;
    return -1;
}

private void addToken(ref SdkMap map, const(char)[] text, Kind kind, ptrdiff_t method) {
    if (method < 0 || text.length == 0) return;
    foreach (i; 0 .. map.tokenCount) {
        auto t = &map.tokens[i];
        if (t.method == method && t.str == text) {
            if (kind < t.kind) t.kind = kind; // a name the SDK also dispatches is no weak name
            return;
        }
    }
    if (map.tokenCount >= maxTokens || text.length > map.tokens[0].text.length) { map.full = true; return; }
    auto t = &map.tokens[map.tokenCount++];
    foreach (k, c; text) t.text[k] = c;
    t.len = cast(ubyte) text.length;
    t.kind = kind;
    t.method = cast(ubyte) method;
}

// `export const AGENT_METHODS = { session_new: "session/new", … }`, and CLIENT_METHODS.
void readSchema(const(char)[] text, ref SdkMap map) {
    foreach (agent; [true, false]) {
        auto open = find(text, agent ? "AGENT_METHODS = {" : "CLIENT_METHODS = {");
        if (open < 0) continue;
        auto close = find(text, "}", cast(size_t) open);
        if (close < 0) continue;
        auto body_ = text[cast(size_t) open .. cast(size_t) close];
        size_t p = find(body_, "{") + 1;
        while (p < body_.length) {
            while (p < body_.length && !identChar(body_[p])) p++;
            auto key = identAt(body_, p);
            if (key.length == 0) break;
            p += key.length;
            auto q = find(body_, `"`, p);
            if (q < 0) break;
            auto e = find(body_, `"`, cast(size_t) q + 1);
            if (e < 0) break;
            auto method = addMethod(map, body_[cast(size_t) q + 1 .. cast(size_t) e], agent);
            p = cast(size_t) e + 1;
            if (method < 0 || keyMethod(map, key, agent) >= 0) continue;
            if (map.keyCount >= maxKeys || key.length > map.keys[0].text.length) { map.full = true; continue; }
            auto k = &map.keys[map.keyCount++];
            foreach (j, c; key) k.text[j] = c;
            k.len = cast(ubyte) key.length;
            k.method = cast(ubyte) method;
            k.agent = agent;
        }
    }
}

// The method `AGENT_METHODS.key` or `CLIENT_METHODS.key` names, the first after `from`, and where it ends.
private ptrdiff_t methodAfter(ref const SdkMap map, const(char)[] t, size_t from, size_t until, out size_t end) {
    auto a = find(t[0 .. until], "AGENT_METHODS.", from);
    auto c = find(t[0 .. until], "CLIENT_METHODS.", from);
    if (a < 0 && c < 0) return -1;
    bool agent = a >= 0 && (c < 0 || a < c);
    auto tag = agent ? "AGENT_METHODS." : "CLIENT_METHODS.";
    auto i = cast(size_t) (agent ? a : c) + tag.length;
    auto key = identAt(t, i);
    end = i + key.length;
    return keyMethod(map, key, agent);
}

private bool keyword(const(char)[] s) {
    foreach (k; ["if", "for", "while", "switch", "return", "catch", "function", "await", "super", "new", "const", "let", "else", "do", "throw", "typeof"])
        if (s == k) return true;
    return false;
}

// A line that defines a method: modifiers, maybe async, then the name and its parameters.
private const(char)[] definedOn(const(char)[] line) {
    auto s = trimmed(line);
    foreach (m; ["public ", "private ", "protected ", "override ", "static ", "readonly ", "async "])
        if (at(s, 0, m)) s = trimmed(s[m.length .. $]);
    auto name = identAt(s, 0);
    if (name.length == 0 || keyword(name)) return null;
    if (name.length >= s.length || (s[name.length] != '(' && s[name.length] != '<')) return null;
    if (s[$ - 1] == ';') return null;
    return name;
}

// One SDK source file: its table of paths, its specs, its dispatch, and the methods that send.
void readAcp(const(char)[] t, ref SdkMap map) {
    // `export const methods = { agent: { session: { new: schema.AGENT_METHODS.session_new, …`
    auto tableAt = find(t, "const methods");
    if (tableAt >= 0) {
        auto open = find(t, "{", cast(size_t) tableAt);
        const(char)[][6] stack;
        size_t depth = 0;
        size_t p = open < 0 ? t.length : cast(size_t) open + 1;
        while (p < t.length) {
            auto nl = find(t, "\n", p);
            auto lineEnd = nl < 0 ? t.length : cast(size_t) nl;
            auto line = trimmed(t[p .. lineEnd]);
            p = lineEnd + 1;
            if (line.length == 0) continue;
            if (line[0] == '}') {
                if (depth == 0) break;
                depth--;
                continue;
            }
            auto key = identAt(line, 0);
            if (key.length == 0) continue;
            if (line[$ - 1] == '{') {
                if (depth < stack.length) stack[depth] = key;
                depth++;
                continue;
            }
            size_t end;
            auto method = methodAfter(map, line, 0, line.length, end);
            if (method < 0 || depth > stack.length) continue;
            char[96] path = 0;
            size_t n = 0;
            void put(const(char)[] s) { foreach (c; s) if (n < path.length) path[n++] = c; }
            put("methods.");
            foreach (d; 0 .. depth) { put(stack[d]); put("."); }
            put(key);
            addToken(map, path[0 .. n], Kind.path, method);
        }
    }

    // `newSession: requestSpec<…>(schema.AGENT_METHODS.session_new, …)`
    foreach (spec; [": requestSpec", ": notificationSpec"]) {
        size_t from = 0;
        while (true) {
            auto i = find(t, spec, from);
            if (i < 0) break;
            from = cast(size_t) i + spec.length;
            size_t ls = cast(size_t) i;
            while (ls > 0 && t[ls - 1] != '\n') ls--;
            auto name = identAt(trimmed(t[ls .. cast(size_t) i]), 0);
            size_t end;
            auto until = cast(size_t) i + 300 < t.length ? cast(size_t) i + 300 : t.length;
            addToken(map, name, Kind.name, methodAfter(map, t, cast(size_t) i, until, end));
        }
    }

    // `case schema.AGENT_METHODS.session_new: { … return agent.newSession(…)`
    {
        size_t from = 0;
        while (true) {
            auto i = find(t, "case schema.", from);
            if (i < 0) break;
            from = cast(size_t) i + 5;
            size_t end;
            auto method = methodAfter(map, t, cast(size_t) i, t.length, end);
            if (method < 0) continue;
            auto next = find(t, "case ", end);
            auto stop = find(t, "default:", end);
            size_t until = t.length;
            if (next >= 0) until = cast(size_t) next;
            if (stop >= 0 && cast(size_t) stop < until) until = cast(size_t) stop;
            // Every `agent.x` in the case: the call follows a guard `if (!agent.x)`.
            foreach (who; ["agent.", "client."]) {
                for (auto c = find(t[0 .. until], who, end); c >= 0; c = find(t[0 .. until], who, cast(size_t) c + 1)) {
                    auto name = identAt(t, cast(size_t) c + who.length);
                    auto after = cast(size_t) c + who.length + name.length;
                    if (at(t, after, "(") || at(t, after, "?.(")) addToken(map, name, Kind.name, method);
                }
            }
        }
    }

    // A method of the SDK's that sends one: `async kill() { … sendRequest(schema.CLIENT_METHODS.terminal_kill`
    {
        size_t from = 0;
        while (true) {
            auto i = find(t, "CLIENT_METHODS.", from);
            if (i < 0) break;
            from = cast(size_t) i + 1;
            auto back = cast(size_t) i > 160 ? cast(size_t) i - 160 : 0;
            auto before = t[back .. cast(size_t) i];
            if (find(before, "sendRequest") < 0 && find(before, "sendNotification") < 0
                    && find(before, ".request(") < 0 && find(before, ".notify(") < 0) continue;
            size_t end;
            auto method = methodAfter(map, t, cast(size_t) i, t.length, end);
            if (method < 0) continue;
            // The definition the send is inside: the last one a line starts before it.
            const(char)[] name;
            size_t ls = 0;
            while (ls < cast(size_t) i) {
                auto nl = find(t, "\n", ls);
                auto le = nl < 0 || cast(size_t) nl > cast(size_t) i ? cast(size_t) i : cast(size_t) nl;
                auto d = definedOn(t[ls .. le]);
                if (d !is null) name = d;
                if (nl < 0 || cast(size_t) nl >= cast(size_t) i) break;
                ls = cast(size_t) nl + 1;
            }
            addToken(map, name, Kind.weak, method);
        }
    }
}

// --- what an agent's source does with them ---

struct Found {
    bool[maxMethods] handles;
    bool[maxMethods] sends;
    bool[maxMethods] weak; // sent by a terminal handle's name, so far unconfirmed
    char[64][4] classes;   // the classes the agent hands AgentSideConnection
    ubyte[4] classLen;
    size_t classCount;
}

// `new AgentSideConnection((conn) => new PiAgent(conn), …)` names the agent's class.
void collectAgents(const(char)[] t, ref Found f) {
    size_t from = 0;
    while (true) {
        auto i = find(t, "AgentSideConnection(", from);
        if (i < 0) break;
        from = cast(size_t) i + 1;
        auto until = cast(size_t) i + 240 < t.length ? cast(size_t) i + 240 : t.length;
        auto n = find(t[0 .. until], "new ", cast(size_t) i);
        if (n < 0) continue;
        auto name = identAt(t, cast(size_t) n + 4);
        if (name.length == 0 || name.length > f.classes[0].length || f.classCount >= f.classes.length) continue;
        bool have = false;
        foreach (k; 0 .. f.classCount) if (f.classes[k][0 .. f.classLen[k]] == name) have = true;
        if (have) continue;
        foreach (k, c; name) f.classes[f.classCount][k] = c;
        f.classLen[f.classCount++] = cast(ubyte) name.length;
    }
}

// Whether `token` stands in `t` whole: not the front of a longer name.
private bool mentions(const(char)[] t, const(char)[] token) {
    size_t from = 0;
    while (true) {
        auto i = find(t, token, from);
        if (i < 0) return false;
        auto after = cast(size_t) i + token.length;
        if (after >= t.length || !identChar(t[after])) return true;
        from = after;
    }
}

// The methods a class's body defines at its top level.
private void classDefines(const(char)[] t, const(char)[] cls, ref const SdkMap map, ref Found f) {
    size_t from = 0;
    while (true) {
        auto i = find(t, "class ", from);
        if (i < 0) return;
        from = cast(size_t) i + 6;
        if (identAt(t, from) != cls) continue;
        auto open = find(t, "{", from);
        if (open < 0) return;
        int depth = 0, lineDepth = 1;
        size_t lineStart = cast(size_t) open + 1;
        foreach (p; cast(size_t) open .. t.length) {
            auto c = t[p];
            if (c == '\n') {
                if (lineDepth == 1) {
                    auto name = definedOn(t[lineStart .. p]);
                    if (name !is null)
                        foreach (k; 0 .. map.tokenCount) {
                            auto tok = &map.tokens[k];
                            if (tok.kind == Kind.name && map.methods[tok.method].agentHandles && tok.str == name)
                                f.handles[tok.method] = true;
                        }
                }
                lineStart = p + 1;
                lineDepth = depth;
            } else if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return;
        }
        return;
    }
}

// One file of the agent's source.
void scanAgent(const(char)[] t, ref const SdkMap map, ref Found f) {
    collectAgents(t, f);
    foreach (k; 0 .. f.classCount) classDefines(t, f.classes[k][0 .. f.classLen[k]], map, f);
    foreach (k; 0 .. map.tokenCount) {
        auto tok = &map.tokens[k];
        auto agentSide = map.methods[tok.method].agentHandles;
        final switch (tok.kind) {
            case Kind.path:
                if (!mentions(t, tok.str)) break;
                if (agentSide) f.handles[tok.method] = true;
                else f.sends[tok.method] = true;
                break;
            case Kind.name:
            case Kind.weak:
                if (agentSide) break; // an agent-side name counts only where its class defines it
                char[100] call = 0;
                call[0] = '.';
                foreach (j, c; tok.str) call[j + 1] = c;
                auto dotted = call[0 .. tok.len + 1];
                bool called = false;
                foreach (tail; ["(", "?.("]) {
                    char[104] whole = 0;
                    foreach (j, c; dotted) whole[j] = c;
                    foreach (j, c; tail) whole[dotted.length + j] = c;
                    if (find(t, whole[0 .. dotted.length + tail.length]) >= 0) called = true;
                }
                if (!called) break;
                if (tok.kind == Kind.name) f.sends[tok.method] = true;
                else f.weak[tok.method] = true;
                break;
        }
    }
}

// A terminal handle's call counts where the agent made a terminal.
void finish(ref Found f, ref const SdkMap map) {
    auto create = map.indexOf("terminal/create");
    if (create < 0 || !f.sends[create]) return;
    foreach (i; 0 .. map.methodCount) if (f.weak[i]) f.sends[i] = true;
}

// --- reading what make install linked ---

import core.sys.posix.sys.mman : mmap, munmap, PROT_READ, MAP_PRIVATE, MAP_FAILED;
import core.sys.posix.fcntl : open, O_RDONLY;
import core.sys.posix.unistd : close;
import core.sys.posix.sys.stat : stat, fstat, stat_t, S_IFMT, S_IFDIR;

// Each file under `dir`, whole, handed to `each` with its path. False when the directory is not there.
bool walk(const(char)[] dir, scope void delegate(const(char)[] path, const(char)[] text) each) {
    import core.sys.posix.dirent : opendir, readdir, closedir;
    char[1024] buf = 0;
    if (dir.length + 2 > buf.length) return false;
    foreach (i, c; dir) buf[i] = c;
    auto d = opendir(&buf[0]);
    if (d is null) return false;
    scope (exit) closedir(d);
    for (auto e = readdir(d); e !is null; e = readdir(d)) {
        size_t len;
        while (e.d_name[len] != 0) len++;
        auto name = e.d_name[0 .. len];
        if (name == "." || name == ".." || name == "node_modules") continue;
        if (dir.length + 1 + len + 1 > buf.length) continue;
        buf[dir.length] = '/';
        foreach (i, c; name) buf[dir.length + 1 + i] = c;
        buf[dir.length + 1 + len] = 0;
        auto path = buf[0 .. dir.length + 1 + len];
        stat_t st;
        if (stat(&buf[0], &st) != 0) continue;
        if ((st.st_mode & S_IFMT) == S_IFDIR) {
            char[1024] sub = 0;
            foreach (i, c; path) sub[i] = c;
            walk(sub[0 .. path.length], each);
            continue;
        }
        auto fd = open(&buf[0], O_RDONLY);
        if (fd < 0) continue;
        scope (exit) close(fd);
        if (fstat(fd, &st) != 0 || st.st_size <= 0) continue;
        auto size = cast(size_t) st.st_size;
        auto mem = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (mem == MAP_FAILED) continue;
        each(path, (cast(const(char)*) mem)[0 .. size]);
        munmap(mem, size);
    }
    return true;
}

private bool endsWith(const(char)[] s, const(char)[] tail) {
    return s.length >= tail.length && s[$ - tail.length .. $] == tail;
}

// A file the agent ships, not one that tests it or only declares types.
private bool agentSource(const(char)[] path) {
    if (!endsWith(path, ".ts") || endsWith(path, ".d.ts")) return false;
    return find(path, "test") < 0 && find(path, "/fixtures/") < 0;
}

// What an SDK version calls each method: its schema tables first, then its source.
bool readSdk(const(char)[] root, ref SdkMap map) {
    bool any = false;
    walk(root, (path, text) {
        if (endsWith(path, "/schema/index.ts")) { readSchema(text, map); any = true; }
    });
    if (!any) return false;
    walk(root, (path, text) {
        if (endsWith(path, "/acp.ts") && find(path, "test") < 0) readAcp(text, map);
    });
    return true;
}

// What one shipped agent handles and sends. False when its source is not there.
bool measureAgent(const(char)[] root, ref const SdkMap map, ref Found f) {
    bool any = false;
    walk(root, (path, text) { if (agentSource(path)) { collectAgents(text, f); any = true; } });
    if (!any) return false;
    walk(root, (path, text) { if (agentSource(path)) scanAgent(text, map, f); });
    finish(f, map);
    return true;
}
