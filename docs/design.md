# Sidecar, thought through

Chris's decisions (2026-10-26), marked **Decided**: ask with a toast; follow-ups on the Notion page plus a Sidecar tab; the bar item folded into Aloi Meetings; Notion through an integration token. Every meeting can be opened later to review it and ask about it.

## What went wrong on day one

The prototype listened all day. A restart within 15 minutes of the last line
"continued the meeting", and on a busy afternoon the last line is never 15
minutes old. So 13:59 to 16:56 became one meeting, 2,687 lines long. It held
the 14:00, 15:00 and 16:30 calls and everything said between them, with no
gap over three minutes. The agent kept one conversation for all of it, which
is why "summarize" summarized the afternoon.

The fix isn't a better timeout. A meeting has to be a thing with edges: it
starts, it ends, it has a title and people, and what you ask is about that
meeting unless you say otherwise.

## The meeting, start to finish

### 1. Before: Sidecar knows what's next

Aloi Meetings already knows the calendar, through `bin/aloi-meetings today`.
It gives subject, start, end, organizer and join URL. Attendees and the agenda
(the event body) are one Graph field away.

- From two minutes before a calendar meeting, Sidecar can listen *for that
  meeting*. The meeting gets its subject as a title, the attendees as names
  the agent can use ("Them" is everyone mixed, so names come from context),
  and the agenda as background. All of this goes into the agent's system
  prompt once, at the start.
- Join from the bar starts listening at the same moment.
- Ad-hoc calls (a phone call, an unscheduled Teams call) start by hand with
  Space and are called "Call at 14:05" until the wrap-up names them.
- **Decided:** a toast asks two minutes before ("Listen to Axiom weekly?").
  Join and listen from the bar starts without asking.

### 2. During: the live view

- The transcript is the same, with names for Them where the attendee list
  makes them obvious later. No guessing live.
- **Mark** (`M`) drops a flag on the current moment ("that matters"). Marks
  become highlights in the notes.
- **Note** (`N`) types a line of your own into the transcript, shown as
  *Chris (note)*. Use it for things nobody said out loud, like "check their
  contract end date".
- **Takeaways**, live: every couple of minutes a cheap model (Haiku) rereads
  what's new and keeps four short lists up to date:
  - **For me to do**: things you committed to, such as "I'll send pricing
    today".
  - **Asked of me, not answered**.
  - **Decisions**.
  - **Open questions**.

  Each item links to the moment it came from. This is the panel you glance
  at; asking stays for everything else.
- **Ask** is scoped to this meeting. The agent sees this meeting's lines,
  notes and marks, plus its title, people and agenda. A switch ("all
  meetings") widens a single question to the library on purpose, never by
  accident.

### 3. The edge: ending a meeting

A meeting ends in one of these ways, and every one is visible:

- **End** (`E`), by hand, which goes straight to the wrap-up.
- **The call app lets go of the mic.** Sidecar shows "The Teams call
  ended" with End now and Not now; with no answer it ends after half a
  minute. (Decided 2026-10-27: record everything while the mic is hot, end
  when it's over, Not now being the exception both ways.)
- **The next calendar meeting starts.** The current one ends and the new
  one begins, always. Two meetings are never merged again.
- Stop listening (Space) pauses the meeting without ending it. Space again
  carries on the same meeting, and only that meeting: no time-based
  guessing.

### 4. After: the wrap-up

When a meeting ends, it lands in **Needs wrap-up**, like Tix's "Needs a
reply". The wrap-up screen shows:

- **Title, date, duration and people**, all editable. An untitled call gets
  a suggested title.
- **Summary**, written by Opus from the whole meeting: a few paragraphs,
  plain. Highlights come from your marks.
- **For me to do**, a checklist. Each item has who, what, when ("today",
  "by Friday") and a link to the moment. You keep, edit or drop each one
  before it goes anywhere.
- **Others committed to**, which is what to chase later.
- **Decisions** and **open questions**.
- Actions:
  - **Send to Notion** (`S`) creates a page in your private **Meetings**
    database: properties (title, date, people, duration, customer if
    there was one, tags), then the summary, follow-ups as to-dos,
    decisions and questions, and the full transcript folded in a toggle.
    Once sent, the meeting shows **In Notion** with the link.
  - **Draft follow-up email** writes an Outlook draft to the attendees in
    your voice (chris-voice), saved in Drafts and never sent.
  - **Copy** puts it all on the clipboard as Markdown.
- **Decided:** to-dos on the Notion meeting page, plus the Follow-ups tab in
  Sidecar, with checkmarks kept in sync.

### 5. Afterwards: the library and your follow-ups

- **Meetings** (the left list, like Tix's queue) is grouped into *Needs
  wrap-up*, *Today*, *This week* and *Earlier*. Each row has its title,
  time, length and a chip: Live, Needs wrap-up or In Notion. Opening one
  shows its transcript, takeaways and its own agent conversation.
- **Follow-ups** (a tab with a count, like Tix's "Needs us") lists every
  open to-do across meetings, oldest first, each linked to its meeting and
  moment. Checking one off here checks it off in Notion too.

## Screen

The same frame as Tix and Smokeping: the yellow logo square and **aloi
sidecar**, a segmented switch (**Meetings · Follow-ups 7**), the engine dot,
search with `/` and **? keys**.

```
┌─ aloi sidecar ─ [Meetings] Follow-ups 7 ───────────────── ● ─ [/ Search] ─ ? keys ┐
│ Needs wrap-up 2 │ Axiom weekly                      ● Listening 23:41   [End  E] │ Agent · Axiom weekly │
│ ▸ Axiom weekly  │ 14:00–14:30 · Amy R, Dan K, you   [Mark M] [Note N]  ⋯         │                      │
│   LIVE  23m     │ ──────────────────────────────────────────────────────────── │ 1 What did I miss?   │
│ ▸ Call at 13:12 │ 14:03  Them   We're targeting the fourteenth…                │ 2 Summarize so far   │
│                 │ 14:04  Me     Okay, two things then…                         │ …                    │
│ Today           │ 14:06  ⚑ marked                                              │                      │
│   Lone Star  ✓  │ …                                                            │ ┌ TAKEAWAYS ───────┐ │
│   Standup    ✓  │ ···    Them   Right now it plays the regular greeting…       │ │ For me: pricing  │ │
│ This week …     │                                                              │ │ Asked: holiday…  │ │
│                 │                                                              │ └──────────────────┘ │
│                 │                                                              │ [Ask the agent    ] │
└─────────────────┴──────────────────────────────────────────────────────────────┴──────────────────────┘
```

When a meeting ends, the centre turns into its wrap-up. A meeting already
in Notion opens to its notes, with the transcript a tab away.

## The bar

The bar item was planned but not built yet. Two ways to do it:

- **Fold it into Aloi Meetings.** The meeting item gains a red dot and the
  elapsed time while Sidecar listens, the panel gains **Join and listen**
  and **Stop**, and "2 to wrap up" shows after calls. This is one item,
  and it's where you already look.
- **A separate Sidecar item.**
- **Decided:** fold it into Aloi Meetings.

## Notion

The private Meetings database isn't reachable from here yet. The claude.ai
Notion connector isn't connected in this Claude Code account, and the
Sidecar agent runs without MCP servers on purpose. Two ways in:

- **An internal integration token** (**Decided**). You make it once at
  notion.so/my-integrations and share only the Meetings database with it.
  Sidecar keeps the token in the keyring (`secret-tool`, like Aloi
  Meetings) and publishes itself. This is predictable: the same page every
  time, and no agent in the loop for a write.
- **The Notion connector inside the agent**, which means turning MCP back
  on for it.

Either way, the first step is reading the database's real properties, so
the page fits what's already there rather than a guessed schema.

## Under the hood

- **Engine:** each meeting is a folder, `meetings/<id>/`, holding
  `meta.json` (title, calendar event, people, start, end, state),
  `transcript.jsonl`, `notes.jsonl` (notes and marks) and
  `takeaways.json`. The API gains `POST /meeting/start {title, event?}`,
  `POST /meeting/end`, `GET /meetings` and `GET /meeting/<id>`. The
  15-minute resume goes away.
- **The agent session belongs to the meeting** (it already does, by id).
  With real edges, that's enough. The all-meetings switch adds the library
  as files the agent may read, instead of pasting them in.
- **Models:**
  - Ask: Opus at low effort.
  - Live takeaways: Haiku, every two minutes and only when there are new
    lines.
  - Wrap-up summary: Opus at medium effort, once per meeting.

  All of it goes through `claude -p` on your login, so no API key is
  needed.
- **Today's merged afternoon** can be split once by the calendar (14:00,
  15:00, 16:30) into three meetings, so it isn't lost.

## Order of work

1. **Edges.** Meetings with a start, an end and a title, the library list,
   the agent scoped to one meeting, and splitting today's file. This fixes
   the bug you hit.
2. **Wrap-up and Notion.** The summary and follow-ups review, then Send to
   Notion and the Outlook draft.
3. **Calendar and bar.** Start from the calendar, automatic ending, and
   the bar item.
4. **During the call.** Live takeaways, Mark and Note, and the Follow-ups
   tab.
5. **The UI pass throughout,** to Tix and Smokeping's standard: the header
   frame, the left list with sections and counts, chips, key hints on
   buttons, a quiet composer, and screenshots at three sizes.

## Notion: the real "My Meetings" database (read 2026-10-26)

The integration token is in the keyring (`secret-tool lookup service aloi-sidecar account notion`) and sees one database: **My Meetings**, `21553fc0-1092-80f5-b264-e9a451b14cee`.

Properties: `Meeting Title` (title), `Date` (date), `Summary` (text), `Duration` (text), `Topic` (text), `Met with` (multi-select of companies and people), `Tags` (multi-select, long and messy), `Format` (select: Video, Phone, In person), `Status` (select: published, no-transcript, external, failed), `Attendees`, `Internal Attendees` and `Organizer` (people), `Source` (url), `PlaudeAI` (checkbox), `Files & media`, `Meeting Date` (created time).

Pages already written by the existing pipeline have this body: `## TL;DR`, a paragraph, `## Topics` with a `###` per topic and bullets, then a toggle "Full transcript". Sidecar's pages follow the same shape, adding `## My follow-ups` (to-dos), `## Their commitments`, `## Decisions` and `## Open questions` before the transcript toggle.

Something else already adds today's meetings here ("LNM" and "Nortridge Integration" appeared with only a title and Summary). Send must look for a page with the same title on the same day first, and offer to fill that page in rather than make a duplicate.
