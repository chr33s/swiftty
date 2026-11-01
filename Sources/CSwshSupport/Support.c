#include "CSwshSupport.h"
#include <crt_externs.h>
char **swsh_environment(void) { return *_NSGetEnviron(); }
#include <signal.h>
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
static void swsh_signal_notification(int number) { (void)number; }
int swsh_observe_signal(int number) {
  struct sigaction action = {0};
  action.sa_handler = swsh_signal_notification;
  sigemptyset(&action.sa_mask);
  return sigaction(number, &action, 0);
}
#include <mach-o/dyld.h>
#include <stdlib.h>
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
int swsh_ignore_signal(int number) { return signal(number, SIG_IGN) == SIG_ERR ? -1 : 0; }
int swsh_default_signal(int number) { return signal(number, SIG_DFL) == SIG_ERR ? -1 : 0; }
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
