QT += core gui qml quick quickcontrols2 dbus network

CONFIG += c++17 release
TARGET = aloi-sidecar
TEMPLATE = app

HEADERS += \
    src/agent.h \
    src/app.h \
    src/engine.h \
    src/instance.h \
    src/theme.h \
    src/tools.h

SOURCES += \
    src/main.cpp \
    src/agent.cpp \
    src/app.cpp \
    src/engine.cpp \
    src/instance.cpp \
    src/theme.cpp

RESOURCES += src/resources.qrc
