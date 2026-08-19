module scan_test;

// CTFE tests — failure shows as a compile error.

import perf : scanInto, lifeOf, expired, plainLength, Life, Perf;
import perf : BLUE, YELLOW, DIM, RESET, THROWN_FOR, ACTING_FOR, LINGER;

// Both are stamps. A throw just taken beats a tool call, because the throw is
// the newer fact about who holds the walk.
static assert(lifeOf(Perf("A", "+", "live", 0, 0, true, 100, 90, 95, 0)) == Life.thrown);
static assert(lifeOf(Perf("A", "+", "live", 0, 0, true, 100, 0, 95, 0)) == Life.acting);

// Neither recent is the stall: the rite sits still and says so by not moving.
static assert(lifeOf(Perf("A", "+", "live", 0, 0, true, 100, 0, 0, 0)) == Life.still);
static assert(lifeOf(Perf("A", "+", "live", 0, 0, true, 1000, 900, 900, 0)) == Life.still);

// A stamp exactly at the edge still counts; one second past it does not.
static assert(lifeOf(Perf("A", "+", "live", 0, 0, true, 100, 0, 100 - ACTING_FOR, 0)) == Life.acting);
static assert(lifeOf(Perf("A", "+", "live", 0, 0, true, 100, 0, 100 - ACTING_FOR - 1, 0)) == Life.still);
static assert(lifeOf(Perf("A", "+", "live", 0, 0, true, 100, 100 - THROWN_FOR, 0, 0)) == Life.thrown);

char[256] scanned(const(char)[] name, const(char)[] base, Life life, long now)() {
    char[256] buf = '.';
    scanInto(name, base, life, now, buf[]);
    return buf;
}

size_t scanLen(const(char)[] name, const(char)[] base, Life life, long now)() {
    char[256] buf = '.';
    return scanInto(name, base, life, now, buf[]);
}

// Nothing happening is the plain name in the rite's own colour.
enum stillWant = DIM ~ "LIME" ~ RESET;
static assert(scanned!("LIME", DIM, Life.still, 7)()[0 .. stillWant.length] == stillWant);

// Acting: two letters lit blue, travelling right to left, so at step 0 they
// are at the end of the name.
enum actingWant =
    DIM ~ "L" ~ RESET ~ DIM ~ "I" ~ RESET ~ DIM ~ "M" ~ RESET ~ BLUE ~ "E" ~ RESET;
static assert(scanned!("LIME", DIM, Life.acting, 100)()[0 .. actingWant.length] == actingWant);

// Thrown: yellow, and travelling the other way, so at step 0 they are at the
// start. Two letters lit, not one.
enum thrownWant =
    YELLOW ~ "L" ~ RESET ~ YELLOW ~ "I" ~ RESET ~ DIM ~ "M" ~ RESET ~ DIM ~ "E" ~ RESET;
static assert(scanned!("LIME", DIM, Life.thrown, 100)()[0 .. thrownWant.length] == thrownWant);

// The pair moves with the second, so consecutive seconds do not draw the same
// thing — which is the whole point of it.
static assert(scanned!("LIME", DIM, Life.thrown, 101)()[0 .. thrownWant.length] != thrownWant);

// A name too short to travel through is left alone.
enum tinyWant = DIM ~ "A" ~ RESET;
static assert(scanned!("A", DIM, Life.acting, 3)()[0 .. tinyWant.length] == tinyWant);

// Visible width: the names, plus two per separator over the comma stored.
static assert(plainLength(Perf("A,B", "++", "done", 0, 0, true, 0, 0, 0, 0)) == 5);
static assert(plainLength(Perf("ABC", "+", "done", 0, 0, true, 0, 0, 0, 0)) == 3);

// A live performance is never furniture, whatever its age.
static assert(!expired(Perf("A,B", "+>", "live", 1, 0, true, 99999, 0, 0, 1)));

// An ended one has its pass, sits, and goes.
static assert(!expired(Perf("A,B", "++", "done", 1, 0, true, 100, 0, 0, 100)));
static assert(expired(Perf("A,B", "++", "done", 1, 0, true, 100_000, 0, 0, 100)));

// Ended, with no stamp to age it by, stays — an unknown age is not an old one.
static assert(!expired(Perf("A,B", "++", "done", 1, 0, true, 100_000, 0, 0, 0)));

// The pass never scales past its cap, so a long chain leaves as promptly as a
// short one.
static assert(expired(Perf("AAAAAAAAAA,BBBBBBBBBB,CCCCCCCCCC", "+++", "done",
                           2, 0, true, 100 + 20 + LINGER + 1, 0, 0, 100)));
