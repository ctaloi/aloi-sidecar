// Drives the real window offscreen against the stand-in engine and Claude,
// and saves what Chris would see: listening with the transcript, then an
// answer from the agent. --check fails on any QML warning.

#include <QDir>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickItem>
#include <functional>
#include <QQuickWindow>
#include <QProcess>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QTemporaryDir>
#include <QTimer>
#include <QtTest/QTest>
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
    // Further down Home: what's been learned, the map first, then with a
    // topic pinned, then what was decided and what's open.
    {
        auto *flick = window->findChild<QQuickItem *>("homeFlick");
        auto *learned = window->findChild<QQuickItem *>("learned");
        if (!flick || !learned || learned->property("topics").toList().isEmpty()) {
            std::fprintf(stderr, "Home has nothing learned to show.\n");
            ++warnings;
        } else {
            const auto scroll = [&](qreal y) {
                const qreal most = flick->property("contentHeight").toReal() - flick->height();
                flick->setProperty("contentY", qMax<qreal>(0, qMin(y, most)));
            };
            scroll(learned->y() - 8);
            wait(300);
            window->grabWindow().save(out + "/home-learned-" + size + ".png");
            learned->setProperty("pinned", learned->property("topics").toList().first().toMap().value("name"));
            wait(300);
            window->grabWindow().save(out + "/home-topic-" + size + ".png");
            learned->setProperty("pinned", QString());
            scroll(learned->y() + learned->height() - flick->height() + 40);
            wait(300);
            window->grabWindow().save(out + "/home-decided-" + size + ".png");
            scroll(0);
            wait(100);
            // Into a topic: its own page, then esc back home.
            const QString name = learned->property("topics").toList().first().toMap().value("name").toString();
            QMetaObject::invokeMethod(window, "openTopic", Q_ARG(QVariant, name));
            for (int i = 0; i < 30 && engine.topic().value("count").toInt() == 0; ++i)
                wait(100);
            wait(300);
            window->grabWindow().save(out + "/topic-" + size + ".png");
            if (window->property("view").toString() != "topic" || engine.topic().value("meetings").toList().isEmpty()) {
                std::fprintf(stderr, "The topic's page didn't open with its meetings.\n");
                ++warnings;
            }
            QMetaObject::invokeMethod(window, "goHome");
            wait(200);
        }
    }
    window->setProperty("view", "meetings");
    wait(400);
    window->grabWindow().save(out + "/listening-" + size + ".png");
    auto *meeting = window->findChild<QObject *>("meetingPane");
    if (meeting->property("tab").toString() != "transcript") {
        std::fprintf(stderr, "The live call didn't open on the transcript.\n");
        ++warnings;
    }
    // n during a call: the box beside the live lines, on the agent tab still.
    {
        meeting->setProperty("tab", "agent");
        const int before = engine.transcript()->notes().size();
        QMetaObject::invokeMethod(meeting, "note");
        wait(200);
        const auto press = [&](int key, const QString &text = {}) {
            QKeyEvent down(QEvent::KeyPress, key, Qt::NoModifier, text);
            QGuiApplication::sendEvent(window, &down);
        };
        for (const QChar c : QString("<b>Ask about the E911 address</b> & the lease"))
            press(0, QString(c));
        wait(100);
        window->grabWindow().save(out + "/live-note-typing-" + size + ".png");
        press(Qt::Key_Return);
        for (int i = 0; i < 30 && engine.transcript()->notes().size() == before; ++i)
            wait(100);
        if (engine.transcript()->notes().size() != before + 1 || meeting->property("tab").toString() != "agent") {
            std::fprintf(stderr, "A note typed during the call didn't land.\n");
            ++warnings;
        }
        press(Qt::Key_Escape);
        wait(300);
        window->grabWindow().save(out + "/live-notes-" + size + ".png");
    }
    window->findChild<QObject *>("meetingPane")->setProperty("tab", "transcript");
    wait(400);
    window->grabWindow().save(out + "/live-transcript-" + size + ".png");
    window->findChild<QObject *>("meetingPane")->setProperty("tab", "agent");
    wait(200);

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
    meeting->setProperty("tab", "transcript");
    auto *liveAsk = window->findChild<QObject *>("liveAsk");
    auto *askButton = window->findChild<QQuickItem *>("askLiveButton");
    QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier,
                      askButton->mapToScene(QPointF(askButton->width() / 2, askButton->height() / 2)).toPoint());
    wait(350);
    auto *input = window->activeFocusItem();
    const QString question = "Has anyone asked me something I haven't answered?";
    if (!liveAsk->property("visible").toBool() || !input || !input->inherits("QQuickTextInput")) {
        std::fprintf(stderr, "Ask AI didn't open with the question field focused.\n");
        ++warnings;
    } else {
        window->grabWindow().save(out + "/live-ask-" + size + ".png");
        agent.setWide(true);
        input->setProperty("text", question);
        QTest::keyClick(window, Qt::Key_Return);
    }
    for (int i = 0; i < 100 && agent.running(); ++i)
        wait(100);
    wait(500);
    const auto messages = agent.messages();
    if (agent.meeting() != engine.current() || agent.wide() || messages.size() != 2
        || messages.first().toMap().value("text").toString() != question
        || messages.last().toMap().value("text").toString().isEmpty()) {
        std::fprintf(stderr, "Ask AI didn't answer in the live meeting's conversation.\n");
        ++warnings;
    }
    window->grabWindow().save(out + "/live-ask-answer-" + size + ".png");
    QTest::keyClick(window, Qt::Key_Escape);
    wait(250);
    if (liveAsk->property("visible").toBool() || meeting->property("tab").toString() != "transcript") {
        std::fprintf(stderr, "Esc didn't close Ask AI and return to the transcript.\n");
        ++warnings;
    }
    meeting->setProperty("tab", "agent");
    wait(200);
    window->grabWindow().save(out + "/answer-" + size + ".png");

    // A past meeting, opened to review.
    engine.select("past-0");
    for (int i = 0; i < 50 && (engine.loading() || engine.transcript()->count() == 0); ++i)
        wait(100);
    wait(500);
    window->grabWindow().save(out + "/review-" + size + ".png");
    QTest::keyClick(window, Qt::Key_A, Qt::ControlModifier | Qt::ShiftModifier);
    wait(250);
    if (!liveAsk->property("visible").toBool() || engine.selected() != engine.current()
        || agent.messages() != messages) {
        std::fprintf(stderr, "The live Ask AI shortcut didn't reopen the call's conversation from a past meeting.\n");
        ++warnings;
    }
    engine.select("past-0");
    wait(250);
    if (liveAsk->property("visible").toBool()) {
        std::fprintf(stderr, "Ask AI stayed open after the transcript changed meetings.\n");
        ++warnings;
    }

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
    // The keys, pressed as Chris would: the same in every Aloi app. Each
    // ends where it should, or it counts as a warning and --check fails.
    QObject *keyRoot = window->findChild<QObject *>("keyRoot");
    auto press = [&](const QString &keys) {
        for (const QChar c : keys) {
            const bool shift = c.isUpper() || QStringLiteral("?>:").contains(c);
            QTest::keyClick(window, c.toLatin1(), shift ? Qt::ShiftModifier : Qt::NoModifier);
            wait(120);
        }
    };
    auto escape = [&] { QTest::keyClick(window, Qt::Key_Escape); wait(150); };
    auto expect = [&](const char *what, bool ok) {
        if (!ok) {
            ++warnings;
            std::fprintf(stderr, "keys: expected %s\n", what);
        }
    };
    auto view = [&] { return window->property("view").toString(); };
    QMetaObject::invokeMethod(keyRoot, "forceActiveFocus");
    wait(100);
    press("gh");
    expect("g h to go home", view() == "home");
    press("?");
    expect("? to list the keys", palette->property("visible").toBool() && palette->property("help").toBool());
    escape();
    expect("esc to close the keys", !palette->property("visible").toBool());
    press(";");
    expect("; to open the palette", palette->property("visible").toBool() && !palette->property("help").toBool());
    escape();
    engine.select("past-0");
    wait(300);
    press("gm");
    expect("g m to open the meeting", view() == "meetings");
    press(">");
    expect("> to ask the agent", pane->property("tab").toString() == "agent"
                                     && window->activeFocusItem() && window->activeFocusItem()->inherits("QQuickTextInput"));
    escape();
    escape();
    expect("esc, out of the ask box, then home", view() == "home");
    // Ticking a follow-up on Home checks it off and stays on Home.
    auto open = [&] {
        int n = 0;
        for (const QVariant &f : engine.followups())
            n += !f.toMap().value("done").toBool();
        return n;
    };
    // Repeater rows are only visual children, so findChildren misses them.
    std::function<QQuickItem *(QQuickItem *)> find = [&](QQuickItem *item) -> QQuickItem * {
        if (item->objectName() == "markDone" && item->isVisible())
            return item;
        for (QQuickItem *child : item->childItems())
            if (QQuickItem *found = find(child))
                return found;
        return nullptr;
    };
    // The follow-ups are near the foot of Home now: scroll down to them.
    if (auto *flick = window->findChild<QQuickItem *>("homeFlick")) {
        flick->setProperty("contentY", qMax<qreal>(0, flick->property("contentHeight").toReal() - flick->height()));
        wait(200);
    }
    QQuickItem *tick = find(window->contentItem());
    expect("a tick box on Home's follow-ups", tick);
    if (tick) {
        const int before = open();
        QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, tick->mapToScene(QPointF(8, 8)).toPoint());
        wait(300);
        expect("the tick to check the follow-up off", open() == before - 1);
        expect("the tick to stay on Home", view() == "home");
        QMetaObject::invokeMethod(keyRoot, "forceActiveFocus");
    }
    // Send all, as Chris would: asked, confirmed, and the bar along the
    // bottom says how far it's got and what came of it. (It did nothing at
    // all once: the action was dropped before it reached the engine.)
    {
        QObject *confirmBox = window->findChild<QObject *>("confirm");
        QObject *bar = window->findChild<QObject *>("bulkBar");
        QMetaObject::invokeMethod(window, "act", Q_ARG(QVariant, QStringLiteral("sendAll")), Q_ARG(QVariant, QVariant()));
        wait(200);
        expect("Send all to ask first", confirmBox && confirmBox->property("visible").toBool());
        QMetaObject::invokeMethod(confirmBox, "accept");
        for (int i = 0; i < 30 && !engine.bulk().value("running").toBool(); ++i)
            wait(50);
        expect("Send all to reach the engine", engine.bulk().value("running").toBool());
        expect("the bar to show while it sends", bar && bar->property("shown").toBool() && bar->property("running").toBool());
        wait(300);
        window->grabWindow().save(out + "/sending-" + size + ".png");
        for (int i = 0; i < 80 && engine.bulk().value("running").toBool(); ++i)
            wait(100);
        wait(300);
        expect("the send to finish", !engine.bulk().value("running").toBool() && engine.bulk().value("done").toInt() >= 1);
        expect("the bar to stay and say what came of it", bar && bar->property("shown").toBool());
        window->grabWindow().save(out + "/sending-done-" + size + ".png");
        bar->setProperty("closed", true);
        wait(100);
        QMetaObject::invokeMethod(keyRoot, "forceActiveFocus");
    }
    press("/");
    expect("/ to search", window->activeFocusItem() && window->activeFocusItem()->objectName() == "search");
    escape();
    press("gf");
    expect("g f for the follow-ups", view() == "followups");
    shot("followups", 900);

    std::printf("%s: %d lines, %lld messages, %d warnings\n", qPrintable(size), engine.transcript()->count(),
                static_cast<long long>(agent.messages().size()), warnings);
    return check && warnings > 0 ? 1 : 0;
}
