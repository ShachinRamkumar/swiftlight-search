#ifndef DIGUP_CJPEG_H
#define DIGUP_CJPEG_H
#include <stddef.h>
#include <stdint.h>

// The caller frees *rgb with digup_jpeg_free on success. Errors return zero.
int digup_jpeg_decode(const uint8_t *bytes, size_t length, uint8_t **rgb,
                      int *width, int *height, char *error, size_t error_size);
void digup_jpeg_free(uint8_t *rgb);
#endif
