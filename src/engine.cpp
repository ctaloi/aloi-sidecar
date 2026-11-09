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
#include <QStandardPaths>
#include <QUrlQuery>

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
    // The first of a run of lines from one side (or one voice), which shows the name.
    case RunStartRole: return index.row() == 0 || m_lines.at(index.row() - 1).speaker != l.speaker
                              || m_lines.at(index.row() - 1).voice != l.voice;
    case VoiceRole: return l.voice;
    case WhoRole: return who(l);
    }
    return {};
}

QHash<int, QByteArray> Transcript::roleNames() const {
    return {{IdRole, "lineId"}, {SpeakerRole, "speaker"}, {TextRole, "text"},
            {TimeRole, "time"}, {StartRole, "start"}, {MineRole, "mine"}, {RunStartRole, "runStart"},
            {VoiceRole, "voice"}, {WhoRole, "voiceName"}};
}

QString Transcript::who(const Line &l) const {
    if (l.voice <= 0)
        return l.speaker;
    const QString name = m_names.value(QString::number(l.voice)).toMap().value("name").toString();
    return name.isEmpty() ? QStringLiteral("Voice %1").arg(l.voice) : name;
}

void Transcript::setNames(const QVariantMap &names) {
    if (names == m_names)
        return;
    m_names = names;
    if (!m_lines.isEmpty())
        emit dataChanged(index(0), index(int(m_lines.size()) - 1), {WhoRole});
}

void Transcript::append(const Line &line) {
    beginInsertRows({}, m_lines.size(), m_lines.size());
    m_lines << line;
    endInsertRows();
    emit countChanged();
    if (line.speaker == "Note")
        emit notesChanged();
}

void Transcript::clear() {
    if (m_lines.isEmpty())
        return;
    beginResetModel();
    m_lines.clear();
    endResetModel();
    emit countChanged();
    emit notesChanged();
}

void Transcript::setLines(const QList<Line> &lines) {
    beginResetModel();
    m_lines = lines;
    endResetModel();
    emit countChanged();
    emit notesChanged();
}

QVariantList Transcript::notes() const {
    QVariantList out;
    for (const auto &l : m_lines)
        if (l.speaker == "Note")
            out << QVariantMap{{"id", l.id}, {"time", l.time}, {"text", l.text}};
    return out;
}

QString Transcript::textAfter(int id) const {
    QStringList rows;
    for (const auto &l : m_lines)
        if (l.id > id)
            rows << QString("[%1] %2: %3").arg(l.time, who(l), l.text);
    return rows.join('\n');
}

int Transcript::rowOf(int id) const {
    // Lines are numbered in order from 0, so the row is usually the id.
    if (id >= 0 && id < m_lines.size() && m_lines.at(id).id == id)
        return id;
    for (int i = 0; i < m_lines.size(); ++i)
        if (m_lines.at(i).id == id)
            return i;
    return -1;
}

double Transcript::startOf(int id) const {
    const int row = rowOf(id);
    return row < 0 ? 0 : m_lines.at(row).start;
}

Engine::Engine(const QString &url, QObject *parent)
    : QObject(parent),
      m_url(!url.isEmpty() ? url : qEnvironmentVariable("SIDECAR_ENGINE", "http://127.0.0.1:8777")) {
    m_retry.setSingleShot(true);
    m_retry.setInterval(2000);
    connect(&m_retry, &QTimer::timeout, this, &Engine::connectToEngine);
    // The transcript names voices the way the meeting on screen does.
    connect(this, &Engine::selectedMeetingChanged, this, [this] {
        m_transcript.setNames(selectedMeeting().value("voices").toMap());
    });
}

Engine::~Engine() {
    for (QNetworkReply *reply : {m_stream.data(), m_fetch.data(), m_wrapupFetch.data(), m_candidatesFetch.data()}) {
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
            s.value("time").toString(), s.value("start").toDouble(), s.value("voice").toInt()};
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
        const auto line = lineFrom(event);
        if (meeting == m_current) {
            m_live << line;
            if (m_selected == m_current)
                m_transcript.append(line);
        } else if (meeting == m_selected && !m_loading) {
            m_transcript.append(line);  // a note added to a meeting that's over
        }
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
        const QVariantMap call = event.value("call").toObject().toVariantMap();
        const QVariantMap settings = event.value("settings").toObject().toVariantMap();
        const int open = event.value("followups_open").toInt();
        const QVariantMap bulk = event.value("bulk").toObject().toVariantMap();
        if (event.contains("bulk") && bulk != m_bulk) {  // a window opened part way through Send all
            m_bulk = bulk;
            emit bulkChanged();
        }
        if (on != m_listening || newMeeting || call != m_call || settings != m_settings || open != m_followupsOpen) {
            m_listening = on;
            m_current = current;
            m_call = call;
            m_settings = settings;
            m_followupsOpen = open;
            emit stateChanged();
        }
        // A new meeting comes on screen, unless Chris is reading another one.
        // With nothing chosen yet, the newest meeting is shown.
        if (!current.isEmpty() && (newMeeting && !m_chosen))
            showLive();
        else if (m_selected.isEmpty() && !m_meetings.isEmpty())
            select(current.isEmpty() ? m_meetings.first().toMap().value("id").toString() : current);
    } else if (type == "wrapup") {
        if (event.value("id").toString() == m_selected) {
            m_wrapup = event.value("wrapup").toObject().toVariantMap();
            emit wrapupChanged();
        }
    } else if (type == "takeaways") {
        if (event.value("id").toString() == m_selected) {
            m_takeaways = event.value("takeaways").toObject().toVariantMap();
            emit wrapupChanged();
        }
    } else if (type == "bulk") {
        m_bulk = event.value("bulk").toObject().toVariantMap();
        emit bulkChanged();
    } else if (type == "followups") {
        fetchFollowups();
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
        fetchWrapup(m_current);
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
    fetchWrapup(id);
    m_transcript.clear();
    if (m_fetch) {
        m_fetch->disconnect(this);
        m_fetch->abort();
    }
    setLoading(true);
    QNetworkRequest request(m_url.resolved(QUrl(path(id))));
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
    post(path(id), QJsonObject{{"title", title.trimmed()}}, "PATCH");
}

QString Engine::path(const QString &id, const QString &rest) {
    return "/meeting/" + QString::fromUtf8(QUrl::toPercentEncoding(id)) + rest;
}

void Engine::fetchWrapup(const QString &id) {
    if (m_wrapupFetch) {
        m_wrapupFetch->disconnect(this);
        m_wrapupFetch->abort();
    }
    if (!m_wrapup.isEmpty() || !m_takeaways.isEmpty() || !m_brief.isEmpty()) {
        m_wrapup.clear();
        m_takeaways.clear();
        m_brief.clear();
        emit wrapupChanged();
    }
    if (id.isEmpty())
        return;
    m_wrapupFetch = m_network.get(QNetworkRequest(m_url.resolved(QUrl(path(id, "/wrapup")))));
    connect(m_wrapupFetch, &QNetworkReply::finished, this, [this, id, reply = m_wrapupFetch.data()] {
        reply->deleteLater();
        if (reply != m_wrapupFetch)
            return;
        m_wrapupFetch = nullptr;
        if (reply->error() != QNetworkReply::NoError || id != m_selected)
            return;
        const QJsonObject body = QJsonDocument::fromJson(reply->readAll()).object();
        m_wrapup = body.value("wrapup").toObject().toVariantMap();
        m_takeaways = body.value("takeaways").toObject().toVariantMap();
        m_brief = body.value("brief").toObject().toVariantMap();
        emit wrapupChanged();
    });
}

void Engine::resume(const QString &id) {
    m_chosen = false;
    post(path(id, "/resume"), {});
}

void Engine::merge(const QString &id, const QString &other) {
    QNetworkRequest request(m_url.resolved(QUrl(path(id, "/merge"))));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QNetworkReply *reply = m_network.post(request, QJsonDocument(QJsonObject{{"with", other}}).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        const QByteArray data = reply->readAll();
        if (reply->error() != QNetworkReply::NoError) {
            setError(data.isEmpty() ? reply->errorString() : QString::fromUtf8(data));
            return;
        }
        // The kept meeting's transcript changed under it: load it afresh.
        const QString kept = QJsonDocument::fromJson(data).object().value("id").toString();
        m_selected.clear();
        select(kept);
        emit copied(tr("Merged into one meeting; its wrap-up is being drafted again."));
    });
}

void Engine::finish(const QString &id, bool email) {
    QNetworkRequest request(m_url.resolved(QUrl(path(id, "/finish"))));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QNetworkReply *reply = m_network.post(request, QJsonDocument(QJsonObject{{"email", email}}).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, id] {
        reply->deleteLater();
        const QByteArray data = reply->readAll();
        if (reply->error() != QNetworkReply::NoError) {
            setError(data.isEmpty() ? reply->errorString() : QString::fromUtf8(data));
            return;
        }
        // A page from that day is already there to fill in: Chris picks.
        if (QJsonDocument::fromJson(data).object().value("started").toObject().value("notion").toString() == "choose")
            emit choosePage(id);
    });
}

void Engine::nameVoice(const QString &id, int voice, const QString &name) {
    post(path(id), QJsonObject{{"voices", QJsonObject{{QString::number(voice), name.trimmed()}}}}, "PATCH");
}

void Engine::remove(const QString &id) {
    post(path(id), {}, "DELETE");
}

void Engine::setSkipped(const QString &id, bool skipped) {
    post(path(id), QJsonObject{{"skipped", skipped}}, "PATCH");
}

void Engine::draftWrapup(const QString &id, bool replace) {
    post(path(id, "/wrapup"), QJsonObject{{"replace", replace}});
}

void Engine::saveWrapup(const QString &id, const QVariantMap &edited) {
    post(path(id, "/wrapup"), QJsonObject{{"edited", edited.isEmpty() ? QJsonValue() : QJsonValue(QJsonObject::fromVariantMap(edited))}}, "PUT");
}

void Engine::findNotionPages(const QString &id) {
    if (m_candidatesFetch) {
        m_candidatesFetch->disconnect(this);
        m_candidatesFetch->abort();
    }
    m_candidates.clear();
    m_candidatesError.clear();
    m_candidatesLoading = true;
    emit candidatesChanged();
    m_candidatesFetch = m_network.get(QNetworkRequest(m_url.resolved(QUrl(path(id, "/notion")))));
    connect(m_candidatesFetch, &QNetworkReply::finished, this, [this, reply = m_candidatesFetch.data()] {
        reply->deleteLater();
        if (reply != m_candidatesFetch)
            return;
        m_candidatesFetch = nullptr;
        m_candidatesLoading = false;
        const QJsonObject body = QJsonDocument::fromJson(reply->readAll()).object();
        if (body.contains("error"))
            m_candidatesError = body.value("error").toString();
        else if (reply->error() != QNetworkReply::NoError)
            m_candidatesError = tr("The engine didn't answer: %1").arg(reply->errorString());
        else
            m_candidates = body.value("pages").toArray().toVariantList();
        emit candidatesChanged();
    });
}

void Engine::sendToNotion(const QString &id, const QString &target) {
    QJsonObject body;
    if (!target.isEmpty())
        body.insert("target", target);
    post(path(id, "/notion"), body);
}

void Engine::copyWrapup(const QString &id) {
    QNetworkReply *reply = m_network.get(QNetworkRequest(m_url.resolved(QUrl(path(id, "/markdown")))));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            setError(tr("There's no wrap-up to copy yet."));
            return;
        }
        copyToClipboard(QString::fromUtf8(reply->readAll()));
        emit copied(tr("Wrap-up copied as Markdown"));
    });
}

void Engine::copyTranscript(const QString &id) {
    if (id == m_selected && !m_loading) {
        copyToClipboard(transcriptText());
        emit copied(tr("Transcript copied"));
        return;
    }
    QNetworkReply *reply = m_network.get(QNetworkRequest(m_url.resolved(QUrl(path(id)))));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError)
            return;
        QStringList rows;
        for (const auto &v : QJsonDocument::fromJson(reply->readAll()).object().value("segments").toArray()) {
            const QJsonObject s = v.toObject();
            rows << QString("[%1] %2: %3").arg(QDateTime::fromSecsSinceEpoch(qint64(s.value("start").toDouble())).toString("HH:mm:ss"),
                                               s.value("speaker").toString(), s.value("text").toString());
        }
        copyToClipboard(rows.join('\n'));
        emit copied(tr("Transcript copied"));
    });
}

QString Engine::meetingFolder(const QString &id) const {
    const QString root = qEnvironmentVariable("SIDECAR_MEETINGS",
        QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/aloi-sidecar/meetings");
    return root + "/" + id;
}

void Engine::addNote(const QString &id, const QString &text) {
    if (!text.trimmed().isEmpty())
        post(path(id, "/note"), QJsonObject{{"kind", "note"}, {"text", text.trimmed()}});
}

void Engine::mark(const QString &id) {
    post(path(id, "/note"), QJsonObject{{"kind", "mark"}});
}

void Engine::writeEmail(const QString &id) {
    post(path(id, "/email"), {});
}

void Engine::editEmail(const QString &id, const QVariantMap &changes) {
    post(path(id, "/email"), QJsonObject::fromVariantMap(changes), "PUT");
}

void Engine::saveEmail(const QString &id) {
    post(path(id, "/email/save"), {});
}

void Engine::fetchFollowups() {
    QNetworkReply *reply = m_network.get(QNetworkRequest(m_url.resolved(QUrl("/followups"))));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError)
            return;
        m_followups = QJsonDocument::fromJson(reply->readAll()).object().value("followups").toArray().toVariantList();
        emit followupsChanged();
    });
}

void Engine::search(const QString &q) {
    const QString query = q.trimmed();
    m_searching = query;
    if (query.size() < 2) {
        m_searched.clear();
        m_searchResults.clear();
        emit searchChanged();
        return;
    }
    QUrl url = m_url.resolved(QUrl("/search"));
    QUrlQuery params;
    params.addQueryItem("q", query);
    url.setQuery(params);
    QNetworkReply *reply = m_network.get(QNetworkRequest(url));
    connect(reply, &QNetworkReply::finished, this, [this, reply, query] {
        reply->deleteLater();
        // Typing outruns the answers; only the latest search counts.
        if (reply->error() != QNetworkReply::NoError || query != m_searching)
            return;
        m_searched = query;
        m_searchResults = QJsonDocument::fromJson(reply->readAll()).object().value("results").toArray().toVariantList();
        emit searchChanged();
    });
}

void Engine::setFollowupDone(const QString &meeting, int index, bool done) {
    // Ticked on screen straight away; the engine's answer confirms it.
    for (auto &v : m_followups) {
        QVariantMap f = v.toMap();
        if (f.value("meeting").toString() == meeting && f.value("index").toInt() == index) {
            f["done"] = done;
            v = f;
        }
    }
    emit followupsChanged();
    post("/followups/done", QJsonObject{{"meeting", meeting}, {"index", index}, {"done", done}});
}

void Engine::setFollowupFlagged(const QString &meeting, int index, bool flagged) {
    for (auto &v : m_followups) {
        QVariantMap f = v.toMap();
        if (f.value("meeting").toString() == meeting && f.value("index").toInt() == index) {
            f["flagged"] = flagged;
            v = f;
        }
    }
    emit followupsChanged();
    post("/followups/flag", QJsonObject{{"meeting", meeting}, {"index", index}, {"flagged", flagged}});
}

void Engine::sendAll(const QStringList &ids) {
    post("/notion/bulk", QJsonObject{{"ids", QJsonArray::fromStringList(ids)}});
}

void Engine::removeFollowup(const QString &meeting, int index) {
    QNetworkRequest request(m_url.resolved(QUrl("/followups/remove")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QNetworkReply *reply = m_network.post(request, QJsonDocument(QJsonObject{{"meeting", meeting}, {"index", index}}).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        const QByteArray data = reply->readAll();
        if (reply->error() != QNetworkReply::NoError) {
            setError(data.isEmpty() ? reply->errorString() : QString::fromUtf8(data));
            return;
        }
        m_followups = QJsonDocument::fromJson(data).object().value("followups").toArray().toVariantList();
        emit followupsChanged();
    });
}

void Engine::syncFollowups() {
    if (m_syncing)
        return;
    m_syncing = true;
    emit followupsChanged();
    QNetworkRequest request(m_url.resolved(QUrl("/followups/sync")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QNetworkReply *reply = m_network.post(request, QByteArray("{}"));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        m_syncing = false;
        const QJsonObject body = QJsonDocument::fromJson(reply->readAll()).object();
        if (body.contains("error"))
            setError(body.value("error").toString());
        else if (body.contains("followups"))
            m_followups = body.value("followups").toArray().toVariantList();
        emit followupsChanged();
    });
}

void Engine::setSetting(const QString &key, const QVariant &value) {
    post("/settings", QJsonObject{{key, QJsonValue::fromVariant(value)}}, "PATCH");
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
