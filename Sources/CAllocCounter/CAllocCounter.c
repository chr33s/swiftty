#include "CAllocCounter.h"
#include <pthread.h>
#include <stdatomic.h>
#include <execinfo.h>
#include <stdlib.h>

// libmalloc calls this hook for every malloc/calloc/realloc/free when set.
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2,
                              uintptr_t arg3, uintptr_t result,
                              uint32_t num_hot_frames_to_skip);
extern malloc_logger_t *malloc_logger;

#define MALLOC_LOG_TYPE_ALLOCATE 2

static pthread_t target;
static int trace; // ALLOC_COUNTER_TRACE=1 prints a backtrace per allocation
static int inside; // only the target thread reaches the trace path
static _Atomic uint64_t count;

static void logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3,
                   uintptr_t result, uint32_t skip) {
  (void)a1; (void)a2; (void)a3; (void)result; (void)skip;
  if ((type & MALLOC_LOG_TYPE_ALLOCATE) && pthread_equal(pthread_self(), target))
  {
    atomic_fetch_add_explicit(&count, 1, memory_order_relaxed);
    if (trace && !inside) {
      inside = 1;
      void *frames[32];
      int n = backtrace(frames, 32);
      backtrace_symbols_fd(frames, n, 2);
      inside = 0;
    }
  }
}

void alloc_counter_start(void) {
  target = pthread_self();
  trace = getenv("ALLOC_COUNTER_TRACE") != 0;
  atomic_store(&count, 0);
  malloc_logger = logger;
}

uint64_t alloc_counter_stop(void) {
  malloc_logger = 0;
  return atomic_load(&count);
}
