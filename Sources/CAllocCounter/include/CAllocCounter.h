#pragma once
#include <stdint.h>

/// Starts counting heap allocations made by the calling thread.
/// Existing malloc logging continues during the measurement.
void alloc_counter_start(void);
/// Stops counting and returns the number of allocations observed.
/// Restores the previous logger if the counter still owns the hook.
uint64_t alloc_counter_stop(void);
