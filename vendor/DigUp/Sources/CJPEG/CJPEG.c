#include "CJPEG.h"
#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include <string.h>
#include "jpeglib.h"

struct decoder {
    struct jpeg_decompress_struct jpeg;
    struct jpeg_error_mgr errors;
    jmp_buf jump;
    uint8_t *pixels;
    char message[JMSG_LENGTH_MAX];
};

static void failed(j_common_ptr jpeg) {
    struct decoder *d = (struct decoder *)jpeg;
    (*jpeg->err->format_message)(jpeg, d->message);
    longjmp(d->jump, 1);
}

// Pillow rejects truncated JPEGs unless LOAD_TRUNCATED_IMAGES is enabled.
static void message(j_common_ptr jpeg, int level) {
    if (level < 0) failed(jpeg);
}

int digup_jpeg_decode(const uint8_t *bytes, size_t length, uint8_t **rgb,
                      int *width, int *height, char *error, size_t error_size) {
    *rgb = NULL;
    struct decoder *d = calloc(1, sizeof(*d));
    if (!d) { snprintf(error, error_size, "JPEG decoder allocation failed"); return 0; }
    d->jpeg.err = jpeg_std_error(&d->errors);
    d->errors.error_exit = failed;
    d->errors.emit_message = message;
    if (setjmp(d->jump)) {
        snprintf(error, error_size, "%s", d->message);
        jpeg_destroy_decompress(&d->jpeg);
        free(d->pixels);
        free(d);
        return 0;
    }
    jpeg_create_decompress(&d->jpeg);
    jpeg_mem_src(&d->jpeg, bytes, length);
    jpeg_read_header(&d->jpeg, TRUE);
    int cmyk = d->jpeg.jpeg_color_space == JCS_CMYK || d->jpeg.jpeg_color_space == JCS_YCCK;
    d->jpeg.out_color_space = cmyk ? JCS_CMYK : JCS_RGB;
    d->jpeg.dct_method = JDCT_ISLOW;
    d->jpeg.do_fancy_upsampling = TRUE;
    d->jpeg.scale_num = 1;
    d->jpeg.scale_denom = 1;
    if (!d->jpeg.image_width || !d->jpeg.image_height ||
        d->jpeg.image_width > 100000 || d->jpeg.image_height > 100000 ||
        (uint64_t)d->jpeg.image_width * d->jpeg.image_height > 100000000) {
        snprintf(d->message, sizeof(d->message), "JPEG dimensions exceed limit");
        longjmp(d->jump, 1);
    }
    jpeg_start_decompress(&d->jpeg);
    size_t w = d->jpeg.output_width, h = d->jpeg.output_height;
    d->pixels = malloc(w * h * 3);
    if (!d->pixels) {
        snprintf(d->message, sizeof(d->message), "JPEG pixels allocation failed");
        longjmp(d->jump, 1);
    }
    JSAMPARRAY scanline = (*d->jpeg.mem->alloc_sarray)((j_common_ptr)&d->jpeg,
                             JPOOL_IMAGE, (JDIMENSION)(w * d->jpeg.output_components), 1);
    while (d->jpeg.output_scanline < h) {
        size_t y = d->jpeg.output_scanline;
        jpeg_read_scanlines(&d->jpeg, scanline, 1);
        uint8_t *row = d->pixels + y * w * 3;
        if (cmyk) {
            // Pillow's JPEG rawmode is CMYK;I, even without an Adobe marker.
            // Its CMYK -> RGB rounding was verified over all 65,536 C,K pairs.
            for (size_t x = 0; x < w; x++) {
                unsigned k = scanline[0][x * 4 + 3];
                for (int c = 0; c < 3; c++) row[x * 3 + c] = (scanline[0][x * 4 + c] * k + 127) / 255;
            }
        } else memcpy(row, scanline[0], w * 3);
    }
    jpeg_finish_decompress(&d->jpeg);
    *rgb = d->pixels;
    *width = (int)w;
    *height = (int)h;
    jpeg_destroy_decompress(&d->jpeg);
    free(d);
    return 1;
}

void digup_jpeg_free(uint8_t *rgb) { free(rgb); }
