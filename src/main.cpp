// Aloi Sidecar: a live transcript of your meeting, and an agent to ask about it.

#include <QCommandLineParser>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>

#include "agent.h"
#include "app.h"
#include "engine.h"
#include "instance.h"
#include "theme.h"

int main(int argc, char *argv[]) {
    // The agent's hook asking whether a command may run: no window, just the
    // question to the Sidecar that's open, and its answer.
    for (int i = 1; i < argc; ++i) {
        if (QByteArrayView(argv[i]) == "--approve") {
            QCoreApplication app(argc, argv);
            return Instance::approve();
        }
    }

    QGuiApplication app(argc, argv);
    app.setApplicationName("aloi-sidecar");
    app.setApplicationDisplayName("Aloi Sidecar");
    app.setApplicationVersion("0.1.0");
    // Matches the window to aloi-sidecar.desktop, so the compositor (Wayland
    // app_id) and the launcher pick up the installed icon.
    app.setDesktopFileName("aloi-sidecar");
    app.setWindowIcon(QIcon::fromTheme("aloi-sidecar"));

    QCommandLineParser parser;
    parser.setApplicationDescription("A live transcript of your meeting, and an agent to ask about it.");
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption ask("ask", "Bring Sidecar forward with the cursor in the ask box.");
    const QCommandLineOption toggle("toggle", "Turn listening on or off.");
    const QCommandLineOption quiet("no-listen", "Open without starting to listen.");
    parser.addOptions({ask, toggle, quiet});
    parser.process(app);
    const QString action = parser.isSet(ask) ? "ask" : parser.isSet(toggle) ? "toggle" : "";

    Instance instance;
    if (!instance.claim(action))
        return 0;

    App::prepare();
    Theme theme;
    // SIDECAR_ENGINE, SIDECAR_CLAUDE and SIDECAR_STATE point at stand-ins,
    // for screenshots and tests that must not touch the real meeting.
    Engine engine;
    Agent agent(engine.transcript(), qEnvironmentVariable("SIDECAR_CLAUDE"), qEnvironmentVariable("SIDECAR_STATE"));
    QObject::connect(&engine, &Engine::meetingChanged, &agent, [&] { agent.setMeeting(engine.meeting()); });

    // What the agent wants to run beyond a lookup comes in over the bus
    // from its hook, and waits for Chris in the agent panel.
    instance.setApprover([&agent](const QString &session, const QString &command, const QString &description,
                                  std::function<void(const QString &)> answer) {
        agent.requestApproval(session, command, description, std::move(answer));
    });

    QQmlApplicationEngine qml;
    if (!App::load(qml, theme, engine, agent, &instance))
        return 1;

    // Opening Sidecar is for a call, so it starts listening; closing it
    // stops, so nothing is heard while it's closed.
    engine.setListenOnConnect(!parser.isSet(quiet));
    QObject::connect(&app, &QGuiApplication::aboutToQuit, &engine, &Engine::stopListeningNow);
    engine.connectToEngine();
    return app.exec();
}
