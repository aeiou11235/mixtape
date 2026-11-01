# Cassette designs as add-ons

Mixtape can load extra cassette designs. A pack of designs is one file ending in
`.mixtapeskins`: double-click it, or choose **New Cassette → Add Cassette Designs…** in the
cassette's menu, and its designs appear under **New Cassette**.

A tape made with an add-on design carries that design inside the `.mixtape` file and the web
page, so your friends see it even if they don't have the add-on.

## Making your own

A `.mixtapeskins` file is a zip archive:

```
pack.json
my-design/back.png
my-design/front.png
```

Each design is two pictures of the cassette, seen straight from the front. The app draws the
turning reels and the tape **between** them, and the label text **on top**:

- **back.png** – everything behind the reels: the back half of the shell as you see it
  through the window and holes, and the shadow on the table.
- **front.png** – everything in front of the reels: shell, label, screws, reflections.
  Transparent where the reels should show (the window, the hub holes, the head openings),
  half-transparent for clear or coloured "jelly" plastic.

Both pictures cover the shell plus a margin on every side (for the shadow), at any
resolution up to 4000 px. The shell is 100.4 × 63.8 mm; with a 5 mm margin at 10 px per mm
a picture is 1104 × 738 px.

### pack.json

All positions are in millimetres from the top-left corner of the shell.

```json
{
  "format": 1,
  "id": "yourname.pack",
  "name": "My Tapes",
  "author": "Your Name",
  "version": "1.0",
  "designs": [{
    "id": "my-design",
    "name": "My Design",
    "back": "my-design/back.png",
    "front": "my-design/front.png",
    "margin": 5,
    "hubY": 28.3,
    "hubColor": "#f3f1ea",
    "rollers": [8.6, 60.8, 91.8, 60.8, 1.7],
    "pen": "#1d3f97",
    "title": { "x": 14.6, "y": 5.2, "w": 78.5, "h": 7.8 },
    "labelZone": { "x": 5.6, "y": 4.8, "w": 89.2, "h": 13.5 },
    "labels": [
      { "kind": "side", "x": 9.5, "y": 8.95, "size": 4, "font": "HelveticaNeue-Bold", "color": "#ffffff", "align": "center" },
      { "kind": "length", "x": 38.6, "y": 42, "size": 6, "font": "Futura-Bold", "prefix": "MX-", "prefixColor": "#111111", "color": "#e8712a" }
    ]
  }]
}
```

| Field | Meaning |
|---|---|
| `id` | Letters, digits, `-`, `_` and `.` only. The pack id should be unique to you (e.g. `yourname.pack`); installing a pack with the same id replaces the old one. |
| `margin` | Picture around the shell on every side, in mm. |
| `hubY` | Height of the hub centres. The hubs are always 42.5 mm apart, centred. |
| `hubColor` | Colour of the hubs the app draws. |
| `rollers` | Left roller x, y, right roller x, y, radius: where the tape runs around the bottom corners. |
| `pen` | Colour of the handwritten title. |
| `title` | Where the title is written. |
| `labelZone` | Double-clicking here edits the title. |
| `labels` | Text the app writes: `side` (A/B), `length` (C60), `total` (60 MIN), `minutes` (2×30 MIN) or `text` (with `"text": "…"`). `y` is the middle of the line. Optional: `prefix` and `prefixColor`, `tracking`, `align` (`left`, `center`, `right`). |

Zip the pack (its contents, or the folder holding them) and name the file `.mixtapeskins`:

```bash
cd my-pack && zip -r "../My Tapes.mixtapeskins" pack.json */back.png */front.png
```
