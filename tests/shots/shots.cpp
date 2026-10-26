// Drives the real window offscreen against the stand-in engine and Claude,
// and saves what Chris would see: listening with the transcript, then an
// answer from the agent. --check fails on any QML warning.

#include <QDir>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QTimer>
#include <cstdio>

#include "../../src/agent.h"
#include "../../src/app.h"
#include "../../src/engine.h"
#include "../../src/theme.h"

static int warnings = 0;

static void handler(QtMsgType type, const QMessageLogContext &, const QString &message) {
    if (type != QtDebugMsg && type != QtInfoMsg) {
        ++warnings;
        std::fprintf(stderr, "%s\n", qPrintable(message));
    }
}

static void wait(int ms) {
    QEventLoop loop;
    QTimer::singleShot(ms, &loop, &QEventLoop::quit);
    loop.exec();
}

int main(int argc, char *argv[]) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    const QStringList args = app.arguments();
    const bool check = args.contains("--check");
    QString size = "1280x820", out = "docs";
    for (int i = 1; i < args.size(); ++i) {
        if (args[i].contains('x') && args[i][0].isDigit()) size = args[i];
        if (args[i] == "--out" && i + 1 < args.size()) out = args[++i];
    }
    qInstallMessageHandler(handler);

    QTemporaryDir state, themeDir;
    App::prepare();
    // An empty theme folder: the default accent, whatever the desktop's theme is.
    Theme theme(themeDir.path());
    Engine engine(qEnvironmentVariable("SIDECAR_ENGINE", "http://127.0.0.1:8779"));
    Agent agent(engine.transcript(), qEnvironmentVariable("SIDECAR_CLAUDE"), state.path());
    agent.setApprover("/bin/false");
    QObject::connect(&engine, &Engine::meetingChanged, &agent, [&] { agent.setMeeting(engine.meeting()); });

    QQmlApplicationEngine qml;
    if (!App::load(qml, theme, engine, agent, nullptr))
        return 1;
    auto *window = qobject_cast<QQuickWindow *>(qml.rootObjects().first());
    const QStringList wh = size.split('x');
    window->resize(wh[0].toInt(), wh[1].toInt());
    engine.connectToEngine();

    for (int i = 0; i < 50 && engine.transcript()->count() == 0; ++i)
        wait(100);
    if (engine.transcript()->count() == 0) {
        std::fprintf(stderr, "No transcript from the stand-in engine.\n");
        return 1;
    }
    wait(800);
    QDir().mkpath(out);
    window->grabWindow().save(out + "/listening-" + size + ".png");

    agent.ask("Has anyone asked me something I haven't answered?");
    for (int i = 0; i < 100 && agent.running(); ++i)
        wait(100);
    wait(500);
    window->grabWindow().save(out + "/answer-" + size + ".png");

    std::printf("%s: %d lines, %lld messages, %d warnings\n", qPrintable(size), engine.transcript()->count(),
                static_cast<long long>(agent.messages().size()), warnings);
    return check && warnings > 0 ? 1 : 0;
}
