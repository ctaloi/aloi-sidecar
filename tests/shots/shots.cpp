// Drives the real window offscreen against the stand-in engine and Claude,
// and saves what Chris would see: listening with the transcript, then an
// answer from the agent. --check fails on any QML warning.

#include <QDir>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QProcess>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QTemporaryDir>
#include <QTimer>
#include <cstdio>

#include "../../src/agent.h"
#include "../../src/app.h"
#include "../../src/engine.h"
#include "../../src/instance.h"
#include "theme.h"

static int warnings = 0;

static void handler(QtMsgType type, const QMessageLogContext &, const QString &message) {
    // The offscreen platform can't take a minimum size, which rolling the
    // window up changes; that's the platform, not the window.
    if (message.contains("propagateSizeHints"))
        return;
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

    // --approval: the real hook and bus, so a command the agent wants to run
    // comes back to this window as a card (needs the real claude, and
    // build/aloi-sidecar for the hook).
    const bool approval = args.contains("--approval");
    QTemporaryDir state, themeDir;
    App::prepare();
    // An empty theme folder: the default accent, whatever the desktop's theme is.
    Theme theme(themeDir.path());
    Engine engine(qEnvironmentVariable("SIDECAR_ENGINE", "http://127.0.0.1:8779"));
    Agent agent(engine.transcript(), qEnvironmentVariable("SIDECAR_CLAUDE"), state.path());
    agent.setApprover(approval ? QDir::currentPath() + "/build/aloi-sidecar" : "/bin/false");
    QObject::connect(&engine, &Engine::selectedMeetingChanged, &agent, [&] {
        agent.setMeeting(engine.selected(), Agent::describe(engine.selectedMeeting()));
    });
    Instance instance;
    if (approval) {
        if (!instance.claim({})) {
            std::fprintf(stderr, "Another Sidecar has the bus name; close it first.\n");
            return 1;
        }
        instance.setApprover([&agent](const QString &session, const QString &command, const QString &description,
                                      std::function<void(const QString &)> answer) {
            agent.requestApproval(session, command, description, std::move(answer));
        });
    }

    QQmlApplicationEngine qml;
    if (!App::load(qml, theme, engine, agent, approval ? &instance : nullptr))
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
    // Home first, where it opens; then the meeting that's on.
    window->grabWindow().save(out + "/home-" + size + ".png");
    window->setProperty("view", "meetings");
    wait(400);
    window->grabWindow().save(out + "/listening-" + size + ".png");

    // Rolled up to its bar; offscreen there's no Hyprland to size it, so
    // the harness does.
    QMetaObject::invokeMethod(window, "setShaded", Q_ARG(QVariant, true));
    window->resize(560, 40);
    wait(400);
    window->grabWindow().save(out + "/shaded-" + size + ".png");
    QMetaObject::invokeMethod(window, "setShaded", Q_ARG(QVariant, false));
    window->resize(wh[0].toInt(), wh[1].toInt());
    wait(300);

    if (approval) {
        agent.ask("Run exactly `curl -sI https://example.com` and tell me the HTTP status line, nothing else.");
        for (int i = 0; i < 600 && agent.approvals().isEmpty() && agent.running(); ++i)
            wait(100);
        if (agent.approvals().isEmpty()) {
            std::fprintf(stderr, "No approval was asked for.\n");
            return 1;
        }
        wait(300);
        window->grabWindow().save(out + "/approval-" + size + ".png");
        std::printf("asked to run: %s\n", qPrintable(agent.approvals().first().toMap().value("command").toString()));
        agent.decide(agent.approvals().first().toMap().value("id").toString(), "once");
        for (int i = 0; i < 600 && agent.running(); ++i)
            wait(100);
        wait(300);
        window->grabWindow().save(out + "/approved-" + size + ".png");
        std::printf("answer: %s\n", qPrintable(agent.messages().last().toMap().value("text").toString()));
        return 0;
    }
    agent.ask("Has anyone asked me something I haven't answered?");
    for (int i = 0; i < 100 && agent.running(); ++i)
        wait(100);
    wait(500);
    window->grabWindow().save(out + "/answer-" + size + ".png");

    // A past meeting, opened to review.
    engine.select("past-0");
    for (int i = 0; i < 50 && (engine.loading() || engine.transcript()->count() == 0); ++i)
        wait(100);
    wait(500);
    window->grabWindow().save(out + "/review-" + size + ".png");

    // The rest of a meeting's life: its transcript, its menu, sending it,
    // one already in Notion, one being drafted, and a call noticed.
    auto *pane = window->findChild<QObject *>("meetingPane");
    auto shot = [&](const QString &name, int ms = 500) {
        wait(ms);
        window->grabWindow().save(out + "/" + name + "-" + size + ".png");
    };
    pane->setProperty("tab", "transcript");
    shot("review-transcript");
    pane->setProperty("tab", "notes");
    wait(200);
    // A right-click on the second meeting in the list (the list shows from 1100 wide).
    if (window->width() >= 1100) {
        const QPointF at(150, 52 + 6 + 40 + 58 + 40 + 29);
        for (auto type : {QEvent::MouseButtonPress, QEvent::MouseButtonRelease}) {
            QMouseEvent e(type, at, window->mapToGlobal(at), Qt::RightButton,
                          type == QEvent::MouseButtonPress ? Qt::RightButton : Qt::NoButton, Qt::NoModifier);
            QGuiApplication::sendEvent(window, &e);
        }
        shot("menu", 300);
        QKeyEvent esc(QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier);
        QGuiApplication::sendEvent(window, &esc);
        wait(200);
    }
    QMetaObject::invokeMethod(window, "act", Q_ARG(QVariant, "email"), Q_ARG(QVariant, engine.selectedMeeting()));
    shot("email", 700);
    QMetaObject::invokeMethod(window->findChild<QObject *>("emailSheet"), "close");
    wait(200);
    QMetaObject::invokeMethod(window, "act", Q_ARG(QVariant, "send"), Q_ARG(QVariant, engine.selectedMeeting()));
    shot("send", 700);
    QKeyEvent esc(QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier);
    QGuiApplication::sendEvent(window, &esc);
    QMetaObject::invokeMethod(window->findChild<QObject *>("sendSheet"), "close");
    engine.select("past-1");
    shot("sent", 700);
    engine.select("past-2");
    shot("drafting", 700);
    QProcess::execute("curl", {"-s", "-o", "/dev/null", "-X", "POST", "-H", "Content-Type: application/json",
                               "-d", R"({"listening": false, "call": {"app": "Teams", "since": 1}})",
                               qEnvironmentVariable("SIDECAR_ENGINE") + "/_call"});
    engine.select(engine.current());
    shot("call", 900);
    QObject *palette = window->findChild<QObject *>("palette");
    QMetaObject::invokeMethod(palette, "open", Q_ARG(QVariant, true));
    shot("keys", 400);
    QMetaObject::invokeMethod(palette, "close");
    QMetaObject::invokeMethod(palette, "open", Q_ARG(QVariant, false));
    shot("palette", 400);
    for (const QChar c : QStringLiteral("harb")) {
        QKeyEvent press(QEvent::KeyPress, 0, Qt::NoModifier, QString(c));
        QGuiApplication::sendEvent(window, &press);
    }
    shot("palette-typed", 300);
    QMetaObject::invokeMethod(palette, "close");
    QMetaObject::invokeMethod(window, "act", Q_ARG(QVariant, QStringLiteral("merge")), Q_ARG(QVariant, engine.meetingById("past-0")));
    shot("merge", 400);
    QMetaObject::invokeMethod(palette, "close");
    window->findChild<QObject *>("search")->setProperty("text", "port");
    shot("search", 900);
    window->findChild<QObject *>("search")->setProperty("text", "");
    if (window->width() < 1100) {
        QMetaObject::invokeMethod(window->findChild<QObject *>("listDrawer"), "open");
        shot("drawer", 600);
        QMetaObject::invokeMethod(window->findChild<QObject *>("listDrawer"), "close");
        wait(400);
    }
    window->setProperty("view", "followups");
    shot("followups", 900);

    std::printf("%s: %d lines, %lld messages, %d warnings\n", qPrintable(size), engine.transcript()->count(),
                static_cast<long long>(agent.messages().size()), warnings);
    return check && warnings > 0 ? 1 : 0;
}
