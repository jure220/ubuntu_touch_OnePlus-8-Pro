#include "viewfinder.h"

#include "ircamera.h"

#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QSGTexture>

IRViewfinder::IRViewfinder(QQuickItem *parent) : QQuickItem(parent) {
  setFlag(ItemHasContents, true);
}

void IRViewfinder::setCamera(IRCamera *c) {
  if (m_camera == c) return;
  if (m_camera) disconnect(m_camera, nullptr, this, nullptr);
  m_camera = c;
  if (m_camera)
    connect(m_camera, &IRCamera::frameReady, this, &IRViewfinder::onFrame, Qt::QueuedConnection);
  emit cameraChanged();
}

void IRViewfinder::onFrame(const QImage &frame) {
  const QSize old = m_frame.size();
  m_frame = frame;
  m_dirty = true;
  if (old != frame.size()) emit frameSizeChanged();
  update();
}

QSGNode *IRViewfinder::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *) {
  if (m_frame.isNull()) {
    delete oldNode;
    return nullptr;
  }

  auto *node = static_cast<QSGSimpleTextureNode *>(oldNode);
  if (!node) {
    node = new QSGSimpleTextureNode();
    node->setFiltering(QSGTexture::Linear);
    m_dirty = true;
  }

  if (m_dirty) {
    /* The node owns its texture; replacing it frees the previous one. */
    QSGTexture *tex = window()->createTextureFromImage(m_frame, QQuickWindow::TextureIsOpaque);
    node->setTexture(tex);
    node->setOwnsTexture(true);
    m_dirty = false;
  }

  node->setRect(boundingRect());
  return node;
}
