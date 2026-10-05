/*
 * hybris_ndk -- reach Android's Camera2 NDK from a normal glibc process.
 *
 * libcamera2ndk.so and libmediandk.so are bionic (Android) libraries, so the
 * glibc dynamic loader cannot open them. libhybris can: it runs Android's own
 * linker inside our process and bridges bionic's libc calls to glibc's. We ask
 * glibc's dlopen for libhybris itself, then use libhybris' android_dlopen /
 * android_dlsym for everything Android.
 *
 * Every Android entry point below is therefore a function POINTER, named with
 * an h_ prefix (h_ACameraManager_create, ...). Signatures come from the AOSP
 * headers in ../ndk, copied from the tree this device's system image was built
 * from, so the layouts match the .so on the device exactly.
 */
#ifndef IRCAM_HYBRIS_NDK_H
#define IRCAM_HYBRIS_NDK_H

#include "../ndk/compat/bionic-shim.h"
#include "camera/NdkCameraManager.h"
#include "camera/NdkCameraDevice.h"
#include "camera/NdkCameraCaptureSession.h"
#include "camera/NdkCaptureRequest.h"
#include "camera/NdkCameraMetadata.h"
#include "media/NdkImageReader.h"
#include "media/NdkImage.h"

/* The two Android libraries we drive, and every symbol taken from each.
 * Listing them here once means a typo becomes a startup error naming the exact
 * symbol, never a silent NULL call. */
#define IRCAM_CAMERA2_SYMBOLS(X)                                                                  \
  X(ACameraManager *, ACameraManager_create, (void))                                              \
  X(void, ACameraManager_delete, (ACameraManager *))                                              \
  X(camera_status_t, ACameraManager_getCameraIdList, (ACameraManager *, ACameraIdList **))        \
  X(void, ACameraManager_deleteCameraIdList, (ACameraIdList *))                                   \
  X(camera_status_t, ACameraManager_getCameraCharacteristics,                                     \
    (ACameraManager *, const char *, ACameraMetadata **))                                         \
  X(camera_status_t, ACameraManager_openCamera,                                                   \
    (ACameraManager *, const char *, ACameraDevice_StateCallbacks *, ACameraDevice **))           \
  X(camera_status_t, ACameraMetadata_getConstEntry,                                               \
    (const ACameraMetadata *, uint32_t, ACameraMetadata_const_entry *))                           \
  X(void, ACameraMetadata_free, (ACameraMetadata *))                                              \
  X(bool, ACameraMetadata_isLogicalMultiCamera,                                                   \
    (const ACameraMetadata *, size_t *, const char *const **))                                    \
  X(camera_status_t, ACameraDevice_close, (ACameraDevice *))                                      \
  X(const char *, ACameraDevice_getId, (const ACameraDevice *))                                   \
  X(camera_status_t, ACameraDevice_createCaptureRequest,                                          \
    (const ACameraDevice *, ACameraDevice_request_template, ACaptureRequest **))                  \
  X(camera_status_t, ACameraDevice_createCaptureSession,                                          \
    (ACameraDevice *, const ACaptureSessionOutputContainer *,                                     \
     const ACameraCaptureSession_stateCallbacks *, ACameraCaptureSession **))                     \
  X(camera_status_t, ACaptureSessionOutputContainer_create, (ACaptureSessionOutputContainer **))  \
  X(void, ACaptureSessionOutputContainer_free, (ACaptureSessionOutputContainer *))                \
  X(camera_status_t, ACaptureSessionOutput_create, (ANativeWindow *, ACaptureSessionOutput **))   \
  X(void, ACaptureSessionOutput_free, (ACaptureSessionOutput *))                                  \
  X(camera_status_t, ACaptureSessionOutputContainer_add,                                          \
    (ACaptureSessionOutputContainer *, const ACaptureSessionOutput *))                            \
  X(camera_status_t, ACameraOutputTarget_create, (ANativeWindow *, ACameraOutputTarget **))       \
  X(void, ACameraOutputTarget_free, (ACameraOutputTarget *))                                      \
  X(camera_status_t, ACaptureRequest_addTarget, (ACaptureRequest *, const ACameraOutputTarget *)) \
  X(camera_status_t, ACaptureRequest_setEntry_u8,                                                 \
    (ACaptureRequest *, uint32_t, uint32_t, const uint8_t *))                                     \
  X(camera_status_t, ACaptureRequest_setEntry_i32,                                                \
    (ACaptureRequest *, uint32_t, uint32_t, const int32_t *))                                     \
  X(camera_status_t, ACaptureRequest_setEntry_i64,                                                \
    (ACaptureRequest *, uint32_t, uint32_t, const int64_t *))                                     \
  X(void, ACaptureRequest_free, (ACaptureRequest *))                                              \
  X(camera_status_t, ACameraCaptureSession_capture,                                               \
    (ACameraCaptureSession *, ACameraCaptureSession_captureCallbacks *, int, ACaptureRequest **,  \
     int *))                                                                                      \
  X(camera_status_t, ACameraCaptureSession_setRepeatingRequest,                                   \
    (ACameraCaptureSession *, ACameraCaptureSession_captureCallbacks *, int, ACaptureRequest **,  \
     int *))                                                                                      \
  X(camera_status_t, ACameraCaptureSession_stopRepeating, (ACameraCaptureSession *))              \
  X(void, ACameraCaptureSession_close, (ACameraCaptureSession *))

#define IRCAM_MEDIANDK_SYMBOLS(X)                                                                 \
  X(media_status_t, AImageReader_new, (int32_t, int32_t, int32_t, int32_t, AImageReader **))      \
  X(void, AImageReader_delete, (AImageReader *))                                                  \
  X(media_status_t, AImageReader_getWindow, (AImageReader *, ANativeWindow **))                   \
  X(media_status_t, AImageReader_setImageListener,                                                \
    (AImageReader *, AImageReader_ImageListener *))                                               \
  X(media_status_t, AImageReader_acquireNextImage, (AImageReader *, AImage **))                   \
  X(void, AImage_delete, (AImage *))                                                              \
  X(media_status_t, AImage_getWidth, (const AImage *, int32_t *))                                 \
  X(media_status_t, AImage_getHeight, (const AImage *, int32_t *))                                \
  X(media_status_t, AImage_getFormat, (const AImage *, int32_t *))                                \
  X(media_status_t, AImage_getTimestamp, (const AImage *, int64_t *))                             \
  X(media_status_t, AImage_getNumberOfPlanes, (const AImage *, int32_t *))                        \
  X(media_status_t, AImage_getPlaneRowStride, (const AImage *, int, int32_t *))                   \
  X(media_status_t, AImage_getPlanePixelStride, (const AImage *, int, int32_t *))                 \
  X(media_status_t, AImage_getPlaneData, (const AImage *, int, uint8_t **, int *))

/* Binder threadpool. CameraService does not just take our calls, it calls BACK
 * into this process: the capture buffers live in a BufferQueue we own, and the
 * service queries it (NATIVE_WINDOW_CONSUMER_USAGE_BITS) and hands buffers to
 * it over binder. A process with no threadpool never answers, which surfaces as
 * "Cannot query consumer endpoint usage!" and a stream that produces no frames.
 * Android apps get this for free from the ART runtime; a standalone native
 * client has to start it, and these are libbinder_ndk's plain-C entry points
 * for exactly that. */
#define IRCAM_BINDER_SYMBOLS(X)                                                                   \
  X(void, ABinderProcess_startThreadPool, (void))                                                 \
  X(bool, ABinderProcess_setThreadPoolMaxThreadCount, (uint32_t))                                 \
  X(bool, ABinderProcess_isThreadPoolStarted, (void))

#define IRCAM_DECLARE_PTR(ret, name, args) extern ret (*h_##name) args;
IRCAM_CAMERA2_SYMBOLS(IRCAM_DECLARE_PTR)
IRCAM_MEDIANDK_SYMBOLS(IRCAM_DECLARE_PTR)
IRCAM_BINDER_SYMBOLS(IRCAM_DECLARE_PTR)
#undef IRCAM_DECLARE_PTR

/* Load libhybris and both Android libraries, then bind every symbol above.
 * Returns 0 on success; on failure returns -1 and fills errbuf. */
int hybris_ndk_init(char *errbuf, size_t errlen);

/* Human-readable names for the two Android status enums. */
const char *camera_status_name(camera_status_t s);
const char *media_status_name(media_status_t s);

#endif /* IRCAM_HYBRIS_NDK_H */
