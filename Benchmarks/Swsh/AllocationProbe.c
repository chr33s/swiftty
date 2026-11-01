// Linked only into the separate measurement build, never the shipped shell.
#include "CAllocCounter.h"
#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/resource.h>
#include <unistd.h>

typedef void(malloc_logger_t)(uint32_t, uintptr_t, uintptr_t, uintptr_t,
                              uintptr_t, uint32_t);
extern malloc_logger_t *malloc_logger;
static malloc_logger_t *previous_logger;
static _Atomic(uint64_t) process_allocations;

// The callback allocates nothing. Static storage survives callbacks already
// in flight when the destructor restores the previous logger.
static void count_all_threads(uint32_t type, uintptr_t a1, uintptr_t a2,
                              uintptr_t a3, uintptr_t result, uint32_t skip) {
  if (type & 2) atomic_fetch_add_explicit(&process_allocations, 1, memory_order_relaxed);
  if (previous_logger) previous_logger(type, a1, a2, a3, result, skip);
}

__attribute__((constructor)) static void begin_measurement(void) {
  alloc_counter_start();
  previous_logger = malloc_logger;
  malloc_logger = count_all_threads;
}

__attribute__((destructor)) static void end_measurement(void) {
  if (malloc_logger == count_all_threads) malloc_logger = previous_logger;
  uint64_t all_threads = atomic_load_explicit(&process_allocations, memory_order_relaxed);
  uint64_t main_thread = alloc_counter_stop();
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage) != 0) _exit(125);
  dprintf(STDERR_FILENO,
          "SWSH_MEASURE {\"pid\":%d,\"main_thread_allocations\":%" PRIu64
          ",\"all_thread_allocations\":%" PRIu64 ",\"peak_rss_bytes\":%ld}\n",
          getpid(), main_thread, all_threads, usage.ru_maxrss);
}
