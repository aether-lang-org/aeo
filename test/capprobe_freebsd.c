/* capprobe_freebsd.c — Capsicum self-report probe, runs INSIDE a FreeBSD
 * bhyve-VM guest. Opens its ONE allowed channel (TCP socket to the aeocha-side
 * listener on the host) BEFORE confining, cap_enter()s, then attempts each
 * escape class and reports the result back over the allowed channel. The
 * confined guest process proves its OWN confinement — no procstat, no host
 * observation. (FreeBSD guest, so Capsicum is available to the guest process
 * itself — the whole point of freebsd_vm{} vs a Linux guest.)
 *
 *   cc -o capprobe capprobe_freebsd.c && ./capprobe <host> <port>
 */
#include <sys/capsicum.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int chan;
static void report(const char *s){ write(chan, s, strlen(s)); write(chan, "\n", 1); }

int main(int argc, char **argv){
    if(argc<3){ fprintf(stderr,"usage: %s host port\n",argv[0]); return 2; }
    /* 1) ALLOWED CHANNEL — open before confinement (the one fd we keep). */
    chan = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa; memset(&sa,0,sizeof sa);
    sa.sin_family=AF_INET; sa.sin_port=htons(atoi(argv[2]));
    inet_pton(AF_INET, argv[1], &sa.sin_addr);
    if(connect(chan,(struct sockaddr*)&sa,sizeof sa)!=0){ perror("connect"); return 3; }

    /* 2) CONFINE SELF — cap_enter() (irreversible). */
    if(cap_enter()!=0){ report("CAP_ENTER FAILED"); return 4; }
    unsigned int m=0; cap_getmode(&m);
    report(m==1 ? "IN_CAPMODE 1" : "IN_CAPMODE 0");

    /* 3) ESCAPE ATTEMPTS — each must be DENIED by the kernel. */
    /* fs-read: open a global path */
    int fd = open("/etc/passwd", O_RDONLY);
    report(fd<0 ? "fs-read BLOCKED" : "fs-read ESCAPED");
    if(fd>=0) close(fd);
    /* fs-write: create a new file */
    fd = open("/tmp/vm-escape", O_RDWR|O_CREAT, 0600);
    report(fd<0 ? "fs-write BLOCKED" : "fs-write ESCAPED");
    if(fd>=0) close(fd);
    /* tcpip-egress: new socket + connect out */
    {
        int s2=socket(AF_INET,SOCK_STREAM,0);
        struct sockaddr_in d; memset(&d,0,sizeof d);
        d.sin_family=AF_INET; d.sin_port=htons(80); d.sin_addr.s_addr=htonl(0x01010101);
        int rc=connect(s2,(struct sockaddr*)&d,sizeof d);
        report(rc==0 ? "egress-connect ESCAPED" : "egress-connect BLOCKED");
        if(s2>=0) close(s2);
    }
    /* tcpip-ingress: new socket + bind */
    {
        int s3=socket(AF_INET,SOCK_STREAM,0);
        struct sockaddr_in b; memset(&b,0,sizeof b);
        b.sin_family=AF_INET; b.sin_port=htons(18080); b.sin_addr.s_addr=INADDR_ANY;
        int rc=bind(s3,(struct sockaddr*)&b,sizeof b);
        report(rc==0 ? "ingress-bind ESCAPED" : "ingress-bind BLOCKED");
        if(s3>=0) close(s3);
    }
    /* 4) prove the allowed channel still works post-confinement. */
    report("ALLOWED-CHANNEL still-open OK");
    close(chan);
    return 0;
}
