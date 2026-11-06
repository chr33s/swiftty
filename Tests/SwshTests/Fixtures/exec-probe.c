#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#else
#include <string.h>
#endif

static void hex(const char *label, const char *value) {
  printf("%s=", label);
  if (value) for (const unsigned char *p = (const unsigned char *)value; *p; ++p) printf("%02x", *p);
  putchar('\n');
}

int main(int argc, char **argv) {
  if (argc == 3 && argv[1][0] == 'i') {
#ifndef __APPLE__
    // Linux reports the same process-wide sets as hexadecimal masks.
    char path[64], line[256];
    snprintf(path, sizeof(path), "/proc/%d/status", atoi(argv[2]));
    FILE *status = fopen(path, "r");
    if (!status) return 24;
    unsigned long long ignored = 0, caught = 0;
    int found = 0;
    while (fgets(line, sizeof(line), status)) {
      if (!strncmp(line, "SigIgn:", 7)) { ignored = strtoull(line + 7, 0, 16); ++found; }
      if (!strncmp(line, "SigCgt:", 7)) { caught = strtoull(line + 7, 0, 16); ++found; }
    }
    fclose(status);
    if (found != 2) return 24;
    printf("ignored=%u\ncaught=%u\n", (unsigned)ignored, (unsigned)caught);
    return 0;
#else
    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, atoi(argv[2])};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (sysctl(query, 4, &info, &size, 0, 0) != 0 || size != sizeof(info)) return 24;
    // Darwin exposes process-wide caught/ignored dispositions. The deprecated
    // p_sigmask is deliberately not used as evidence about thread signal masks.
    printf("ignored=%u\ncaught=%u\n", info.kp_proc.p_sigignore, info.kp_proc.p_sigcatch);
    return 0;
#endif
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
