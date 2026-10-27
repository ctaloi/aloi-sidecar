#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <QVariantList>
#include <functional>

class Transcript;

// The conversation as a list model, for the view. A streamed answer changes
// only its own row, so the rows above it aren't rebuilt and re-measured with
// every word, which is what made the view jump while an answer came in.
class MessageModel : public QAbstractListModel {
    Q_OBJECT
public:
    enum { MessageRole = Qt::UserRole + 1 };
    using QAbstractListModel::QAbstractListModel;
    int rowCount(const QModelIndex &parent = {}) const override { return parent.isValid() ? 0 : m_rows.size(); }
    QVariant data(const QModelIndex &index, int role) const override {
        return index.isValid() && role == MessageRole ? m_rows.value(index.row()) : QVariant();
    }
    QHash<int, QByteArray> roleNames() const override { return {{MessageRole, "entry"}}; }
    // Brings the rows in line with the conversation: changed rows in place,
    // new ones appended, and only a different conversation starts over.
    void sync(const QVariantList &rows) {
        const qsizetype common = std::min(rows.size(), m_rows.size());
        bool sameStart = true;
        for (qsizetype i = 0; i + 1 < common && sameStart; ++i)
            sameStart = rows[i].toMap().value("role") == m_rows[i].toMap().value("role");
        if (!sameStart || rows.size() < m_rows.size()) {
            beginResetModel();
            m_rows = rows;
            endResetModel();
            return;
        }
        for (qsizetype i = 0; i < common; ++i) {
            if (rows[i] != m_rows[i]) {
                m_rows[i] = rows[i];
                emit dataChanged(index(int(i)), index(int(i)), {MessageRole});
            }
        }
        if (rows.size() > m_rows.size()) {
            beginInsertRows({}, int(m_rows.size()), int(rows.size() - 1));
            for (qsizetype i = m_rows.size(); i < rows.size(); ++i)
                m_rows.append(rows[i]);
            endInsertRows();
        }
    }

private:
    QVariantList m_rows;
};


// A conversation with Claude about the meeting, through `claude -p`, with
// every skill Chris has in Claude Code. Each meeting keeps its own session
// (resumed on every question) and transcript of questions and answers,
// saved under ~/.local/state/aloi-sidecar. Each question carries only the
// lines said since the last one; the session already holds the rest.
//
// The agent looks things up; it doesn't change anything on its own. Read
// tools and plain reading commands run by themselves, and anything else
// waits for Chris to allow it in the window. (The same design as Aloi Tix.)
class Agent : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString meeting READ meeting NOTIFY meetingChanged)
    // The next question goes across every meeting, not only this one. It
    // resets after that question, so the library is never searched by accident.
    Q_PROPERTY(bool wide READ wide WRITE setWide NOTIFY wideChanged)
    Q_PROPERTY(QVariantList messages READ messages NOTIFY messagesChanged)
    // The same conversation, for a ListView: rows change in place.
    Q_PROPERTY(MessageModel *messageModel READ messageModel CONSTANT)
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(QString activity READ activity NOTIFY activityChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    // What the agent is waiting for Chris to allow: [{id, command, description, skill}].
    Q_PROPERTY(QVariantList approvals READ approvals NOTIFY approvalsChanged)

public:
    // The claude program and the state directory; empty uses the real ones.
    explicit Agent(Transcript *transcript, const QString &program = {}, const QString &stateDirectory = {},
                   QObject *parent = nullptr);
    ~Agent() override;

    QString meeting() const { return m_meeting; }
    QVariantList messages() const { return m_sessions.value(m_meeting).messages; }
    MessageModel *messageModel() { return &m_model; }
    bool running() const { return m_process != nullptr; }
    QString activity() const { return running() ? m_activity : QString(); }
    QString error() const { return m_error; }
    QVariantList approvals() const;

    // Read-only lookups run on their own; anything else the agent wants to
    // run comes here first (through the workspace's hook and aloi-sidecar
    // --approve) and waits for Chris. answer gets "allow", or "deny:" and why.
    using Answer = std::function<void(const QString &decision)>;
    void requestApproval(const QString &sessionId, const QString &command, const QString &description, Answer answer);
    // "once", "skill" (always, for the skill the command runs) or "deny".
    Q_INVOKABLE void decide(const QString &id, const QString &verdict);
    // The skill a command runs (its folder under .../skills/), or empty.
    static QString skillOf(const QString &command);
    void setApprover(const QString &program) { m_approver = program; }

    // The meeting on screen, and a line about it for the agent ("Meeting with
    // Cadle", when, whether it's live or over).
    Q_INVOKABLE void setMeeting(const QString &meeting, const QString &about = {});
    Q_INVOKABLE void ask(const QString &question);
    bool wide() const { return m_wide; }
    void setWide(bool on) { if (m_wide != on) { m_wide = on; emit wideChanged(); } }
    // Where every meeting's folder is, for questions across them.
    static QString meetingsDir();
    Q_INVOKABLE void stop();
    // Start this meeting's conversation over.
    Q_INVOKABLE void forget();

    // What goes to Claude for a question: the new lines, then the question.
    QString prompt(const QString &question, bool firstOfSession) const;
    static QString systemPrompt();
    // The line about a meeting the agent gets first: title, when, live or over.
    static QString describe(const QVariantMap &meeting);
    QStringList allowedTools() const;
    // The folder the agent runs in, with Chris's skills linked in.
    QString workspace() const;
    void prepareWorkspace() const;
    QStringList arguments(const QString &sessionId, bool resume) const;

signals:
    void wideChanged();
    void meetingChanged();
    void messagesChanged();
    void runningChanged();
    void activityChanged();
    void errorChanged();
    void approvalsChanged();
    void approvalRequested(const QString &command);

private:
    MessageModel m_model;
    bool m_wide = false;
    struct Pending {
        QString id, command, description, skill;
        Answer answer;
    };
    struct Session {
        QString id;
        int sentThrough = -1;  // the last transcript line the agent has seen
        QVariantList messages;
    };

    void answerAll(const QString &decision);
    void addStep(const QString &step);
    QString allowPath() const;
    QStringList allowedSkills() const;
    void start(const QString &prompt, bool resume);
    void handleLine(const QJsonObject &event);
    void appendText(const QString &text);
    void finishAnswer();
    void setActivity(const QString &activity);
    void setError(const QString &error);
    void load();
    void save() const;
    QString statePath() const;

    Transcript *m_transcript;
    QString m_program;
    QString m_stateDirectory;
    QString m_approver;
    QList<Pending> m_pending;
    QString m_meeting;
    QString m_about;
    QString m_busyMeeting;
    QHash<QString, Session> m_sessions;
    QString m_error;

    QProcess *m_process = nullptr;
    QString m_activity;
    QByteArray m_buffer;
    QString m_stderr;
    QString m_retryPrompt;
    int m_retryThrough = -1;
    bool m_gotResult = false;
    bool m_newBlock = false;
};
