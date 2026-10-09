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

// Other threads can still enter the hook while a measurement starts or stops.
static _Atomic(pthread_t) target;
static int trace; // ALLOC_COUNTER_TRACE=1 prints a backtrace per allocation
static int inside; // only the target thread reaches the trace path
static _Atomic uint64_t count;
static _Atomic(malloc_logger_t *) previous_logger;

static void logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3,
                   uintptr_t result, uint32_t skip) {
  if ((type & MALLOC_LOG_TYPE_ALLOCATE) &&
      pthread_equal(pthread_self(), atomic_load_explicit(&target, memory_order_relaxed)))
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
  malloc_logger_t *previous = atomic_load_explicit(&previous_logger, memory_order_acquire);
  if (previous) {
    previous(type, a1, a2, a3, result, skip);
  }
}

void alloc_counter_start(void) {
  if (malloc_logger != logger) {
    atomic_store_explicit(&previous_logger, malloc_logger, memory_order_release);
  }
  atomic_store_explicit(&target, pthread_self(), memory_order_relaxed);
  trace = getenv("ALLOC_COUNTER_TRACE") != 0;
  atomic_store(&count, 0);
  malloc_logger = logger;
}

uint64_t alloc_counter_stop(void) {
  if (malloc_logger == logger) {
    malloc_logger = atomic_load_explicit(&previous_logger, memory_order_acquire);
  }
  return atomic_load(&count);
}
