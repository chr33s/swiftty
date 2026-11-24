// Kitty graphics payloads are base64 (spec.graphics.md §5). NEON decodes
// 64 input bytes per step: vld4 splits them into the four sextet lanes,
// table lookups map each lane to its value, and vst3 interleaves the three
// output bytes. Blocks with padding, whitespace or invalid bytes are left
// to the Swift decoder, which applies Ghostty's rules.
#include "CKittyBase64.h"

#if defined(__ARM_NEON)
#include <arm_neon.h>

// Sextet values of bytes 0-63 and 64-127; 0xFF marks bytes outside the
// alphabet. Out-of-range lookups return 0, so bytes 128 and above are
// rejected separately.
static const uint8_t low_table[64] = {
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 62,  255, 255, 255, 63,
  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  255, 255, 255, 255, 255, 255,
};
static const uint8_t high_table[64] = {
  255, 0,   1,   2,   3,   4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,
  15,  16,  17,  18,  19,  20,  21,  22,  23,  24,  25,  255, 255, 255, 255, 255,
  255, 26,  27,  28,  29,  30,  31,  32,  33,  34,  35,  36,  37,  38,  39,  40,
  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  51,  255, 255, 255, 255, 255,
};

static inline uint8x16_t sextets(
  uint8x16_t v, uint8x16x4_t low, uint8x16x4_t high, uint8x16_t *invalid
) {
  const uint8x16_t r = vorrq_u8(
    vqtbl4q_u8(low, v), vqtbl4q_u8(high, vsubq_u8(v, vdupq_n_u8(64))));
  *invalid = vorrq_u8(
    *invalid, vorrq_u8(vcgtq_u8(r, vdupq_n_u8(63)), vcgeq_u8(v, vdupq_n_u8(128))));
  return r;
}

size_t swiftty_base64_decode_blocks(const uint8_t *src, size_t n, uint8_t *dst) {
  size_t i = 0;
  size_t o = 0;
  const uint8x16x4_t low = vld1q_u8_x4(low_table);
  const uint8x16x4_t high = vld1q_u8_x4(high_table);
  while (i + 64 <= n) {
    const uint8x16x4_t in = vld4q_u8(src + i);
    uint8x16_t invalid = vdupq_n_u8(0);
    const uint8x16_t a = sextets(in.val[0], low, high, &invalid);
    const uint8x16_t b = sextets(in.val[1], low, high, &invalid);
    const uint8x16_t c = sextets(in.val[2], low, high, &invalid);
    const uint8x16_t d = sextets(in.val[3], low, high, &invalid);
    if (vmaxvq_u8(invalid) != 0) break;
    uint8x16x3_t out;
    out.val[0] = vorrq_u8(vshlq_n_u8(a, 2), vshrq_n_u8(b, 4));
    out.val[1] = vorrq_u8(vshlq_n_u8(b, 4), vshrq_n_u8(c, 2));
    out.val[2] = vorrq_u8(vshlq_n_u8(c, 6), d);
    vst3q_u8(dst + o, out);
    i += 64;
    o += 48;
  }
  return i;
}

#else

size_t swiftty_base64_decode_blocks(const uint8_t *src, size_t n, uint8_t *dst) {
  (void)src;
  (void)n;
  (void)dst;
  return 0;
}

#endif
