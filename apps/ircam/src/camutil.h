/* Small helpers shared by the command-line tool and the QML plugin, so the two
 * cannot drift apart on how a camera's streams are chosen or named. */
#ifndef IRCAM_CAMUTIL_H
#define IRCAM_CAMUTIL_H

#include "hybris_ndk.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Human name for an AIMAGE_FORMAT_* value. */
const char *ircam_format_name(int32_t format);

/* True if the camera advertises the given ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_* */
int ircam_has_capability(const ACameraMetadata *chars, uint8_t capability);

typedef struct {
  int32_t format, width, height;
} IRCamStream;

/* Choose an output stream from the camera's static metadata.
 *
 *   want_format  0 = pick the most useful available, else an AIMAGE_FORMAT_*
 *   want_w/h     0 = largest available, else that exact size
 *   max_pixels   0 = no cap, else ignore sizes larger than this (used to pick a
 *                preview-sized stream rather than the full sensor)
 *   aspect       0 = any shape, else prefer sizes with this width/height ratio.
 *                A viewfinder must match the stills it takes, and this sensor
 *                offers 2:1 modes that are larger than any 4:3 one under a
 *                pixel cap -- picking by size alone silently crops the preview.
 *                Falls back to ignoring shape if nothing matches.
 *
 * Returns 0 and fills *out on success, -1 if nothing matched. */
int ircam_pick_stream(const ACameraMetadata *chars, int32_t want_format, int32_t want_w,
                      int32_t want_h, int64_t max_pixels, double aspect, IRCamStream *out);

#ifdef __cplusplus
}
#endif
#endif
