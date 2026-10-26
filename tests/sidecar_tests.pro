QT += core network dbus testlib
CONFIG += c++17 testcase
TARGET = sidecar_tests
TEMPLATE = app
INCLUDEPATH += ../src
HEADERS += ../src/agent.h ../src/engine.h ../src/instance.h ../src/tools.h
SOURCES += sidecar_tests.cpp ../src/agent.cpp ../src/engine.cpp ../src/instance.cpp
