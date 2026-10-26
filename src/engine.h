#pragma once

#include <QAbstractListModel>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QUrl>
#include <QVariantList>

class QNetworkReply;

// The meeting's lines, in order, as the window's transcript list.
class Transcript : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Role { IdRole = Qt::UserRole + 1, SpeakerRole, TextRole, TimeRole, StartRole, MineRole, RunStartRole };
    using QAbstractListModel::QAbstractListModel;

    int rowCount(const QModelIndex &parent = {}) const override { return parent.isValid() ? 0 : m_lines.size(); }
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;
    int count() const { return m_lines.size(); }

    struct Line {
        int id = -1;
        QString speaker, text, time;
        double start = 0;
    };
    void append(const Line &line);
    void clear();
    void setLines(const QList<Line> &lines);
    const QList<Line> &lines() const { return m_lines; }
    // The lines after id, one per row as "[time] speaker: text", for the agent.
    QString textAfter(int id) const;
    int lastId() const { return m_lines.isEmpty() ? -1 : m_lines.last().id; }

signals:
    void countChanged();

private:
    QList<Line> m_lines;
};

// The engine (engine/engine.py, a systemd user service) hears the meeting
// and transcribes it. This is its other end: the event stream from
// /events, the meetings it keeps, and the switches that start, pause and
// end one. The engine replays everything to every new connection, so a
// reconnect simply starts over.
//
// Two meetings matter at once: the current one (live or paused, if any),
// whose lines arrive as they're said, and the selected one, which is on
// screen and which the agent is asked about. They're the same meeting
// during a call; afterwards any past meeting can be selected to review.
class Engine : public QObject {
    Q_OBJECT
    Q_PROPERTY(Transcript *transcript READ transcript CONSTANT)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(bool listening READ listening NOTIFY stateChanged)
    // The live or paused meeting's id, or empty between meetings.
    Q_PROPERTY(QString current READ current NOTIFY stateChanged)
    // Every meeting, newest first: [{id, title, started, ended, state, lines, event, people, notion}].
    Q_PROPERTY(QVariantList meetings READ meetings NOTIFY meetingsChanged)
    Q_PROPERTY(QString selected READ selected NOTIFY selectedChanged)
    Q_PROPERTY(QVariantMap selectedMeeting READ selectedMeeting NOTIFY selectedMeetingChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    // [{label, speaker, level, alive, speaking}], a few times a second while listening.
    Q_PROPERTY(QVariantList channels READ channels NOTIFY channelsChanged)
    // [{label, speaker, text}]: what each channel is saying right now, before
    // it settles into a line. Only for the current meeting.
    Q_PROPERTY(QVariantList interims READ interims NOTIFY interimsChanged)
    Q_PROPERTY(int echoes READ echoes NOTIFY echoesChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
    // url: the engine's address; empty uses SIDECAR_ENGINE or 127.0.0.1:8777.
    explicit Engine(const QString &url = {}, QObject *parent = nullptr);
    ~Engine() override;

    Transcript *transcript() { return &m_transcript; }
    bool connected() const { return m_connected; }
    bool listening() const { return m_listening; }
    QString current() const { return m_current; }
    QVariantList meetings() const { return m_meetings; }
    QString selected() const { return m_selected; }
    QVariantMap selectedMeeting() const { return meetingById(m_selected); }
    bool loading() const { return m_loading; }
    QVariantList channels() const { return m_channels; }
    QVariantList interims() const;
    int echoes() const { return m_echoes; }
    QString error() const { return m_error; }

    Q_INVOKABLE QVariantMap meetingById(const QString &id) const;
    Q_INVOKABLE void connectToEngine();
    // Space: listening on or off. With no meeting on, listening starts one.
    Q_INVOKABLE void setListening(bool on);
    Q_INVOKABLE void toggleListening() { setListening(!m_listening); }
    // A new meeting, ending the current one; title empty for "Call at 14:05".
    Q_INVOKABLE void startMeeting(const QString &title = {});
    Q_INVOKABLE void endMeeting();
    Q_INVOKABLE void rename(const QString &id, const QString &title);
    // Show a meeting (and point the agent at it).
    Q_INVOKABLE void select(const QString &id);
    // The selected meeting's transcript as plain text, for the clipboard.
    Q_INVOKABLE QString transcriptText() const { return m_transcript.textAfter(-1); }
    Q_INVOKABLE void copyToClipboard(const QString &text) const;
    // When the window closes: stop listening and wait (briefly) for the
    // engine to say so, so nothing is heard with the app closed.
    void stopListeningNow();
    // Listen as soon as the engine is reachable (the app was opened for a call).
    void setListenOnConnect(bool on) { m_listenOnConnect = on; }

    // One event from the stream, as the engine sends it. Public for tests.
    void handleEvent(const QJsonObject &event);
    // A past meeting's lines, as GET /meeting/<id> returns them. Public for tests.
    void handleMeeting(const QJsonObject &reply);

signals:
    void connectedChanged();
    void stateChanged();
    void meetingsChanged();
    void selectedChanged();
    void selectedMeetingChanged();
    void loadingChanged();
    void channelsChanged();
    void interimsChanged();
    void echoesChanged();
    void errorChanged();

private:
    void setConnected(bool on);
    void setError(const QString &error);
    void setLoading(bool on);
    void post(const QString &path, const QJsonObject &body, const QByteArray &verb = "POST");
    void startService();
    void upsert(const QVariantMap &meeting);
    void showLive();
    static Transcript::Line lineFrom(const QJsonObject &segment);

    QUrl m_url;
    QNetworkAccessManager m_network;
    QPointer<QNetworkReply> m_stream;
    QPointer<QNetworkReply> m_fetch;
    QByteArray m_buffer;
    QTimer m_retry;
    Transcript m_transcript;
    // The current meeting's lines, kept whether or not it's on screen.
    QList<Transcript::Line> m_live;
    bool m_connected = false;
    bool m_listening = false;
    bool m_listenOnConnect = false;
    bool m_loading = false;
    bool m_chosen = false;  // Chris picked a meeting, so a new one doesn't take over the screen
    int m_refusals = 0;
    QString m_current, m_selected, m_error;
    QVariantList m_meetings;
    QVariantList m_channels;
    QList<QVariantMap> m_interims;
    int m_echoes = 0;
};
