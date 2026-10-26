#pragma once

#include <QDBusContext>
#include <QObject>
#include <functional>

// One Sidecar at a time. The first registers on the session bus; a second
// launch (the launcher again, a hotkey) brings the first forward and exits.
// Two would answer the agent's hook for each other.
class Instance : public QObject, protected QDBusContext {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "dev.ctaloi.Sidecar")

public:
    static constexpr const char *Service = "dev.ctaloi.Sidecar";

    // True when this is the only Sidecar; false after waking the other.
    bool claim(const QString &action);

    // Who decides what the agent may run: called with the request and a
    // function to call with "allow" or "deny:<why>" whenever Chris answers.
    using Approver = std::function<void(const QString &session, const QString &command, const QString &description,
                                        std::function<void(const QString &)> answer)>;
    void setApprover(Approver approver) { m_approver = std::move(approver); }

    // aloi-sidecar --approve, run by the agent's hook: asks the Sidecar that's open
    // over the session bus and prints the hook's answer. Exit code for main.
    static int approve();
    // A command the hook lets through without asking.
    static bool readOnly(const QString &command);

public slots:
    // Come forward; action "ask" also puts the cursor in the ask box,
    // "toggle" turns listening on or off.
    Q_SCRIPTABLE void Open(const QString &action);
    // Ask the agent about the call, from outside the window.
    Q_SCRIPTABLE void Ask(const QString &question);
    // The agent's hook asking whether a command may run; the reply waits for
    // Chris ("allow", or "deny:" and why).
    Q_SCRIPTABLE QString Approve(const QString &session, const QString &command, const QString &description);

signals:
    void openRequested(const QString &action);
    void askRequested(const QString &question);

private:
    Approver m_approver;
};
