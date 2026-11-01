<p align="center"><img src="docs/cassette.png" width="520" alt="A worn clear tape labelled JAPANOISE on red label tape"></p>

<h1 align="center">Mixtape App</h1>

<p align="center"><b>The perfect simulation of an audio cassette for your Mac – just like in 1986.</b></p>

<p align="center"><a href="https://mixtape.toyko.online">mixtape.toyko.online</a></p>

It’s the simulation of a cheap tape recorder, not a high-end audiophile component. A cassette on your Mac desktop. Tape whatever your Mac is playing – a song on Spotify, a clip on YouTube, an Instagram reel (if you REALLY have to) – or your own voice introducing the next song. Flip it over, punch the title onto label tape, and send it to a friend. They don’t even need the app: one tap on the link and the tape plays – on a phone it fills the whole screen.

Recording is fiddly, just like back then in 1986. There’s no shortcut: you can’t just drop in a playlist and hit send. You record in real time, listening to every song as it goes onto the tape. You hit PAUSE at just the right moment – the pause key squeaks a little, and the cut is never quite perfect. It takes time, it’s a pain in the …, but it’s actually fun. That’s exactly the feeling. And you make the effort, because it’s for that one special friend.

<p align="center">
<b><a href="../../releases/latest/download/Mixtape.dmg">⬇ Download Mixtape.dmg</a></b> &nbsp;·&nbsp; macOS 14.4 or later · Apple silicon & Intel
</p>

---

## The story behind it

I’m old enough to have done this for real. In 1986, where I grew up – in the south of Germany near the Czech border (it was the Czechoslovak border back then, just to be exact) – our local record store only had country music. Swapping tapes with friends at school (and after) was the only way to hear anything new. We put real effort into every mixtape, because we made them for each other. To be honest, I wouldn’t have known about The Cramps or The Vaselines without them. A good tape was a sign of friendship.

Tapes stayed with me. In Berlin in the 90s, cassettes were still the medium of the underground – demos, mixtapes and live recordings, passed from hand to hand.

That’s the feeling Mixtape App brings back – into the digital age. You’re not recording for yourself. You’re recording for your friends.

**Make the perfect mixtape. Share it with friends.**

## What it does

- **Just a cassette.** No window, no Dock icon – only the tape floats on your desktop. Hover over it and the deck appears.
- **Records what your Mac plays** – Spotify, YouTube, anything – or the microphone. Switch between SYS and MIC while recording.
- **Like real tape:** recording overwrites what was there, each side holds half the running time (C46, C60, C90), and you flip the cassette to play side B.
- **Four tape types:** Ferro, Chrome, Metal and Clear – and more as add-ons, like the *80s Collection* and its well-worn *Worn Edition*. Make your own: [docs/ADDONS.md](docs/ADDONS.md).
- **Label tape:** type the title onto an embossed plastic strip with a blinking block cursor – 16 colours, as many strips as you like, stuck anywhere and at any angle. There is no delete key: go back and press over it, like the real thing.
- **Drawings** right on the cassette.
- **Write protection:** break out the tab for side A or B and REC won't go down.
- **VU meters and a REC LEVEL fader** that saturates like analog tape when you push it into the red. Outside recording the fader is the volume control.
- **Tape sound** – hiss, wow & flutter, tape tone, spool noise, key clunks – each with its own strength slider, and the settings travel with the tape. Hiss starts switched off.
- **Pause from anywhere** with ⌥⌘P.
- **Send it to a friend – three ways:**
  - **As a link** – one tap and it plays, on any phone or computer. Pasted into an email it shows as a little picture of your cassette. On a phone the tape fills the screen sideways: tap the middle to play or stop, the ends to wind, hold an end while it plays to listen at speed. The tape is encrypted on your Mac before it goes up; the key travels only in the link, so the server can’t read it. Links work for 7 days.
  - **As a web page** for anyone: one `.html` file with the whole tape inside. Your friend opens it in any browser – no app needed – and sees your cassette with its label and drawings, ready to play from the start of side A. It stays under 25 MB, so it fits in an email.
  - **As a Mixtape file** for friends who have the app: they can record over it and send it back.

<p align="center"><img src="docs/deck.png" width="520" alt="A yellow 90s indie rock tape with the deck and VU meters open"></p>

<p align="center"><img src="docs/chrome.png" width="440" alt="A black dark wave tape with three label strips"> <img src="docs/clear.png" width="440" alt="A yellow rainbow tape on blue"></p>

## Free cassette designs

<p align="center"><img src="docs/free-sampler.png" width="700" alt="Three worn cassettes: a clear one labelled Japanoise, a yellow one labelled Indie Rock, a black one labelled Dark Wave"></p>

**[⬇ Free Sampler](https://github.com/aeiou11235/mixtape/releases/download/addons/Free-Sampler.mixtapeskins)** – three cassettes from the *80s Collection – Worn Edition*, well loved, scratched and stickered. Download it, double-click it, and the designs appear under **New Cassette** in the cassette's menu – each as C46, C60 or C90. Make your own: [docs/ADDONS.md](docs/ADDONS.md).

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
| ••• or right-click the cassette | new cassette, tape type, tape sound, **Send to a Friend**, all other settings |
| ⌥⌘P | pause from any app |

## Building from source

Requires the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh      # builds build/Mixtape.app (universal, ad-hoc signed)
./package.sh    # also builds Mixtape.dmg with the guide
./release.sh 0.2 "What’s new"   # publishes a new version here on GitHub
```

The app is plain Swift (AppKit + SwiftUI) without an Xcode project. The web-page tape is `Player/player.html`, filled in by the app with the tape and its audio. System audio is captured with a Core Audio process tap, the microphone through the HAL directly. A `.mixtape` file is a zip archive holding `tape.json` and the recorded takes as AAC files.

Mixtape was written with the help of AI coding tools.
