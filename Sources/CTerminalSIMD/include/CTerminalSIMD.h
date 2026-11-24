#ifndef CTERMINALSIMD_H
#define CTERMINALSIMD_H

#include <stddef.h>
#include <stdint.h>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

/// Stores `n` cells at `dst`, one per byte of `src`: each cell is the
/// 16-byte template whose first word is the byte and whose other words
/// are `w1`, `w2` and `w3`.
///
/// Swift's SIMD conversions compile to calls here, and moving each byte
/// through a general register costs more than the stores. NEON widens
/// sixteen bytes in vector registers and `vst4q` interleaves them with the
/// template, four cells per store.
static inline __attribute__((always_inline)) void swiftty_store_ascii(
  const uint8_t *src, size_t n, uint32_t w1, uint32_t w2, uint32_t w3,
  void *dst
) {
  uint32_t *out = (uint32_t *)dst;
  size_t i = 0;
#if defined(__ARM_NEON)
  uint32x4x4_t cells;
  cells.val[1] = vdupq_n_u32(w1);
  cells.val[2] = vdupq_n_u32(w2);
  cells.val[3] = vdupq_n_u32(w3);
  for (; n - i >= 16; i += 16) {
    const uint8x16_t bytes = vld1q_u8(src + i);
    const uint16x8_t low = vmovl_u8(vget_low_u8(bytes));
    const uint16x8_t high = vmovl_high_u8(bytes);
    cells.val[0] = vmovl_u16(vget_low_u16(low));
    vst4q_u32(out + i * 4, cells);
    cells.val[0] = vmovl_high_u16(low);
    vst4q_u32(out + (i + 4) * 4, cells);
    cells.val[0] = vmovl_u16(vget_low_u16(high));
    vst4q_u32(out + (i + 8) * 4, cells);
    cells.val[0] = vmovl_high_u16(high);
    vst4q_u32(out + (i + 12) * 4, cells);
  }
  if (n - i >= 8) {
    const uint16x8_t wide = vmovl_u8(vld1_u8(src + i));
    cells.val[0] = vmovl_u16(vget_low_u16(wide));
    vst4q_u32(out + i * 4, cells);
    cells.val[0] = vmovl_high_u16(wide);
    vst4q_u32(out + (i + 4) * 4, cells);
    i += 8;
  }
  // Short runs (most lines end in one): one vector store per cell.
  const uint32x4_t blank = vsetq_lane_u32(0, cells.val[1], 0);
  const uint32x4_t base = vcopyq_laneq_u32(
    vcopyq_laneq_u32(blank, 2, cells.val[2], 0), 3, cells.val[3], 0
  );
  for (; i < n; i++) {
    vst1q_u32(out + i * 4, vsetq_lane_u32(src[i], base, 0));
  }
  return;
#endif
  for (; i < n; i++) {
    out[i * 4] = src[i];
    out[i * 4 + 1] = w1;
    out[i * 4 + 2] = w2;
    out[i * 4 + 3] = w3;
  }
}

/// Stores cells for the leading scalars of `p[0..<n]` that are narrow and
/// join nothing, U+0020 to U+02FF except U+00A9 and U+00AE, eight at a
/// time; returns how many it stored, a multiple of eight. Cells are as in
/// `swiftty_store_ascii`, with the scalar as the first word.
static inline __attribute__((always_inline)) size_t swiftty_store_narrow(
  const uint32_t *p, size_t n, uint32_t w1, uint32_t w2, uint32_t w3,
  void *dst
) {
  size_t i = 0;
#if defined(__ARM_NEON)
  uint32_t *out = (uint32_t *)dst;
  uint32x4x4_t cells;
  cells.val[1] = vdupq_n_u32(w1);
  cells.val[2] = vdupq_n_u32(w2);
  cells.val[3] = vdupq_n_u32(w3);
  const uint32x4_t low = vdupq_n_u32(0x20);
  const uint32x4_t span = vdupq_n_u32(0x300 - 0x20);
  const uint32x4_t copyright = vdupq_n_u32(0xA9);
  const uint32x4_t registered = vdupq_n_u32(0xAE);
  for (; n - i >= 8; i += 8) {
    const uint32x4_t a = vld1q_u32(p + i);
    const uint32x4_t b = vld1q_u32(p + i + 4);
    const uint32x4_t inA = vbicq_u32(
      vcltq_u32(vsubq_u32(a, low), span),
      vorrq_u32(vceqq_u32(a, copyright), vceqq_u32(a, registered))
    );
    const uint32x4_t inB = vbicq_u32(
      vcltq_u32(vsubq_u32(b, low), span),
      vorrq_u32(vceqq_u32(b, copyright), vceqq_u32(b, registered))
    );
    if (vminvq_u32(vandq_u32(inA, inB)) == 0) break;
    cells.val[0] = a;
    vst4q_u32(out + i * 4, cells);
    cells.val[0] = b;
    vst4q_u32(out + (i + 4) * 4, cells);
  }
#else
  (void)p; (void)n; (void)w1; (void)w2; (void)w3; (void)dst;
#endif
  return i;
}

#if defined(__ARM_NEON)
/// The index of the first nonzero byte of `mask`, which has 0x00 or 0xFF
/// lanes and at least one 0xFF.
static inline __attribute__((always_inline)) size_t swiftty_first_set(
  uint8x16_t mask
) {
  // Narrow each byte pair to a nibble: four bits per lane.
  const uint64_t bits = vget_lane_u64(
    vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(mask), 4)), 0
  );
  return (size_t)__builtin_ctzll(bits) / 4;
}
#endif

/// The first index in `start..<end` whose byte is a C0 control (below
/// 0x20), or `end`.
///
/// Swift's `pointwiseMin` and `any` on these vectors compile to calls here,
/// one per vector.
static inline __attribute__((always_inline)) size_t swiftty_scan_controls(
  const uint8_t *p, size_t start, size_t end
) {
  size_t i = start;
#if defined(__ARM_NEON)
  const uint8x16_t space = vdupq_n_u8(0x20);
  while (end - i >= 64) {
    const uint8x16x4_t v = vld1q_u8_x4(p + i);
    const uint8x16_t low = vminq_u8(
      vminq_u8(v.val[0], v.val[1]), vminq_u8(v.val[2], v.val[3])
    );
    if (vminvq_u8(low) < 0x20) break;
    i += 64;
  }
  while (end - i >= 16) {
    const uint8x16_t below = vcltq_u8(vld1q_u8(p + i), space);
    if (vmaxvq_u8(below) != 0) return i + swiftty_first_set(below);
    i += 16;
  }
#endif
  while (i < end && p[i] >= 0x20) i++;
  return i;
}

/// The first index in `start..<end` whose byte is a C0 control or 0x80
/// and above (not kitty graphics payload), or `end`. As signed bytes both
/// are below 0x20, so one minimum per 64 bytes finds either.
static inline __attribute__((always_inline)) size_t swiftty_scan_payload(
  const uint8_t *p, size_t start, size_t end
) {
  size_t i = start;
#if defined(__ARM_NEON)
  const int8x16_t space = vdupq_n_s8(0x20);
  while (end - i >= 64) {
    const int8x16x4_t v = vld1q_s8_x4((const int8_t *)p + i);
    const int8x16_t low = vminq_s8(
      vminq_s8(v.val[0], v.val[1]), vminq_s8(v.val[2], v.val[3])
    );
    if (vminvq_s8(low) < 0x20) break;
    i += 64;
  }
  while (end - i >= 16) {
    const uint8x16_t below = vcltq_s8(vld1q_s8((const int8_t *)p + i), space);
    if (vmaxvq_u8(below) != 0) return i + swiftty_first_set(below);
    i += 16;
  }
#endif
  while (i < end && p[i] >= 0x20 && p[i] < 0x80) i++;
  return i;
}

#endif
