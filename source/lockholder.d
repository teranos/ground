module lockholder;

// Who holds ground.db's write lock, asked of the kernel by the hook that is
// left waiting on it. SQLite in WAL mode takes that lock as a POSIX byte lock
// on the -shm file, and F_GETLK answers with the pid holding it.

import core.sys.posix.fcntl : open, fcntl, flock, F_GETLK, F_WRLCK, F_UNLCK, O_RDWR;
import core.sys.posix.unistd : close;
import core.stdc.stdio : SEEK_SET;

// WAL_WRITE_LOCK, WAL_CKPT_LOCK and WAL_RECOVER_LOCK: bytes 120 to 122 of the
// -shm (sqlite3.c, UNIX_SHM_BASE). The read slots after them are left out, so
// a reader is never named for a writer's wait.
version (OSX) extern (C) int sysctl(int*, uint, void*, size_t*, void*, size_t);

enum SHM_WRITE_LOCKS = 120;
enum SHM_WRITE_LOCKS_LEN = 3;

// The -shm, opened once and never closed: closing any descriptor of it drops
// every POSIX lock SQLite holds on it, and decay died of that, bus error 10.
__gshared int shmFd = -1;
__gshared char[1024] shmOpened = 0; // the path shmFd is of

/// The pid holding the write lock on the store whose -shm is shmPath; 0 when
/// nobody does or the file would not open.
int writeLockHolder(const(char)* shmPath) {
    import core.stdc.string : strcmp, strncpy;
    if (shmFd < 0 || strcmp(shmOpened.ptr, shmPath) != 0) {
        // Another store's -shm is opened beside the last, which stays open.
        shmFd = open(shmPath, O_RDWR);
        strncpy(shmOpened.ptr, shmPath, shmOpened.length - 1);
    }
    auto fd = shmFd;
    if (fd < 0) return 0;
    flock fl;
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = SHM_WRITE_LOCKS;
    fl.l_len = SHM_WRITE_LOCKS_LEN;
    if (fcntl(fd, F_GETLK, &fl) != 0) return 0;
    return fl.l_type == F_UNLCK ? 0 : fl.l_pid;
}

/// The holder as a phase value: what it runs, its subcommand, then #pid, with
/// no space in it and never a leading digit, e.g. ground_decay#4242.
const(char)[] holderName(int pid, char[] dest) {
    // A process's whole argument area, its environment in it; a hook's runs to
    // several kilobytes.
    __gshared char[262144] args = 0;
    auto got = argsOf(pid, args[]);
    size_t n;
    void put(const(char)[] s) {
        foreach (c; s) {
            if (n >= dest.length) return;
            dest[n++] = (c == ' ' || c == '=' || c == '\t' || c == '\n') ? '_' : c;
        }
    }
    const(char)[] first = got.length > 0 ? got[0] : null;
    if (first.length > 0) {
        size_t base = 0;
        foreach (i, c; first) if (c == '/') base = i + 1;
        put(first[base .. $]);
        if (got.length > 1 && got[1].length > 0 && got[1][0] != '-') {
            put("_");
            put(got[1]);
        }
    } else {
        put("pid");
    }
    if (n > 0 && dest[0] >= '0' && dest[0] <= '9') dest[0] = '_';
    put("#");
    char[12] digits = 0;
    size_t d;
    auto v = pid;
    do { digits[d++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0 && d < digits.length);
    foreach_reverse (i; 0 .. d) put(digits[i .. i + 1]);
    return dest[0 .. n];
}

// The first two arguments the process was started with, read from the kernel;
// empty when it will not say.
private const(char)[][] argsOf(int pid, char[] buf) {
    __gshared const(char)[][2] out_;
    size_t len;
    version (OSX) {
        enum CTL_KERN = 1;
        enum KERN_PROCARGS2 = 49;
        int[3] mib = [CTL_KERN, KERN_PROCARGS2, pid];
        // Asked with a buffer short of the whole area, the kernel does not hand
        // back its start: the size is asked first, and one too big is no name.
        if (sysctl(mib.ptr, 3, null, &len, null, 0) != 0 || len > buf.length) return out_[0 .. 0];
        len = buf.length;
        if (sysctl(mib.ptr, 3, buf.ptr, &len, null, 0) != 0 || len < int.sizeof) return out_[0 .. 0];
        // argc, the executable's path, padding, then argv itself.
        int argc = *cast(int*) buf.ptr;
        size_t i = int.sizeof;
        while (i < len && buf[i] != 0) i++;
        while (i < len && buf[i] == 0) i++;
        size_t found;
        while (i < len && found < out_.length && found < cast(size_t) argc) {
            auto start = i;
            while (i < len && buf[i] != 0) i++;
            out_[found++] = buf[start .. i];
            i++;
        }
        return out_[0 .. found];
    } else version (linux) {
        import core.stdc.stdio : snprintf;
        import core.sys.posix.unistd : read;
        char[32] path = 0;
        snprintf(path.ptr, path.length, "/proc/%d/cmdline", pid);
        auto fd = open(path.ptr, 0);
        if (fd < 0) return out_[0 .. 0];
        auto r = read(fd, buf.ptr, buf.length);
        close(fd);
        if (r <= 0) return out_[0 .. 0];
        len = cast(size_t) r;
        size_t i, found;
        while (i < len && found < out_.length) {
            auto start = i;
            while (i < len && buf[i] != 0) i++;
            out_[found++] = buf[start .. i];
            i++;
        }
        return out_[0 .. found];
    } else {
        return out_[0 .. 0];
    }
}
