/*
 * ircam-shot -- open one camera by Camera2 id and save a frame.
 *
 * Written for the OnePlus 8 Pro's colour-filter ("photochrom") camera, which is
 * camera id 4. That camera does not advertise BACKWARD_COMPATIBLE, so Ubuntu
 * Touch's normal camera stack (QtMultimedia -> libhybris Camera API1) cannot
 * open it at all. Camera2 can, and this program is the smallest thing that
 * proves it end to end: open, configure a stream, pull frames, write a file.
 *
 * Nothing here is specific to camera 4 -- pass any id.
 */
#define _GNU_SOURCE
#include "camutil.h"
#include "hybris_ndk.h"
#include "imgwrite.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* ---------------------------------------------------------------- state --- */

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_device_error = 0;      /* non-zero: HAL reported the device failed */
static int g_disconnected = 0;
static int g_capture_failed = 0;
static int g_frames_started = 0;
static int g_frames_completed = 0;

static const char *device_error_name(int err) {
  switch (err) {
    case ERROR_CAMERA_IN_USE: return "ERROR_CAMERA_IN_USE";
    case ERROR_MAX_CAMERAS_IN_USE: return "ERROR_MAX_CAMERAS_IN_USE";
    case ERROR_CAMERA_DISABLED: return "ERROR_CAMERA_DISABLED";
    case ERROR_CAMERA_DEVICE: return "ERROR_CAMERA_DEVICE";
    case ERROR_CAMERA_SERVICE: return "ERROR_CAMERA_SERVICE";
    default: return "(unknown device error)";
  }
}

static void on_watchdog(int sig) {
  (void)sig;
  static const char msg[] =
      "WATCHDOG: still stuck after the deadline -- the camera HAL never returned "
      "control. Exiting hard; see the lines above for how far it got.\n";
  ssize_t ignored = write(2, msg, sizeof msg - 1);
  (void)ignored;
  _exit(3);
}

static void on_disconnected(void *ctx, ACameraDevice *dev) {
  (void)ctx; (void)dev;
  pthread_mutex_lock(&g_lock);
  g_disconnected = 1;
  pthread_mutex_unlock(&g_lock);
  fprintf(stderr, "[cb] camera disconnected\n");
}

static void on_error(void *ctx, ACameraDevice *dev, int error) {
  (void)ctx; (void)dev;
  pthread_mutex_lock(&g_lock);
  g_device_error = error;
  pthread_mutex_unlock(&g_lock);
  fprintf(stderr, "[cb] camera device error %d (%s)\n", error, device_error_name(error));
}

static void on_session_closed(void *c, ACameraCaptureSession *s) { (void)c; (void)s; }
static void on_session_ready(void *c, ACameraCaptureSession *s) { (void)c; (void)s; }
static void on_session_active(void *c, ACameraCaptureSession *s) { (void)c; (void)s; }

static void on_capture_started(void *c, ACameraCaptureSession *s, const ACaptureRequest *r,
                               int64_t ts) {
  (void)c; (void)s; (void)r; (void)ts;
  pthread_mutex_lock(&g_lock);
  g_frames_started++;
  pthread_mutex_unlock(&g_lock);
}

static void on_capture_progressed(void *c, ACameraCaptureSession *s, ACaptureRequest *r,
                                  const ACameraMetadata *result) {
  (void)c; (void)s; (void)r; (void)result;
}

static void on_capture_completed(void *c, ACameraCaptureSession *s, ACaptureRequest *r,
                                 const ACameraMetadata *result) {
  (void)c; (void)s; (void)r; (void)result;
  pthread_mutex_lock(&g_lock);
  g_frames_completed++;
  pthread_mutex_unlock(&g_lock);
}

static void on_capture_failed(void *c, ACameraCaptureSession *s, ACaptureRequest *r,
                              ACameraCaptureFailure *f) {
  (void)c; (void)s; (void)r;
  pthread_mutex_lock(&g_lock);
  g_capture_failed++;
  pthread_mutex_unlock(&g_lock);
  fprintf(stderr, "[cb] capture FAILED (frame %ld, reason %d, wasImageCaptured=%d)\n",
          f ? (long)f->frameNumber : -1L, f ? f->reason : -1, f ? f->wasImageCaptured : -1);
}

static void on_sequence_completed(void *c, ACameraCaptureSession *s, int id, int64_t f) {
  (void)c; (void)s; (void)id; (void)f;
}
static void on_sequence_aborted(void *c, ACameraCaptureSession *s, int id) {
  (void)c; (void)s;
  fprintf(stderr, "[cb] capture sequence %d ABORTED\n", id);
}
static void on_buffer_lost(void *c, ACameraCaptureSession *s, ACaptureRequest *r,
                           ANativeWindow *w, int64_t f) {
  (void)c; (void)s; (void)r; (void)w;
  fprintf(stderr, "[cb] buffer lost on frame %lld\n", (long long)f);
}

/* ------------------------------------------------------------- metadata --- */

static int meta_i32(const ACameraMetadata *m, uint32_t tag, const int32_t **out, uint32_t *count) {
  ACameraMetadata_const_entry e;
  if (h_ACameraMetadata_getConstEntry(m, tag, &e) != ACAMERA_OK) return -1;
  *out = e.data.i32;
  *count = e.count;
  return 0;
}

static const char *facing_name(uint8_t v) {
  switch (v) {
    case ACAMERA_LENS_FACING_FRONT: return "FRONT";
    case ACAMERA_LENS_FACING_BACK: return "BACK";
    case ACAMERA_LENS_FACING_EXTERNAL: return "EXTERNAL";
    default: return "?";
  }
}

static const char *capability_name(uint8_t v) {
  switch (v) {
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE: return "BACKWARD_COMPATIBLE";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR: return "MANUAL_SENSOR";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING:
      return "MANUAL_POST_PROCESSING";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_RAW: return "RAW";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_READ_SENSOR_SETTINGS:
      return "READ_SENSOR_SETTINGS";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_BURST_CAPTURE: return "BURST_CAPTURE";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT: return "DEPTH_OUTPUT";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_MOTION_TRACKING: return "MOTION_TRACKING";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA:
      return "LOGICAL_MULTI_CAMERA";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_MONOCHROME: return "MONOCHROME";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_SECURE_IMAGE_DATA: return "SECURE_IMAGE_DATA";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_SYSTEM_CAMERA: return "SYSTEM_CAMERA";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_STREAM_USE_CASE: return "STREAM_USE_CASE";
    case ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_ULTRA_HIGH_RESOLUTION_SENSOR:
      return "ULTRA_HIGH_RESOLUTION_SENSOR";
    default: return "(other)";
  }
}

/* The colour filter array tells a colour sensor from a mono or near-infrared
 * one, so it is the single most telling field when hunting an IR camera. */
static const char *cfa_name(uint8_t v) {
  switch (v) {
    case ACAMERA_SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_RGGB: return "RGGB";
    case ACAMERA_SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GRBG: return "GRBG";
    case ACAMERA_SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GBRG: return "GBRG";
    case ACAMERA_SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_BGGR: return "BGGR";
    case ACAMERA_SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_RGB: return "RGB";
    case ACAMERA_SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_MONO: return "MONO";
    case ACAMERA_SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_NIR: return "NIR";
    default: return "?";
  }
}

static void describe_camera(ACameraManager *mgr, const char *id) {
  ACameraMetadata *m = NULL;
  printf("======================================================================\n");
  camera_status_t s = h_ACameraManager_getCameraCharacteristics(mgr, id, &m);
  if (s != ACAMERA_OK) {
    printf("camera %-3s  getCameraCharacteristics FAILED: %s\n", id, camera_status_name(s));
    return;
  }
  printf("camera id %s\n", id);

  ACameraMetadata_const_entry e;
  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_LENS_FACING, &e) == ACAMERA_OK)
    printf("  %-32s %s\n", "LENS_FACING", facing_name(e.data.u8[0]));

  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_REQUEST_AVAILABLE_CAPABILITIES, &e) ==
      ACAMERA_OK) {
    printf("  %-32s ", "REQUEST_AVAILABLE_CAPABILITIES");
    for (uint32_t i = 0; i < e.count; i++)
      printf("%s%s", i ? ", " : "", capability_name(e.data.u8[i]));
    printf("\n");
    int bc = 0;
    for (uint32_t i = 0; i < e.count; i++)
      if (e.data.u8[i] == ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE) bc = 1;
    if (!bc)
      printf("  %-32s no BACKWARD_COMPATIBLE -> unreachable from Camera API1,\n"
             "  %-32s i.e. invisible to the stock Ubuntu Touch camera app\n",
             "", "");
  }

  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_SENSOR_INFO_COLOR_FILTER_ARRANGEMENT, &e) ==
      ACAMERA_OK)
    printf("  %-32s %s\n", "SENSOR_INFO_COLOR_FILTER_ARRANGEMENT", cfa_name(e.data.u8[0]));
  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_SENSOR_INFO_PHYSICAL_SIZE, &e) == ACAMERA_OK)
    printf("  %-32s %g x %g mm\n", "SENSOR_INFO_PHYSICAL_SIZE", e.data.f[0], e.data.f[1]);
  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_SENSOR_INFO_PIXEL_ARRAY_SIZE, &e) == ACAMERA_OK)
    printf("  %-32s %d x %d\n", "SENSOR_INFO_PIXEL_ARRAY_SIZE", e.data.i32[0], e.data.i32[1]);
  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_SENSOR_INFO_SENSITIVITY_RANGE, &e) == ACAMERA_OK)
    printf("  %-32s ISO %d - %d\n", "SENSOR_INFO_SENSITIVITY_RANGE", e.data.i32[0],
           e.data.i32[1]);
  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_SENSOR_INFO_EXPOSURE_TIME_RANGE, &e) ==
      ACAMERA_OK)
    printf("  %-32s %.1f us - %.1f ms\n", "SENSOR_INFO_EXPOSURE_TIME_RANGE",
           e.data.i64[0] / 1e3, e.data.i64[1] / 1e6);
  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_LENS_INFO_AVAILABLE_FOCAL_LENGTHS, &e) ==
      ACAMERA_OK) {
    printf("  %-32s ", "LENS_INFO_AVAILABLE_FOCAL_LENGTHS");
    for (uint32_t i = 0; i < e.count; i++) printf("%s%g mm", i ? ", " : "", e.data.f[i]);
    printf("\n");
  }
  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_LENS_INFO_AVAILABLE_APERTURES, &e) == ACAMERA_OK)
    printf("  %-32s f/%g\n", "LENS_INFO_AVAILABLE_APERTURES", e.data.f[0]);
  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_FLASH_INFO_AVAILABLE, &e) == ACAMERA_OK)
    printf("  %-32s %s\n", "FLASH_INFO_AVAILABLE", e.data.u8[0] ? "yes" : "no");
  if (h_ACameraMetadata_getConstEntry(m, ACAMERA_SENSOR_ORIENTATION, &e) == ACAMERA_OK)
    printf("  %-32s %d degrees\n", "SENSOR_ORIENTATION", e.data.i32[0]);

  size_t npc = 0;
  const char *const *phys = NULL;
  if (h_ACameraMetadata_isLogicalMultiCamera(m, &npc, &phys)) {
    printf("  %-32s yes -> physical ids", "LOGICAL_MULTI_CAMERA");
    for (size_t i = 0; i < npc; i++) printf(" %s", phys[i]);
    printf("\n");
  }

  /* Output sizes, largest first, grouped by format. */
  const int32_t *cfg;
  uint32_t n;
  if (meta_i32(m, ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS, &cfg, &n) == 0) {
    static const int32_t shown[] = {AIMAGE_FORMAT_JPEG, AIMAGE_FORMAT_YUV_420_888,
                                    AIMAGE_FORMAT_RAW16, AIMAGE_FORMAT_RAW10,
                                    AIMAGE_FORMAT_PRIVATE};
    printf("  output sizes:\n");
    for (size_t k = 0; k < sizeof shown / sizeof shown[0]; k++) {
      int32_t bw = 0, bh = 0, count = 0;
      for (uint32_t i = 0; i + 3 < n; i += 4) {
        if (cfg[i] != shown[k]) continue;
        if (cfg[i + 3] == ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS_INPUT) continue;
        count++;
        if ((int64_t)cfg[i + 1] * cfg[i + 2] > (int64_t)bw * bh) {
          bw = cfg[i + 1];
          bh = cfg[i + 2];
        }
      }
      if (count)
        printf("    %-22s largest %dx%d  (%d size%s offered)\n", ircam_format_name(shown[k]), bw, bh,
               count, count == 1 ? "" : "s");
    }
  }
  h_ACameraMetadata_free(m);
}

/* ---------------------------------------------------------------- saving -- */

static uint8_t clamp8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : (uint8_t)v); }

/* YUV_420_888 -> RGB. Android hands these out as full-range JFIF YCbCr, which
 * is what the coefficients below assume. */
static uint8_t *yuv420_to_rgb(AImage *img, int w, int h) {
  uint8_t *yp, *up, *vp;
  int yl, ul, vl, yrs, urs, vrs, ups, vps;
  if (h_AImage_getPlaneData(img, 0, &yp, &yl) != AMEDIA_OK ||
      h_AImage_getPlaneData(img, 1, &up, &ul) != AMEDIA_OK ||
      h_AImage_getPlaneData(img, 2, &vp, &vl) != AMEDIA_OK)
    return NULL;
  if (h_AImage_getPlaneRowStride(img, 0, &yrs) != AMEDIA_OK ||
      h_AImage_getPlaneRowStride(img, 1, &urs) != AMEDIA_OK ||
      h_AImage_getPlaneRowStride(img, 2, &vrs) != AMEDIA_OK ||
      h_AImage_getPlanePixelStride(img, 1, &ups) != AMEDIA_OK ||
      h_AImage_getPlanePixelStride(img, 2, &vps) != AMEDIA_OK)
    return NULL;

  uint8_t *rgb = malloc((size_t)w * h * 3);
  if (!rgb) return NULL;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      int Y = yp[(size_t)y * yrs + x];
      int U = up[(size_t)(y / 2) * urs + (x / 2) * ups] - 128;
      int V = vp[(size_t)(y / 2) * vrs + (x / 2) * vps] - 128;
      uint8_t *o = rgb + ((size_t)y * w + x) * 3;
      o[0] = clamp8(Y + ((91881 * V) >> 16));
      o[1] = clamp8(Y - ((22554 * U + 46802 * V) >> 16));
      o[2] = clamp8(Y + ((116130 * U) >> 16));
    }
  }
  return rgb;
}

static int save_image(AImage *img, int32_t format, const char *stem, char *pathout,
                      size_t pathlen) {
  int32_t w = 0, h = 0, planes = 0;
  h_AImage_getWidth(img, &w);
  h_AImage_getHeight(img, &h);
  h_AImage_getNumberOfPlanes(img, &planes);
  printf("  frame: %dx%d, format %s, %d plane(s)\n", w, h, ircam_format_name(format), planes);

  if (format == AIMAGE_FORMAT_JPEG) {
    uint8_t *data;
    int len;
    if (h_AImage_getPlaneData(img, 0, &data, &len) != AMEDIA_OK || len <= 4) return -1;
    /* Sanity-check that the HAL really gave us a JPEG, not an empty buffer. */
    if (!(data[0] == 0xFF && data[1] == 0xD8))
      fprintf(stderr, "  warning: buffer does not start with a JPEG SOI marker\n");
    snprintf(pathout, pathlen, "%s.jpg", stem);
    FILE *f = fopen(pathout, "wb");
    if (!f) return -1;
    int ok = fwrite(data, 1, (size_t)len, f) == (size_t)len;
    fclose(f);
    printf("  jpeg payload: %d bytes\n", len);
    return ok ? 0 : -1;
  }

  if (format == AIMAGE_FORMAT_YUV_420_888) {
    uint8_t *rgb = yuv420_to_rgb(img, w, h);
    if (!rgb) return -1;
    snprintf(pathout, pathlen, "%s.png", stem);
    int rc = png_write_rgb8(pathout, rgb, w, h);
    free(rgb);
    return rc;
  }

  if (format == AIMAGE_FORMAT_RAW16) {
    uint8_t *data;
    int len;
    int rs = 0;
    if (h_AImage_getPlaneData(img, 0, &data, &len) != AMEDIA_OK) return -1;
    h_AImage_getPlaneRowStride(img, 0, &rs);
    uint16_t *g = malloc((size_t)w * h * 2);
    if (!g) return -1;
    for (int y = 0; y < h; y++)
      memcpy(g + (size_t)y * w, data + (size_t)y * rs, (size_t)w * 2);
    snprintf(pathout, pathlen, "%s.pgm", stem);
    int rc = pgm_write_gray16(pathout, g, w, h);
    free(g);
    return rc;
  }

  /* Anything else: write the bytes verbatim rather than pretend to decode. */
  uint8_t *data;
  int len;
  if (h_AImage_getPlaneData(img, 0, &data, &len) != AMEDIA_OK) return -1;
  snprintf(pathout, pathlen, "%s.bin", stem);
  FILE *f = fopen(pathout, "wb");
  if (!f) return -1;
  int ok = fwrite(data, 1, (size_t)len, f) == (size_t)len;
  fclose(f);
  return ok ? 0 : -1;
}

/* ------------------------------------------------------------------ main -- */

static void usage(void) {
  fprintf(stderr,
          "usage: ircam-shot [options]\n"
          "  --id N            camera id to open (default 4, the colour-filter camera)\n"
          "  --out DIR         output directory (default $HOME/Pictures)\n"
          "  --format F        jpeg | yuv | raw16   (default: best available)\n"
          "  --size WxH        force an output size\n"
          "  --frames N        discard N-1 frames, keep the Nth (default 8)\n"
          "  --timeout S       seconds to wait for frames (default 15)\n"
          "  --iso N           manual sensitivity\n"
          "  --exposure-ms M   manual exposure time in milliseconds\n"
          "  --auto            do not force manual exposure even without 3A\n"
          "  --list            print full characteristics for every camera and exit\n");
}

int main(int argc, char **argv) {
  const char *cam_id = "4";
  const char *outdir = NULL;
  int32_t want_format = 0, want_w = 0, want_h = 0;
  int frames = 8, timeout_s = 15, iso = 0, list_only = 0, force_auto = 0;
  double exposure_ms = 0;

  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    int last = (i + 1 >= argc);
    if (!strcmp(a, "--list")) list_only = 1;
    else if (!strcmp(a, "--auto")) force_auto = 1;
    else if (!strcmp(a, "--id") && !last) cam_id = argv[++i];
    else if (!strcmp(a, "--out") && !last) outdir = argv[++i];
    else if (!strcmp(a, "--frames") && !last) frames = atoi(argv[++i]);
    else if (!strcmp(a, "--timeout") && !last) timeout_s = atoi(argv[++i]);
    else if (!strcmp(a, "--iso") && !last) iso = atoi(argv[++i]);
    else if (!strcmp(a, "--exposure-ms") && !last) exposure_ms = atof(argv[++i]);
    else if (!strcmp(a, "--size") && !last) sscanf(argv[++i], "%dx%d", &want_w, &want_h);
    else if (!strcmp(a, "--format") && !last) {
      const char *f = argv[++i];
      if (!strcmp(f, "jpeg")) want_format = AIMAGE_FORMAT_JPEG;
      else if (!strcmp(f, "yuv")) want_format = AIMAGE_FORMAT_YUV_420_888;
      else if (!strcmp(f, "raw16")) want_format = AIMAGE_FORMAT_RAW16;
      else { usage(); return 2; }
    } else { usage(); return 2; }
  }
  if (frames < 1) frames = 1;

  /* Progress must survive a kill: when the HAL stalls, the interesting part of
   * the story is everything printed before the stall. */
  setvbuf(stdout, NULL, _IOLBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);

  /* Watchdog. ACameraCaptureSession_stopRepeating and ACameraDevice_close can
   * block forever if the HAL never returned a buffer, so bound the whole run. */
  signal(SIGALRM, on_watchdog);
  alarm((unsigned)(timeout_s + 30));

  char err[512];
  if (hybris_ndk_init(err, sizeof err) != 0) {
    fprintf(stderr, "cannot reach Android's camera libraries: %s\n", err);
    return 1;
  }
  printf("libhybris: libcamera2ndk.so, libmediandk.so, libbinder_ndk.so loaded; all symbols bound\n");

  /* Must happen before any camera call: CameraService calls back into this
   * process to drive the buffer queue, and without listener threads those
   * transactions are never answered. */
  h_ABinderProcess_setThreadPoolMaxThreadCount(4);
  h_ABinderProcess_startThreadPool();
  printf("binder threadpool started: %s\n",
         h_ABinderProcess_isThreadPoolStarted() ? "yes" : "NO");

  ACameraManager *mgr = h_ACameraManager_create();
  if (!mgr) {
    fprintf(stderr, "ACameraManager_create() failed\n");
    return 1;
  }

  ACameraIdList *ids = NULL;
  camera_status_t cs = h_ACameraManager_getCameraIdList(mgr, &ids);
  if (cs != ACAMERA_OK) {
    fprintf(stderr, "getCameraIdList: %s\n", camera_status_name(cs));
    return 1;
  }
  printf("cameras visible to Camera2: %d ->", ids->numCameras);
  for (int i = 0; i < ids->numCameras; i++) printf(" %s", ids->cameraIds[i]);
  printf("\n");
  if (list_only) {
    for (int i = 0; i < ids->numCameras; i++) describe_camera(mgr, ids->cameraIds[i]);
    h_ACameraManager_deleteCameraIdList(ids);
    h_ACameraManager_delete(mgr);
    return 0;
  }

  ACameraMetadata *chars = NULL;
  cs = h_ACameraManager_getCameraCharacteristics(mgr, cam_id, &chars);
  if (cs != ACAMERA_OK) {
    fprintf(stderr, "getCameraCharacteristics(%s): %s\n", cam_id, camera_status_name(cs));
    return 1;
  }
  int backward_compatible =
      ircam_has_capability(chars, ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE);
  int manual_sensor = ircam_has_capability(chars, ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR);
  printf("camera %s: BACKWARD_COMPATIBLE=%s MANUAL_SENSOR=%s\n", cam_id,
         backward_compatible ? "yes" : "NO", manual_sensor ? "yes" : "no");

  IRCamStream ch;
  if (ircam_pick_stream(chars, want_format, want_w, want_h, 0, 0.0, &ch) != 0) {
    fprintf(stderr, "no usable output stream found\n");
    return 1;
  }
  printf("chosen stream: %s %dx%d\n", ircam_format_name(ch.format), ch.width, ch.height);

  /* Reader first: the camera needs a surface to configure a session against. */
  AImageReader *reader = NULL;
  media_status_t ms = h_AImageReader_new(ch.width, ch.height, ch.format, 4, &reader);
  if (ms != AMEDIA_OK) {
    fprintf(stderr, "AImageReader_new: %s\n", media_status_name(ms));
    return 1;
  }
  ANativeWindow *window = NULL;
  ms = h_AImageReader_getWindow(reader, &window);
  if (ms != AMEDIA_OK) {
    fprintf(stderr, "AImageReader_getWindow: %s\n", media_status_name(ms));
    return 1;
  }
  printf("AImageReader ready (window %p)\n", (void *)window);

  ACameraDevice_StateCallbacks dev_cb = {NULL, on_disconnected, on_error};
  ACameraDevice *dev = NULL;
  printf("opening camera %s ...\n", cam_id);
  cs = h_ACameraManager_openCamera(mgr, cam_id, &dev_cb, &dev);
  if (cs != ACAMERA_OK) {
    fprintf(stderr, "ACameraManager_openCamera(%s): %s\n", cam_id, camera_status_name(cs));
    return 1;
  }
  printf("OPENED camera %s (device id reported as \"%s\")\n", cam_id, h_ACameraDevice_getId(dev));

  ACaptureSessionOutputContainer *outputs = NULL;
  ACaptureSessionOutput *output = NULL;
  h_ACaptureSessionOutputContainer_create(&outputs);
  cs = h_ACaptureSessionOutput_create(window, &output);
  if (cs != ACAMERA_OK) {
    fprintf(stderr, "ACaptureSessionOutput_create: %s\n", camera_status_name(cs));
    return 1;
  }
  h_ACaptureSessionOutputContainer_add(outputs, output);

  ACameraCaptureSession_stateCallbacks sess_cb = {NULL, on_session_closed, on_session_ready,
                                                  on_session_active};
  ACameraCaptureSession *session = NULL;
  cs = h_ACameraDevice_createCaptureSession(dev, outputs, &sess_cb, &session);
  if (cs != ACAMERA_OK) {
    fprintf(stderr, "createCaptureSession: %s\n", camera_status_name(cs));
    return 1;
  }
  printf("capture session created\n");

  /* Which request templates does this camera accept? On a camera without
   * BACKWARD_COMPATIBLE the usual ones can be rejected, so report all of them
   * rather than assume, and use the first that works. */
  static const struct {
    ACameraDevice_request_template t;
    const char *name;
  } templates[] = {{TEMPLATE_STILL_CAPTURE, "STILL_CAPTURE"}, {TEMPLATE_PREVIEW, "PREVIEW"},
                   {TEMPLATE_MANUAL, "MANUAL"},               {TEMPLATE_RECORD, "RECORD"},
                   {TEMPLATE_ZERO_SHUTTER_LAG, "ZERO_SHUTTER_LAG"},
                   {TEMPLATE_VIDEO_SNAPSHOT, "VIDEO_SNAPSHOT"}};
  ACaptureRequest *request = NULL;
  const char *used_template = NULL;
  for (size_t i = 0; i < sizeof templates / sizeof templates[0]; i++) {
    ACaptureRequest *r = NULL;
    camera_status_t s = h_ACameraDevice_createCaptureRequest(dev, templates[i].t, &r);
    printf("  template %-17s : %s\n", templates[i].name, camera_status_name(s));
    if (s == ACAMERA_OK && !request) {
      request = r;
      used_template = templates[i].name;
    } else if (s == ACAMERA_OK) {
      h_ACaptureRequest_free(r);
    }
  }
  if (!request) {
    fprintf(stderr, "no request template accepted by this camera\n");
    return 1;
  }
  printf("using template %s\n", used_template);

  ACameraOutputTarget *target = NULL;
  cs = h_ACameraOutputTarget_create(window, &target);
  if (cs != ACAMERA_OK) {
    fprintf(stderr, "ACameraOutputTarget_create: %s\n", camera_status_name(cs));
    return 1;
  }
  h_ACaptureRequest_addTarget(request, target);

  /* Without BACKWARD_COMPATIBLE there is no auto-exposure to lean on, so drive
   * the sensor by hand unless told otherwise. */
  int manual = (!backward_compatible && manual_sensor && !force_auto) || iso || exposure_ms > 0;
  if (manual && manual_sensor) {
    ACameraMetadata_const_entry e;
    int64_t exp_ns = exposure_ms > 0 ? (int64_t)(exposure_ms * 1e6) : 20000000; /* 20 ms */
    int32_t sens = iso ? iso : 400;
    if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_SENSOR_INFO_EXPOSURE_TIME_RANGE, &e) ==
        ACAMERA_OK) {
      if (exp_ns < e.data.i64[0]) exp_ns = e.data.i64[0];
      if (exp_ns > e.data.i64[1]) exp_ns = e.data.i64[1];
    }
    if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_SENSOR_INFO_SENSITIVITY_RANGE, &e) ==
        ACAMERA_OK) {
      if (sens < e.data.i32[0]) sens = e.data.i32[0];
      if (sens > e.data.i32[1]) sens = e.data.i32[1];
    }
    uint8_t off = ACAMERA_CONTROL_MODE_OFF;
    uint8_t ae_off = ACAMERA_CONTROL_AE_MODE_OFF;
    h_ACaptureRequest_setEntry_u8(request, ACAMERA_CONTROL_MODE, 1, &off);
    h_ACaptureRequest_setEntry_u8(request, ACAMERA_CONTROL_AE_MODE, 1, &ae_off);
    h_ACaptureRequest_setEntry_i64(request, ACAMERA_SENSOR_EXPOSURE_TIME, 1, &exp_ns);
    h_ACaptureRequest_setEntry_i32(request, ACAMERA_SENSOR_SENSITIVITY, 1, &sens);
    printf("manual exposure: %.1f ms @ ISO %d\n", exp_ns / 1e6, sens);
  }

  ACameraCaptureSession_captureCallbacks cap_cb = {
      NULL, on_capture_started, on_capture_progressed, on_capture_completed,
      on_capture_failed, on_sequence_completed, on_sequence_aborted, on_buffer_lost};

  int seq = 0;
  cs = h_ACameraCaptureSession_setRepeatingRequest(session, &cap_cb, 1, &request, &seq);
  if (cs != ACAMERA_OK) {
    fprintf(stderr, "setRepeatingRequest: %s\n", camera_status_name(cs));
    return 1;
  }
  printf("streaming; waiting for %d frame(s)...\n", frames);

  /* Poll rather than use an image-available callback: fewer moving parts, and
   * the reader queues frames for us regardless. */
  AImage *keep = NULL;
  int got = 0;
  struct timespec t0, t_first = {0, 0};
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (;;) {
    AImage *img = NULL;
    ms = h_AImageReader_acquireNextImage(reader, &img);
    if (ms == AMEDIA_OK && img) {
      got++;
      if (got == 1) clock_gettime(CLOCK_MONOTONIC, &t_first);
      if (got >= frames) {
        keep = img;
        break;
      }
      h_AImage_delete(img);
      continue;
    }
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
    pthread_mutex_lock(&g_lock);
    int derr = g_device_error, disc = g_disconnected, cfail = g_capture_failed;
    int started = g_frames_started, completed = g_frames_completed;
    pthread_mutex_unlock(&g_lock);
    if (derr || disc) {
      fprintf(stderr, "aborting: device %s\n", disc ? "disconnected" : "reported an error");
      break;
    }
    if (elapsed > timeout_s) {
      fprintf(stderr,
              "timed out after %.0f s: %d image(s) delivered, %d capture(s) started, "
              "%d completed, %d failed\n",
              elapsed, got, started, completed, cfail);
      break;
    }
    usleep(20000);
  }

  int rc = 1;
  if (keep) {
    struct timespec t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_end);
    double to_first = (t_first.tv_sec - t0.tv_sec) + (t_first.tv_nsec - t0.tv_nsec) / 1e9;
    double streaming = (t_end.tv_sec - t_first.tv_sec) + (t_end.tv_nsec - t_first.tv_nsec) / 1e9;
    pthread_mutex_lock(&g_lock);
    printf("got frame %d of %d (captures started %d, completed %d, failed %d)\n", got, frames,
           g_frames_started, g_frames_completed, g_capture_failed);
    pthread_mutex_unlock(&g_lock);
    printf("timing: %.2f s to first frame, then %d frame(s) in %.2f s = %.1f fps\n", to_first,
           got - 1, streaming, got > 1 ? (got - 1) / streaming : 0.0);

    char dir[512];
    if (outdir) snprintf(dir, sizeof dir, "%s", outdir);
    else {
      const char *home = getenv("HOME");
      snprintf(dir, sizeof dir, "%s/Pictures", home ? home : ".");
    }
    if (mkdir(dir, 0755) != 0 && errno != EEXIST)
      fprintf(stderr, "warning: cannot create %s: %s\n", dir, strerror(errno));

    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char stem[640];
    snprintf(stem, sizeof stem, "%s/ircam-cam%s-%04d%02d%02d-%02d%02d%02d", dir, cam_id,
             tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);

    char path[768];
    if (save_image(keep, ch.format, stem, path, sizeof path) == 0) {
      printf("SAVED %s\n", path);
      rc = 0;
    } else {
      fprintf(stderr, "failed to write image file\n");
    }
    h_AImage_delete(keep);
  }

  h_ACameraCaptureSession_stopRepeating(session);
  h_ACameraCaptureSession_close(session);
  h_ACaptureRequest_free(request);
  h_ACameraOutputTarget_free(target);
  h_ACaptureSessionOutputContainer_free(outputs);
  h_ACaptureSessionOutput_free(output);
  h_ACameraDevice_close(dev);
  h_AImageReader_delete(reader);
  h_ACameraMetadata_free(chars);
  h_ACameraManager_deleteCameraIdList(ids);
  h_ACameraManager_delete(mgr);
  return rc;
}
