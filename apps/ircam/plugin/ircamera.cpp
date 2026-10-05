#include "ircamera.h"

extern "C" {
#include "camutil.h"
#include "hybris_ndk.h"
}

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <cmath>
#include <cstring>
#include <unistd.h>

namespace {

/* libhybris and the Android libraries are process-wide; bind them once. */
bool ensureNdk(QString *err) {
  static bool tried = false;
  static bool ok = false;
  static QString message;
  if (!tried) {
    tried = true;
    char buf[512];
    ok = hybris_ndk_init(buf, sizeof buf) == 0;
    message = ok ? QString() : QString::fromUtf8(buf);
    if (ok) {
      /* Without listener threads CameraService cannot call back into us to
       * drive the buffer queue, and streams silently produce no frames. */
      h_ABinderProcess_setThreadPoolMaxThreadCount(4);
      h_ABinderProcess_startThreadPool();
    }
  }
  if (!ok && err) *err = message;
  return ok;
}

inline quint8 clamp8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : quint8(v)); }

/* Mean luma from the Y plane, subsampled — cheap enough to run every frame. */
double meanLuma(AImage *img, int w, int h) {
  quint8 *yp = nullptr;
  int yl = 0, yrs = 0;
  if (h_AImage_getPlaneData(img, 0, &yp, &yl) != AMEDIA_OK || !yp) return -1.0;
  if (h_AImage_getPlaneRowStride(img, 0, &yrs) != AMEDIA_OK || yrs <= 0) return -1.0;
  uint64_t sum = 0;
  int n = 0;
  const int step = 8;
  for (int y = 0; y < h; y += step) {
    const quint8 *row = yp + qsizetype(y) * yrs;
    for (int x = 0; x < w; x += step) {
      sum += row[x];
      ++n;
    }
  }
  return n > 0 ? double(sum) / double(n) : -1.0;
}

/* YUV_420_888 -> RGB888. Android delivers full-range JFIF YCbCr here. */
QImage yuvToImage(AImage *img, int w, int h) {
  quint8 *yp, *up, *vp;
  int yl, ul, vl, yrs, urs, vrs, ups, vps;
  if (h_AImage_getPlaneData(img, 0, &yp, &yl) != AMEDIA_OK ||
      h_AImage_getPlaneData(img, 1, &up, &ul) != AMEDIA_OK ||
      h_AImage_getPlaneData(img, 2, &vp, &vl) != AMEDIA_OK)
    return QImage();
  if (h_AImage_getPlaneRowStride(img, 0, &yrs) != AMEDIA_OK ||
      h_AImage_getPlaneRowStride(img, 1, &urs) != AMEDIA_OK ||
      h_AImage_getPlaneRowStride(img, 2, &vrs) != AMEDIA_OK ||
      h_AImage_getPlanePixelStride(img, 1, &ups) != AMEDIA_OK ||
      h_AImage_getPlanePixelStride(img, 2, &vps) != AMEDIA_OK)
    return QImage();

  QImage out(w, h, QImage::Format_RGB888);
  for (int y = 0; y < h; ++y) {
    uchar *dst = out.scanLine(y);
    const quint8 *yrow = yp + qsizetype(y) * yrs;
    const quint8 *urow = up + qsizetype(y / 2) * urs;
    const quint8 *vrow = vp + qsizetype(y / 2) * vrs;
    for (int x = 0; x < w; ++x) {
      const int Y = yrow[x];
      const int U = urow[(x / 2) * ups] - 128;
      const int V = vrow[(x / 2) * vps] - 128;
      dst[x * 3 + 0] = clamp8(Y + ((91881 * V) >> 16));
      dst[x * 3 + 1] = clamp8(Y - ((22554 * U + 46802 * V) >> 16));
      dst[x * 3 + 2] = clamp8(Y + ((116130 * U) >> 16));
    }
  }
  return out;
}

const char *facingName(quint8 v) {
  switch (v) {
    case ACAMERA_LENS_FACING_FRONT: return "front";
    case ACAMERA_LENS_FACING_BACK: return "back";
    default: return "external";
  }
}

/* Callbacks. The NDK requires non-null function pointers even when we only
 * care about failures, so these are real functions rather than nullptrs. */
struct DeviceState {
  std::atomic<bool> failed{false};
};

void onDisconnected(void *ctx, ACameraDevice *) {
  if (ctx) static_cast<DeviceState *>(ctx)->failed = true;
}
void onError(void *ctx, ACameraDevice *, int err) {
  qWarning("IRCamera: device error %d", err);
  if (ctx) static_cast<DeviceState *>(ctx)->failed = true;
}
void onSessionNoop(void *, ACameraCaptureSession *) {}
void onCapStarted(void *, ACameraCaptureSession *, const ACaptureRequest *, int64_t) {}
void onCapResult(void *, ACameraCaptureSession *, ACaptureRequest *, const ACameraMetadata *) {}
void onCapFailed(void *, ACameraCaptureSession *, ACaptureRequest *, ACameraCaptureFailure *) {}
void onSeqDone(void *, ACameraCaptureSession *, int, int64_t) {}
void onSeqAborted(void *, ACameraCaptureSession *, int) {}
void onBufferLost(void *, ACameraCaptureSession *, ACaptureRequest *, ANativeWindow *, int64_t) {}

}  // namespace

IRCamera::IRCamera(QObject *parent) : QObject(parent) {}

IRCamera::~IRCamera() { stop(); }

void IRCamera::setStatus(const QString &s) {
  if (m_status == s) return;
  m_status = s;
  emit statusChanged();
}

void IRCamera::markSettingsDirty() {
  m_settingsDirty.store(true);
}

void IRCamera::setCameraId(const QString &id) {
  if (m_cameraId == id) return;
  const bool wasActive = m_running.load();
  if (wasActive) stop();
  m_cameraId = id;
  emit cameraIdChanged();
  if (wasActive) start();
}

void IRCamera::setIso(int v) {
  if (m_iso == v) return;
  m_iso = v;
  emit isoChanged();
  if (m_running.load()) markSettingsDirty();
}
void IRCamera::setExposureMs(qreal v) {
  if (qFuzzyCompare(m_exposureMs, v)) return;
  m_exposureMs = v;
  emit exposureMsChanged();
  if (m_running.load()) markSettingsDirty();
}
void IRCamera::setManualExposure(bool v) {
  if (m_manualExposure == v) return;
  m_manualExposure = v;
  emit manualExposureChanged();
  if (m_running.load()) markSettingsDirty();
}

void IRCamera::applySettings() {
  if (!m_running.load()) return;
  markSettingsDirty();
}

void IRCamera::refreshCameras() {
  QString err;
  if (!ensureNdk(&err)) {
    emit errorOccurred(tr("Cannot reach Android's camera libraries: %1").arg(err));
    return;
  }
  ACameraManager *mgr = h_ACameraManager_create();
  if (!mgr) {
    emit errorOccurred(tr("ACameraManager_create() failed"));
    return;
  }
  ACameraIdList *ids = nullptr;
  if (h_ACameraManager_getCameraIdList(mgr, &ids) != ACAMERA_OK || !ids) {
    h_ACameraManager_delete(mgr);
    emit errorOccurred(tr("Could not list cameras"));
    return;
  }

  QVariantList list;
  for (int i = 0; i < ids->numCameras; ++i) {
    const QString id = QString::fromUtf8(ids->cameraIds[i]);
    ACameraMetadata *chars = nullptr;
    if (h_ACameraManager_getCameraCharacteristics(mgr, ids->cameraIds[i], &chars) != ACAMERA_OK)
      continue;

    QVariantMap m;
    m["id"] = id;
    ACameraMetadata_const_entry e;
    if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_LENS_FACING, &e) == ACAMERA_OK)
      m["facing"] = QString::fromUtf8(facingName(e.data.u8[0]));
    if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_LENS_INFO_AVAILABLE_FOCAL_LENGTHS, &e) ==
        ACAMERA_OK)
      m["focalLength"] = double(e.data.f[0]);
    if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_SENSOR_INFO_PIXEL_ARRAY_SIZE, &e) ==
        ACAMERA_OK)
      m["resolution"] = QStringLiteral("%1x%2").arg(e.data.i32[0]).arg(e.data.i32[1]);
    if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_SENSOR_INFO_PHYSICAL_SIZE, &e) ==
        ACAMERA_OK)
      m["sensorWidthMm"] = double(e.data.f[0]);

    const bool bc = ircam_has_capability(
        chars, ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE);
    const bool logical = ircam_has_capability(
        chars, ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA);
    m["backwardCompatible"] = bc;
    m["logicalMultiCamera"] = logical;
    /* The one camera the stock app can never open is the interesting one. */
    m["hiddenFromStockApp"] = !bc && !logical;
    h_ACameraMetadata_free(chars);
    list.append(m);
  }
  h_ACameraManager_deleteCameraIdList(ids);
  h_ACameraManager_delete(mgr);
  m_cameras = list;
  emit camerasChanged();
}

void IRCamera::start() {
  if (m_running.load()) return;
  QString err;
  if (!ensureNdk(&err)) {
    emit errorOccurred(tr("Cannot reach Android's camera libraries: %1").arg(err));
    return;
  }
  m_stopRequested = false;
  m_settingsDirty = false;
  m_running = true;
  emit activeChanged();
  m_thread = std::thread([this] { threadMain(); });
}

void IRCamera::stop() {
  if (!m_running.load() && !m_thread.joinable()) return;
  m_stopRequested = true;
  if (m_thread.joinable()) m_thread.join();
  m_running = false;
  emit activeChanged();
  setStatus(QStringLiteral("stopped"));
}

void IRCamera::capture() {
  if (!m_running.load()) {
    emit errorOccurred(tr("Camera is not running"));
    return;
  }
  m_captureRequested = true;
}

void IRCamera::threadMain() {
  const QByteArray idUtf8 = m_cameraId.toUtf8();
  DeviceState devState;

  ACameraManager *mgr = h_ACameraManager_create();
  if (!mgr) {
    QMetaObject::invokeMethod(this, [this] {
      emit errorOccurred(tr("ACameraManager_create() failed"));
    }, Qt::QueuedConnection);
    m_running = false;
    return;
  }

  ACameraMetadata *chars = nullptr;
  if (h_ACameraManager_getCameraCharacteristics(mgr, idUtf8.constData(), &chars) != ACAMERA_OK) {
    QMetaObject::invokeMethod(this, [this] {
      emit errorOccurred(tr("Cannot read characteristics for camera %1").arg(m_cameraId));
    }, Qt::QueuedConnection);
    h_ACameraManager_delete(mgr);
    m_running = false;
    return;
  }

  ACameraMetadata_const_entry oe;
  int orientation = 90;
  if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_SENSOR_ORIENTATION, &oe) == ACAMERA_OK)
    orientation = oe.data.i32[0];
  QMetaObject::invokeMethod(this, [this, orientation] {
    if (m_sensorOrientation != orientation) {
      m_sensorOrientation = orientation;
      emit sensorOrientationChanged();
    }
  }, Qt::QueuedConnection);

  const bool backwardCompatible = ircam_has_capability(
      chars, ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE);
  const bool manualSensor =
      ircam_has_capability(chars, ACAMERA_REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR);
  /* Cameras without BACKWARD_COMPATIBLE have no 3A. We always drive exposure
   * ourselves on those (software auto or the user's manual values). */
  const bool noHwAe = !backwardCompatible;

  int64_t expMinNs = 66700;       /* ~66.7 us — camera 4 floor */
  int64_t expMaxNs = 199700000;   /* ~199.7 ms */
  int32_t isoMin = 100, isoMax = 1600;
  ACameraMetadata_const_entry re;
  if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_SENSOR_INFO_EXPOSURE_TIME_RANGE, &re) ==
      ACAMERA_OK) {
    expMinNs = re.data.i64[0];
    expMaxNs = re.data.i64[1];
  }
  if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_SENSOR_INFO_SENSITIVITY_RANGE, &re) ==
      ACAMERA_OK) {
    isoMin = re.data.i32[0];
    isoMax = re.data.i32[1];
  }

  /* The viewfinder must frame what the photo will contain, so the preview is
   * chosen to match the sensor's own shape. Without that, this sensor's 2:1
   * modes win on pixel count under the cap and the preview quietly shows a
   * crop of the still. */
  double aspect = 0.0;
  ACameraMetadata_const_entry pe;
  if (h_ACameraMetadata_getConstEntry(chars, ACAMERA_SENSOR_INFO_PIXEL_ARRAY_SIZE, &pe) ==
          ACAMERA_OK &&
      pe.data.i32[1] > 0)
    aspect = double(pe.data.i32[0]) / double(pe.data.i32[1]);

  /* Preview: YUV, capped near 1.3 MP so the CPU colour conversion keeps up.
   * Still: the largest JPEG the HAL will encode for us, same shape. */
  IRCamStream preview{}, still{};
  const bool havePreview =
      ircam_pick_stream(chars, AIMAGE_FORMAT_YUV_420_888, 0, 0, 1300000, aspect, &preview) == 0;
  const bool haveStill =
      ircam_pick_stream(chars, AIMAGE_FORMAT_JPEG, 0, 0, 0, aspect, &still) == 0;
  if (!havePreview) {
    QMetaObject::invokeMethod(this, [this] {
      emit errorOccurred(tr("Camera %1 offers no usable preview stream").arg(m_cameraId));
    }, Qt::QueuedConnection);
    h_ACameraMetadata_free(chars);
    h_ACameraManager_delete(mgr);
    m_running = false;
    return;
  }

  AImageReader *previewReader = nullptr, *stillReader = nullptr;
  ANativeWindow *previewWindow = nullptr, *stillWindow = nullptr;
  if (h_AImageReader_new(preview.width, preview.height, preview.format, 4, &previewReader) !=
          AMEDIA_OK ||
      h_AImageReader_getWindow(previewReader, &previewWindow) != AMEDIA_OK) {
    QMetaObject::invokeMethod(this, [this] {
      emit errorOccurred(tr("Could not create the preview buffer"));
    }, Qt::QueuedConnection);
    h_ACameraMetadata_free(chars);
    h_ACameraManager_delete(mgr);
    m_running = false;
    return;
  }
  bool stillOk = false;
  if (haveStill && h_AImageReader_new(still.width, still.height, still.format, 2, &stillReader) ==
                       AMEDIA_OK &&
      h_AImageReader_getWindow(stillReader, &stillWindow) == AMEDIA_OK)
    stillOk = true;

  /* The vendor pipeline is not always ready the first time after a boot: the
   * open succeeds and createCaptureSession then fails. Retry rather than treat
   * the first failure as final. */
  ACameraDevice *dev = nullptr;
  ACameraDevice_StateCallbacks devCb{&devState, onDisconnected, onError};
  camera_status_t cs = ACAMERA_ERROR_UNKNOWN;
  /* Two independent reasons a first attempt fails: the vendor pipeline is not
   * ready yet just after boot, and a previous instance of this app may still be
   * releasing the device. Both clear within a couple of seconds. */
  for (int attempt = 0; attempt < 6 && !m_stopRequested.load(); ++attempt) {
    cs = h_ACameraManager_openCamera(mgr, idUtf8.constData(), &devCb, &dev);
    if (cs == ACAMERA_OK) break;
    QMetaObject::invokeMethod(this, [this, cs, attempt] {
      setStatus(tr("opening camera failed (%1), retry %2")
                    .arg(QString::fromUtf8(camera_status_name(cs)))
                    .arg(attempt + 1));
    }, Qt::QueuedConnection);
    usleep(1000000);
  }
  if (cs != ACAMERA_OK) {
    const QString reason = QString::fromUtf8(camera_status_name(cs));
    QMetaObject::invokeMethod(this, [this, reason] {
      emit errorOccurred(tr("Cannot open camera %1: %2").arg(m_cameraId, reason));
    }, Qt::QueuedConnection);
    if (stillReader) h_AImageReader_delete(stillReader);
    h_AImageReader_delete(previewReader);
    h_ACameraMetadata_free(chars);
    h_ACameraManager_delete(mgr);
    m_running = false;
    return;
  }

  ACaptureSessionOutputContainer *outputs = nullptr;
  ACaptureSessionOutput *previewOut = nullptr, *stillOut = nullptr;
  ACameraCaptureSession *session = nullptr;
  ACameraCaptureSession_stateCallbacks sessCb{nullptr, onSessionNoop, onSessionNoop,
                                              onSessionNoop};

  /* Try preview + still; if the vendor rejects that pair, fall back to preview
   * alone rather than failing outright. */
  bool sessionOk = false;
  for (int withStill = stillOk ? 1 : 0; withStill >= 0 && !sessionOk; --withStill) {
    h_ACaptureSessionOutputContainer_create(&outputs);
    h_ACaptureSessionOutput_create(previewWindow, &previewOut);
    h_ACaptureSessionOutputContainer_add(outputs, previewOut);
    if (withStill) {
      h_ACaptureSessionOutput_create(stillWindow, &stillOut);
      h_ACaptureSessionOutputContainer_add(outputs, stillOut);
    }
    for (int attempt = 0; attempt < 3 && !sessionOk && !m_stopRequested.load(); ++attempt) {
      if (h_ACameraDevice_createCaptureSession(dev, outputs, &sessCb, &session) == ACAMERA_OK) {
        sessionOk = true;
        break;
      }
      usleep(700000);
    }
    if (!sessionOk) {
      if (stillOut) {
        h_ACaptureSessionOutput_free(stillOut);
        stillOut = nullptr;
      }
      h_ACaptureSessionOutput_free(previewOut);
      previewOut = nullptr;
      h_ACaptureSessionOutputContainer_free(outputs);
      outputs = nullptr;
      if (withStill) stillOk = false;  // retry without the still stream
    }
  }
  if (!sessionOk) {
    QMetaObject::invokeMethod(this, [this] {
      emit errorOccurred(tr("Could not configure a capture session"));
    }, Qt::QueuedConnection);
    h_ACameraDevice_close(dev);
    if (stillReader) h_AImageReader_delete(stillReader);
    h_AImageReader_delete(previewReader);
    h_ACameraMetadata_free(chars);
    h_ACameraManager_delete(mgr);
    m_running = false;
    return;
  }

  const bool stillAvailable = stillOk;
  QMetaObject::invokeMethod(this, [this, stillAvailable] {
    if (m_stillSupported != stillAvailable) {
      m_stillSupported = stillAvailable;
      emit stillSupportedChanged();
    }
  }, Qt::QueuedConnection);

  /* Build the repeating preview request. */
  ACaptureRequest *previewReq = nullptr;
  if (h_ACameraDevice_createCaptureRequest(dev, TEMPLATE_PREVIEW, &previewReq) != ACAMERA_OK)
    h_ACameraDevice_createCaptureRequest(dev, TEMPLATE_STILL_CAPTURE, &previewReq);
  ACameraOutputTarget *previewTarget = nullptr;
  h_ACameraOutputTarget_create(previewWindow, &previewTarget);
  h_ACaptureRequest_addTarget(previewReq, previewTarget);

  /* Write SENSOR_EXPOSURE_TIME / SENSOR_SENSITIVITY into a request. When the
   * camera has no hardware AE we always do this; otherwise only in manual. */
  auto applyExposure = [&](ACaptureRequest *req) {
    if (!req) return;
    const bool drive = manualSensor && (m_manualExposure || noHwAe);
    if (!drive) return;
    int64_t expNs = int64_t(m_exposureMs * 1e6);
    int32_t sens = m_iso;
    expNs = qBound(expMinNs, expNs, expMaxNs);
    sens = qBound(isoMin, sens, isoMax);
    const uint8_t off = ACAMERA_CONTROL_MODE_OFF;
    const uint8_t aeOff = ACAMERA_CONTROL_AE_MODE_OFF;
    h_ACaptureRequest_setEntry_u8(req, ACAMERA_CONTROL_MODE, 1, &off);
    h_ACaptureRequest_setEntry_u8(req, ACAMERA_CONTROL_AE_MODE, 1, &aeOff);
    h_ACaptureRequest_setEntry_i64(req, ACAMERA_SENSOR_EXPOSURE_TIME, 1, &expNs);
    h_ACaptureRequest_setEntry_i32(req, ACAMERA_SENSOR_SENSITIVITY, 1, &sens);
  };
  applyExposure(previewReq);

  ACameraCaptureSession_captureCallbacks capCb{nullptr,      onCapStarted, onCapResult,
                                               onCapResult,  onCapFailed,  onSeqDone,
                                               onSeqAborted, onBufferLost};

  auto pushRepeating = [&]() -> bool {
    applyExposure(previewReq);
    int seq = 0;
    return h_ACameraCaptureSession_setRepeatingRequest(session, &capCb, 1, &previewReq, &seq) ==
           ACAMERA_OK;
  };

  if (!pushRepeating()) {
    QMetaObject::invokeMethod(this, [this] {
      emit errorOccurred(tr("Could not start the preview stream"));
    }, Qt::QueuedConnection);
  } else {
    QMetaObject::invokeMethod(this, [this, preview] {
      setStatus(tr("streaming %1x%2").arg(preview.width).arg(preview.height));
    }, Qt::QueuedConnection);
  }

  /* Still request, reused for every shutter press. */
  ACaptureRequest *stillReq = nullptr;
  ACameraOutputTarget *stillTarget = nullptr;
  if (stillAvailable) {
    if (h_ACameraDevice_createCaptureRequest(dev, TEMPLATE_STILL_CAPTURE, &stillReq) ==
        ACAMERA_OK) {
      h_ACameraOutputTarget_create(stillWindow, &stillTarget);
      h_ACaptureRequest_addTarget(stillReq, stillTarget);
      applyExposure(stillReq);
    }
  }

  const QString picturesDir =
      QStandardPaths::writableLocation(QStandardPaths::PicturesLocation);
  QDir().mkpath(picturesDir);

  int aeHoldFrames = 0; /* settle after an exposure change before metering again */
  int frameCount = 0;

  while (!m_stopRequested.load() && !devState.failed.load()) {
    AImage *img = nullptr;
    if (h_AImageReader_acquireNextImage(previewReader, &img) == AMEDIA_OK && img) {
      int w = 0, h = 0;
      h_AImage_getWidth(img, &w);
      h_AImage_getHeight(img, &h);
      const double mean = meanLuma(img, w, h);
      QImage frame = yuvToImage(img, w, h);
      h_AImage_delete(img);
      if (!frame.isNull()) {
        emit frameReady(frame);
        ++frameCount;

        if (mean >= 0.0) {
          QMetaObject::invokeMethod(this, [this, mean] {
            if (!qFuzzyCompare(m_meanBrightness, mean)) {
              m_meanBrightness = mean;
              emit meanBrightnessChanged();
            }
          }, Qt::QueuedConnection);
        }

        /* Software auto-exposure: no hardware 3A on this sensor. Meter the
         * preview and nudge exposure/ISO toward a mid-grey target without
         * tearing the session down.
         *
         * Dual-rate: large error → stronger proportional step; near the
         * deadband → gentler step to avoid hunting. Meter more often and
         * hold fewer frames so brightness changes settle faster. */
        if (noHwAe && !m_manualExposure && mean >= 0.0 && aeHoldFrames <= 0 &&
            (frameCount % 3) == 0) {
          const double target = 118.0;
          const double deadband = 10.0;
          const double err = std::fabs(mean - target);
          if (err > deadband) {
            double scale = target / std::max(mean, 1.0);
            /* Map error deadband..~70 → gain 0.35..0.75 (clamped). */
            const double gain = qBound(0.35, 0.35 + (err - deadband) / 60.0 * 0.40, 0.75);
            scale = 1.0 + (scale - 1.0) * gain;
            /* Cap per-step jump so a single dark↔bright swing cannot overshoot. */
            scale = qBound(0.50, scale, 2.0);

            double expMs = m_exposureMs;
            int iso = m_iso;
            const double maxExpMs = double(expMaxNs) / 1e6;
            const double minExpMs = std::max(0.05, double(expMinNs) / 1e6);

            double newExp = expMs * scale;
            if (newExp > maxExpMs) {
              const double overflow = newExp / maxExpMs;
              newExp = maxExpMs;
              iso = qBound(isoMin, int(std::lround(iso * overflow)), isoMax);
            } else if (newExp < minExpMs) {
              const double underflow = newExp / minExpMs;
              newExp = minExpMs;
              iso = qBound(isoMin, int(std::lround(iso * underflow)), isoMax);
            } else if (iso > 400 && newExp < maxExpMs * 0.7 && scale > 1.0) {
              /* Prefer longer exposure over high ISO when there is room. */
              const double isoScale = std::min(scale, iso / 400.0);
              iso = qBound(isoMin, int(std::lround(iso / isoScale)), isoMax);
              newExp = std::min(maxExpMs, newExp * isoScale);
            }

            newExp = qBound(minExpMs, newExp, maxExpMs);
            iso = qBound(isoMin, iso, isoMax);

            const bool changed =
                (std::fabs(newExp - expMs) >= 0.15) || (iso != m_iso);
            if (changed) {
              m_exposureMs = newExp;
              m_iso = iso;
              m_settingsDirty.store(true);
              aeHoldFrames = 4; /* settle briefly, then meter again */
              QMetaObject::invokeMethod(this, [this] {
                emit exposureMsChanged();
                emit isoChanged();
              }, Qt::QueuedConnection);
            }
          }
        }
        if (aeHoldFrames > 0) --aeHoldFrames;
      }
    }

    /* Live update of the repeating request — no session stop/start. */
    if (m_settingsDirty.exchange(false)) {
      if (stillReq) applyExposure(stillReq);
      if (!pushRepeating()) {
        QMetaObject::invokeMethod(this, [this] {
          emit errorOccurred(tr("Could not update exposure settings"));
        }, Qt::QueuedConnection);
      } else {
        aeHoldFrames = 4;
        QMetaObject::invokeMethod(this, [this] {
          setStatus(m_manualExposure
                        ? tr("manual %1 ms · ISO %2")
                              .arg(m_exposureMs, 0, 'f', 0)
                              .arg(m_iso)
                        : tr("auto %1 ms · ISO %2")
                              .arg(m_exposureMs, 0, 'f', 0)
                              .arg(m_iso));
        }, Qt::QueuedConnection);
      }
    }

    if (m_captureRequested.exchange(false)) {
      if (stillReq) {
        applyExposure(stillReq); /* match the live preview exposure */
        int sseq = 0;
        h_ACameraCaptureSession_capture(session, &capCb, 1, &stillReq, &sseq);
        /* Wait briefly for the encoded frame rather than blocking forever. */
        AImage *shot = nullptr;
        for (int i = 0; i < 200 && !shot && !m_stopRequested.load(); ++i) {
          if (h_AImageReader_acquireNextImage(stillReader, &shot) != AMEDIA_OK) shot = nullptr;
          if (!shot) usleep(25000);
        }
        if (shot) {
          uint8_t *data = nullptr;
          int len = 0;
          if (h_AImage_getPlaneData(shot, 0, &data, &len) == AMEDIA_OK && len > 4) {
            const QString name =
                QStringLiteral("%1/ircam-cam%2-%3.jpg")
                    .arg(picturesDir, m_cameraId,
                         QDateTime::currentDateTime().toString("yyyyMMdd-hhmmss"));
            QFile f(name);
            if (f.open(QIODevice::WriteOnly) &&
                f.write(reinterpret_cast<const char *>(data), len) == len) {
              f.close();
              QMetaObject::invokeMethod(this, [this, name] {
                m_lastPhoto = name;
                emit lastPhotoChanged();
                emit photoSaved(name);
              }, Qt::QueuedConnection);
            } else {
              QMetaObject::invokeMethod(this, [this, name] {
                emit errorOccurred(tr("Could not write %1").arg(name));
              }, Qt::QueuedConnection);
            }
          }
          h_AImage_delete(shot);
        } else {
          QMetaObject::invokeMethod(this, [this] {
            emit errorOccurred(tr("The camera did not return a still image"));
          }, Qt::QueuedConnection);
        }
      } else {
        QMetaObject::invokeMethod(this, [this] {
          emit errorOccurred(tr("This camera did not accept a full-resolution still stream"));
        }, Qt::QueuedConnection);
      }
    }

    usleep(5000);
  }

  if (devState.failed.load()) {
    QMetaObject::invokeMethod(this, [this] {
      emit errorOccurred(tr("The camera device reported a failure and was closed"));
    }, Qt::QueuedConnection);
  }

  h_ACameraCaptureSession_stopRepeating(session);
  h_ACameraCaptureSession_close(session);
  if (stillReq) h_ACaptureRequest_free(stillReq);
  if (stillTarget) h_ACameraOutputTarget_free(stillTarget);
  if (previewReq) h_ACaptureRequest_free(previewReq);
  if (previewTarget) h_ACameraOutputTarget_free(previewTarget);
  if (stillOut) h_ACaptureSessionOutput_free(stillOut);
  if (previewOut) h_ACaptureSessionOutput_free(previewOut);
  if (outputs) h_ACaptureSessionOutputContainer_free(outputs);
  h_ACameraDevice_close(dev);
  if (stillReader) h_AImageReader_delete(stillReader);
  h_AImageReader_delete(previewReader);
  h_ACameraMetadata_free(chars);
  h_ACameraManager_delete(mgr);
  m_running = false;
}
