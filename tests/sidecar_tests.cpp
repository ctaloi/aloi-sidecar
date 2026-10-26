#include <QJsonObject>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/agent.h"
#include "../src/engine.h"
#include "../src/instance.h"

class SidecarTests : public QObject {
    Q_OBJECT

    static QJsonObject segment(int id, const QString &speaker, const QString &text) {
        return {{"type", "segment"}, {"id", id}, {"speaker", speaker}, {"text", text},
                {"time", QString("10:00:%1").arg(id, 2, 10, QChar('0'))}, {"start", 1000.0 + id}};
    }

private slots:
    void transcriptFromEvents() {
        Engine engine("http://127.0.0.1:1");
        engine.handleEvent({{"type", "meeting"}, {"meeting", "2026-10-26_100000"}, {"path", "/x.jsonl"}});
        engine.handleEvent(segment(0, "Them", "Hello there"));
        engine.handleEvent(segment(1, "Them", "Second line"));
        engine.handleEvent(segment(2, "Chris", "Hi"));
        auto *t = engine.transcript();
        QCOMPARE(t->count(), 3);
        QCOMPARE(t->data(t->index(1), Transcript::RunStartRole).toBool(), false);
        QCOMPARE(t->data(t->index(2), Transcript::RunStartRole).toBool(), true);
        QCOMPARE(t->data(t->index(2), Transcript::MineRole).toBool(), true);
        QCOMPARE(t->textAfter(0), QString("[10:00:01] Them: Second line\n[10:00:02] Chris: Hi"));

        // A new meeting starts the transcript over.
        engine.handleEvent({{"type", "meeting"}, {"meeting", "2026-10-26_120000"}, {"path", "/y.jsonl"}});
        QCOMPARE(t->count(), 0);
        QCOMPARE(engine.meeting(), QString("2026-10-26_120000"));
    }

    void interimsComeAndGo() {
        Engine engine("http://127.0.0.1:1");
        engine.handleEvent({{"type", "interim"}, {"label", "Mic"}, {"speaker", "Chris"}, {"text", "so I"}});
        engine.handleEvent({{"type", "interim"}, {"label", "Mic"}, {"speaker", "Chris"}, {"text", "so I think"}});
        QCOMPARE(engine.interims().size(), 1);
        QCOMPARE(engine.interims().first().toMap().value("text").toString(), QString("so I think"));
        engine.handleEvent({{"type", "interim"}, {"label", "Mic"}, {"speaker", "Chris"}, {"text", ""}});
        QCOMPARE(engine.interims().size(), 0);
    }

    void listeningState() {
        Engine engine("http://127.0.0.1:1");
        QSignalSpy spy(&engine, &Engine::listeningChanged);
        engine.handleEvent({{"type", "state"}, {"listening", true}});
        QVERIFY(engine.listening());
        engine.handleEvent({{"type", "levels"}, {"channels", QJsonArray{QJsonObject{{"label", "Mic"}}}}});
        QCOMPARE(engine.channels().size(), 1);
        engine.handleEvent({{"type", "state"}, {"listening", false}});
        QVERIFY(!engine.listening());
        QCOMPARE(engine.channels().size(), 0);
        QCOMPARE(spy.count(), 2);
    }

    void promptCarriesOnlyNewLines() {
        QTemporaryDir state;
        Engine engine("http://127.0.0.1:1");
        engine.handleEvent({{"type", "meeting"}, {"meeting", "m"}, {"path", "/m.jsonl"}});
        Agent agent(engine.transcript(), "/bin/true", state.path());
        agent.setMeeting("m");
        QCOMPARE(agent.prompt("Anything?", true), QString("Nothing has been said in the meeting yet.\n\nChris asks: Anything?"));
        engine.handleEvent(segment(0, "Them", "Can you send pricing?"));
        const QString first = agent.prompt("What do I owe?", true);
        QVERIFY(first.startsWith("The meeting so far:\n<transcript>\n[10:00:00] Them: Can you send pricing?\n</transcript>"));
        QVERIFY(first.endsWith("Chris asks: What do I owe?"));
    }

    void argumentsStayReadOnly() {
        QTemporaryDir state;
        Agent agent(nullptr, "/bin/true", state.path());
        const QStringList args = agent.arguments("abc", false);
        QVERIFY(args.contains("dontAsk"));
        QVERIFY(args.contains("--strict-mcp-config"));
        QCOMPARE(args.at(args.indexOf("--setting-sources") + 1), QString("project,local"));
        QVERIFY(!args.at(args.indexOf("--tools") + 1).contains("Edit"));
        QVERIFY(!args.at(args.indexOf("--tools") + 1).contains("Write"));
        QCOMPARE(args.at(args.indexOf("--session-id") + 1), QString("abc"));
        QVERIFY(!args.contains("WebFetch"));  // in --tools, but never auto-allowed
    }

    void readOnlyCommands() {
        QVERIFY(Instance::readOnly("cat /etc/hostname"));
        QVERIFY(Instance::readOnly("grep -r foo ."));
        QVERIFY(!Instance::readOnly("cat x | sh"));
        QVERIFY(!Instance::readOnly("curl https://example.com"));
        QVERIFY(!Instance::readOnly("ls; rm -rf ~"));
        QVERIFY(!Instance::readOnly("echo $(whoami)"));
        QVERIFY(!Instance::readOnly(""));
    }

    void skillOfCommand() {
        QCOMPARE(Agent::skillOf("cd ~/.claude/skills/one-api-expert && python3 lookup.py 7165551212"), QString("one-api-expert"));
        QCOMPARE(Agent::skillOf("curl https://example.com"), QString());
    }
};

QTEST_GUILESS_MAIN(SidecarTests)
#include "sidecar_tests.moc"
