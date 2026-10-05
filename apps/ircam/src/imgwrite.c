/*
 * Minimal image writers.
 *
 * The camera can hand us a ready-made JPEG, in which case we just write the
 * bytes out. When it hands us YUV or RAW instead we still want a file the phone
 * can display, and cross-compiling libpng/libjpeg for the device would be a lot
 * of machinery for two format conversions. PNG allows deflate streams made
 * entirely of "stored" (uncompressed) blocks, so a valid PNG needs only CRC-32
 * and Adler-32 -- about sixty lines, and no dependency to keep in sync.
 * The files are large but exact; nothing is lost.
 */
#include "imgwrite.h"
#include <stdlib.h>
#include <string.h>

static uint32_t crc_table[256];
static int crc_ready = 0;

static void crc_init(void) {
  for (uint32_t n = 0; n < 256; n++) {
    uint32_t c = n;
    for (int k = 0; k < 8; k++) c = (c & 1) ? 0xedb88320u ^ (c >> 1) : c >> 1;
    crc_table[n] = c;
  }
  crc_ready = 1;
}

static uint32_t crc32_buf(uint32_t crc, const uint8_t *b, size_t n) {
  if (!crc_ready) crc_init();
  crc ^= 0xffffffffu;
  for (size_t i = 0; i < n; i++) crc = crc_table[(crc ^ b[i]) & 0xff] ^ (crc >> 8);
  return crc ^ 0xffffffffu;
}

static void put_be32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

static int write_chunk(FILE *f, const char *type, const uint8_t *data, size_t len) {
  uint8_t hdr[8];
  put_be32(hdr, (uint32_t)len);
  memcpy(hdr + 4, type, 4);
  if (fwrite(hdr, 1, 8, f) != 8) return -1;
  if (len && fwrite(data, 1, len, f) != len) return -1;
  uint32_t crc = crc32_buf(0, (const uint8_t *)type, 4);
  if (len) crc = crc32_buf(crc, data, len);
  uint8_t c[4];
  put_be32(c, crc);
  return fwrite(c, 1, 4, f) == 4 ? 0 : -1;
}

int png_write_rgb8(const char *path, const uint8_t *rgb, int w, int h) {
  if (w <= 0 || h <= 0) return -1;
  FILE *f = fopen(path, "wb");
  if (!f) return -1;

  static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
  if (fwrite(sig, 1, 8, f) != 8) goto err;

  uint8_t ihdr[13];
  put_be32(ihdr, (uint32_t)w);
  put_be32(ihdr + 4, (uint32_t)h);
  ihdr[8] = 8;   /* bit depth */
  ihdr[9] = 2;   /* colour type: truecolour RGB */
  ihdr[10] = 0;  /* deflate */
  ihdr[11] = 0;  /* adaptive filtering */
  ihdr[12] = 0;  /* no interlace */
  if (write_chunk(f, "IHDR", ihdr, sizeof ihdr)) goto err;

  /* Raw scanlines: one filter byte (0 = None) then w*3 sample bytes. */
  const size_t row = (size_t)w * 3 + 1;
  const size_t raw_len = row * (size_t)h;
  uint8_t *raw = malloc(raw_len);
  if (!raw) goto err;
  for (int y = 0; y < h; y++) {
    raw[y * row] = 0;
    memcpy(raw + y * row + 1, rgb + (size_t)y * w * 3, (size_t)w * 3);
  }

  /* zlib stream: 2-byte header, stored deflate blocks, Adler-32 trailer. */
  const size_t MAXB = 65535;
  size_t nblocks = (raw_len + MAXB - 1) / MAXB;
  size_t z_len = 2 + nblocks * 5 + raw_len + 4;
  uint8_t *z = malloc(z_len);
  if (!z) {
    free(raw);
    goto err;
  }
  size_t o = 0;
  z[o++] = 0x78; /* CMF: deflate, 32K window */
  z[o++] = 0x01; /* FLG: no dict, check bits make 0x7801 a multiple of 31 */
  size_t off = 0;
  while (off < raw_len) {
    size_t n = raw_len - off < MAXB ? raw_len - off : MAXB;
    z[o++] = (off + n >= raw_len) ? 1 : 0; /* BFINAL, BTYPE=00 (stored) */
    z[o++] = (uint8_t)(n & 0xff);
    z[o++] = (uint8_t)(n >> 8);
    z[o++] = (uint8_t)(~n & 0xff);
    z[o++] = (uint8_t)((~n >> 8) & 0xff);
    memcpy(z + o, raw + off, n);
    o += n;
    off += n;
  }
  uint32_t a = 1, b = 0;
  for (size_t i = 0; i < raw_len; i++) {
    a = (a + raw[i]) % 65521;
    b = (b + a) % 65521;
  }
  put_be32(z + o, (b << 16) | a);
  o += 4;
  free(raw);

  int rc = write_chunk(f, "IDAT", z, o);
  free(z);
  if (rc) goto err;
  if (write_chunk(f, "IEND", NULL, 0)) goto err;
  return fclose(f) == 0 ? 0 : -1;

err:
  fclose(f);
  return -1;
}

int pgm_write_gray16(const char *path, const uint16_t *gray, int w, int h) {
  FILE *f = fopen(path, "wb");
  if (!f) return -1;
  fprintf(f, "P5\n%d %d\n65535\n", w, h);
  /* PGM is big-endian; the sensor data is little-endian on this device. */
  uint8_t *row = malloc((size_t)w * 2);
  if (!row) {
    fclose(f);
    return -1;
  }
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      uint16_t v = gray[(size_t)y * w + x];
      row[x * 2] = (uint8_t)(v >> 8);
      row[x * 2 + 1] = (uint8_t)(v & 0xff);
    }
    if (fwrite(row, 1, (size_t)w * 2, f) != (size_t)w * 2) {
      free(row);
      fclose(f);
      return -1;
    }
  }
  free(row);
  return fclose(f) == 0 ? 0 : -1;
}
