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
// /events, and the switch that turns listening on and off. The engine
// replays the whole meeting to every new connection, so a reconnect simply
// starts the transcript over.
class Engine : public QObject {
    Q_OBJECT
    Q_PROPERTY(Transcript *transcript READ transcript CONSTANT)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(bool listening READ listening NOTIFY listeningChanged)
    Q_PROPERTY(QString meeting READ meeting NOTIFY meetingChanged)
    Q_PROPERTY(QString meetingPath READ meetingPath NOTIFY meetingChanged)
    // [{label, speaker, level, alive, speaking}], a few times a second while listening.
    Q_PROPERTY(QVariantList channels READ channels NOTIFY channelsChanged)
    // [{label, speaker, text}]: what each channel is saying right now, before
    // it settles into a line.
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
    QString meeting() const { return m_meeting; }
    QString meetingPath() const { return m_meetingPath; }
    QVariantList channels() const { return m_channels; }
    QVariantList interims() const;
    int echoes() const { return m_echoes; }
    QString error() const { return m_error; }

    Q_INVOKABLE void connectToEngine();
    Q_INVOKABLE void setListening(bool on);
    Q_INVOKABLE void toggleListening() { setListening(!m_listening); }
    Q_INVOKABLE void newMeeting();
    // When the window closes: stop listening and wait (briefly) for the
    // engine to say so, so nothing is heard with the app closed.
    void stopListeningNow();
    // Listen as soon as the engine is reachable (the app was opened for a call).
    void setListenOnConnect(bool on) { m_listenOnConnect = on; }

    // One event from the stream, as the engine sends it. Public for tests.
    void handleEvent(const QJsonObject &event);

signals:
    void connectedChanged();
    void listeningChanged();
    void meetingChanged();
    void channelsChanged();
    void interimsChanged();
    void echoesChanged();
    void errorChanged();

private:
    void setConnected(bool on);
    void setError(const QString &error);
    void post(const QString &path, const QJsonObject &body);
    void startService();
    void retry();

    QUrl m_url;
    QNetworkAccessManager m_network;
    QPointer<QNetworkReply> m_stream;
    QByteArray m_buffer;
    QTimer m_retry;
    Transcript m_transcript;
    bool m_connected = false;
    bool m_listening = false;
    bool m_listenOnConnect = false;
    int m_refusals = 0;
    QString m_meeting, m_meetingPath, m_error;
    QVariantList m_channels;
    QList<QVariantMap> m_interims;
    int m_echoes = 0;
};
