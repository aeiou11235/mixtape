<p align="center"><img src="docs/cassette.png" width="520" alt="Mixtape cassette"></p>

<h1 align="center">Mixtape App</h1>

<p align="center"><b>The perfect simulation of an audio cassette for your Mac – just like in 1986.</b></p>

Recording is fiddly. You have to handle everything just right, or something goes wrong. But you make the effort, because it’s all for that one special friend. You record the perfect tape and pass it on.

A cassette on your Mac desktop. Tape what your Mac is playing, flip it over, scribble on the label – and send it to a friend, who can record over it and send it back.

Mixtape App is as personal as it gets. *Vibe-coded with love.*

<p align="center">
<b><a href="../../releases/latest/download/Mixtape.dmg">⬇ Download Mixtape.dmg</a></b> &nbsp;·&nbsp; macOS 14.4 or later · Apple silicon & Intel
</p>

---

## What it does

- **Just a cassette.** No window, no Dock icon – only the tape floats on your desktop. Hover over it and the deck appears.
- **Records what your Mac plays** – Spotify, YouTube, anything – or the microphone. Switch between SYS and MIC while recording.
- **Like real tape:** recording overwrites what was there, each side holds half the running time (C46, C60, C90), and you flip the cassette to play side B.
- **Four tape types:** Ferro, Chrome, Metal and Clear.
- **Hand-written label and drawings** right on the cassette.
- **VU meters and a REC LEVEL fader** that saturates like analog tape when you push it into the red. Outside recording the fader is the volume control.
- **Tape sound** – hiss, wow & flutter, spool noise, key clunks, pause squeal – each can be switched off, and the settings travel with the tape.
- **Pause from anywhere** with ⌥⌘P.
- **Send it:** a tape is a single `.mixtape` file on your Desktop. Attach it to an email or message; the recipient double-clicks it and the cassette appears.

<p align="center"><img src="docs/deck.png" width="520" alt="Mixtape with the deck and VU meters open"></p>

<p align="center"><img src="docs/chrome.png" width="440" alt="A chrome tape, side B"></p>

## Install

1. Download **[Mixtape.dmg](../../releases/latest/download/Mixtape.dmg)** and open it.
2. Drag **Mixtape** onto **Applications**.
3. Mixtape isn’t signed by Apple yet, so macOS blocks it the first time. Double-click Mixtape, click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.

   Alternatively, in Terminal: `xattr -dr com.apple.quarantine /Applications/Mixtape.app`
4. The first time you record, allow Mixtape to record system audio or the microphone.

The guide “Read me first” inside the disk image explains this step by step, with the exact wording of each dialog.

## Using it

| | |
|---|---|
| Move the pointer over the cassette | shows the deck |
| REC · REW · PLAY · FF · PAUSE | like a tape deck; hold FF/REW while playing to cue and review |
| SYS / MIC | record from your Mac’s sound or from the microphone |
| Double-click the label | write the title |
| Pencil | draw on the cassette |
| Gauge | VU meters and the level fader |
| STOP / EJECT | stops the tape; when stopped, turns the cassette over |
| ••• or right-click the cassette | new cassette, tape type, tape sound, all other settings |
| ⌥⌘P | pause from any app |

## Building from source

Requires the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh      # builds build/Mixtape.app (universal, ad-hoc signed)
./package.sh    # also builds Mixtape.dmg with the guide
./release.sh 0.2 "What’s new"   # publishes a new version here on GitHub
```

The app is plain Swift (AppKit + SwiftUI) without an Xcode project. System audio is captured with a Core Audio process tap, the microphone through the HAL directly. A `.mixtape` file is a zip archive holding `tape.json` and the recorded takes as AAC files.
