#pragma once

#include <QFileSystemWatcher>
#include <QHash>
#include <QObject>
#include <QProcess>
#include <QTimer>

class Theme : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString accent READ accent NOTIFY changed)
    Q_PROPERTY(QString accentForeground READ accentForeground NOTIFY changed)
    Q_PROPERTY(int radius READ radius NOTIFY changed)
    Q_PROPERTY(bool dark READ dark NOTIFY changed)
    // The rest of the Omarchy palette, so Sidecar looks like the desktop around
    // it and not only its accent. Each falls back to Sidecar's own dark colors.
    Q_PROPERTY(QString background READ background NOTIFY changed)
    Q_PROPERTY(QString panel READ panel NOTIFY changed)
    Q_PROPERTY(QString raised READ raised NOTIFY changed)
    Q_PROPERTY(QString selection READ selection NOTIFY changed)
    Q_PROPERTY(QString line READ line NOTIFY changed)
    Q_PROPERTY(QString foreground READ foreground NOTIFY changed)
    Q_PROPERTY(QString muted READ muted NOTIFY changed)
    Q_PROPERTY(QString faint READ faint NOTIFY changed)
    Q_PROPERTY(QString danger READ danger NOTIFY changed)

public:
    explicit Theme(const QString &currentDirectory = {}, QObject *parent = nullptr, const QString &hyprctl = {});
    ~Theme() override;

    QString accent() const { return m_accent; }
    QString accentForeground() const;
    int radius() const { return m_radius; }
    bool dark() const { return m_colors.value("mode", "dark") != "light"; }
    QString background() const { return color("background", "#0e0e10"); }
    QString panel() const { return color("dark_background", dark() ? "#141417" : "#f2f2f2"); }
    QString raised() const { return color("lighter_background", dark() ? "#1b1b1f" : "#ffffff"); }
    QString selection() const { return color("selection", dark() ? "#26262c" : "#dcdcdc"); }
    QString line() const { return color("muted", dark() ? "#2a2a30" : "#d0d0d0"); }
    QString foreground() const { return color("foreground", dark() ? "#e8e8ea" : "#1a1a1a"); }
    QString muted() const { return color("light_foreground", dark() ? "#8d8d96" : "#5a5a5a"); }
    QString faint() const { return color("dark_foreground", dark() ? "#5f5f68" : "#9a9a9a"); }
    QString danger() const { return color("red", "#ef5f5f"); }

    static QHash<QString, QString> readColors(const QString &path);

    static QString readAccent(const QString &path);

signals:
    void changed();

private:
    QString color(const QString &key, const QString &fallback) const { return m_colors.value(key, fallback); }
    void reload();
    void refreshRounding();

    QString m_directory;
    QString m_accent = "#FFD60A";
    QHash<QString, QString> m_colors;
    QFileSystemWatcher m_watcher;
    QTimer m_debounce;
    QString m_hyprctl;
    int m_radius = 0;
    QProcess m_roundingProcess;
    QTimer m_roundingPoll, m_roundingTimeout;
};
