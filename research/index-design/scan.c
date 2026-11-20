// Offline comparison kernels. No model or app runtime is linked.
#include <arm_neon.h>
#include <math.h>
#include <stdint.h>
#include <stddef.h>

enum { DIM = 768 };

float quantize(const float *v, int8_t *codes) {
    float largest = 0;
    for (int j = 0; j < DIM; j++) largest = fmaxf(largest, fabsf(v[j]));
    float scale = largest > 0 ? largest / 127.0f : 1.0f;
    for (int j = 0; j < DIM; j++) codes[j] = (int8_t)roundf(v[j] / scale);
    return scale;
}

void int8_scan(const int8_t *rows, const float *scales, size_t n, const float *query, float *out) {
    int8_t q[DIM];
    float qs = quantize(query, q);
    for (size_t r = 0; r < n; r++) {
        const int8_t *v = rows + r * DIM;
        int32x4_t a = vdupq_n_s32(0), b = a, c = a, d = a;
        for (int j = 0; j < DIM; j += 64) {
            a = vdotq_s32(a, vld1q_s8(v+j), vld1q_s8(q+j));
            b = vdotq_s32(b, vld1q_s8(v+j+16), vld1q_s8(q+j+16));
            c = vdotq_s32(c, vld1q_s8(v+j+32), vld1q_s8(q+j+32));
            d = vdotq_s32(d, vld1q_s8(v+j+48), vld1q_s8(q+j+48));
        }
        int32_t dot = vaddvq_s32(vaddq_s32(vaddq_s32(a,b),vaddq_s32(c,d)));
        out[r] = ((float)dot * scales[r]) * qs;
    }
}

void make_codes(const __fp16 *v, size_t n, int8_t *codes, float *scales) {
    float f[DIM];
    for (size_t r=0; r<n; r++) {
        for (int j=0; j<DIM; j++) f[j] = (float)v[r*DIM+j];
        scales[r] = quantize(f,codes+r*DIM);
    }
}

// Reference fp16 storage, exact real dot rounded once to f32 for these input ranges.
// f64 also avoids making fp32 reassociation part of the compression experiment.
void half_scan(const __fp16 *rows, size_t n, const float *q, float *out) {
    for (size_t r=0; r<n; r++) {
        const __fp16 *v = rows+r*DIM;
        float64x2_t a = vdupq_n_f64(0), b = a;
        for (int j=0; j<DIM; j+=4) {
            float32x4_t x = vcvt_f32_f16(vld1_f16(v+j));
            float32x4_t y = vld1q_f32(q+j);
            a = vaddq_f64(a,vmulq_f64(vcvt_f64_f32(vget_low_f32(x)),vcvt_f64_f32(vget_low_f32(y))));
            b = vaddq_f64(b,vmulq_f64(vcvt_f64_f32(vget_high_f32(x)),vcvt_f64_f32(vget_high_f32(y))));
        }
        out[r] = (float)vaddvq_f64(vaddq_f64(a,b));
    }
}

void half_scan_f32(const __fp16 *rows, size_t n, const float *q, float *out) {
    for (size_t r=0; r<n; r++) {
        const __fp16 *v = rows+r*DIM;
        float32x4_t a = vdupq_n_f32(0), b = a;
        for (int j=0; j<DIM; j+=8) {
            a = vaddq_f32(a,vmulq_f32(vcvt_f32_f16(vld1_f16(v+j)),vld1q_f32(q+j)));
            b = vaddq_f32(b,vmulq_f32(vcvt_f32_f16(vld1_f16(v+j+4)),vld1q_f32(q+j+4)));
        }
        out[r] = vaddvq_f32(vaddq_f32(a,b));
    }
}

void binary_scan(const uint8_t *rows,size_t n,const uint8_t *q,float *out) {
    for (size_t r=0;r<n;r++) {
        uint16_t count=0;
        for (int j=0;j<96;j+=16) {
            uint8x16_t bits=veorq_u8(vld1q_u8(rows+r*96+j),vld1q_u8(q+j));
            count+=vaddlvq_u8(vcntq_u8(bits));
        }
        out[r]=1.f-2.f*(float)count/768.f;
    }
}
