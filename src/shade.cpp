#include "shade.h"

#include <QCoreApplication>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QStandardPaths>

Shade::Shade(QObject *parent) : QObject(parent) {
    if (QGuiApplication::platformName() == "wayland" && qEnvironmentVariableIsSet("HYPRLAND_INSTANCE_SIGNATURE"))
        m_hyprctl = QStandardPaths::findExecutable("hyprctl");
}

Shade::~Shade() {
    if (m_process.state() != QProcess::NotRunning) {
        m_process.kill();
        m_process.waitForFinished(1000);
    }
}

// This process's own window, by pid: the focused one may be anything.
void Shade::findSelf(std::function<void(const QJsonObject &)> then) {
    auto *process = new QProcess(this);
    connect(process, &QProcess::finished, this, [this, process, then] {
        process->deleteLater();
        const qint64 pid = QCoreApplication::applicationPid();
        for (const auto &value : QJsonDocument::fromJson(process->readAllStandardOutput()).array()) {
            const auto window = value.toObject();
            if (window.value("pid").toInteger() == pid && window.value("mapped").toBool(true)) {
                then(window);
                return;
            }
        }
        then({});
    });
    process->start(m_hyprctl, {"-j", "clients"});
}

// One hyprctl dispatch per step, as the dock does it: without animating,
// since a float, a resize and a move in a row would each play.
void Shade::dispatch(const QStringList &steps, const QStringList &after, bool shaded) {
    const auto quoted = [this](const QString &step) { return "'" + m_hyprctl + "' dispatch '" + step + "' >/dev/null"; };
    QStringList first, then;
    for (const auto &step : steps) first << quoted(step);
    for (const auto &step : after) then << quoted(step);
    QString command = first.join(" && ");
    if (!then.isEmpty())
        command += "; sleep 0.3; " + then.join("; ");
    if (m_process.state() != QProcess::NotRunning)
        m_process.waitForFinished(2000);
    m_process.disconnect(this);
    connect(&m_process, &QProcess::finished, this, [this, shaded] { emit done(shaded); });
    m_process.start("sh", {"-c", command});
}

void Shade::shade(int width, int height) {
    if (!available()) {
        emit done(true);
        return;
    }
    findSelf([this, width, height](const QJsonObject &window) {
        if (window.isEmpty()) {
            emit done(true);
            return;
        }
        m_before = window;
        const QString target = QString("window = \"address:%1\"").arg(window.value("address").toString());
        const auto at = window.value("at").toArray(), size = window.value("size").toArray();
        // The bar keeps the window's top-right corner, where it sat.
        const int x = at[0].toInt() + size[0].toInt() - width, y = at[1].toInt();
        const QString resize = QString("hl.dsp.window.resize({ x = %1, y = %2, relative = false, %3 })").arg(width).arg(height).arg(target);
        const QString move = QString("hl.dsp.window.move({ x = %1, y = %2, %3 })").arg(x).arg(y).arg(target);
        QStringList steps{QString("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", %1 })").arg(target)};
        if (!window.value("floating").toBool())
            steps << QString("hl.dsp.window.float({ action = \"on\", %1 })").arg(target);
        steps << resize << move;
        if (!window.value("pinned").toBool())
            steps << QString("hl.dsp.window.pin({ action = \"on\", %1 })").arg(target);
        // Once the client has drawn at its new size, Hyprland may have kept
        // it centred on the old one: put it in its corner again.
        dispatch(steps, {move, QString("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", %1 })").arg(target)}, true);
    });
}

void Shade::unshade() {
    if (!available() || m_before.isEmpty()) {
        emit done(false);
        return;
    }
    const QJsonObject before = m_before;
    m_before = {};
    // By the window's own address, though it's been shaded a while: it's
    // still this process's window unless Qt made a new one.
    findSelf([this, before](const QJsonObject &window) {
        if (window.isEmpty()) {
            emit done(false);
            return;
        }
        const QString target = QString("window = \"address:%1\"").arg(window.value("address").toString());
        QStringList steps{QString("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", %1 })").arg(target)};
        if (!before.value("pinned").toBool())
            steps << QString("hl.dsp.window.pin({ action = \"off\", %1 })").arg(target);
        if (before.value("floating").toBool()) {
            const auto at = before.value("at").toArray(), size = before.value("size").toArray();
            steps << QString("hl.dsp.window.resize({ x = %1, y = %2, relative = false, %3 })").arg(size[0].toInt()).arg(size[1].toInt()).arg(target)
                  << QString("hl.dsp.window.move({ x = %1, y = %2, %3 })").arg(at[0].toInt()).arg(at[1].toInt()).arg(target);
        } else {
            // Tiled again on the workspace it was pinned over: the one Chris
            // is looking at, where he clicked to open it.
            steps << QString("hl.dsp.window.float({ action = \"off\", %1 })").arg(target);
        }
        dispatch(steps, {QString("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", %1 })").arg(target)}, false);
    });
}
