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
    // When line id was said, and its row, for jumping to it.
    Q_INVOKABLE double startOf(int id) const;
    Q_INVOKABLE int rowOf(int id) const;

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
    // The selected meeting's wrap-up: {state: drafting|ready|failed, error,
    // draft, edited, drafted}, or empty if it has none yet.
    Q_PROPERTY(QVariantMap wrapup READ wrapup NOTIFY wrapupChanged)
    // The selected meeting's live takeaways: {mine, asked, decisions, questions, updated}.
    Q_PROPERTY(QVariantMap takeaways READ takeaways NOTIFY wrapupChanged)
    // What's on file going into the meeting on screen, from earlier ones in
    // its series or with its people: {related: [{id, title, started, tldr,
    // series, shared}], mine: [{meeting, index, text, due}], theirs: [{meeting, who, text, due}]}.
    Q_PROPERTY(QVariantMap brief READ brief NOTIFY wrapupChanged)
    // Another app holding the mic, as the engine sees it: {app, since}, or empty.
    Q_PROPERTY(QVariantMap call READ call NOTIFY stateChanged)
    // The engine's settings: {watch_calls}.
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY stateChanged)
    // Notion pages from the day of the meeting being sent, to fill one in instead.
    Q_PROPERTY(QVariantList candidates READ candidates NOTIFY candidatesChanged)
    Q_PROPERTY(bool candidatesLoading READ candidatesLoading NOTIFY candidatesChanged)
    Q_PROPERTY(QString candidatesError READ candidatesError NOTIFY candidatesChanged)
    // Chris's follow-ups across every meeting's wrap-up, oldest meeting first:
    // [{meeting, title, started, index, text, due, at, done, doneAt, inNotion, syncError}].
    Q_PROPERTY(QVariantList followups READ followups NOTIFY followupsChanged)
    Q_PROPERTY(int followupsOpen READ followupsOpen NOTIFY stateChanged)
    Q_PROPERTY(bool syncing READ syncing NOTIFY followupsChanged)
    // Meetings whose title or transcript has every word searched for, newest
    // first: [{id, title (matched), count, hits: [{at, speaker, text, time}]}].
    Q_PROPERTY(QVariantList searchResults READ searchResults NOTIFY searchChanged)
    Q_PROPERTY(QString searched READ searched NOTIFY searchChanged)

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
    QVariantMap wrapup() const { return m_wrapup; }
    QVariantMap takeaways() const { return m_takeaways; }
    QVariantMap brief() const { return m_brief; }
    QVariantMap call() const { return m_call; }
    QVariantMap settings() const { return m_settings; }
    QVariantList candidates() const { return m_candidates; }
    bool candidatesLoading() const { return m_candidatesLoading; }
    QString candidatesError() const { return m_candidatesError; }
    QVariantList followups() const { return m_followups; }
    QVariantList searchResults() const { return m_searchResults; }
    QString searched() const { return m_searched; }
    int followupsOpen() const { return m_followupsOpen; }
    bool syncing() const { return m_syncing; }

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

    // A meeting by id, from its right-click menu or the keys.
    // Carry on with an ended meeting (one ended by mistake).
    Q_INVOKABLE void resume(const QString &id);
    // Two meetings that were one call: the earlier keeps both transcripts.
    Q_INVOKABLE void merge(const QString &id, const QString &other);
    // After a call, in one go: a new Notion page and the email in Drafts.
    Q_INVOKABLE void finish(const QString &id);
    // Move a meeting to the trash folder.
    Q_INVOKABLE void remove(const QString &id);
    // Mark a meeting as needing no wrap-up (a test call), or undo that.
    Q_INVOKABLE void setSkipped(const QString &id, bool skipped);
    // Draft the wrap-up again; replace drops Chris's edits.
    Q_INVOKABLE void draftWrapup(const QString &id, bool replace = false);
    // Save Chris's version of the wrap-up; an empty map goes back to the draft.
    Q_INVOKABLE void saveWrapup(const QString &id, const QVariantMap &edited);
    // Look for pages from the meeting's day, then send: target empty for a
    // new page, or a page id to fill in.
    Q_INVOKABLE void findNotionPages(const QString &id);
    Q_INVOKABLE void sendToNotion(const QString &id, const QString &target = {});
    // The wrap-up, or the transcript, of any meeting onto the clipboard.
    Q_INVOKABLE void copyWrapup(const QString &id);
    Q_INVOKABLE void copyTranscript(const QString &id);
    // Where a meeting's files are, for "Show files".
    Q_INVOKABLE QString meetingFolder(const QString &id) const;
    Q_INVOKABLE void setSetting(const QString &key, const QVariant &value);
    // A note Chris types, or a mark on the moment, into a meeting's transcript.
    Q_INVOKABLE void addNote(const QString &id, const QString &text);
    Q_INVOKABLE void mark(const QString &id);
    // The follow-up email: written by Opus, edited here, saved to Outlook Drafts by vmail.
    Q_INVOKABLE void writeEmail(const QString &id);
    Q_INVOKABLE void editEmail(const QString &id, const QVariantMap &changes);
    Q_INVOKABLE void saveEmail(const QString &id);
    Q_INVOKABLE void fetchFollowups();
    Q_INVOKABLE void search(const QString &q);
    // Gone, not done: out of the wrap-up and off the Notion page.
    Q_INVOKABLE void removeFollowup(const QString &meeting, int index);
    Q_INVOKABLE void setFollowupDone(const QString &meeting, int index, bool done);
    // Ticks made in Notion, brought back.
    Q_INVOKABLE void syncFollowups();
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
    void wrapupChanged();
    void candidatesChanged();
    void followupsChanged();
    void searchChanged();
    // Something landed on the clipboard (what, for the toast).
    void copied(const QString &what);

private:
    void setConnected(bool on);
    void setError(const QString &error);
    void setLoading(bool on);
    void post(const QString &path, const QJsonObject &body, const QByteArray &verb = "POST");
    void startService();
    void upsert(const QVariantMap &meeting);
    void showLive();
    void fetchWrapup(const QString &id);
    static QString path(const QString &id, const QString &rest = {});
    static Transcript::Line lineFrom(const QJsonObject &segment);

    QUrl m_url;
    QNetworkAccessManager m_network;
    QPointer<QNetworkReply> m_stream;
    QPointer<QNetworkReply> m_fetch;
    QPointer<QNetworkReply> m_wrapupFetch;
    QPointer<QNetworkReply> m_candidatesFetch;
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
    QVariantMap m_wrapup, m_takeaways, m_brief, m_call, m_settings;
    QVariantList m_candidates;
    bool m_candidatesLoading = false;
    QString m_candidatesError;
    QVariantList m_followups;
    QVariantList m_searchResults;
    QString m_searched;
    QString m_searching;
    int m_followupsOpen = 0;
    bool m_syncing = false;
};
