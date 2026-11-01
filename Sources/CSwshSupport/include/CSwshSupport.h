#ifndef CSWSH_SUPPORT_H
#define CSWSH_SUPPORT_H
// Darwin's crt_externs.h is not exposed through the Swift Darwin module.
char **swsh_environment(void);
// These wrappers expose Darwin's function-like wait macros to Swift.
int swsh_wait_kind(int status); // 1 exit, 2 signal, 3 stop, 4 continue
int swsh_wait_value(int status);
int swsh_observe_signal(int number);
char *swsh_executable_path(void); // caller frees the returned path
int swsh_ignore_signal(int number);
int swsh_default_signal(int number);
char *swsh_controlling_terminal(void); // caller frees the returned path
int swsh_send_standard_descriptors(int socket);
int swsh_receive_standard_descriptors(int socket, int output[3]);
#endif
