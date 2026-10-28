QT += core gui qml quick quickcontrols2 dbus network
CONFIG += c++17
TARGET = shots
TEMPLATE = app
INCLUDEPATH += ../../src
HEADERS += ../../src/agent.h ../../src/app.h ../../src/engine.h ../../src/instance.h ../../src/shade.h ../../src/theme.h ../../src/tools.h
SOURCES += shots.cpp ../../src/agent.cpp ../../src/app.cpp ../../src/engine.cpp ../../src/instance.cpp ../../src/shade.cpp ../../src/theme.cpp
RESOURCES += ../../src/resources.qrc
