/* SPDX-License-Identifier: MIT */
#include "internal.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char **environ;
/* macOS 26 standardised the chdir file action and deprecated the _np name. */
static int add_chdir(posix_spawn_file_actions_t *actions, const char *dir) {
#if defined(__APPLE__) && defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED >= 260000
  return posix_spawn_file_actions_addchdir(actions, dir);
#else
  return posix_spawn_file_actions_addchdir_np(actions, dir);
#endif
}
static mcp_status deadline_after(int ms, int64_t *d, mcp_error *e) {
  int64_t n = mcp_now();
  if (n < 0)
    return mcp_fail(e, MCP_SYSTEM_ERROR, errno, "clock_gettime");
  *d = n + ms;
  return MCP_OK;
}
/* FDs >= 3 make spawn correct even if the embedding app closed stdin/stdout. */
static int high_fd(int fd) {
  if (fd >= 3) {
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) == 0)
      return fd;
  } else {
    int high = fcntl(fd, F_DUPFD_CLOEXEC, 3), saved = errno;
    close(fd);
    errno = saved;
    return high;
  }
  int saved = errno;
  close(fd);
  errno = saved;
  return -1;
}

mcp_status mcp_stdio_open(mcp_client *c, const mcp_options *o, mcp_error *e) {
  mcp_status s = MCP_OK;
  int pair[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
    s = mcp_fail(e, MCP_SYSTEM_ERROR, errno, "socketpair MCP stdio");
    goto failed;
  }
  pair[0] = high_fd(pair[0]);
  pair[1] = high_fd(pair[1]);
  if (pair[0] < 0 || pair[1] < 0) {
    int saved = errno;
    if (pair[0] >= 0)
      close(pair[0]);
    if (pair[1] >= 0)
      close(pair[1]);
    s = mcp_fail(e, MCP_SYSTEM_ERROR, saved,
                 "set MCP close-on-exec descriptors");
    goto failed;
  }
  c->fd = pair[0];
#ifdef SO_NOSIGPIPE
  int one = 1;
  if (setsockopt(c->fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0) {
    s = mcp_fail(e, MCP_SYSTEM_ERROR, errno, "set SO_NOSIGPIPE");
    close(pair[1]);
    goto failed;
  }
#endif
  if (fcntl(c->fd, F_SETFL, O_NONBLOCK) != 0) {
    s = mcp_fail(e, MCP_SYSTEM_ERROR, errno, "set MCP stream nonblocking");
    close(pair[1]);
    goto failed;
  }
  posix_spawn_file_actions_t actions;
  int rc = posix_spawn_file_actions_init(&actions);
  if (rc) {
    s = mcp_fail(e, MCP_SYSTEM_ERROR, rc, "init spawn actions");
    close(pair[1]);
    goto failed;
  }
  rc = posix_spawn_file_actions_adddup2(&actions, pair[1], STDIN_FILENO);
  if (!rc)
    rc = posix_spawn_file_actions_adddup2(&actions, pair[1], STDOUT_FILENO);
  if (!rc)
    rc = posix_spawn_file_actions_addclose(&actions, pair[0]);
  if (!rc)
    rc = posix_spawn_file_actions_addclose(&actions, pair[1]);
  if (!rc && o->cwd)
    rc = add_chdir(&actions, o->cwd);
  if (!rc)
    rc = posix_spawnp(&c->pid, o->command, &actions, NULL,
                      (char *const *)o->argv,
                      o->envp ? (char *const *)o->envp : environ);
  posix_spawn_file_actions_destroy(&actions);
  close(pair[1]);
  if (rc) {
    s = mcp_fail(e, MCP_SYSTEM_ERROR, rc, "spawn MCP server");
    goto failed;
  }
  return MCP_OK;
failed:
  return s;
}

static mcp_status wait_child(mcp_client *c, int *status, bool *exited,
                             mcp_error *e) {
  int64_t d = 0;
  mcp_status s = deadline_after(c->shutdown_ms, &d, e);
  if (s != MCP_OK)
    return s;
  for (;;) {
    pid_t rc = waitpid(c->pid, status, WNOHANG);
    if (rc == c->pid) {
      *exited = true;
      return MCP_OK;
    }
    if (rc < 0 && errno == EINTR)
      continue;
    if (rc < 0) {
      if (errno == ECHILD)
        *exited = true; /* caller reaped it; never signal a reused PID */
      return mcp_fail(e, MCP_SYSTEM_ERROR, errno, "waitpid MCP server");
    }
    int64_t now = mcp_now();
    if (now < 0)
      return mcp_fail(e, MCP_SYSTEM_ERROR, errno, "clock_gettime");
    if (now >= d)
      return MCP_TIMEOUT;
    /* Drain shutdown output so an exiting server cannot fill its pipe. */
    char discard[4096];
    if (c->fd >= 0) {
      ssize_t n = recv(c->fd, discard, sizeof(discard), 0);
      if (n > 0)
        continue;
      if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
        return mcp_fail(e, MCP_SYSTEM_ERROR, errno,
                        "drain MCP shutdown stream");
    }
    struct timespec pause = {0, 1000000};
    nanosleep(&pause, NULL);
  }
}

mcp_status mcp_stdio_close(mcp_client *c, mcp_error *e) {
  if (!c)
    return mcp_fail(e, MCP_OK, 0, "success");
  mcp_status s = MCP_OK;
  if (c->fd >= 0 && shutdown(c->fd, SHUT_WR) != 0 && errno != ENOTCONN)
    s = mcp_fail(e, MCP_SYSTEM_ERROR, errno, "close MCP server stdin");
  if (c->pid > 0) {
    int status = 0;
    bool exited = false, forced = false;
    mcp_error child_error = {0};
    mcp_status w = wait_child(c, &status, &exited, &child_error);
    if (w == MCP_SYSTEM_ERROR && s == MCP_OK)
      s = mcp_fail(e, w, child_error.system_errno, child_error.message);
    if (!exited) {
      forced = true;
      if (kill(c->pid, SIGTERM) != 0 && errno != ESRCH)
        w = mcp_fail(&child_error, MCP_SYSTEM_ERROR, errno,
                     "SIGTERM MCP server");
      else
        w = wait_child(c, &status, &exited, &child_error);
    }
    if (w == MCP_SYSTEM_ERROR && s == MCP_OK)
      s = mcp_fail(e, w, child_error.system_errno, child_error.message);
    if (!exited) {
      if (kill(c->pid, SIGKILL) != 0 && errno != ESRCH)
        w = mcp_fail(&child_error, MCP_SYSTEM_ERROR, errno,
                     "SIGKILL MCP server");
      else {
        pid_t rc;
        do {
          rc = waitpid(c->pid, &status, 0);
        } while (rc < 0 && errno == EINTR);
        if (rc < 0)
          w = mcp_fail(&child_error, MCP_SYSTEM_ERROR, errno,
                       "reap MCP server");
        else {
          exited = true;
          w = MCP_OK;
        }
      }
    }
    if (s == MCP_OK) {
      if (w == MCP_SYSTEM_ERROR)
        s = mcp_fail(e, w, child_error.system_errno, child_error.message);
      else if (forced)
        s = mcp_fail(e, MCP_TIMEOUT, 0, "MCP server required forced shutdown");
      else if (exited && (!WIFEXITED(status) || WEXITSTATUS(status) != 0)) {
        s = mcp_fail(e, MCP_SYSTEM_ERROR, 0,
                     "MCP server exited unsuccessfully");
        if (e)
          e->child_status = status;
      }
    }
  }
  if (c->fd >= 0 && close(c->fd) != 0 && s == MCP_OK)
    s = mcp_fail(e, MCP_SYSTEM_ERROR, errno, "close MCP stream");
  c->fd = -1;
  c->pid = -1;
  return s == MCP_OK ? mcp_fail(e, MCP_OK, 0, "success") : s;
}

mcp_status mcp_queue(mcp_client *c, json *o, int64_t id, mcp_error *e) {
  const char *wire = json_object_to_json_string_ext(o, JSON_C_TO_STRING_PLAIN);
  if (!wire)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "serialize stdio frame");
  size_t n = strlen(wire);
  if (n > c->limit)
    return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0,
                    "outgoing frame exceeds message limit");
  mcp_frame *f = calloc(1, sizeof(*f));
  if (!f)
    return mcp_fail(e, MCP_NO_MEMORY, 0, "allocate outgoing frame");
  f->wire = malloc(n + 1);
  if (!f->wire) {
    free(f);
    return mcp_fail(e, MCP_NO_MEMORY, 0, "copy outgoing frame");
  }
  memcpy(f->wire, wire, n);
  f->wire[n] = '\n';
  f->length = n + 1;
  f->id = id;
  if (c->tx_tail)
    c->tx_tail->next = f;
  else
    c->tx_head = f;
  c->tx_tail = f;
  return MCP_OK;
}

static mcp_status flush(mcp_client *c, mcp_error *e) {
  while (c->tx_head) {
    mcp_frame *f = c->tx_head;
#ifdef MSG_NOSIGNAL
    ssize_t n =
        send(c->fd, f->wire + f->offset, f->length - f->offset, MSG_NOSIGNAL);
#else
    ssize_t n = send(c->fd, f->wire + f->offset, f->length - f->offset, 0);
#endif
    if (n < 0) {
      if (errno == EINTR)
        continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK)
        return MCP_OK;
      return mcp_fail(e, MCP_SYSTEM_ERROR, errno, "write MCP stdio frame");
    }
    if (!n)
      return mcp_fail(e, MCP_EOF, 0, "MCP stream closed during write");
    f->offset += (size_t)n;
    if (f->offset < f->length)
      return MCP_OK;
    mcp_request *r = mcp_find(c, f->id);
    if (r)
      r->sent = true;
    c->tx_head = f->next;
    if (!c->tx_head)
      c->tx_tail = NULL;
    free(f->wire);
    free(f);
  }
  return MCP_OK;
}

mcp_status mcp_stdio_poll(mcp_client *c, int ms, mcp_error *e) {
  mcp_status s = flush(c, e);
  if (s != MCP_OK)
    return s;
  /* Bound work per poll so a chatty peer cannot starve deadlines. */
  for (unsigned budget = 0; budget < 64; budget++) {
    char *nl = memchr(c->buffer, '\n', c->used);
    if (nl) {
      size_t consumed = (size_t)(nl - c->buffer) + 1, n = consumed - 1;
      if (n && c->buffer[n - 1] == '\r')
        n--;
      s = mcp_dispatch(c, NULL, c->buffer, n, e);
      memmove(c->buffer, c->buffer + consumed, c->used - consumed);
      c->used -= consumed;
      if (s != MCP_OK)
        return s;
      /* Deliver completed requests without probing EOF after the final frame.
       */
      if (!c->used)
        return flush(c, e);
      continue;
    }
    if (c->used > c->limit)
      return mcp_fail(e, MCP_MESSAGE_TOO_LARGE, 0,
                      "incoming stdio frame exceeds message limit");
    struct pollfd p = {.fd = c->fd,
                       .events = POLLIN | (c->tx_head ? POLLOUT : 0)};
    int rc = poll(&p, 1, budget ? 0 : ms);
    if (rc < 0) {
      if (errno == EINTR)
        return MCP_OK;
      return mcp_fail(e, MCP_SYSTEM_ERROR, errno, "poll MCP stream");
    }
    if (!rc)
      return MCP_OK;
    if (p.revents & POLLOUT) {
      s = flush(c, e);
      if (s != MCP_OK)
        return s;
    }
    if (p.revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = recv(c->fd, c->buffer + c->used, c->limit + 1 - c->used, 0);
      if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
          return MCP_OK;
        return mcp_fail(e, MCP_SYSTEM_ERROR, errno, "read MCP stream");
      }
      if (!n && c->used) {
        s = mcp_retain_failure(c, NULL, c->buffer, c->used, e);
        if (s != MCP_OK)
          return s;
      }
      if (!n)
        return mcp_fail(e, c->used ? MCP_PROTOCOL_ERROR : MCP_EOF, 0,
                        c->used ? "truncated stdio frame" : "MCP stream ended");
      c->used += (size_t)n;
    }
  }
  return MCP_OK;
}

mcp_status mcp_stdio_cancel(mcp_request *r, const char *reason, mcp_error *e) {
  mcp_client *c = r->client;
  if (!c->modern && !strcmp(r->method, "initialize"))
    return MCP_OK;
  mcp_frame **p = &c->tx_head;
  while (*p) {
    mcp_frame *f = *p;
    if (f->id == r->id && !f->offset) {
      *p = f->next;
      if (c->tx_tail == f) {
        c->tx_tail = c->tx_head;
        while (c->tx_tail && c->tx_tail->next)
          c->tx_tail = c->tx_tail->next;
      }
      free(f->wire);
      free(f);
      return MCP_OK;
    }
    p = &f->next;
  }
  json *o = json_object_new_object(), *params = json_object_new_object();
  bool ok = mcp_add(params, "requestId", json_object_new_int64(r->id));
  if (reason)
    ok = mcp_add(params, "reason", json_object_new_string(reason)) && ok;
  ok = mcp_add(o, "jsonrpc", json_object_new_string("2.0")) && ok;
  ok =
      mcp_add(o, "method", json_object_new_string("notifications/cancelled")) &&
      ok;
  ok = mcp_add(o, "params", params) && ok;
  mcp_status s =
      ok ? mcp_queue(c, o, 0, e)
         : mcp_fail(e, MCP_NO_MEMORY, 0, "build cancellation notification");
  json_object_put(o);
  return s;
}
