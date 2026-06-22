/* capfd.c — tiny extern helpers for the Capsicum breakout spec.
 *
 * std.capsicum.rights_limit(fd, mask) needs a RAW INTEGER fd, but the Aether
 * stdlib hands back opaque ptrs (file_open_raw -> ptr). These externs obtain
 * real int fds (files + sockets) so the spec can narrow them with
 * rights_limit() and prove the per-fd RIGHTS layer of confinement — i.e. a
 * granted read-only fd refuses write, a connect-only socket refuses bind, etc.
 * That models aeo's constraint("disk", ..., "rd") vs "rd,wr".
 *
 * Plus a couple of post-cap_enter operation helpers that report errno so the
 * spec can assert ECAPMODE / ENOTCAPABLE rather than guess from a wrapper.
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/* open a path; write!=0 -> O_RDWR|O_CREAT, else O_RDONLY. returns fd or -1. */
int aeo_open_fd(const char *path, int write) {
    int flags = write ? (O_RDWR | O_CREAT) : O_RDONLY;
    return open(path, flags, 0600);
}

/* a fresh socket fd (AF_INET stream). returns fd or -1. */
int aeo_socket_fd(void) {
    return socket(AF_INET, SOCK_STREAM, 0);
}

/* try to write to fd. returns 0 on success, else errno (positive). */
int aeo_try_write(int fd) {
    ssize_t n = write(fd, "x", 1);
    if (n >= 0) return 0;
    return errno;
}

/* try to read from fd. returns 0 on success, else errno. */
int aeo_try_read(int fd) {
    char b[1];
    ssize_t n = read(fd, b, 1);
    if (n >= 0) return 0;
    return errno;
}

/* try to connect fd to host:port. returns 0 on success, else errno. */
int aeo_try_connect(int fd, unsigned int ip_be, int port) {
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((unsigned short)port);
    sa.sin_addr.s_addr = ip_be; /* already network order */
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) return 0;
    return errno;
}

/* try to bind fd to 0.0.0.0:port. returns 0 on success, else errno. */
int aeo_try_bind(int fd, int port) {
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((unsigned short)port);
    sa.sin_addr.s_addr = INADDR_ANY;
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) == 0) return 0;
    return errno;
}

/* try to listen on fd. returns 0 on success, else errno. */
int aeo_try_listen(int fd) {
    if (listen(fd, 1) == 0) return 0;
    return errno;
}

int aeo_close_fd(int fd) { return close(fd); }

/* ECAPMODE (capability mode violation) and ENOTCAPABLE (right not granted),
 * exposed so the spec can name the exact denial it expects. */
int aeo_ECAPMODE(void)    { return ECAPMODE; }
int aeo_ENOTCAPABLE(void) { return ENOTCAPABLE; }
