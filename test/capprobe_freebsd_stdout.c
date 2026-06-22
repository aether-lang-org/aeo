/* capprobe_freebsd_stdout.c — Capsicum self-report probe for a FreeBSD bhyve-VM
 * guest, reporting over STDOUT (fd 1, inherited — the allowed channel that
 * survives cap_enter). The host captures stdout over the ssh pipe. Same
 * self-report-from-inside-confinement pattern; stdout is simpler + needs no
 * inbound port (pf on the host blocks arbitrary aeonat->host ports; the ssh
 * pipe is already permitted).
 *   cc -o capprobe capprobe_freebsd_stdout.c && ./capprobe
 */
#include <sys/capsicum.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

static void report(const char *s){ write(1, s, strlen(s)); write(1, "\n", 1); }

int main(void){
    /* stdout (fd 1) is our inherited allowed channel — open before confine. */
    if(cap_enter()!=0){ report("CAP_ENTER FAILED"); return 4; }
    unsigned int m=0; cap_getmode(&m);
    report(m==1 ? "IN_CAPMODE 1" : "IN_CAPMODE 0");

    int fd = open("/etc/passwd", O_RDONLY);
    report(fd<0 ? "fs-read BLOCKED" : "fs-read ESCAPED"); if(fd>=0) close(fd);

    fd = open("/tmp/vm-escape", O_RDWR|O_CREAT, 0600);
    report(fd<0 ? "fs-write BLOCKED" : "fs-write ESCAPED"); if(fd>=0) close(fd);

    { int s=socket(AF_INET,SOCK_STREAM,0); struct sockaddr_in d; memset(&d,0,sizeof d);
      d.sin_family=AF_INET; d.sin_port=htons(80); d.sin_addr.s_addr=htonl(0x01010101);
      report(connect(s,(struct sockaddr*)&d,sizeof d)==0 ? "egress-connect ESCAPED" : "egress-connect BLOCKED");
      if(s>=0) close(s); }

    { int s=socket(AF_INET,SOCK_STREAM,0); struct sockaddr_in b; memset(&b,0,sizeof b);
      b.sin_family=AF_INET; b.sin_port=htons(18080); b.sin_addr.s_addr=INADDR_ANY;
      report(bind(s,(struct sockaddr*)&b,sizeof b)==0 ? "ingress-bind ESCAPED" : "ingress-bind BLOCKED");
      if(s>=0) close(s); }

    report("ALLOWED-CHANNEL still-open OK");  /* stdout still works post-confine */
    return 0;
}
