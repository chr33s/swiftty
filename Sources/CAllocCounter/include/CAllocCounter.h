#pragma once
#include <stdint.h>

/// Starts counting heap allocations made by the calling thread.
void alloc_counter_start(void);
/// Stops counting and returns the number of allocations observed.
uint64_t alloc_counter_stop(void);
