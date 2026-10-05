/*
 * IRViewfinder -- draws the live frames from an IRCamera.
 *
 * Frames go straight into the scene graph as a texture, so there is no file
 * round-trip and no CPU blit per frame beyond the one colour conversion the
 * camera thread already does.
 */
#ifndef IRVIEWFINDER_H
#define IRVIEWFINDER_H

#include <QImage>
#include <QQuickItem>

class IRCamera;

class IRViewfinder : public QQuickItem {
  Q_OBJECT
  Q_PROPERTY(IRCamera *camera READ camera WRITE setCamera NOTIFY cameraChanged)
  /* Natural size of the incoming frames, so QML can letterbox correctly. */
  Q_PROPERTY(int frameWidth READ frameWidth NOTIFY frameSizeChanged)
  Q_PROPERTY(int frameHeight READ frameHeight NOTIFY frameSizeChanged)

 public:
  explicit IRViewfinder(QQuickItem *parent = nullptr);

  IRCamera *camera() const { return m_camera; }
  void setCamera(IRCamera *c);
  int frameWidth() const { return m_frame.width(); }
  int frameHeight() const { return m_frame.height(); }

 signals:
  void cameraChanged();
  void frameSizeChanged();

 protected:
  QSGNode *updatePaintNode(QSGNode *node, UpdatePaintNodeData *) override;

 private slots:
  void onFrame(const QImage &frame);

 private:
  IRCamera *m_camera = nullptr;
  QImage m_frame;
  bool m_dirty = false;
  QSize m_lastSize;
};

#endif
