QT += core gui qml quick quickcontrols2 dbus network testlib
CONFIG += c++17
TARGET = shots
TEMPLATE = app
INCLUDEPATH += ../../src
HEADERS += ../../src/agent.h ../../src/app.h ../../src/engine.h ../../src/instance.h ../../src/shade.h ../../src/tools.h
SOURCES += shots.cpp ../../src/agent.cpp ../../src/app.cpp ../../src/engine.cpp ../../src/instance.cpp ../../src/shade.cpp
RESOURCES += ../../src/resources.qrc

# The pieces every Aloi app shares (theme, scrolling, buttons, palette, bar).
ALOI_UI = $$clean_path($$PWD/../../../aloi-ui)
!exists($$ALOI_UI/aloi-ui.pri): error("Aloi UI is missing: clone it to $$ALOI_UI")
include($$ALOI_UI/aloi-ui.pri)
