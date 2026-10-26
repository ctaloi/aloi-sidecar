# Aloi Sidecar

A live transcript of the meeting you're in, and an agent beside it that you
can ask about the call while it's going on, with every skill you have in
Claude Code.

![Sidecar during a call, answering a question](docs/answer-1440x900.png)

- **Hears both sides.** Your mic is "Me"; every speaker output (laptop,
  each display) is "Them", so it doesn't matter where the call's audio goes
  or which app the call is in. Speech is transcribed on this machine with
  NVIDIA's Parakeet (sherpa-onnx); no audio leaves the laptop.
- **Listening is never in doubt.** Opening Sidecar starts listening, the
  pill at the top left pulses red while it does, Space pauses, and closing
  the window stops it. Nothing is heard while Sidecar is closed.
- **Ask anything about the call.** "What did I miss?", "Has anyone asked me
  something I haven't answered?", or "look up their numbers": the agent
  gets the lines said since your last question and can use your skills
  (Vaspian One, Silhouette, mail and calendar, Notion, Telescope…).
- **Every meeting has edges.** It starts when you listen (Space) or start
  one (Ctrl+N), pauses with Space, and ends with E. Nothing is merged into a
  meeting by time. Each is a folder in `~/.local/share/aloi-sidecar/meetings/`
  (`meta.json` and `transcript.jsonl`); a meeting nobody spoke in leaves
  nothing behind.
- **Go back to any meeting.** The list on the left has every meeting, live
  first, then today, yesterday, this week and earlier. Open one to read it
  and ask about it: each meeting has its own conversation with the agent,
  which sees that meeting's transcript and no other.

## Nothing changes by itself

The agent runs like Aloi Tix's: `claude -p` in
`~/.local/state/aloi-sidecar/agent`, whose `.claude/skills` and
`.claude/commands` link to yours, without your MCP servers or user settings
(their allow rules and hooks), on Opus at low effort for speed.

- Read, Grep, Glob, Skill, WebSearch, WebFetch and plain reading commands
  run on their own. It has no Edit or Write.
- Anything else it wants to run (a skill's script, `curl`, `python3`) waits
  in the agent panel with the exact command: **Allow** (`Y`), **Always for**
  that skill, or **Deny** (`N`). Skills you always allow are kept in
  `~/.local/state/aloi-sidecar/agent-allow.json`.
- What people say on the call is never taken as an instruction; only your
  question is. It writes emails and notes in its answer for you to use, and
  doesn't send or change anything during the call.
- `~/.config/aloi-sidecar/agent-tools` (one tool pattern per line) replaces
  the allowed list, if you want it to reach further.

## Keys

`?` lists them all.

| Key | Action |
|-----|--------|
| `Space` | Listen / pause (starts a meeting if none is on) |
| `E` | End the meeting |
| `Ctrl+N` | Start a new meeting |
| `R` | Rename the meeting on screen |
| `J` / `K` | Next / previous meeting |
| `G` | Go to the meeting that's on now |
| `\` | Show / hide the meetings list |
| `Ctrl+F` | Search meetings |
| `/` | Ask about the meeting on screen |
| `1`–`4` | Ask a suggested question |
| `Esc` | Stop the agent, leave the ask box |
| `Y` / `N` | Allow / deny what the agent wants to run |
| `End` | Back to the live end of the transcript |
| `Ctrl+Shift+K` | New chat with the agent |
| `Q` | Quit (pauses listening) |

`aloi-sidecar --ask` brings Sidecar forward with the cursor in the ask box
(for a Hyprland binding); `--toggle` turns listening on or off;
`--no-listen` opens without listening.

## How it fits together

- `engine/` is the ear: a Python service (`aloi-sidecar-engine`, a systemd
  user unit) that captures through PipeWire with `parec`, finds speech with
  Silero VAD and transcribes with Parakeet. It keeps the meetings
  (`GET /meetings`, `GET`/`PATCH /meeting/<id>`, `POST /meeting/start`,
  `POST /meeting/end`), listens only while asked (`POST /listen`), streams
  lines, live previews and levels from `GET /events`, and drops your mic's
  copy of what the speakers played.
  `http://127.0.0.1:8777` is a plain web view with a direct Claude ask box,
  kept as a fallback (it uses the key linked at
  `~/.config/aloi-sidecar/api-key`).
- `src/` is the app: C++ and Qt Quick, following the Omarchy theme live,
  with the agent and its approvals (the `--approve` hook asks the open
  window over D-Bus, as `dev.ctaloi.Sidecar`).

## Build

```sh
bin/build      # build/aloi-sidecar
bin/test       # unit tests, then the window offscreen at three sizes
bin/shots      # screenshots into docs/, against the stand-in engine and Claude
bin/install    # the engine's environment, models and service, then the package
```

Needs `qt6-base`, `qt6-declarative`, `qt6-wayland`, `uv` and Claude Code.
The models (about 650 MB) download on the first `bin/install`.

## License

MIT
