#include "app.h"

#include <QFont>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QUrl>

#include "agent.h"
#include "aloiui.h"
#include "engine.h"
#include "instance.h"
#include "shade.h"
#include "theme.h"

void App::prepare() {
    QQuickStyle::setStyle("Material");
    aloi::registerQmlTypes();
    // The whole app speaks in the Omarchy font, like the terminal and the
    // bar: fontconfig's monospace is what Omarchy's font picker sets.
    QFont font("monospace");
    font.setStyleHint(QFont::Monospace);
    QGuiApplication::setFont(font);
}

bool App::load(QQmlApplicationEngine &qml, Theme &theme, Engine &engine, Agent &agent, Instance *instance) {
    auto *context = qml.rootContext();
    context->setContextProperty("theme", &theme);
    context->setContextProperty("engine", &engine);
    context->setContextProperty("transcript", engine.transcript());
    context->setContextProperty("agent", &agent);
    context->setContextProperty("instance", instance);
    context->setContextProperty("shade", new Shade(&qml));
    qml.load(QUrl("qrc:/Main.qml"));
    return !qml.rootObjects().isEmpty();
}
