#include "camutil.h"

const char *ircam_format_name(int32_t f) {
  switch (f) {
    case AIMAGE_FORMAT_JPEG: return "JPEG";
    case AIMAGE_FORMAT_YUV_420_888: return "YUV_420_888";
    case AIMAGE_FORMAT_RAW16: return "RAW16";
    case AIMAGE_FORMAT_RAW10: return "RAW10";
    case AIMAGE_FORMAT_RAW12: return "RAW12";
    case AIMAGE_FORMAT_RAW_PRIVATE: return "RAW_PRIVATE";
    case AIMAGE_FORMAT_PRIVATE: return "IMPLEMENTATION_DEFINED";
    case AIMAGE_FORMAT_Y8: return "Y8";
    default: return "(other)";
  }
}

int ircam_has_capability(const ACameraMetadata *chars, uint8_t capability) {
  ACameraMetadata_const_entry e;
  if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_REQUEST_AVAILABLE_CAPABILITIES, &e) !=
      ACAMERA_OK)
    return 0;
  for (uint32_t i = 0; i < e.count; i++)
    if (e.data.u8[i] == capability) return 1;
  return 0;
}

int ircam_pick_stream(const ACameraMetadata *chars, int32_t want_format, int32_t want_w,
                      int32_t want_h, int64_t max_pixels, double aspect, IRCamStream *out) {
  /* Preference order when the caller does not care: a JPEG the HAL encodes for
   * us, else YUV we can convert ourselves, else 16-bit RAW. */
  static const int32_t prefer[] = {AIMAGE_FORMAT_JPEG, AIMAGE_FORMAT_YUV_420_888,
                                   AIMAGE_FORMAT_RAW16};
  ACameraMetadata_const_entry e;
  if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS, &e) !=
      ACAMERA_OK)
    return -1;

  const int32_t single[1] = {want_format};
  const int32_t *list = want_format ? single : prefer;
  const int nlist = want_format ? 1 : (int)(sizeof prefer / sizeof prefer[0]);

  /* Pass 0 honours the requested shape; pass 1 is the fallback that ignores it. */
  for (int pass = (aspect > 0.0 ? 0 : 1); pass <= 1; pass++) {
    for (int p = 0; p < nlist; p++) {
      IRCamStream best = {0, 0, 0};
      for (uint32_t i = 0; i + 3 < e.count; i += 4) {
        const int32_t fmt = e.data.i32[i], w = e.data.i32[i + 1], h = e.data.i32[i + 2];
        if (e.data.i32[i + 3] == ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS_INPUT) continue;
        if (fmt != list[p]) continue;
        if (want_w && want_h && (w != want_w || h != want_h)) continue;
        if (max_pixels && (int64_t)w * h > max_pixels) continue;
        if (pass == 0 && h > 0) {
          const double r = (double)w / (double)h;
          if (r < aspect * 0.98 || r > aspect * 1.02) continue;
        }
        if ((int64_t)w * h > (int64_t)best.width * best.height) {
          best.format = fmt;
          best.width = w;
          best.height = h;
        }
      }
      if (best.width) {
        *out = best;
        return 0;
      }
    }
  }
  return -1;
}
