// acp_live GROUND_CODE CWD SCRIPT: drives a ground code over ACP from a script,
// and prints every line both ways. The script's directives are in README.md.
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// How long a wait or expect reads before it fails.
#define WAIT_MS 300000

typedef struct line_buffer {
    char *data;
    size_t length, capacity;
} line_buffer;

typedef struct ground {
    pid_t pid;
    int in, out, err;
    line_buffer out_lines, err_lines;
} ground;

static const char *binary, *cwd;
static char sid[256];

static void die(const char *what) {
    fprintf(stderr, "acp_live: %s: %s\n", what, strerror(errno));
    exit(2);
}

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long) t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void start(ground *g) {
    int in[2], out[2], err[2];
    if (pipe(in) != 0 || pipe(out) != 0 || pipe(err) != 0) die("pipe");
    g->pid = fork();
    if (g->pid < 0) die("fork");
    if (g->pid == 0) {
        dup2(in[0], 0);
        dup2(out[1], 1);
        dup2(err[1], 2);
        close(in[0]); close(in[1]); close(out[0]); close(out[1]); close(err[0]); close(err[1]);
        execl(binary, binary, (char *) NULL);
        fprintf(stderr, "acp_live: exec %s: %s\n", binary, strerror(errno));
        _exit(127);
    }
    close(in[0]); close(out[1]); close(err[1]);
    g->in = in[1];
    g->out = out[0];
    g->err = err[0];
    g->out_lines.length = g->err_lines.length = 0;
}

// The sessionId a session/new or session/resume answer names, kept as $SID.
static void keep_sid(const char *line) {
    static const char mark[] = "\"result\":{\"sessionId\":\"";
    const char *at = strstr(line, mark);
    if (at == NULL) return;
    at += sizeof mark - 1;
    const char *end = strchr(at, '"');
    if (end == NULL || (size_t) (end - at) >= sizeof sid) return;
    memcpy(sid, at, (size_t) (end - at));
    sid[end - at] = '\0';
}

// Prints each whole line read so far after its mark; true when one holds want.
static int lines_out(line_buffer *b, const char *mark, const char *want) {
    int seen = 0;
    size_t from = 0;
    for (size_t i = 0; i < b->length; i++) {
        if (b->data[i] != '\n') continue;
        b->data[i] = '\0';
        const char *line = b->data + from;
        printf("%s%s\n", mark, line);
        if (mark[0] == '<') keep_sid(line);
        if (want != NULL && strstr(line, want) != NULL) seen = 1;
        from = i + 1;
    }
    memmove(b->data, b->data + from, b->length - from);
    b->length -= from;
    fflush(stdout);
    return seen;
}

// One read into b: 0 at the end of fd.
static int fill(int fd, line_buffer *b) {
    if (b->capacity - b->length < 65536) {
        b->capacity = b->capacity * 2 + 65536;
        if ((b->data = realloc(b->data, b->capacity)) == NULL) die("realloc");
    }
    ssize_t n = read(fd, b->data + b->length, b->capacity - b->length - 1);
    if (n < 0 && errno == EINTR) return 1;
    if (n <= 0) return 0;
    b->length += (size_t) n;
    return 1;
}

// Reads stdout and stderr for ms, or until a stdout line holds want:
// 1 seen, 0 not, -1 ground code's stdout ended first.
static int read_for(ground *g, long ms, const char *want) {
    long until = now_ms() + ms;
    for (;;) {
        long left = until - now_ms();
        if (left <= 0) return 0;
        struct pollfd fds[2] = {{g->out, POLLIN, 0}, {g->err, POLLIN, 0}};
        int n = poll(fds, g->err >= 0 ? 2 : 1, (int) left);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) die("poll");
        if (g->err >= 0 && (fds[1].revents & (POLLIN | POLLHUP))) {
            if (!fill(g->err, &g->err_lines)) { close(g->err); g->err = -1; }
            lines_out(&g->err_lines, "! ", NULL);
        }
        if (fds[0].revents & (POLLIN | POLLHUP)) {
            if (!fill(g->out, &g->out_lines)) return -1;
            if (lines_out(&g->out_lines, "< ", want) && want != NULL) return 1;
        }
    }
}

// Closes ground code's stdin, prints what it still writes, and says how it ended.
static void finish(ground *g) {
    close(g->in);
    while (read_for(g, WAIT_MS, NULL) == 0) {}
    while (g->err >= 0) {
        if (!fill(g->err, &g->err_lines)) { close(g->err); g->err = -1; }
        lines_out(&g->err_lines, "! ", NULL);
    }
    close(g->out);
    int status;
    while (waitpid(g->pid, &status, 0) < 0) if (errno != EINTR) die("waitpid");
    if (WIFEXITED(status)) printf("# ground code exited %d\n", WEXITSTATUS(status));
    else printf("# ground code ended by signal %d\n", WTERMSIG(status));
    fflush(stdout);
}

// The line with each $CWD and $SID replaced; the caller frees it.
static char *expand(const char *line) {
    size_t n = 0;
    for (const char *p = line; (p = strchr(p, '$')) != NULL; p++) n++;
    char *out = malloc(strlen(line) + 1 + n * (strlen(cwd) + sizeof sid)), *w = out;
    if (out == NULL) die("malloc");
    for (const char *p = line; *p; ) {
        if (strncmp(p, "$CWD", 4) == 0) { w += sprintf(w, "%s", cwd); p += 4; }
        else if (strncmp(p, "$SID", 4) == 0) { w += sprintf(w, "%s", sid); p += 4; }
        else *w++ = *p++;
    }
    *w = '\0';
    return out;
}

// wait ID reads for the answer to request ID; expect TEXT for a line holding TEXT.
static int awaited(ground *g, const char *line) {
    char *want;
    if (strncmp(line, "wait ", 5) == 0) {
        if ((want = malloc(strlen(line) + 32)) == NULL) die("malloc");
        sprintf(want, "{\"jsonrpc\":\"2.0\",\"id\":%s,", line + 5);
    } else {
        want = expand(line + 7);
    }
    int seen = read_for(g, WAIT_MS, want);
    free(want);
    if (seen == 1) return 1;
    printf("# FAILED: %s: %s\n", line, seen == 0 ? "nothing arrived" : "ground code ended first");
    return 0;
}

static int sent(ground *g, const char *line) {
    char *message = expand(line);
    printf("> %s\n", message);
    fflush(stdout);
    size_t length = strlen(message);
    message[length] = '\n';
    int whole = write(g->in, message, length + 1) == (ssize_t) (length + 1);
    free(message);
    if (!whole) printf("# FAILED: ground code took no more input\n");
    return whole;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: acp_live GROUND_CODE CWD SCRIPT\n");
        return 2;
    }
    binary = argv[1];
    cwd = argv[2];
    FILE *script = fopen(argv[3], "r");
    if (script == NULL) die(argv[3]);
    signal(SIGPIPE, SIG_IGN);
    ground g = {0};
    start(&g);
    char *line = NULL;
    size_t capacity = 0;
    ssize_t got;
    int ok = 1;
    while (ok && (got = getline(&line, &capacity, script)) >= 0) {
        if (got > 0 && line[got - 1] == '\n') line[--got] = '\0';
        if (got == 0) continue;
        if (line[0] == '#') { printf("%s\n", line); fflush(stdout); }
        else if (strcmp(line, "restart") == 0) { finish(&g); printf("# restart\n"); start(&g); }
        else if (strncmp(line, "sleep ", 6) == 0) ok = read_for(&g, atol(line + 6), NULL) != -1;
        else if (strncmp(line, "wait ", 5) == 0 || strncmp(line, "expect ", 7) == 0) ok = awaited(&g, line);
        else ok = sent(&g, line);
    }
    free(line);
    fclose(script);
    finish(&g);
    return ok ? 0 : 1;
}
