# DCS Replay Deck

**Rewind a DCS track.** Plus proper speed control, marks you can name, and a timeline that
shows you where every missile launch happened.

Built for making video. Miss the shot? Jump back thirty seconds. Want that AMRAAM launch
from four different angles? Mark it once and go straight back to it, every time.

![Replay Deck](deck/ReplayDeck.png)

---

## Install

1. Download **ReplayDeck.exe**
2. Run it
3. **Restart DCS**

That's it. The exe installs its own DCS hook the first time you run it, and repairs it
automatically whenever you update. Nothing to copy, nothing to unzip.

Nothing is written into your DCS install folder — the hook lives in
`Saved Games\DCS\Scripts\Hooks\`, so it survives DCS updates and cannot break an integrity
check.

## Use

Start a replay from DCS's Replay menu, then run Replay Deck.

| | |
|---|---|
| **−10s / −30s / −60s / −5m** | Jump back from wherever you are |
| **◆ MARK HERE** | Pauses the replay and lets you name the moment |
| **◀ last mark / next mark ▶** | Jump straight to a mark, landing 10 seconds before it |
| **◀◀ ❚❚ 1× ▶▶** | Slow down (to 1/64), pause, normal, speed up |
| **events: N** | Every shot, hit and kill DCS reported, as a list |

The timeline uses three colours:

- 🔺 **red triangles** — events DCS reported. Click one to jump there
- **amber lines** — your marks
- **blue lines** — where a jump-back landed. Click to clear

A jump switches to the F10 map while it runs, then puts you back in F2 at normal speed,
paused and ready to record.

---

## About rewind

**DCS cannot actually rewind, and it never has.** A `.trk` file is the mission, plus a
recording of every command you pressed, plus a random seed — DCS re-simulates the whole
thing from the start each time you play it. There is no saved snapshot of minute 47 to jump
back to.

So Replay Deck rewinds the only way anything can: it restarts the track and fast-forwards
back to where you asked for, then pauses on the exact second. **One button instead of a menu
crawl**, and you can walk away while it works.

How long that takes depends on your machine and the mission. Measured on the development
box: a short single-player track fast-forwards at about **24×**, a unit-heavy multiplayer
one at about **6.6×**. So an hour-deep rewind is a few minutes, not instant. Short tracks
are near enough instant.

The **seek** button (steady / fast / max) sets how hard it pushes. Max is quickest, but DCS
itself can become unstable at extreme time acceleration on unit-heavy missions — that is a
DCS limitation, not this tool, and it is why the default is not max.

## Where the event markers come from

DCS's own debriefing data, not Tacview. No export step, no extra software, and it works on
tracks you flew months ago.

Events appear **after a replay pass finishes**, because that is when DCS writes them. Run a
track through once — or seek to the end — and every launch is marked from then on. They are
saved per mission, so it is a one-time cost per track.

---

## Requirements

- Windows
- DCS World
- Nothing else. The exe is self-contained; no .NET install needed.

## Support

Come and say hello in Discord — bugs, ideas and "it did something weird" all welcome.

**https://discord.gg/PGfmpJMeY5**

---

*Copyright © SYNTAX. All rights reserved.*
