/*
 * IRCamera -- a QML-facing camera object backed by Android's Camera2 NDK,
 * reached through libhybris.
 *
 * The whole point of this class is the OnePlus 8 Pro's colour-filter camera
 * (id 4), which Ubuntu Touch's normal camera stack cannot open because it does
 * not advertise BACKWARD_COMPATIBLE. Nothing here is specific to it, though:
 * any camera id the device exposes can be driven.
 *
 * All Camera2 work happens on a private worker thread; frames reach the GUI
 * thread as QImages via a queued signal.
 */
#ifndef IRCAMERA_H
#define IRCAMERA_H

#include <QImage>
#include <QObject>
#include <QVariantList>
#include <atomic>
#include <thread>

class IRCamera : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString cameraId READ cameraId WRITE setCameraId NOTIFY cameraIdChanged)
  Q_PROPERTY(bool active READ isActive NOTIFY activeChanged)
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)
  Q_PROPERTY(QVariantList cameras READ cameras NOTIFY camerasChanged)
  Q_PROPERTY(int sensorOrientation READ sensorOrientation NOTIFY sensorOrientationChanged)
  Q_PROPERTY(bool stillSupported READ stillSupported NOTIFY stillSupportedChanged)
  Q_PROPERTY(QString lastPhoto READ lastPhoto NOTIFY lastPhotoChanged)
  Q_PROPERTY(int iso READ iso WRITE setIso NOTIFY isoChanged)
  Q_PROPERTY(qreal exposureMs READ exposureMs WRITE setExposureMs NOTIFY exposureMsChanged)
  Q_PROPERTY(bool manualExposure READ manualExposure WRITE setManualExposure
                 NOTIFY manualExposureChanged)
  Q_PROPERTY(qreal meanBrightness READ meanBrightness NOTIFY meanBrightnessChanged)

 public:
  explicit IRCamera(QObject *parent = nullptr);
  ~IRCamera() override;

  QString cameraId() const { return m_cameraId; }
  void setCameraId(const QString &id);
  bool isActive() const { return m_running.load(); }
  QString status() const { return m_status; }
  QVariantList cameras() const { return m_cameras; }
  int sensorOrientation() const { return m_sensorOrientation; }
  bool stillSupported() const { return m_stillSupported; }
  QString lastPhoto() const { return m_lastPhoto; }
  int iso() const { return m_iso; }
  void setIso(int v);
  qreal exposureMs() const { return m_exposureMs; }
  void setExposureMs(qreal v);
  bool manualExposure() const { return m_manualExposure; }
  void setManualExposure(bool v);
  qreal meanBrightness() const { return m_meanBrightness; }

  /* Enumerate every camera the device exposes to Camera2, with the fields that
   * actually distinguish them. Safe to call before start(). */
  Q_INVOKABLE void refreshCameras();
  Q_INVOKABLE void start();
  Q_INVOKABLE void stop();
  /* Request one full-resolution still. The file lands in ~/Pictures and its
   * path arrives via photoSaved(). */
  Q_INVOKABLE void capture();
  /* Push the current exposure/ISO into the live repeating request without
   * tearing down the capture session (avoids the Apply freeze). */
  Q_INVOKABLE void applySettings();

 signals:
  void cameraIdChanged();
  void activeChanged();
  void statusChanged();
  void camerasChanged();
  void sensorOrientationChanged();
  void stillSupportedChanged();
  void lastPhotoChanged();
  void isoChanged();
  void exposureMsChanged();
  void manualExposureChanged();
  void meanBrightnessChanged();

  /* Queued to the GUI thread; the viewfinder item consumes this. */
  void frameReady(const QImage &frame);
  void photoSaved(const QString &path);
  void errorOccurred(const QString &message);

 private:
  void threadMain();
  void setStatus(const QString &s);
  void markSettingsDirty();

  QString m_cameraId = QStringLiteral("4");
  QString m_status = QStringLiteral("idle");
  QString m_lastPhoto;
  QVariantList m_cameras;
  int m_sensorOrientation = 90;
  bool m_stillSupported = false;
  int m_iso = 800;
  qreal m_exposureMs = 33.0;
  /* false = software auto (default). Hardware has no AE on camera 4. */
  bool m_manualExposure = false;
  qreal m_meanBrightness = 0.0;

  std::thread m_thread;
  std::atomic<bool> m_running{false};
  std::atomic<bool> m_stopRequested{false};
  std::atomic<bool> m_captureRequested{false};
  std::atomic<bool> m_settingsDirty{false};
};

#endif
