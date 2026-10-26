#include "instance.h"

#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusReply>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <cstdio>
#include <QProcess>
#include <QStandardPaths>

bool Instance::claim(const QString &action) {
    auto bus = QDBusConnection::sessionBus();
    if (!bus.isConnected())
        return true;  // no session bus: nothing to coordinate with
    if (bus.registerService(Service)) {
        bus.registerObject("/", this, QDBusConnection::ExportScriptableSlots);
        return true;
    }
    QDBusInterface other(Service, "/", Service, bus);
    other.call("Open", action);
    return false;
}

void Instance::Open(const QString &action) {
    emit openRequested(action);
    // Wayland won't let a window raise itself; Omarchy's helper asks Hyprland.
    const QString focus = QStandardPaths::findExecutable("omarchy-hyprland-focus-app");
    if (!focus.isEmpty())
        QProcess::startDetached(focus, {"^aloi-sidecar$"});
}

QString Instance::Approve(const QString &session, const QString &command, const QString &description) {
    if (!m_approver)
        return QStringLiteral("deny:Sidecar can't ask Chris right now.");
    // The answer comes when Chris clicks, so the reply goes out then.
    setDelayedReply(true);
    const QDBusMessage request = message();
    auto bus = connection();
    m_approver(session, command, description, [request, bus](const QString &decision) mutable {
        bus.send(request.createReply(decision));
    });
    return {};
}

// Read-only commands that never need asking: plain reading tools on their
// own (no pipes, redirects or chaining, which could make them anything).
// The hook allows those itself: the agent's dontAsk mode would quietly
// refuse them, since they aren't on its list.
bool Instance::readOnly(const QString &command) {
    const QString c = command.trimmed();
    static const QRegularExpression shell(QStringLiteral(R"([;&|<>`$\n\\])"));
    if (c.isEmpty() || shell.match(c).hasMatch())
        return false;
    const QStringList words = c.split(QRegularExpression("\\s+"));
    static const QStringList reading{"ls", "cat", "head", "tail", "wc", "pwd", "echo", "date", "which",
                                     "file", "stat", "jq", "grep", "rg", "basename", "dirname"};
    return reading.contains(words.first());
}

namespace {

void answerHook(const QString &decision, const QString &reason) {
    const QJsonObject out{{"hookSpecificOutput", QJsonObject{{"hookEventName", "PreToolUse"},
                                                             {"permissionDecision", decision},
                                                             {"permissionDecisionReason", reason}}}};
    std::fputs(QJsonDocument(out).toJson(QJsonDocument::Compact).constData(), stdout);
    std::fputs("\n", stdout);
}

} // namespace

int Instance::approve() {
    QFile in;
    if (!in.open(stdin, QIODevice::ReadOnly))
        return 0;
    const QJsonObject hook = QJsonDocument::fromJson(in.readAll()).object();
    if (hook.value("tool_name").toString() != "Bash")
        return 0;
    const QJsonObject input = hook.value("tool_input").toObject();
    const QString command = input.value("command").toString();
    if (readOnly(command)) {
        answerHook("allow", "A read-only lookup.");
        return 0;
    }

    auto bus = QDBusConnection::sessionBus();
    QDBusInterface sidecar(Service, "/", Service, bus);
    sidecar.setTimeout(30 * 60 * 1000);
    const QDBusReply<QString> reply =
        sidecar.call("Approve", hook.value("session_id").toString(), command, input.value("description").toString());
    if (!reply.isValid()) {
        answerHook("deny", "Sidecar isn't open to ask Chris, so this didn't run.");
        return 0;
    }
    const QString decision = reply.value();
    if (decision == "allow")
        answerHook("allow", "Chris allowed it in Sidecar.");
    else
        answerHook("deny", decision.startsWith("deny:") ? decision.mid(5) : "Chris said no.");
    return 0;
}
