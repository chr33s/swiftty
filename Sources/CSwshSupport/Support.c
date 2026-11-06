#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include "CSwshSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#ifdef __APPLE__
#include <crt_externs.h>
char **swsh_environment(void) { return *_NSGetEnviron(); }
#else
extern char **environ;
char **swsh_environment(void) { return environ; }
#endif
#include <signal.h>
#include <pthread.h>
#include <sys/wait.h>
int swsh_wait_kind(int status) {
  if (WIFEXITED(status)) return 1;
  if (WIFSIGNALED(status)) return 2;
  if (WIFSTOPPED(status)) return 3;
  if (WIFCONTINUED(status)) return 4;
  return 0;
}
int swsh_wait_value(int status) {
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return WTERMSIG(status);
  if (WIFSTOPPED(status)) return WSTOPSIG(status);
  return 0;
}
// Where kqueue cannot report signals, the handler forwards each number through
// a nonblocking pipe. The pipe is unused, and the handler a no-op, until
// swsh_signal_pipe is first called. Only async-signal-safe calls are made.
static int swsh_signal_descriptors[2] = {-1, -1};
static void swsh_signal_notification(int number) {
  if (swsh_signal_descriptors[1] < 0) return;
  int saved = errno;
  unsigned char byte = (unsigned char)number;
  (void)!write(swsh_signal_descriptors[1], &byte, 1);
  errno = saved;
}
int swsh_signal_pipe(void) {
  if (swsh_signal_descriptors[0] >= 0) return swsh_signal_descriptors[0];
  int descriptors[2];
  if (pipe(descriptors) != 0) return -1;
  for (int i = 0; i < 2; ++i) {
    if (fcntl(descriptors[i], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(descriptors[i], F_SETFL, O_NONBLOCK) != 0) {
      close(descriptors[0]);
      close(descriptors[1]);
      return -1;
    }
  }
  swsh_signal_descriptors[0] = descriptors[0];
  swsh_signal_descriptors[1] = descriptors[1];
  return descriptors[0];
}
int swsh_observe_signal(int number) {
  struct sigaction action = {0};
  action.sa_handler = swsh_signal_notification;
  sigemptyset(&action.sa_mask);
  return sigaction(number, &action, 0);
}
#include <stdlib.h>
int swsh_ignore_signal(int number) { return signal(number, SIG_IGN) == SIG_ERR ? -1 : 0; }
int swsh_default_signal(int number) { return signal(number, SIG_DFL) == SIG_ERR ? -1 : 0; }
#ifndef __APPLE__
#ifdef __linux__
#include <sys/prctl.h>
#endif
char *swsh_executable_path(void) { return realpath("/proc/self/exe", 0); }
// Image replacement without POSIX_SPAWN_SETEXEC: the new image gets default
// dispositions for the shell's signals and an empty mask. Returns errno when
// execve fails, with the caller's signal state restored.
//
// The shell never holds a default disposition it did not have before. execve
// itself resets a caught signal to its default, so each ignored signal is
// given a handler that does nothing instead of SIG_DFL. A blocked signal with
// a default action gets a handler that records it before the mask is cleared;
// after a failure it is raised again under the restored mask, so it stays
// pending as it was.
static volatile sig_atomic_t swsh_replace_held[NSIG];
static void swsh_replace_ignore(int number) { (void)number; }
static void swsh_replace_hold(int number) { swsh_replace_held[number] = 1; }
int swsh_replace(const char *path, char *const argv[], char *const envp[]) {
  static const int signals[] = {SIGINT, SIGQUIT, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU, SIGHUP, SIGTERM, SIGCHLD};
  struct sigaction previous[NSIG];
  unsigned char changed[NSIG] = {0};
  sigset_t empty, mask;
  sigemptyset(&empty);
  pthread_sigmask(SIG_SETMASK, 0, &mask);
  for (int number = 1; number < NSIG; ++number) {
    if (number == SIGKILL || number == SIGSTOP) continue;
    if (sigaction(number, 0, &previous[number]) != 0) continue;
    int listed = 0;
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) listed |= signals[i] == number;
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    if (previous[number].sa_handler == SIG_IGN && listed) action.sa_handler = swsh_replace_ignore;
    else if (previous[number].sa_handler == SIG_DFL && sigismember(&mask, number) == 1) action.sa_handler = swsh_replace_hold;
    else continue;
    swsh_replace_held[number] = 0;
    if (sigaction(number, &action, 0) == 0) changed[number] = 1;
  }
  pthread_sigmask(SIG_SETMASK, &empty, 0);
  execve(path, argv, envp);
  int code = errno;
  pthread_sigmask(SIG_SETMASK, &mask, 0);
  for (int number = 1; number < NSIG; ++number) {
    if (!changed[number]) continue;
    sigaction(number, &previous[number], 0);
    if (swsh_replace_held[number]) pthread_kill(pthread_self(), number);
  }
  return code;
}
// Job-control launch without POSIX_SPAWN_START_SUSPENDED. The child joins its
// process group, applies the wiring, and then waits for SIGCONT before execve,
// so the group can be assembled and given the terminal first. SIGCONT stays
// blocked from before fork until that wait, so an early release is not lost.
// Only async-signal-safe calls run in the child. The image is replaced after
// this function returns, so an execve failure is reported by the child on
// standard error with status 126 or 127.
static void swsh_report(const char *text) {
  size_t length = 0;
  while (text[length]) ++length;
  (void)!write(STDERR_FILENO, text, length);
}
int swsh_spawn_gated(pid_t *pid, const char *path, char *const argv[], char *const envp[],
                     pid_t group, const int *wiring, int count, int keep_terminal_stops) {
  static const int signals[] = {SIGINT, SIGQUIT, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU, SIGHUP, SIGTERM, SIGCHLD};
  sigset_t all, previous;
  sigfillset(&all);
  pid_t parent = getpid();
  // No shell handler may run in the child: it would write to the shell's pipe.
  int error = pthread_sigmask(SIG_SETMASK, &all, &previous);
  if (error) return error;
  pid_t child = fork();
  if (child < 0) {
    error = errno;
    pthread_sigmask(SIG_SETMASK, &previous, 0);
    return error;
  }
  if (child == 0) {
#ifdef __linux__
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) _exit(126);
#else
    if (getppid() != parent) _exit(126);
#endif
    struct sigaction standard = {0};
    standard.sa_handler = SIG_DFL;
    sigemptyset(&standard.sa_mask);
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
      int number = signals[i];
      if (keep_terminal_stops && (number == SIGTSTP || number == SIGTTIN || number == SIGTTOU)) continue;
      sigaction(number, &standard, 0);
    }
    if (setpgid(0, group) != 0) _exit(126);
    for (int i = 0; i < count; ++i) {
      int source = wiring[2 * i], destination = wiring[2 * i + 1];
      if (source < 0) {
        if (close(destination) != 0) _exit(126);
      } else if (source == destination) {
        if (fcntl(source, F_SETFD, 0) != 0) _exit(126);
      } else if (dup2(source, destination) < 0) _exit(126);
    }
    sigset_t gate, empty;
    sigemptyset(&gate);
    sigaddset(&gate, SIGCONT);
    sigemptyset(&empty);
    int received;
    while (sigwait(&gate, &received) != 0) {}
#ifdef __linux__
    (void)prctl(PR_SET_PDEATHSIG, 0);
#endif
    pthread_sigmask(SIG_SETMASK, &empty, 0);
    execve(path, argv, envp);
    int code = errno;
    swsh_report("swsh: posix_spawn: ");
    swsh_report(code == ENOENT ? "No such file or directory" : code == ENOTDIR ? "Not a directory"
      : code == EACCES ? "Permission denied" : code == ENOEXEC ? "Exec format error"
      : code == EISDIR ? "Is a directory" : "cannot execute");
    swsh_report("\n");
    _exit(code == ENOENT || code == ENOTDIR ? 127 : 126);
  }
  // Both sides join the group, so it exists before the caller uses it.
  (void)setpgid(child, group);
  pthread_sigmask(SIG_SETMASK, &previous, 0);
  *pid = child;
  return 0;
}
#include <sys/ioctl.h>
#include <string.h>
// /dev/tty names the controlling terminal. A session leader started on a
// terminal it does not yet control may claim it, without force.
char *swsh_controlling_terminal(void) {
  int fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (fd < 0 && getsid(0) == getpid() && isatty(STDIN_FILENO)) {
    if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) != 0) return 0;
    fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
  }
  if (fd < 0) return 0;
  close(fd);
  return strdup("/dev/tty");
}
#else
#include <mach-o/dyld.h>
char *swsh_executable_path(void) {
  uint32_t size = 0;
  _NSGetExecutablePath(0, &size);
  char *buffer = malloc(size);
  if (!buffer) return 0;
  if (_NSGetExecutablePath(buffer, &size) != 0) { free(buffer); return 0; }
  char *resolved = realpath(buffer, 0);
  free(buffer);
  return resolved;
}
#include <libproc.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
char *swsh_controlling_terminal(void) {
  struct proc_bsdinfo info;
  int count = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info));
  if (count != sizeof(info)) { errno = ENXIO; return 0; }
  // Darwin's SETSID + spawn-open PTY hosts can leave a new session without
  // a controlling terminal. Only its leader may claim the attached slave;
  // no force flag is used, and nested shells never take this path.
  if ((dev_t)info.e_tdev == (dev_t)-1 && getsid(0) == getpid() && isatty(STDIN_FILENO)) {
    if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) != 0) return 0;
    count = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (count != sizeof(info)) { errno = ENXIO; return 0; }
  }
  char name[128];
  if (!devname_r((dev_t)info.e_tdev, S_IFCHR, name, sizeof(name))) return 0;
  char *path = 0;
  if (asprintf(&path, "/dev/%s", name) < 0) return 0;
  struct stat device;
  if (stat(path, &device) != 0 || device.st_rdev != (dev_t)info.e_tdev) {
    free(path);
    errno = ENXIO;
    return 0;
  }
  return path;
}
#endif

// A bounded, single-message descriptor handoff for parent-builtin redirect setup.
// C owns ancillary-message layout; Swift owns every returned descriptor lifetime.
#include <sys/socket.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
int swsh_send_standard_descriptors(int socket) {
  int descriptors[3], count = 0;
  unsigned char mask = 0;
  for (int fd = 0; fd < 3; ++fd) {
    if (fcntl(fd, F_GETFD) >= 0) {
      mask |= 1 << fd;
      descriptors[count++] = fd;
    } else if (errno != EBADF) return -1;
  }
  union { struct cmsghdr align; char bytes[CMSG_SPACE(3 * sizeof(int))]; } control = {0};
  struct iovec data = { &mask, sizeof(mask) };
  struct msghdr message = {0};
  message.msg_iov = &data;
  message.msg_iovlen = 1;
  if (count) {
    message.msg_control = control.bytes;
    message.msg_controllen = (socklen_t)CMSG_SPACE(count * sizeof(int));
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(count * sizeof(int));
    memcpy(CMSG_DATA(header), descriptors, count * sizeof(int));
  }
  ssize_t sent;
  do { sent = sendmsg(socket, &message, 0); } while (sent < 0 && errno == EINTR);
  if (sent == 1) return 0;
  if (sent >= 0) errno = EIO;
  return -1;
}

int swsh_receive_standard_descriptors(int socket, int output[3]) {
  for (int i = 0; i < 3; ++i) output[i] = -1;
  unsigned char mask = 0;
  union { struct cmsghdr align; char bytes[CMSG_SPACE(3 * sizeof(int))]; } control = {0};
  struct iovec data = { &mask, sizeof(mask) };
  struct msghdr message = {0};
  message.msg_iov = &data;
  message.msg_iovlen = 1;
  message.msg_control = control.bytes;
  message.msg_controllen = sizeof(control.bytes);
  ssize_t received;
  do { received = recvmsg(socket, &message, MSG_DONTWAIT); } while (received < 0 && errno == EINTR);
  if (received < 0) return -1;
  int descriptors[3], count = 0, invalid = received != 1 || (mask & ~7) || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC));
  for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
    if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS || header->cmsg_len < CMSG_LEN(0)) { invalid = 1; continue; }
    size_t size = header->cmsg_len - CMSG_LEN(0);
    if (size % sizeof(int)) invalid = 1;
    for (size_t i = 0; i < size / sizeof(int); ++i) {
      int fd;
      memcpy(&fd, (char *)CMSG_DATA(header) + i * sizeof(int), sizeof(fd));
      if (count < 3) descriptors[count++] = fd;
      else { close(fd); invalid = 1; }
    }
  }
  if (count != !!(mask & 1) + !!(mask & 2) + !!(mask & 4)) invalid = 1;
  int error = EINVAL;
  if (!invalid) {
    int index = 0;
    for (int slot = 0; slot < 3; ++slot) {
      if (!(mask & (1 << slot))) continue;
      // recvmsg may allocate a closed standard slot. Relocate immediately,
      // leaving the parent's standard descriptors exactly as they were.
      output[slot] = fcntl(descriptors[index++], F_DUPFD_CLOEXEC, 10);
      if (output[slot] < 0) { error = errno; invalid = 1; break; }
    }
  }
  for (int i = 0; i < count; ++i) close(descriptors[i]);
  if (!invalid) return 0;
  for (int i = 0; i < 3; ++i) { if (output[i] >= 0) close(output[i]); output[i] = -1; }
  errno = error;
  return -1;
}
