#ifndef CKITTYBASE64_H
#define CKITTYBASE64_H

#include <stddef.h>
#include <stdint.h>

/// Decodes leading 64-byte blocks of standard-alphabet base64 (no padding,
/// whitespace or other bytes) from `src` into `dst`, 48 bytes per block.
/// Stops before the first block holding any other byte. Returns the number
/// of input bytes consumed; output bytes written are 3/4 of that. Without
/// NEON it consumes nothing and callers decode everything themselves.
size_t swiftty_base64_decode_blocks(const uint8_t *src, size_t n, uint8_t *dst);

#endif
