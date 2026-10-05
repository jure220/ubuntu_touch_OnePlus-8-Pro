#ifndef IRCAM_IMGWRITE_H
#define IRCAM_IMGWRITE_H
#include <stdint.h>
#include <stdio.h>

/* Save an 8-bit RGB buffer as a PNG. Uses deflate "stored" blocks, so the file
 * is a fully valid PNG with no compression and no zlib dependency. Returns 0 on
 * success. */
int png_write_rgb8(const char *path, const uint8_t *rgb, int w, int h);

/* Save a 16-bit single-channel buffer as a binary PGM (P5), the standard
 * lossless format for raw sensor greyscale. Returns 0 on success. */
int pgm_write_gray16(const char *path, const uint16_t *gray, int w, int h);

#endif
