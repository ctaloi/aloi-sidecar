#include "engine.h"

#include <QClipboard>
#include <QDateTime>
#include <QEventLoop>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>

#include "tools.h"

static const char *Me = "Chris";

QVariant Transcript::data(const QModelIndex &index, int role) const {
    if (!index.isValid() || index.row() >= m_lines.size())
        return {};
    const Line &l = m_lines.at(index.row());
    switch (role) {
    case IdRole: return l.id;
    case SpeakerRole: return l.speaker;
    case TextRole: return l.text;
    case TimeRole: return l.time;
    case StartRole: return l.start;
    case MineRole: return l.speaker == Me;
    // The first of a run of lines from one side, which shows the name.
    case RunStartRole: return index.row() == 0 || m_lines.at(index.row() - 1).speaker != l.speaker;
    }
    return {};
}

QHash<int, QByteArray> Transcript::roleNames() const {
    return {{IdRole, "lineId"}, {SpeakerRole, "speaker"}, {TextRole, "text"},
            {TimeRole, "time"}, {StartRole, "start"}, {MineRole, "mine"}, {RunStartRole, "runStart"}};
}

void Transcript::append(const Line &line) {
    beginInsertRows({}, m_lines.size(), m_lines.size());
    m_lines << line;
    endInsertRows();
    emit countChanged();
}

void Transcript::clear() {
    if (m_lines.isEmpty())
        return;
    beginResetModel();
    m_lines.clear();
    endResetModel();
    emit countChanged();
}

void Transcript::setLines(const QList<Line> &lines) {
    beginResetModel();
    m_lines = lines;
    endResetModel();
    emit countChanged();
}

QString Transcript::textAfter(int id) const {
    QStringList rows;
    for (const auto &l : m_lines)
        if (l.id > id)
            rows << QString("[%1] %2: %3").arg(l.time, l.speaker, l.text);
    return rows.join('\n');
}

Engine::Engine(const QString &url, QObject *parent)
    : QObject(parent),
      m_url(!url.isEmpty() ? url : qEnvironmentVariable("SIDECAR_ENGINE", "http://127.0.0.1:8777")) {
    m_retry.setSingleShot(true);
    m_retry.setInterval(2000);
    connect(&m_retry, &QTimer::timeout, this, &Engine::connectToEngine);
}

Engine::~Engine() {
    for (QNetworkReply *reply : {m_stream.data(), m_fetch.data()}) {
        if (reply) {
            reply->disconnect(this);
            reply->abort();
        }
    }
}

void Engine::connectToEngine() {
    if (m_stream)
        return;
    QNetworkRequest request(m_url.resolved(QUrl("/events")));
    request.setRawHeader("Accept", "text/event-stream");
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
    request.setTransferTimeout(0);
    m_buffer.clear();
    m_stream = m_network.get(request);

    connect(m_stream, &QNetworkReply::readyRead, this, [this] {
        if (!m_connected) {
            // A fresh connection replays the live meeting from the top.
            m_live.clear();
            m_interims.clear();
            emit interimsChanged();
            setConnected(true);
            m_refusals = 0;
            setError({});
        }
        m_buffer += m_stream->readAll();
        // Server-sent events: blocks split by a blank line, data on "data:" lines.
        int end;
        while ((end = m_buffer.indexOf("\n\n")) >= 0) {
            const QByteArray block = m_buffer.left(end);
            m_buffer.remove(0, end + 2);
            for (const QByteArray &row : block.split('\n'))
                if (row.startsWith("data: "))
                    handleEvent(QJsonDocument::fromJson(row.mid(6)).object());
        }
        if (m_listenOnConnect) {
            m_listenOnConnect = false;
            setListening(true);
        }
    });
    connect(m_stream, &QNetworkReply::finished, this, [this] {
        const bool refused = m_stream->error() == QNetworkReply::ConnectionRefusedError;
        m_stream->deleteLater();
        m_stream = nullptr;
        setConnected(false);
        m_channels.clear();
        emit channelsChanged();
        if (!refused)
            m_refusals = 0;
        else if (m_refusals++ == 0)
            startService();  // not running: start it once, then give it time to load the model
        else if (m_refusals > 8)
            setError(tr("The engine isn't running. Start it with: systemctl --user start aloi-sidecar-engine"));
        m_retry.start();
    });
}

void Engine::startService() {
    auto *process = new QProcess(this);
    process->setProcessEnvironment(toolEnvironment());
    connect(process, &QProcess::finished, process, &QObject::deleteLater);
    connect(process, &QProcess::errorOccurred, process, &QObject::deleteLater);
    process->start("systemctl", {"--user", "start", "aloi-sidecar-engine.service"});
    setError(tr("Starting the engine…"));
}

void Engine::setConnected(bool on) {
    if (m_connected == on)
        return;
    m_connected = on;
    if (!on && m_listening) {
        m_listening = false;
        emit stateChanged();
    }
    emit connectedChanged();
}

void Engine::setError(const QString &error) {
    if (m_error == error)
        return;
    m_error = error;
    emit errorChanged();
}

void Engine::setLoading(bool on) {
    if (m_loading == on)
        return;
    m_loading = on;
    emit loadingChanged();
}

Transcript::Line Engine::lineFrom(const QJsonObject &s) {
    return {s.value("id").toInt(), s.value("speaker").toString(), s.value("text").toString(),
            s.value("time").toString(), s.value("start").toDouble()};
}

QVariantMap Engine::meetingById(const QString &id) const {
    for (const auto &m : m_meetings)
        if (m.toMap().value("id").toString() == id)
            return m.toMap();
    return {};
}

void Engine::upsert(const QVariantMap &meeting) {
    const QString id = meeting.value("id").toString();
    for (int i = 0; i < m_meetings.size(); ++i) {
        if (m_meetings[i].toMap().value("id").toString() == id) {
            m_meetings[i] = meeting;
            emit meetingsChanged();
            if (id == m_selected)
                emit selectedMeetingChanged();
            return;
        }
    }
    // Newest first: a new meeting goes on top.
    int at = 0;
    while (at < m_meetings.size() && m_meetings[at].toMap().value("started").toDouble() > meeting.value("started").toDouble())
        ++at;
    m_meetings.insert(at, meeting);
    emit meetingsChanged();
}

void Engine::handleEvent(const QJsonObject &event) {
    const QString type = event.value("type").toString();
    if (type == "segment") {
        const QString meeting = event.value("meeting").toString();
        if (meeting != m_current)
            return;
        const auto line = lineFrom(event);
        m_live << line;
        if (m_selected == m_current)
            m_transcript.append(line);
    } else if (type == "interim") {
        const QString label = event.value("label").toString(), text = event.value("text").toString();
        for (int i = 0; i < m_interims.size(); ++i) {
            if (m_interims[i].value("label") == label) {
                if (text.isEmpty())
                    m_interims.removeAt(i);
                else
                    m_interims[i]["text"] = text;
                emit interimsChanged();
                return;
            }
        }
        if (!text.isEmpty()) {
            m_interims << QVariantMap{{"label", label}, {"speaker", event.value("speaker").toString()}, {"text", text}};
            emit interimsChanged();
        }
    } else if (type == "levels") {
        m_channels = event.value("channels").toArray().toVariantList();
        emit channelsChanged();
    } else if (type == "meetings") {
        m_meetings = event.value("meetings").toArray().toVariantList();
        emit meetingsChanged();
        emit selectedMeetingChanged();
    } else if (type == "meeting") {
        upsert(event.value("meeting").toObject().toVariantMap());
    } else if (type == "meeting_removed") {
        const QString id = event.value("id").toString();
        for (int i = 0; i < m_meetings.size(); ++i)
            if (m_meetings[i].toMap().value("id").toString() == id)
                m_meetings.removeAt(i--);
        emit meetingsChanged();
        if (id == m_selected) {
            m_chosen = false;
            select(m_meetings.isEmpty() ? QString() : m_meetings.first().toMap().value("id").toString());
        }
    } else if (type == "state") {
        const bool on = event.value("listening").toBool();
        const QString current = event.value("current").toString();
        if (!on) {
            if (!m_channels.isEmpty()) {
                m_channels.clear();
                emit channelsChanged();
            }
            if (!m_interims.isEmpty()) {
                m_interims.clear();
                emit interimsChanged();
            }
        }
        const bool newMeeting = current != m_current;
        if (newMeeting)
            m_live.clear();
        if (on != m_listening || newMeeting) {
            m_listening = on;
            m_current = current;
            emit stateChanged();
        }
        // A new meeting comes on screen, unless Chris is reading another one.
        // With nothing chosen yet, the newest meeting is shown.
        if (!current.isEmpty() && (newMeeting && !m_chosen))
            showLive();
        else if (m_selected.isEmpty() && !m_meetings.isEmpty())
            select(current.isEmpty() ? m_meetings.first().toMap().value("id").toString() : current);
    } else if (type == "echo_dropped") {
        ++m_echoes;
        emit echoesChanged();
    }
}

void Engine::showLive() {
    if (m_selected != m_current) {
        m_selected = m_current;
        emit selectedChanged();
        emit selectedMeetingChanged();
        emit interimsChanged();
    }
    if (m_fetch) {
        m_fetch->disconnect(this);
        m_fetch->abort();
    }
    setLoading(false);
    m_transcript.setLines(m_live);
}

void Engine::select(const QString &id) {
    if (id.isEmpty())
        return;
    m_chosen = id != m_current;
    if (id == m_current) {
        showLive();
        return;
    }
    if (id == m_selected && !m_loading)
        return;
    m_selected = id;
    emit selectedChanged();
    emit selectedMeetingChanged();
    emit interimsChanged();
    m_transcript.clear();
    if (m_fetch) {
        m_fetch->disconnect(this);
        m_fetch->abort();
    }
    setLoading(true);
    QNetworkRequest request(m_url.resolved(QUrl("/meeting/" + QString::fromUtf8(QUrl::toPercentEncoding(id)))));
    m_fetch = m_network.get(request);
    connect(m_fetch, &QNetworkReply::finished, this, [this, reply = m_fetch.data()] {
        reply->deleteLater();
        if (reply != m_fetch)
            return;
        m_fetch = nullptr;
        setLoading(false);
        if (reply->error() != QNetworkReply::NoError) {
            setError(tr("Couldn't open that meeting: %1").arg(reply->errorString()));
            return;
        }
        handleMeeting(QJsonDocument::fromJson(reply->readAll()).object());
    });
}

void Engine::handleMeeting(const QJsonObject &reply) {
    const QVariantMap meeting = reply.value("meeting").toObject().toVariantMap();
    if (meeting.value("id").toString() != m_selected)
        return;
    QList<Transcript::Line> lines;
    for (const auto &value : reply.value("segments").toArray()) {
        QJsonObject s = value.toObject();
        // Stored lines have no display time; the engine adds it only to live events.
        if (!s.contains("time"))
            s.insert("time", QDateTime::fromSecsSinceEpoch(qint64(s.value("start").toDouble())).toString("HH:mm:ss"));
        lines << lineFrom(s);
    }
    m_transcript.setLines(lines);
    upsert(meeting);
}

QVariantList Engine::interims() const {
    QVariantList out;
    if (m_selected == m_current)
        for (const auto &i : m_interims)
            out << i;
    return out;
}

void Engine::post(const QString &path, const QJsonObject &body, const QByteArray &verb) {
    QNetworkRequest request(m_url.resolved(QUrl(path)));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QNetworkReply *reply = m_network.sendCustomRequest(request, verb, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        if (reply->error() != QNetworkReply::NoError)
            setError(tr("The engine didn't answer: %1").arg(reply->errorString()));
        reply->deleteLater();
    });
}

void Engine::setListening(bool on) {
    if (!m_connected) {
        m_listenOnConnect = on;
        return;
    }
    if (on)
        m_chosen = false;  // listening brings the live meeting on screen
    post("/listen", QJsonObject{{"on", on}});
}

void Engine::startMeeting(const QString &title) {
    m_chosen = false;
    QJsonObject body;
    if (!title.trimmed().isEmpty())
        body.insert("title", title.trimmed());
    post("/meeting/start", body);
}

void Engine::endMeeting() {
    post("/meeting/end", {});
}

void Engine::rename(const QString &id, const QString &title) {
    if (title.trimmed().isEmpty())
        return;
    post("/meeting/" + QString::fromUtf8(QUrl::toPercentEncoding(id)), QJsonObject{{"title", title.trimmed()}}, "PATCH");
}

void Engine::copyToClipboard(const QString &text) const {
    QGuiApplication::clipboard()->setText(text);
}

void Engine::stopListeningNow() {
    if (!m_connected || !m_listening)
        return;
    QNetworkRequest request(m_url.resolved(QUrl("/listen")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setTransferTimeout(3000);
    QNetworkReply *reply = m_network.post(request, QByteArray(R"({"on":false})"));
    QEventLoop wait;
    connect(reply, &QNetworkReply::finished, &wait, &QEventLoop::quit);
    wait.exec();
    reply->deleteLater();
}
