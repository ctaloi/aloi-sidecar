# Aloi Meetings

Your next Microsoft 365 meeting, right in the Omarchy bar. A small calendar
icon sits in the middle of the bar, just left of the clock. Half an hour before a meeting it
becomes the meeting's title and a countdown: *Standup · in 12m*. It stays while
the meeting runs (*8m left*), so running late doesn't make it vanish.

- **Today at a glance.** Click the icon for today's meetings. Past meetings
  fade, the one you're in is highlighted, and the list opens scrolled to what's
  current.
- **One-click join.** Teams, Zoom, Google Meet, Webex and GoTo links get a
  **Join** button. Teams and Meet open as web app windows, the way Omarchy runs
  them. Zoom opens in the Zoom app when it's installed. Right-click the bar to
  join the meeting it's showing.
- **Only what you're going to.** All-day events sit on one quiet line. Cancelled
  meetings are left out. Declined meetings and time marked free stay in the list
  but never claim the bar. Tentative meetings count, since you might go.
- **The link, wherever it hides.** The join link comes from the meeting itself,
  or else from the location or the invite text, with Outlook Safe Links
  unwrapped.
- **Honest when offline.** If a refresh fails, the bar keeps the last good copy
  and the panel says how old it is.

## How it works

`bin/aloi-meetings` signs in to Microsoft 365 in your browser with Vaspian's
own app registration, "Aloi vmail", shared with vmail and vteams. It asks only for
`Calendars.Read` and keeps the sign-in in the desktop keyring. It has its own
sign-in, separate from vmail's, because two apps sharing one refresh token
would keep logging each other out.

The shell asks it for today's meetings every five minutes, every two when a
meeting is close, and again after the laptop wakes or a new day starts. The
countdown ticks on the minute without asking Microsoft anything.

## Requirements

- [Omarchy](https://omarchy.org) with the Quickshell-based shell.
- `python3` and `secret-tool` (libsecret), both already part of Omarchy.

## Install (development)

```bash
d=~/.config/omarchy/plugins/aloi.meetings; mkdir -p $d
for f in manifest.json BarWidget.qml MeetingsContent.qml Service.qml Model.js Registry.js bin i18n; do
  ln -sfn ~/Work/meetings/$f $d/$f
done
omarchy-shell shell rescanPlugins
omarchy plugin enable aloi.meetings --section centerEnd --before omarchy.clock
```

Click the icon and choose **Sign in with Microsoft**.

## Using it

| Action | Mouse | Keyboard (panel open) |
|---|---|---|
| Today's meetings | Click the bar icon | |
| Join a meeting | Its **Join** button | Arrow keys or `j`/`k`, then Enter |
| Join the meeting in the bar | Right-click the bar icon | Enter |
| Open in Outlook | Click the meeting | `o` |
| Check again | Refresh button, or middle-click the bar icon | `r` |

From a script: `omarchy-shell aloi.meetings join`, `… status`, `… refresh`.

## Settings

Saved on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | |
|---|---|---|
| `withinMinutes` | `30` | How soon before a meeting it takes over the bar |
| `maxTitleLength` | `28` | Longer titles are shortened in the bar |
| `showWhenIdle` | `true` | Keep the calendar icon when nothing is close |
| `zoomApp` | `true` | Open Zoom links in the Zoom app |
| `timeFormat` | `h:mm AP` | Qt time format for the list, e.g. `HH:mm` |

## Tests

```bash
node --test tests/
omarchy plugin validate .
```

## License

MIT
