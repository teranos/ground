module polling;

// poll(2), the one declaration of it the binaries have: exec waits on a
// script's pipes with it, and ground code on its client's input.

extern (C) {
    struct pollfd {
        int fd;
        short events;
        short revents;
    }
    int poll(pollfd* fds, uint nfds, int timeout);
}

enum POLLIN  = 0x001;
enum POLLHUP = 0x010;
enum POLLERR = 0x008;
