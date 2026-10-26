#include "engine.h"

#include <QEventLoop>
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
    if (m_stream) {
        m_stream->disconnect(this);
        m_stream->abort();
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
            // A fresh connection replays the meeting from the top.
            m_transcript.clear();
            m_interims.clear();
            emit interimsChanged();
            setConnected(true);
            m_refusals = 0;
            setError({});
            if (m_listenOnConnect) {
                m_listenOnConnect = false;
                setListening(true);
            }
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
        retry();
    });
}

void Engine::retry() {
    m_retry.start();
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
        emit listeningChanged();
    }
    emit connectedChanged();
}

void Engine::setError(const QString &error) {
    if (m_error == error)
        return;
    m_error = error;
    emit errorChanged();
}

void Engine::handleEvent(const QJsonObject &event) {
    const QString type = event.value("type").toString();
    if (type == "segment") {
        m_transcript.append({event.value("id").toInt(), event.value("speaker").toString(),
                             event.value("text").toString(), event.value("time").toString(),
                             event.value("start").toDouble()});
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
    } else if (type == "state") {
        const bool on = event.value("listening").toBool();
        if (!on && !m_channels.isEmpty()) {
            m_channels.clear();
            emit channelsChanged();
        }
        if (!on && !m_interims.isEmpty()) {
            m_interims.clear();
            emit interimsChanged();
        }
        if (on != m_listening) {
            m_listening = on;
            emit listeningChanged();
        }
    } else if (type == "meeting") {
        const QString name = event.value("meeting").toString();
        if (name != m_meeting) {
            // A new meeting's lines follow this event; an old one's were replayed.
            m_transcript.clear();
            m_meeting = name;
            m_meetingPath = event.value("path").toString();
            emit meetingChanged();
        }
    } else if (type == "echo_dropped") {
        ++m_echoes;
        emit echoesChanged();
    }
}

QVariantList Engine::interims() const {
    QVariantList out;
    for (const auto &i : m_interims)
        out << i;
    return out;
}

void Engine::post(const QString &path, const QJsonObject &body) {
    QNetworkRequest request(m_url.resolved(QUrl(path)));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QNetworkReply *reply = m_network.post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
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
    post("/listen", QJsonObject{{"on", on}});
}

void Engine::newMeeting() {
    post("/meeting/new", {});
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
