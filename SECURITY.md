# Security & privacy — DCS Replay Deck

Replay Deck is closed source, so this document states exactly what it does on your machine.
It is deliberately exhaustive and boring. If anything here turns out to be wrong, that is a
bug — report it in the Discord and it will be fixed.

Every release ships a published **SHA-256** so you can verify the exact file you downloaded,
and the DCS-side hook (the only code that runs inside DCS) is published in full — see the
bottom of this document. The current release has been scanned by ~70 antivirus engines with
zero detections: [VirusTotal report](https://www.virustotal.com/gui/file/aa1542aab4b139c9ee586bff92034c50074f9a3c66f379a1dbb9085d79db3e04).

## It is not a keylogger

This is the thing people worry about, so it comes first.

The global shortcuts (mark, pause, jump to previous/next mark, custom rewind) are registered
with the Windows **`RegisterHotKey`** API for exactly five combinations, all `Ctrl+Alt+…`:

| Shortcut | Action |
|---|---|
| `Ctrl+Alt+M` | mark here |
| `Ctrl+Alt+P` | pause / resume |
| `Ctrl+Alt+Left` | previous mark |
| `Ctrl+Alt+Right` | next mark |
| `Ctrl+Alt+Backspace` | custom rewind |

With `RegisterHotKey`, Windows notifies the application **only** when one of those exact
combinations is pressed. The app never receives, sees, records, or transmits any other
keystroke — it is not technically capable of it. This is **not** a low-level keyboard hook
(`WH_KEYBOARD_LL`), which *would* see everything you type; that was avoided on purpose, and
you can confirm it from the published hook and the behaviour of the app.

Separately, the deck **sends** synthesised keystrokes **to DCS** (the time-acceleration keys
and the F2/F10 view keys) when you drive a seek or change speed. That is why an automated
sandbox may tag "input manipulation" — it is the tool doing its one job: driving the replay.
It only sends to whatever window has focus while a seek is running, and only those keys.

## Network — localhost only, nothing leaves your machine

Replay Deck makes **no external network connections**. There is no telemetry, no analytics,
no update check, no "phone home", no account, no server. The only sockets it opens are on the
loopback interface (`127.0.0.1`):

| Purpose | Socket |
|---|---|
| Receive state from the DCS hook | UDP `127.0.0.1:31490` |
| Send commands to the DCS hook | UDP `127.0.0.1:31491` |
| Talk to OBS (only if you enable recording) | WebSocket to `127.0.0.1:4455` (host/port you set) |

If you scan the exe on VirusTotal you may see one contacted IP (a Cloudflare address). That
is the **.NET runtime's** own certificate/connectivity check, not this application — the app
contains no HTTP or web client code at all.

## Files it writes

Nothing is written into your DCS **install** folder, so DCS updates and Integrity Check are
unaffected. What it does write:

| Path | What |
|---|---|
| `Saved Games\DCS\Scripts\Hooks\ReplayDeck.lua` | The DCS-side hook, self-installed on first run and re-checked each launch. **Published in full — see below.** |
| `%LOCALAPPDATA%\DCS-Replay-Deck\settings.json` | Your DCS folder, OBS host/port/lead/trail, window position, custom-rewind amount. The OBS password is stored **encrypted** (see below). |
| `%LOCALAPPDATA%\DCS-Replay-Deck\marks\*.json` | Your named marks, per track. |
| `%LOCALAPPDATA%\DCS-Replay-Deck\events\*.json` | The event list DCS reported, per track (cached so you do not re-scan). |
| `%LOCALAPPDATA%\DCS-Replay-Deck\seek.log` | A diagnostic log of seeks. Local only. |
| `<track>-unlocked.trk` | Only when you click **Unlock** — a copy of a chosen track with view restrictions removed. Your original is never modified. |

OBS video clips are written by **OBS**, to OBS's own recording folder — Replay Deck only tells
OBS when to start and stop.

## The OBS password

If you use the recording feature, your obs-websocket password is stored **encrypted with
Windows DPAPI**, tied to your Windows user account, in the settings file above. It is useless
if that file is copied to another machine or account. It is never logged, never sent anywhere
except the localhost OBS socket you connect to, and it is **never** read out of OBS's own
config file.

## Permissions

Replay Deck runs as a **normal user process**. It does not require administrator rights,
installs no driver or service, makes no registry changes, and does not set itself to start
with Windows.

## What it reads

To do its job it reads: your DCS `Saved Games` folder (to find tracks and read the debrief log
for events), the running process list (to find the DCS window), and standard user folder
paths. This is why a sandbox may tag "system/user discovery" — it is finding DCS and your
tracks, nothing more.

## The DCS hook — the code that runs inside DCS

The hook is the only part of Replay Deck that executes inside your DCS process, so it is
published in full: [**ReplayDeck.lua**](ReplayDeck.lua). The exe installs this exact file; you
can diff it against what lands in your `Scripts\Hooks` folder.

It is a read-only reporter plus a command receiver. It reads DCS's model time and mission
info and sends them out on UDP loopback; it receives pause / resume / restart / seek commands
back. It does not modify your mission, read your files, or change DCS beyond what replaying a
track already does.

## Verify it yourself

1. Check the download's SHA-256 against the value in the user guide / pinned post.
2. Scan the exe — [VirusTotal report](https://www.virustotal.com/gui/file/aa1542aab4b139c9ee586bff92034c50074f9a3c66f379a1dbb9085d79db3e04).
3. Read the hook above and diff it against your installed copy.
4. Run it sandboxed if you would rather — it needs nothing special and will work fine.

Questions or something that does not match what you observe: **https://discord.gg/PGfmpJMeY5**
