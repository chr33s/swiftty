#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/sysctl.h>

static void hex(const char *label, const char *value) {
  printf("%s=", label);
  if (value) for (const unsigned char *p = (const unsigned char *)value; *p; ++p) printf("%02x", *p);
  putchar('\n');
}

int main(int argc, char **argv) {
  if (argc == 3 && argv[1][0] == 'i') {
    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, atoi(argv[2])};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (sysctl(query, 4, &info, &size, 0, 0) != 0 || size != sizeof(info)) return 24;
    // Darwin exposes process-wide caught/ignored dispositions. The deprecated
    // p_sigmask is deliberately not used as evidence about thread signal masks.
    printf("ignored=%u\ncaught=%u\n", info.kp_proc.p_sigignore, info.kp_proc.p_sigcatch);
    return 0;
  }
  printf("pid=%d\ngroup=%d\n", getpid(), getpgrp());
  sigset_t blocked;
  sigprocmask(SIG_SETMASK, 0, &blocked);
  int signals[] = {SIGINT, SIGQUIT, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU, SIGHUP, SIGTERM, SIGCHLD};
  int defaults = 1, unblocked = 1;
  for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
    struct sigaction action;
    sigaction(signals[i], 0, &action);
    defaults &= action.sa_handler == SIG_DFL;

  }
  for (int number = 1; number < NSIG; ++number) unblocked &= sigismember(&blocked, number) == 0;
  printf("defaults=%d\nunblocked=%d\nfds=", defaults, unblocked);
  for (int fd = 3; fd < 1024; ++fd) if (fcntl(fd, F_GETFD) >= 0) printf("%d,", fd);
  putchar('\n');
  char *cwd = getcwd(0, 0);
  hex("cwd", cwd);
  free(cwd);
  hex("argument", argc > 1 ? argv[1] : "");
  hex("raw", getenv("RAW"));
  return 23;
}
