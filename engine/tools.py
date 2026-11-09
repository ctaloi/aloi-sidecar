"""Where the engine finds the programs it runs.

systemd starts the engine at login with a bare PATH, so claude, behind mise's
wrappers, would go missing. These are the same places src/tools.h looks.
"""
import os
from pathlib import Path


def extend_path():
    home = Path.home()
    path = os.environ.get("PATH", "").split(":")
    for folder in (home / ".local/bin", home / ".local/share/mise/command-wrappers/bin",
                   home / ".local/share/mise/shims", "/usr/local/bin", "/usr/bin"):
        if str(folder) not in path:
            path.append(str(folder))
    os.environ["PATH"] = ":".join(p for p in path if p)
