# Aloi Sidecar in the bar

A recording dot: a quiet ring while Sidecar isn't listening, solid red
(breathing) while it is. Hover for what it's listening to and for how long.

- **Click:** the panel, with what Sidecar is listening to and Stop, or Listen,
  plus Open and how many calls are still to wrap up.
- **Right-click:** listen now, or stop.
- **Listen:** Sidecar names the call itself. It uses the meeting on (or about
  to start) in your calendar, or the call app's window.

The day's meetings aren't here any more. They're in the clock (Aloi
Calendar), and Sidecar's engine reads them from Aloi Calendar's engine
(`engine/agenda.py`). There's no sign-in of its own: Outlook comes through
vmail, once, for both.

`bin/install-plugin` links it in; `node --test plugin/tests` checks it.
IPC: `omarchy-shell aloi.sidecar open|close|toggle|listen|stop|status`.
