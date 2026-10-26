#pragma once

#include <QDir>
#include <QProcessEnvironment>
#include <QStandardPaths>
#include <QStringList>

// An app started from the launcher doesn't get the shell's PATH, so the engine tools in
// ~/.local/bin and claude behind mise's wrappers would go missing. Look in
// those places too, and hand the same PATH to the tools Sidecar runs.
inline QStringList toolDirectories() {
    const QString home = QDir::homePath();
    return {home + "/.local/bin", home + "/.local/share/mise/command-wrappers/bin",
            home + "/.local/share/mise/shims", "/usr/local/bin", "/usr/bin"};
}

inline QString findTool(const QString &name) {
    const QString found = QStandardPaths::findExecutable(name);
    return !found.isEmpty() ? found : QStandardPaths::findExecutable(name, toolDirectories());
}

inline QProcessEnvironment toolEnvironment() {
    auto env = QProcessEnvironment::systemEnvironment();
    QStringList path = env.value("PATH").split(':', Qt::SkipEmptyParts);
    for (const auto &dir : toolDirectories())
        if (!path.contains(dir))
            path << dir;
    env.insert("PATH", path.join(':'));
    return env;
}
