#define _GNU_SOURCE
#include "hybris_ndk.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IRCAM_DEFINE_PTR(ret, name, args) ret (*h_##name) args = NULL;
IRCAM_CAMERA2_SYMBOLS(IRCAM_DEFINE_PTR)
IRCAM_MEDIANDK_SYMBOLS(IRCAM_DEFINE_PTR)
IRCAM_BINDER_SYMBOLS(IRCAM_DEFINE_PTR)
#undef IRCAM_DEFINE_PTR

/* bionic's dlopen flags; they do not have to match glibc's and here they don't
 * need to -- these values are passed straight to Android's linker. */
#define ANDROID_RTLD_NOW 0x00002
#define ANDROID_RTLD_GLOBAL 0x00100

static void *(*android_dlopen)(const char *, int);
static void *(*android_dlsym)(void *, const char *);
static const char *(*android_dlerror)(void);

static void *g_camera2;
static void *g_mediandk;
static void *g_binder;

static int fail(char *buf, size_t len, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, len, fmt, ap);
  va_end(ap);
  return -1;
}

int hybris_ndk_init(char *errbuf, size_t errlen) {
  void *hyb = dlopen("libhybris-common.so.1", RTLD_NOW | RTLD_GLOBAL);
  if (!hyb) return fail(errbuf, errlen, "dlopen(libhybris-common.so.1): %s", dlerror());

  android_dlopen = dlsym(hyb, "android_dlopen");
  android_dlsym = dlsym(hyb, "android_dlsym");
  android_dlerror = dlsym(hyb, "android_dlerror");
  if (!android_dlopen || !android_dlsym)
    return fail(errbuf, errlen, "libhybris has no android_dlopen/android_dlsym");

  const int flags = ANDROID_RTLD_NOW | ANDROID_RTLD_GLOBAL;
  g_camera2 = android_dlopen("libcamera2ndk.so", flags);
  if (!g_camera2) {
    const char *e = android_dlerror ? android_dlerror() : NULL;
    return fail(errbuf, errlen, "android_dlopen(libcamera2ndk.so): %s",
                e ? e : "(no error string)");
  }
  g_mediandk = android_dlopen("libmediandk.so", flags);
  if (!g_mediandk) {
    const char *e = android_dlerror ? android_dlerror() : NULL;
    return fail(errbuf, errlen, "android_dlopen(libmediandk.so): %s", e ? e : "(no error string)");
  }
  g_binder = android_dlopen("libbinder_ndk.so", flags);
  if (!g_binder) {
    const char *e = android_dlerror ? android_dlerror() : NULL;
    return fail(errbuf, errlen, "android_dlopen(libbinder_ndk.so): %s",
                e ? e : "(no error string)");
  }

#define IRCAM_BIND(lib, ret, name, args)                                                          \
  do {                                                                                            \
    void *p = android_dlsym(lib, #name);                                                          \
    if (!p) return fail(errbuf, errlen, "android_dlsym(%s) returned NULL", #name);                \
    h_##name = (ret(*) args)p;                                                                    \
  } while (0);
#define BIND_CAM(ret, name, args) IRCAM_BIND(g_camera2, ret, name, args)
#define BIND_MED(ret, name, args) IRCAM_BIND(g_mediandk, ret, name, args)
#define BIND_BND(ret, name, args) IRCAM_BIND(g_binder, ret, name, args)
  IRCAM_CAMERA2_SYMBOLS(BIND_CAM)
  IRCAM_MEDIANDK_SYMBOLS(BIND_MED)
  IRCAM_BINDER_SYMBOLS(BIND_BND)
#undef BIND_CAM
#undef BIND_MED
#undef BIND_BND
#undef IRCAM_BIND

  return 0;
}

const char *camera_status_name(camera_status_t s) {
  switch (s) {
    case ACAMERA_OK: return "OK";
    case ACAMERA_ERROR_UNKNOWN: return "ERROR_UNKNOWN";
    case ACAMERA_ERROR_INVALID_PARAMETER: return "ERROR_INVALID_PARAMETER";
    case ACAMERA_ERROR_CAMERA_DISCONNECTED: return "ERROR_CAMERA_DISCONNECTED";
    case ACAMERA_ERROR_NOT_ENOUGH_MEMORY: return "ERROR_NOT_ENOUGH_MEMORY";
    case ACAMERA_ERROR_METADATA_NOT_FOUND: return "ERROR_METADATA_NOT_FOUND";
    case ACAMERA_ERROR_CAMERA_DEVICE: return "ERROR_CAMERA_DEVICE";
    case ACAMERA_ERROR_CAMERA_SERVICE: return "ERROR_CAMERA_SERVICE";
    case ACAMERA_ERROR_SESSION_CLOSED: return "ERROR_SESSION_CLOSED";
    case ACAMERA_ERROR_INVALID_OPERATION: return "ERROR_INVALID_OPERATION";
    case ACAMERA_ERROR_STREAM_CONFIGURE_FAIL: return "ERROR_STREAM_CONFIGURE_FAIL";
    case ACAMERA_ERROR_CAMERA_IN_USE: return "ERROR_CAMERA_IN_USE";
    case ACAMERA_ERROR_MAX_CAMERA_IN_USE: return "ERROR_MAX_CAMERA_IN_USE";
    case ACAMERA_ERROR_CAMERA_DISABLED: return "ERROR_CAMERA_DISABLED";
    case ACAMERA_ERROR_PERMISSION_DENIED: return "ERROR_PERMISSION_DENIED";
    case ACAMERA_ERROR_UNSUPPORTED_OPERATION: return "ERROR_UNSUPPORTED_OPERATION";
    default: return "(unknown camera_status_t)";
  }
}

const char *media_status_name(media_status_t s) {
  switch (s) {
    case AMEDIA_OK: return "OK";
    case AMEDIA_ERROR_UNKNOWN: return "ERROR_UNKNOWN";
    case AMEDIA_ERROR_MALFORMED: return "ERROR_MALFORMED";
    case AMEDIA_ERROR_UNSUPPORTED: return "ERROR_UNSUPPORTED";
    case AMEDIA_ERROR_INVALID_OBJECT: return "ERROR_INVALID_OBJECT";
    case AMEDIA_ERROR_INVALID_PARAMETER: return "ERROR_INVALID_PARAMETER";
    case AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE: return "IMGREADER_NO_BUFFER_AVAILABLE";
    case AMEDIA_IMGREADER_MAX_IMAGES_ACQUIRED: return "IMGREADER_MAX_IMAGES_ACQUIRED";
    case AMEDIA_IMGREADER_CANNOT_LOCK_IMAGE: return "IMGREADER_CANNOT_LOCK_IMAGE";
    case AMEDIA_IMGREADER_IMAGE_NOT_LOCKED: return "IMGREADER_IMAGE_NOT_LOCKED";
    default: return "(unknown media_status_t)";
  }
}
