# Builds the IRCam QML plugin (and, when asked, the command-line tool) for the
# phone. Run inside the arm64 Qt container -- see click/build.sh.
cmake_minimum_required(VERSION 3.16)
project(ircam CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(Qt5 5.15 REQUIRED COMPONENTS Core Gui Qml Quick)

# The Android side is reached entirely through libhybris at runtime, so nothing
# Android is linked here; only these headers are needed at build time.
set(NDK_INCLUDES ${CMAKE_CURRENT_SOURCE_DIR}/ndk ${CMAKE_CURRENT_SOURCE_DIR}/ndk/compat)

add_library(ircamplugin SHARED
    plugin/plugin.cpp
    plugin/ircamera.cpp
    plugin/viewfinder.cpp
    src/hybris_ndk.c
    src/camutil.c
)
target_include_directories(ircamplugin PRIVATE ${NDK_INCLUDES} src plugin)
target_link_libraries(ircamplugin PRIVATE Qt5::Core Qt5::Gui Qt5::Qml Qt5::Quick ${CMAKE_DL_LIBS})
set_target_properties(ircamplugin PROPERTIES C_STANDARD 11)

# Install the plugin next to its qmldir so QML can import IRCam 1.0.
install(TARGETS ircamplugin DESTINATION lib/IRCam)
install(FILES plugin/qmldir DESTINATION lib/IRCam)
