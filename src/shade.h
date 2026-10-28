#pragma once

#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <functional>

// The window rolled up to its bar, like the classic Mac OS window shade:
// Hyprland floats it, pins it on every workspace at the bar's height, and
// later puts it back the way it was. Only under Hyprland on Wayland; the
// offscreen harness never touches the real compositor.
class Shade : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool available READ available CONSTANT)

public:
    explicit Shade(QObject *parent = nullptr);
    ~Shade() override;
    bool available() const { return !m_hyprctl.isEmpty(); }

    // Call once Qt has taken the window's smaller minimum size, or the
    // client holds the compositor to the old one.
    Q_INVOKABLE void shade(int width, int height);
    Q_INVOKABLE void unshade();

signals:
    // The compositor has done its part (or there was nothing to do).
    void done(bool shaded);

private:
    void findSelf(std::function<void(const QJsonObject &)> then);
    void dispatch(const QStringList &steps, const QStringList &after, bool shaded);

    QString m_hyprctl;
    QProcess m_process;
    // The window as it was before shading: floating, size, at, pinned.
    QJsonObject m_before;
};
