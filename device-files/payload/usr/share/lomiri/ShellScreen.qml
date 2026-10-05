/*
* Copyright (C) 2016 Canonical Ltd.
*
* This program is free software; you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation; version 3.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

import QtQuick 2.15
import Lomiri.Components 1.3
import WindowManager 1.0
import Cursor 1.1
import "Components"

ScreenWindow {
    id: screenWindow

    color: "black"
    title: "Lomiri Shell"

    property int screenIndex: -1
    readonly property bool primary: {
        // If this is the only screen then it's the primary one
        if (Screens.count === 1)
            return true;

        // BUG FIX (re-applied 2026-09-17 after the 24.04-2.x upgrade; upstream
        // still has this): the stock version returns true for screenIndex 1 via
        // the phone/tablet rule AND true for screenIndex 0 via the fallback, so
        // with an external monitor attached BOTH screens report primary == true.
        // Exactly one screen must be primary.
        if (deviceConfiguration.category == "phone" || deviceConfiguration.category == "tablet")
            return screenIndex === 1;

        return screenIndex === 0;
    }

    DeviceConfiguration {
        id: deviceConfiguration
    }

    Loader {
        id: loader
        width: screenWindow.width
        height: screenWindow.height

        sourceComponent: {
            if ((deviceConfiguration.category == "phone" || deviceConfiguration.category == "tablet")
                 && Screens.count > 1 && screenIndex === 0) {
                return disabledScreenComponent;
            }
            return shellComponent;
        }
    }

    Component {
        id: shellComponent
        OrientedShell {
            // Size from the Window explicitly. Do NOT rely on implicitWidth --
            // Loader sizes to its item's implicit size, which created a 0x0 loop
            // and left AvailableDesktopArea at QRect(0,24 0x0) (black external
            // display). Re-applied after the 24.04-2.x upgrade.
            width: screenWindow.width
            height: screenWindow.height
            screen: screenWindow.screen
            visible: true
            screenIndex: screenWindow.screenIndex

            deviceConfiguration {
                overrideName: Screens.count > 1 ? "desktop" : false
            }
        }
    }

    Component {
        id: disabledScreenComponent
        DisabledScreenNotice {
            width: screenWindow.width
            height: screenWindow.height
            screen: screenWindow.screen
            oskEnabled: Screens.count > 1
        }
    }
}
