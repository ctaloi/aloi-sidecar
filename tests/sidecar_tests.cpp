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
    static QJsonObject meeting(const QString &id, const QString &state, double started) {
        return {{"id", id}, {"title", "Meeting " + id}, {"state", state}, {"started", started}, {"lines", 0}};
    }

    // A streamed answer changes its own row in place; nothing above it is
    // rebuilt, and only a different conversation resets the list.
    void messageModelUpdatesInPlace() {
        MessageModel model;
        auto msg = [](const QString &role, const QString &text) { return QVariantMap{{"role", role}, {"text", text}}; };
        QSignalSpy reset(&model, &QAbstractItemModel::modelReset);
        QSignalSpy inserted(&model, &QAbstractItemModel::rowsInserted);
        QSignalSpy changed(&model, &QAbstractItemModel::dataChanged);
        model.sync({msg("you", "Q"), msg("agent", "A")});
        QCOMPARE(model.rowCount(), 2);
        QCOMPARE(inserted.count(), 1);
        model.sync({msg("you", "Q"), msg("agent", "An")});
        model.sync({msg("you", "Q"), msg("agent", "Answer")});
        QCOMPARE(changed.count(), 2);
        QCOMPARE(changed.last().at(0).value<QModelIndex>().row(), 1);
        QCOMPARE(reset.count(), 0);
        QCOMPARE(model.data(model.index(1), MessageModel::MessageRole).toMap().value("text").toString(), QString("Answer"));
        model.sync({});
        QCOMPARE(reset.count(), 1);
        QCOMPARE(model.rowCount(), 0);
    }

    // Lines told apart by voice read as the voice's name, or "Voice 2".
    void voicesReadAsNames() {
        Transcript t;
        t.setLines({{0, "Them", "Hi", "10:00:00", 1, 1}, {1, "Them", "Hello", "10:00:01", 2, 2}, {2, "Chris", "Hey", "10:00:02", 3, 0}});
        t.setNames(QVariantMap{{"1", QVariantMap{{"name", "Hector"}, {"by", "hand"}}}});
        QCOMPARE(t.data(t.index(0), Transcript::WhoRole).toString(), QString("Hector"));
        QCOMPARE(t.data(t.index(1), Transcript::WhoRole).toString(), QString("Voice 2"));
        QVERIFY(t.data(t.index(1), Transcript::RunStartRole).toBool());  // another voice starts a run
        QVERIFY(t.textAfter(-1).contains("Hector: Hi"));
    }

    void liveMeetingFromEvents() {
        Engine engine("http://127.0.0.1:1");
        engine.handleEvent({{"type", "meetings"}, {"meetings", QJsonArray{meeting("b", "live", 2000), meeting("a", "ended", 1000)}}});
        engine.handleEvent({{"type", "state"}, {"listening", true}, {"current", "b"}});
        QCOMPARE(engine.current(), QString("b"));
        QCOMPARE(engine.selected(), QString("b"));  // the live meeting comes on screen
        QVERIFY(engine.listening());
        auto seg = [](int id, const QString &who, const QString &text, const QString &m) {
            QJsonObject s = segment(id, who, text);
            s.insert("meeting", m);
            return s;
        };
        engine.handleEvent(seg(0, "Them", "Hello there", "b"));
        engine.handleEvent(seg(1, "Them", "Second line", "b"));
        engine.handleEvent(seg(2, "Chris", "Hi", "b"));
        engine.handleEvent(seg(0, "Them", "From another meeting", "a"));  // not the live one: ignored
        auto *t = engine.transcript();
        QCOMPARE(t->count(), 3);
        QCOMPARE(t->data(t->index(1), Transcript::RunStartRole).toBool(), false);
        QCOMPARE(t->data(t->index(2), Transcript::RunStartRole).toBool(), true);
        QCOMPARE(t->data(t->index(2), Transcript::MineRole).toBool(), true);
        QCOMPARE(t->textAfter(0), QString("[10:00:01] Them: Second line\n[10:00:02] Chris: Hi"));
    }

    void reviewingAPastMeeting() {
        Engine engine("http://127.0.0.1:1");
        engine.handleEvent({{"type", "meetings"}, {"meetings", QJsonArray{meeting("b", "live", 2000), meeting("a", "ended", 1000)}}});
        engine.handleEvent({{"type", "state"}, {"listening", true}, {"current", "b"}});
        QJsonObject live = segment(0, "Them", "Live line");
        live.insert("meeting", "b");
        engine.handleEvent(live);
        engine.handleEvent({{"type", "interim"}, {"label", "Mic"}, {"speaker", "Chris"}, {"text", "so I"}});
        QCOMPARE(engine.interims().size(), 1);

        engine.select("a");
        QCOMPARE(engine.selected(), QString("a"));
        QCOMPARE(engine.transcript()->count(), 0);
        QCOMPARE(engine.interims().size(), 0);  // the live preview belongs to the live meeting
        QJsonObject old{{"id", 0}, {"speaker", "Them"}, {"text", "An old line"}, {"start", 1000.0}, {"end", 1003.0}};
        engine.handleMeeting({{"meeting", meeting("a", "ended", 1000)}, {"segments", QJsonArray{old}}});
        QCOMPARE(engine.transcript()->count(), 1);

        // Live lines keep coming in the background, and are there on the way back.
        QJsonObject more = segment(1, "Chris", "Another live line");
        more.insert("meeting", "b");
        engine.handleEvent(more);
        QCOMPARE(engine.transcript()->count(), 1);
        engine.select("b");
        QCOMPARE(engine.transcript()->count(), 2);
    }

    void meetingsStayNewestFirst() {
        Engine engine("http://127.0.0.1:1");
        engine.handleEvent({{"type", "meetings"}, {"meetings", QJsonArray{meeting("b", "ended", 2000), meeting("a", "ended", 1000)}}});
        engine.handleEvent({{"type", "meeting"}, {"meeting", meeting("c", "live", 3000)}});
        QCOMPARE(engine.meetings().first().toMap().value("id").toString(), QString("c"));
        QJsonObject renamed = meeting("b", "ended", 2000);
        renamed.insert("title", "Renamed");
        engine.handleEvent({{"type", "meeting"}, {"meeting", renamed}});
        QCOMPARE(engine.meetings().size(), 3);
        QCOMPARE(engine.meetingById("b").value("title").toString(), QString("Renamed"));
        engine.handleEvent({{"type", "meeting_removed"}, {"id", "c"}});
        QCOMPARE(engine.meetings().size(), 2);
    }

    void describeAMeeting() {
        QVariantMap m{{"title", "Weekly ops"}, {"started", 1793037600.0}, {"ended", 1793039400.0}, {"state", "ended"}};
        const QString about = Agent::describe(m);
        QVERIFY(about.startsWith("Meeting: \"Weekly ops\""));
        QVERIFY(about.contains("going back over it"));
        m["state"] = "live";
        QVERIFY(Agent::describe(m).contains("happening now"));
    }

    void interimsComeAndGo() {
        Engine engine("http://127.0.0.1:1");
        engine.handleEvent({{"type", "meetings"}, {"meetings", QJsonArray{meeting("b", "live", 2000)}}});
        engine.handleEvent({{"type", "state"}, {"listening", true}, {"current", "b"}});
        engine.handleEvent({{"type", "interim"}, {"label", "Mic"}, {"speaker", "Chris"}, {"text", "so I"}});
        engine.handleEvent({{"type", "interim"}, {"label", "Mic"}, {"speaker", "Chris"}, {"text", "so I think"}});
        QCOMPARE(engine.interims().size(), 1);
        QCOMPARE(engine.interims().first().toMap().value("text").toString(), QString("so I think"));
        engine.handleEvent({{"type", "interim"}, {"label", "Mic"}, {"speaker", "Chris"}, {"text", ""}});
        QCOMPARE(engine.interims().size(), 0);
    }

    void listeningState() {
        Engine engine("http://127.0.0.1:1");
        QSignalSpy spy(&engine, &Engine::stateChanged);
        engine.handleEvent({{"type", "state"}, {"listening", true}, {"current", "m"}});
        QVERIFY(engine.listening());
        engine.handleEvent({{"type", "levels"}, {"channels", QJsonArray{QJsonObject{{"label", "Mic"}}}}});
        QCOMPARE(engine.channels().size(), 1);
        engine.handleEvent({{"type", "state"}, {"listening", false}});
        QVERIFY(!engine.listening());
        QCOMPARE(engine.channels().size(), 0);
        QCOMPARE(spy.count(), 2);
        QCOMPARE(engine.current(), QString());
    }

    void promptCarriesOnlyNewLines() {
        QTemporaryDir state;
        Engine engine("http://127.0.0.1:1");
        Agent agent(engine.transcript(), "/bin/true", state.path());
        agent.setMeeting("m", "Meeting: \"Test\", now. It's happening now.");
        QCOMPARE(agent.prompt("Anything?", true),
                 QString("Meeting: \"Test\", now. It's happening now.\n\nNothing has been said in the meeting yet.\n\nChris asks: Anything?"));
        engine.handleEvent(segment(0, "Them", "Can you send pricing?"));
        const QString first = agent.prompt("What do I owe?", true);
        QVERIFY(first.contains("The meeting so far:\n<transcript>\n[10:00:00] Them: Can you send pricing?\n</transcript>"));
        // Later questions carry only what's new, without the meeting line again.
        QVERIFY(!agent.prompt("Again?", false).contains("Meeting:"));
        QVERIFY(first.endsWith("Chris asks: What do I owe?"));
    }

    void wideQuestionsSearchEveryMeeting() {
        QTemporaryDir state, meetings;
        qputenv("SIDECAR_MEETINGS", meetings.path().toUtf8());
        Engine engine("http://127.0.0.1:1");
        Agent agent(engine.transcript(), "/bin/true", state.path());
        agent.setMeeting("m", "Meeting: \"Test\"");
        QVERIFY(!agent.prompt("Anything?", true).contains(meetings.path()));
        agent.setWide(true);
        const QString wide = agent.prompt("When did Amy mention pricing?", true);
        QVERIFY(wide.contains(meetings.path()));
        QVERIFY(wide.endsWith("Chris asks: When did Amy mention pricing?"));
        // Every meeting is readable to the agent.
        const QStringList args = agent.arguments("abc", false);
        QVERIFY(args.contains(meetings.path()));
        qunsetenv("SIDECAR_MEETINGS");
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
