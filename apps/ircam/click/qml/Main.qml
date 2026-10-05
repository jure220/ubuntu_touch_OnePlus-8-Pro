/*
 * IR Camera -- a viewfinder for the OnePlus 8 Pro's colour-filter camera.
 *
 * The stock camera app cannot open this sensor at all: it does not advertise
 * BACKWARD_COMPATIBLE, and Ubuntu Touch's camera stack speaks Camera API1,
 * which can only drive cameras that do. Everything here goes through Camera2
 * instead, via the IRCam plugin.
 */
import QtQuick 2.12
import Lomiri.Components 1.3
import Lomiri.Components.Popups 1.3
import IRCam 1.0

MainView {
    id: root
    objectName: "mainView"
    applicationName: "ircam.z3phyr"
    automaticOrientation: false
    anchorToKeyboard: false
    width: units.gu(50)
    height: units.gu(85)

    theme.name: "Lomiri.Components.Themes.SuruDark"

    property string toastText: ""

    IRCamera {
        id: cam
        cameraId: "4"
        // Software auto by default — this sensor has no hardware AE.
        manualExposure: false
        iso: 800
        exposureMs: 33

        onErrorOccurred: {
            console.log("IRCAM error: " + message)
            root.toastText = message
            toast.restart()
        }
        onPhotoSaved: {
            console.log("IRCAM saved: " + path)
            root.toastText = i18n.tr("Saved %1").arg(path.split("/").pop())
            toast.restart()
        }
        onStatusChanged: console.log("IRCAM status: " + status)
        Component.onCompleted: {
            refreshCameras()
            console.log("IRCAM cameras: " + cameras.length)
            start()
        }
    }

    Timer { id: toast; interval: 3500; onTriggered: root.toastText = "" }

    Page {
        anchors.fill: parent
        header: PageHeader {
            id: header
            title: i18n.tr("IR Camera")
            subtitle: cam.status
            trailingActionBar.actions: [
                Action {
                    iconName: "camera-flip"
                    text: i18n.tr("Choose camera")
                    onTriggered: PopupUtils.open(cameraPicker)
                },
                Action {
                    iconName: "settings"
                    text: i18n.tr("Exposure")
                    onTriggered: controls.visible = !controls.visible
                }
            ]
        }

        // ---------------------------------------------------------- viewfinder
        Rectangle {
            id: stage
            anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: bar.top }
            color: "black"
            clip: true

            IRViewfinder {
                id: view
                camera: cam
                anchors.centerIn: parent

                // The sensor is mounted rotated, so the frames arrive on their
                // side. Rotating the item is free; rotating each frame is not.
                rotation: cam.sensorOrientation

                // After rotation the item's width maps to the screen's height,
                // so fit against the swapped extent. Portrait lock keeps stage
                // geometry stable when the phone is tilted.
                readonly property bool sideways: (cam.sensorOrientation % 180) !== 0
                readonly property real availW: sideways ? stage.height : stage.width
                readonly property real availH: sideways ? stage.width : stage.height
                readonly property real ar: view.frameHeight > 0
                                           ? view.frameWidth / view.frameHeight : 4 / 3
                width: Math.min(availW, availH * ar)
                height: width / ar
            }

            ActivityIndicator {
                anchors.centerIn: parent
                running: view.frameWidth === 0
                visible: running
            }

            Label {
                anchors { centerIn: parent; verticalCenterOffset: units.gu(5) }
                visible: view.frameWidth === 0
                text: i18n.tr("Starting camera %1…").arg(cam.cameraId)
                color: "white"
            }

            // Quick exposure readout (always visible, not only in the panel)
            Label {
                anchors { left: parent.left; top: parent.top; margins: units.gu(1) }
                text: {
                    var mode = cam.manualExposure ? i18n.tr("M") : i18n.tr("A")
                    return mode + "  " + cam.exposureMs.toFixed(0) + " ms · ISO " + cam.iso
                           + (cam.meanBrightness > 0
                              ? "  ·  ▓ " + cam.meanBrightness.toFixed(0) : "")
                }
                color: "#dddddd"
                fontSize: "small"
            }

            // exposure controls, hidden by default
            Rectangle {
                id: controls
                visible: false
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                // Deliberately a fixed height. Deriving it from the child column
                // makes the layout's implicit size depend on the parent it feeds,
                // which QML reports as a binding loop.
                height: units.gu(38)
                color: Qt.rgba(0, 0, 0, 0.75)

                Column {
                    id: column
                    anchors { left: parent.left; right: parent.right; top: parent.top
                              margins: units.gu(2) }
                    spacing: units.gu(1)

                    Button {
                        width: parent.width
                        text: cam.manualExposure
                              ? i18n.tr("Using Manual — tap for Auto")
                              : i18n.tr("Using Auto — tap for Manual")
                        onClicked: {
                            cam.manualExposure = !cam.manualExposure
                            cam.applySettings()
                        }
                    }

                    Label {
                        text: i18n.tr("Exposure  %1 ms").arg(cam.exposureMs.toFixed(0))
                        color: "white"
                        opacity: cam.manualExposure ? 1.0 : 0.55
                    }
                    Slider {
                        id: expSlider
                        width: parent.width
                        minimumValue: 1; maximumValue: 199
                        enabled: cam.manualExposure
                        Component.onCompleted: value = cam.exposureMs
                        // Keep the handle in sync when auto adjusts, without
                        // fighting the user while they drag.
                        Connections {
                            target: cam
                            onExposureMsChanged: expSlider.value = cam.exposureMs
                        }
                        onValueChanged: if (cam.manualExposure) cam.exposureMs = value
                        live: false
                    }
                    Label {
                        text: i18n.tr("ISO  %1").arg(cam.iso)
                        color: "white"
                        opacity: cam.manualExposure ? 1.0 : 0.55
                    }
                    Slider {
                        id: isoSlider
                        width: parent.width
                        minimumValue: 100; maximumValue: 1600
                        enabled: cam.manualExposure
                        Component.onCompleted: value = cam.iso
                        Connections {
                            target: cam
                            onIsoChanged: isoSlider.value = cam.iso
                        }
                        onValueChanged: if (cam.manualExposure) cam.iso = Math.round(value)
                        live: false
                    }
                    Label {
                        width: parent.width
                        text: cam.manualExposure
                              ? i18n.tr("Manual — Apply updates the live preview (no restart)")
                              : i18n.tr("Auto — software exposure (this sensor has no hardware AE)")
                        color: "#bbbbbb"
                        fontSize: "small"
                        wrapMode: Text.Wrap
                    }
                    Button {
                        width: parent.width
                        text: i18n.tr("Apply")
                        enabled: cam.manualExposure
                        // Push SENSOR_EXPOSURE_TIME / SENSOR_SENSITIVITY into the
                        // repeating request. Do NOT stop()/start() — that rebuilds
                        // the whole session and freezes the UI.
                        onClicked: {
                            cam.applySettings()
                            controls.visible = false
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------------- toast
        Rectangle {
            visible: root.toastText !== ""
            anchors { bottom: bar.top; horizontalCenter: parent.horizontalCenter
                      bottomMargin: units.gu(2) }
            width: Math.min(parent.width - units.gu(4), msg.implicitWidth + units.gu(4))
            height: msg.implicitHeight + units.gu(2)
            radius: units.gu(0.5)
            color: Qt.rgba(0, 0, 0, 0.8)
            Label {
                id: msg
                anchors.centerIn: parent
                width: parent.width - units.gu(2)
                text: root.toastText
                color: "white"
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // ------------------------------------------------------------ shutter
        Rectangle {
            id: bar
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: units.gu(12)
            color: "#0d0d0d"

            Label {
                anchors { left: parent.left; leftMargin: units.gu(2); verticalCenter: parent.verticalCenter }
                width: units.gu(12)
                text: cam.stillSupported ? i18n.tr("Full res\n2592×1944")
                                         : i18n.tr("Preview\nonly")
                color: "#999999"
                fontSize: "small"
            }

            AbstractButton {
                id: shutter
                anchors.centerIn: parent
                width: units.gu(9); height: width
                enabled: cam.active
                onClicked: cam.capture()

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border { width: units.gu(0.4); color: shutter.enabled ? "white" : "#555555" }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width - units.gu(1.6); height: width
                    radius: width / 2
                    color: shutter.pressed ? "#cccccc"
                                           : (shutter.enabled ? "white" : "#555555")
                }
            }

            Label {
                anchors { right: parent.right; rightMargin: units.gu(2); verticalCenter: parent.verticalCenter }
                width: units.gu(12)
                horizontalAlignment: Text.AlignRight
                text: i18n.tr("camera %1").arg(cam.cameraId)
                color: "#999999"
                fontSize: "small"
            }
        }
    }

    // ------------------------------------------------------------ camera list
    Component {
        id: cameraPicker
        Dialog {
            id: dlg
            title: i18n.tr("Camera")
            text: i18n.tr("Cameras marked hidden cannot be opened by the stock camera app.")

            Repeater {
                model: cam.cameras
                delegate: Button {
                    width: parent.width
                    color: modelData.id === cam.cameraId ? LomiriColors.orange : theme.palette.normal.foreground
                    text: {
                        var s = i18n.tr("Camera %1 — %2").arg(modelData.id).arg(modelData.facing)
                        if (modelData.focalLength)
                            s += "  " + modelData.focalLength.toFixed(2) + "mm"
                        if (modelData.hiddenFromStockApp)
                            s += "  ★ " + i18n.tr("hidden")
                        else if (modelData.logicalMultiCamera)
                            s += "  " + i18n.tr("(virtual)")
                        return s
                    }
                    onClicked: {
                        cam.cameraId = modelData.id
                        PopupUtils.close(dlg)
                    }
                }
            }
            Button {
                text: i18n.tr("Cancel")
                onClicked: PopupUtils.close(dlg)
            }
        }
    }
}
