# PixelClip — iOS app

SwiftUI (iOS 26, Swift 6, strict concurrency) companion for the PixelClip hair clip. XcodeGen is the source
of truth, one `./build.sh` drives everything, one navigation stack (Home at the root). Paths below written
`PixelClipKit/<Folder>/…` are short for `PixelClipKit/Sources/PixelClipKit/<Folder>/…` (except `PixelClipKit/Tests/` and
`PixelClipKit/Tools/`).

```
ios/
  project.yml          XcodeGen spec (never hand-edit PixelClip.xcodeproj — it's generated and git-ignored)
  build.sh             build · run · test · device
  Sources/             the app: App/ (entry, router, demo content), Model/, Views/, Resources/, assets
  PixelClipKit/             local Swift package, no UIKit: .hca codec (incl. scrolling strips), colour pipeline,
                       protocol models, HTTP + virtual clients, sync engine, playlist composer, Bluetooth
                       doorbell + hotspot joiner, send skip rules + timings, motion-sensor calibration, playback engine, playlist schedule, board items, text/drawing engines + tests
  ShareExtension/      the PixelClipShare extension (photos/videos → Send, texts/links → Reader) + MediaInbox
  UITests/             the app's smoke walk
  scripts/make_icon.swift   renders the app icon
  Sources/Resources/Fonts/  bundled OFL fonts + FONTS.json (written by ../tools/fonts/fetch_fonts.py)
  fixtures-out/        .hca written by the Swift encoder, for cross-checking with core/'s C decoder
```

## Build, run, test

```sh
brew install xcodegen          # once
./build.sh                     # xcodegen + Debug build for the simulator
./build.sh run                 # …then install + launch; extra args go to the app (see Debug launch arguments)
./build.sh test                # swift test (macOS, incl. C-decoder parity) + xcodebuild test (simulator)
DEVICE_ID=<udid> ./build.sh device   # build, install and launch on an iPhone (USB or same Wi‑Fi)
```

Choose the simulator with `SIM_NAME="iPhone 17 Pro" ./build.sh run` or `SIM_UDID=… ./build.sh run`
(`xcrun simctl list devices` lists them). `./build.sh device` needs `DEVICE_ID` (from
`xcrun devicectl list devices`) and a signing team (see Bundle id and signing). Only actionable lines are
printed; the full log is `build/last-build.log`.

`./build.sh test` also runs the `PixelClipUITests` smoke check (`HomeSmokeTests`, see The app ▸ UI test). It builds `../core` with CMake if `../build/core/tools/hcainfo` is missing, so the
parity tests can run `hcaenc`/`hcainfo` against Swift output (they skip themselves if the tools
aren't there, and always on the simulator).

Directly, if you prefer:

```sh
xcodegen generate
xcodebuild -project PixelClip.xcodeproj -scheme PixelClip -destination 'platform=iOS Simulator,name=<simulator name>' build test
(cd PixelClipKit && swift test)
```

## The app

One home screen, four verbs (**Send, Draw, Write, Playlist**), four Extras one tap away, and nothing
technical on the way (design: [`docs/DESIGN.md`](docs/DESIGN.md)). No tab bar, no
onboarding, no connect button, no confirmation dialogs: every Send can be undone, removing from the
playlist is a swipe with a 5-second Undo. Dark-first (ground `#0E0C14`, cards `#1A1726`, accent
`#C6A2FF`; light mode keeps the system backgrounds and the `#8445CE` accent), the system font with
Dynamic Type, press feedback on touch-down everywhere (`Z2Press`), SwiftUI springs (`Z2.spring`),
reduced motion respected, VoiceOver labels on every icon button.

### Screens and where they live

| Screen | Code (Sources/Views unless noted) | What it reuses |
|---|---|---|
| Navigation | `AppRoot` (one `NavigationStack`, the sheets, the toast, the photo picker); `App/Router.swift` (`Route`, `Extra`, `ComposeMode`, `Toast`) | — |
| **Home** | `HomeView`, one screen without scrolling on a 390×844 iPhone at the default text size (only Recent may be below the fold; larger text scrolls): header + `StatusLine` (`ClipSession.statusLine`, green dot when `isNearby`, peeks over Bluetooth every 30 s, 10 s while a send waits, and reads `/status` over a fast-lane link that's up), the send-status capsule, `NowPreview` (the virtual clip's live panel; else what `/status.playlist.current` says the clip plays, heard in the last 15 min — `ClipReported`, "On the clip now · playlist · Tarot"; else the Now item) + the **Undo** pill (`NowOnClip.canUndo`), the four `VerbTile`s (~88 pt, icon left of the title), `ExtrasRow`, `RecentStrip` | `ClipScreenPreview`, `ContentPreview`, `LibraryItemPreview` |
| **Send** | the system photo picker (`AppRoot`), then `SendCropView`: the clip-shaped frame ("THE CLIP SEES THIS"), a trim bar for videos/Live Photos/GIFs, "Show the whole photo" (fit/fill) | `CropCanvas` + `CropAnimator`, `EditorModel`, `RangeSlider` |
| **Draw** | `DrawScreen` → `CreateDrawView` (portrait: the big buttons under the timeline; landscape: Send in the bar); keeps the doodle in progress until it's sent | `CreateDrawModel`, `CreateCanvas` |
| **Write** | `WriteView`: live preview, text box (160 letters), four looks (`WriteLook`: **Bold** Fredoka Bold, **Script** Pacifico, **Typewriter** VT323, **DOTS** DotGothic16 with the LED dot pattern). The app decides still vs scroll: still when the message, fitted to the screen, is at least as big as a scrolling line (40 % of the height) would be. **Bounce around** (§5b.1, under the looks; "The words move with your movement"): at most 12 words ("7 of 12 words" near the limit, typing stops there), the preview shows the words resting along the bottom edge, and Send / Add to the playlist store a **words sheet** instead of a picture | `CreateTextModel`, `MarqueeRenderer`, `WordsSheetRenderer` |
| **Playlist** | `PlaylistView`: the on/off card, rows (thumbnail, name, `PlaylistStore.timingLine`), drag to reorder, swipe to remove + Undo toast, tap → `TimingSheet` ("Play it once at a time"), **+ Add something** → `AddSomethingSheet` (photo, drawing, message, an extra; every maker then ends in "Add to the playlist") | `PlaylistStore` (Model) |
| **Extras** (sheets) | `ExtraSheet` + `ExtraLayout`; `ScenesExtra`, `LoopsExtra` (same file), `TarotExtra` + `TarotReadingsView` + `TarotCardEditor` (`ExtraTarot.swift`), `ReaderExtra` | `SceneAnimation`, `StarterStore`, `TarotSettings` / `TarotBundle` / `TarotMaker` (`Model/TarotStore.swift`), `ReaderPlayer`, `ReaderStore` |
| Re-send | `ResendSheet` (Recent ▸ a thumbnail); long-press a thumbnail ▸ Remove from recents (hidden at once, the library copy goes 5 s later unless the clip or the playlist uses it) | — |
| **Settings** | `SettingsView`: Clip (brightness, auto-rotate + upside down, battery), If something's off (`CantFindClipSheet` in `HelpViews`, `CalibrationSheet`, Advanced) | `ClipSession` |
| Advanced | `AdvancedSettingsView`: clip name, screen on while receiving, Wi‑Fi always on / timeout, sleep level, Bluetooth wake, hotspot password, forget Wi‑Fi, reset the motion sensor, firmware update, battery log + reset, the clip's raw status, About, Debug (virtual clip) | old `SettingsView` internals |
| Share extension | `ShareExtension/`: a photo/GIF/video goes to `MediaInbox` (App Group) and opens in Send's crop screen when PixelClip becomes active (`App/ShareInbox.swift`); a text or link goes to `ReaderInbox` and opens in the Reader extra | `ShareSheetView`, `ReaderStore.importInbox` |

**The Extras.** *Tarot*: see [The Tarot](#the-tarot-oracle-protocol-5f) below. *Scenes*: the five
scenes with their palettes. *Loops*: the 20 PixelClip pack loops. *Reader*: paste (a `PasteButton`, no
prompt) or a file, or one of the saved texts; 250 / 350 / 500 wpm.

### Bouncing words (PROTOCOL §5b.1)

`PixelClipKit/Text/WordsSheet.swift`: `WordsSheetRenderer.render(WordsSheetSpec)` turns a text into the `words` scene's
**sheet**: one frame per word (whitespace-separated, ≤ 12) in the Write look's font and colour (the accent; DOTS
through the LED dot pattern) on black — black is transparent on the clip. The point size is the largest (binary
search to 0.25 pt) with the cap height ≤ 72 px, the line height ≤ 96 px, the widest word's ink ≤ 360 px, the
words' total ink ≤ 45 % of 536×240 and N·w·h ≤ 514 560; every frame is the largest ink box plus 2 px with the word
centred (one Bold word: ~79 pt, bounded by the line height; twelve: ~63 pt, bounded by the ink area). The `.hca` is
RGB565BE, RLE16 when it's smaller, with the glyph-atlas flag (its frames are sprites, so a non-536×240 asset is
accepted and can't be shown as a picture); id `words-<10 hex of SHA-256 of the words, the look and the size>`, the
same for the same text and look. `restingStill(frames)` lays the words along the bottom edge (rows from the bottom
up, centred, 8 px apart): Write's preview, the library thumbnail and the virtual clip's frame (no physics).
`MomentContent.words(sheet:text:)` composes to `{"type":"scene","scene":"words","id":"<sheet>","params":{"bounce":60}}`
(in `queue[]` the sheet goes in `asset`, `id` being the entry's own); `assetRefs` / `assetIDs` carry the sheet, so the
sync uploads it, the plan drops the item without it and `keepIDs` protects it; `/status.playlist.current` is
`scene:words`. The library stores it as kind `words` (`LibraryStore.addWords`: id = the sheet id, `words.json` with
the text and the look, the resting still as poster); `content(for:)` gives `.words`. The virtual clip validates it
like the firmware (sheet required → 422 `invalid_playlist`, absent → `unknown_asset`, 1–12 frames, ≤ 536×240,
N·w·h ≤ 514 560 → `invalid_playlist`; deleting the sheet drops the item) and shows the resting still; `POST /show`
of a sheet a words item or queue entry uses shows it as that scene (like the oracle's borrow), another atlas → 404
`unknown_asset`.

### Board items (PROTOCOL §5g)

A board is a generic list of timed row pictures (a timetable, the rest of today's agenda): a sheet `.hca` of row
frames, an optional fixed header and "nothing left" frame, and rows that each disappear on the clip's own clock once
their `until` has passed; the clip scrolls the list when it is taller than the screen. PixelClipKit models it as
`BoardContent` / `BoardRow` (`PixelClipKit/Board/Board.swift`): `playlistItem()` gives `{"type":"board","id":"<sheet>",
"header":…,"empty":…,"rows":[…],"scroll_px_s":16}` and `queueEntry(…)` the `queue[]` form (the sheet in `asset`);
`MomentContent.board` carries it through the playlist composer, the Tonight plan and the sync like any other item.
`Board` holds the §5g limits, `visibleRows` and `frame(…)` (the panel at a given time), which the virtual clip uses
to validate (`invalid_playlist` / `unknown_asset` as the firmware) and draw a board, reporting `board:<sheet>` as
`/status.playlist.current`.

**The app has no screen that builds a board today**: it is a device and API capability (and a PixelClipKit model), ready
for a feature that renders rows into a sheet (up to 536 px wide; the clip centres narrower rows).

### Sending, invisible

`App/Sender.swift` is the only way the UI sends. `sendNow(content, title:)` sets Now and runs
`SyncController(.playlist)` in the background; `read(docID:)`
runs `SyncController(.reader(…readNow: true))`; `addToPlaylist` adds to `PlaylistStore` and sends. No
progress sheet and no toast: the **send-status capsule** (`Views/SendStatusCapsule.swift`, Liquid Glass,
floating below Home's header and at the top of the Playlist screen) says the `Sender.stage` in plain words —
"Looking for the clip…", "Waking the clip…", "Connecting…", "Sending 2 of 5 · 40%", "Sent" (5 s, with
**Undo**) or "Added to the playlist". When the clip can't be reached (`SendProblem.needsConnectionHelp`,
button press, not answering) the job is kept: "Can't reach the clip — will retry" with **Retry** (a full
attempt now) and **Cancel** (stop waiting; the changes go with the next send); a Bluetooth look runs
**every 10 s** while the app is open (whatever screen is up) and when it comes to the foreground, and the
send goes out as soon as one hears the clip. Other problems (full, rejected) show their title with Retry.
Removals keep their toast. Playlist edits (reorder, remove, timing, on/off) send quietly but show in the
capsule too. Every send is still the one composed document (`ClipDocument`: Now + the playlist); the
playlist's pictures (and Now's) are never deleted from the clip as orphans (`SyncOptions.keepIDs`), so
turning the playlist off and on again is a playlist PUT over Bluetooth, not a Wi‑Fi upload. Now plays
first in the rotation, so the switch alone would leave what's on the clip there for the rest of its minute
(and every off/on starts that minute over): `Sender.turnPlaylist(on:)` follows a successful send with
`POST /next` when the rotation has a second entry, so turning the playlist on shows something new at once.

**Send log** (Settings ▸ Advanced ▸ Send log, `Model/SendLog.swift`, also the unified log, category
`sendlog`): one line per step — the toggle, the request (or "queued behind the running send"), every
Bluetooth look ("heard PixelClip-1A2B (−58 dBm)", "not heard (look scan timed out)", "found … already connected
to this iPhone (not advertising): using that link", "the link doesn't answer: dropping it and scanning"),
the fast lane or the doorbell ("writing the wake", "wake accepted"), the join, every request with its route
and time ("PUT /playlist over Bluetooth · 0.09 s"), the outcome and the 10 s retries. Share or clear it there.

**Why "turning the playlist on did nothing" could happen (the cause the code and the firmware point to).** The phone only found the clip by its Bluetooth
advertising, and the clip advertises only while no central is connected to it. When iOS kept a connection
to the clip up after the app had let it go (or the app's own link had gone stale), every scan timed out:
`nearby` went nil (grey dot, "will send when the clip is near"), the fast lane couldn't link, the doorbell
couldn't ring — so the clip saw no wake, no session and no PUT — and every retry repeated the same failing
scan. A look also trusted an already-linked peripheral forever and never scanned again. Now: a scan also
takes the clip from the peripherals already connected to the iPhone
(`retrieveConnectedPeripherals`, rssi 0 in the log); a look on an existing link checks that it answers
(2 s) and otherwise drops it and scans; a send whose fast lane linked but didn't answer falls back to the
doorbell + Wi‑Fi path instead of giving up; the wait looks every 10 s from any screen; and the playlist's
pictures stay on the clip, so the toggle needs only Bluetooth.

### The Tarot (oracle, PROTOCOL §5f)

Jean Dodal's 22 trumps (Lyon, 1701; BnF via
Wikimedia Commons, public domain) with PixelClip's own texts, read the way *The Way of Tarot* reads a three-card row.
One reading only (§5f.6): the person holds a question, presses once to arm the deck, shakes, three cards
answer — no question card, no card of the day, no modes (§5f.8). The app's preview frames (`PIXELCLIP_TAROT_PNG=<dir> swift test --filter TarotTests/testWriteScreens`);
a whole draw as the clip shows it, walked with taps only at Medium text (armed, the five lean screens, the three
details):
`PIXELCLIP_TAROT_FLOW_PNG=<dir> swift test --filter TarotFlowPNGTests`.

- **Resources.** `Sources/Resources/Tarot/` (folder reference → `PixelClip.app/Tarot/`): `dodal/00-le-mat.png …
  21-le-monde.png` + `back.png` (236×448, matched by their `NN-`
  prefix), `readings.json` and the phrase bundles `reader-fr.txt`, `reader-en.txt`. These checked-in files are the
  maintained copies; the two phrase bundles are kept byte-identical to `core/fixtures/tarot/` and
  `PixelClipKit/Tests/Fixtures/tarot/` (the C and Swift tests read those).
- **The extra** (`TarotExtra`): the deck face down + three faces fanned out; Français / English; Text on the clip
  Small / Medium / **Large** (default); Edit readings › (the 22 cards → `TarotCardEditor`: the card large, its name
  on the clip, keyword, last line (the closing, said when the card is in the centre) and reading editable per
  language, a live preview, Restore the original; the card's question and number note are no longer edited: nothing
  on the clip uses them); Send / Add to the playlist. Settings and edits persist in `TarotSettings` (UserDefaults).
- **What goes to the clip (§5f.2, §5f.10–§5f.12).** Per language — the deck `D` at **108×206** (§5f.12: the
  card's ratio, leaving the keyword row under the three; back + 22 faces downscaled from the 236×448 Dodal scans with
  vImage's high-quality Lanczos and Floyd–Steinberg dithered, a glyph atlas; shared by both languages; roughly 1 MB, an estimate from the
  card area; its id carries the size, `tarot-dodal-dk108-…`, so a deck of another size is remade and uploaded once), the keys `K` (§5f.12 **160×34**, frame i = card i's keyword in Playfair Medium Italic, white on black; one size per language, the
  largest (half-points) at which the longest keyword's ink fits 140 px and the line (ascent + descent) 28 px —
  **fr 21 pt** (the line height decides; widest "Transmission" 120 px), **en 20.5 pt** ("Transformation", 138 px);
  the ink centred across the 140×28 box at (10, 2) and the line box centred in its rows, so all keywords share one
  baseline; 51 / 49 KB; optional on the clip), the **phrase bundle** (`/texts`, `tarot-reader-<lang>-<10 hex of SHA-256>`) and two **glyph-atlas
  fonts** (`TarotFonts`, Playfair Display) at the chosen text size: the body `tarot-font<pt>-<hash>` at 18 / 22 / 26
  pt with its accent atlases, a compact face (12 pt) and, since §5f.11, a **large** face at 1.3× (23 / 29 / 34 pt) —
  `{n,na,c,ca,l,la}` atlases, the document with `"large":{…}`; 295 / 368 / 441 KB, of which the large face +135 /
  +181 / +223 KB — and the numeral's `tarot-big<pt>-<hash>` at 48 / 56 / 64 pt (26 / 30 / 35 KB). No notes, no text
  asset. Sizes coexist on the clip; atlases nothing uses any more are cleaned up. Per language at Large roughly
  1.6 MB, of which the deck is roughly 1 MB (estimates, not measured at this deck size).
- **Item.** `{"type":"oracle","id":B,"reader":B,"deck":D,"keys":K,"font":F,"font_big":G,"cards":22,
  "shake_g":0.9,"face_ms":0,"page_ms":0,"hold_ms":300000}`: `id` is the bundle's `/texts` id (`reader` the same, one
  release); no `pages`, no `mode`, no `daily`, no `notes` (older ones are read and ignored); queue entries name it
  in `asset`.
  `OracleItem.libraryID` (never sent) ties it to the library item, only the app's poster (the waits screen, never
  uploaded; its recipe `oracle.json` and `reader.txt` beside it). `Playlist.assetIDs` carries D and K;
  `oracleReaderIDs` / `oracleFontIDs` the rest. Older oracles are remade after launch (`TarotMaker.upgrade`). Held
  as a lone Now item; in the playlist (and as a one-off) it plays **3 minutes**.
- **Sending.** `TarotReaderSend.prepare` (before the playlist, as for the Reader): font atlases the clip lacks →
  `/fonts` (body, big) → `/texts` (the bundle); then `SyncEngine` puts D, K and the playlist. An oracle whose
  bundle or body font couldn't go is left out of the send, a missing big font only drops `font_big`; Tarot bundles
  and atlases that neither the new playlist nor the clip's current one names are deleted. The user's edits go into the
  bundle's card lines (`ReaderBundle`, byte-identical to the shipped file without edits, `srole` and `brief` lines
  and all).
- **Sentence reader** (§5f.1 v3, §5f.6, §5f.7). `PixelClipKit/Tarot/SentenceReader.swift` is a line-for-line port of
  `core/src/oracle_reader.c`: `compose(a:b:c:)` (`orr_compose`) and `composeLean(a:b:c:fits:)` (`orr_compose_lean`),
  q = −1 always (the engine refuses a question card). Paragraph: findings couple by order 5, encounter 4, centre
  gaze 4, facing/back 3 ×2, kinship 3, succession 3, degree step 2, arc 2, placement 2, hidden sum 2,
  open/closed 1, follow 1, echo 1, then the positions and **B's closing**; over 900 bytes the weakest finding goes
  first. Lean screens: (0) by card — one `[short.card]` variant for the row (`"-1,A,B,C,short.card"`) filled with
  A, B, C (`{X.srole}`, else the role); (1) by position — `[short.positions]`; (2) by the numbers — the arc
  sentence with its numerals; (3) together — the strongest finding other than arc, gaze.front, follow and echo;
  (4) and — the second such finding + " " + B's closing if that fits a page, else the finding alone if it fits,
  else the closing alone (also with no second finding). "Fits a page" is the caller's test: the clip's body font at
  the item's size (`OracleScreens.fitsLeanPage`, as the virtual clip and Home use it); without one, ≤ 150 code
  points (the fixtures' reference rule). Variant = 32-bit FNV-1a over `"-1,A,B,C,<section>"`.
  `SentenceReaderTests` replays **every case of `cases.json` (118) and `cases-lean.json` (318)** byte for byte,
  3 000 engine rows in `PixelClipKit/Tests/Fixtures/tarot/reader-rows.txt` (paragraph and the five lean screens), and
  every row of a bundle when `PIXELCLIP_READER_ALL=<dir>` holds the engine's dumps (all 55 440 rows of fr, en, synth,
  synth3, long and nocentre matched on 2026-10-19).
- **Arming** (§5f.8). A shake on waits does nothing; a **tap** on waits arms: **armed** shows the back with
  `[prompt.armed]` ("Secoue le jeu." / "Shake the deck.", else the plain prompt; `[prompt]` is now "Pense à ta
  question, puis appuie." / "Hold your question, then press."). On armed a shake **or** a tap deals, a double-tap
  disarms, `hold_ms` idles it back to waits. Shakes are ignored from the shuffle through the hold: a new draw means
  back to waits, tap, shake. `POST /oracle/draw` deals from anywhere (the phone chose it).
- **No interruptions** (§5f.8). While a draw is in progress (any state but waits) the virtual clip
  (`PlaybackEngine.setDrawInProgress`) defers the oracle's end (rotation `duration_ms`, a show's or queue entry's
  end, its time window), and every queue entry; back at waits they fire at once if still
  due (a queue entry more than 10 minutes late is skipped, as always). `/show` and a new playlist still take effect
  at once.
- **Screens, in order** (§5f.7, at most 11, each one page): waits → armed → (shuffle) → **three** → lean **by card** →
  **by position** → **by the numbers** → **together** → **and** → **detail** A · B · C (`card.<i>.brief`, skipped
  when the bundle has none) → three (hold). No thread, no reading pages, no paragraph screens: the paragraph is
  composed for `/status.oracle.reading` and the phone. Tap = next (`POST /oracle/turn`; on waits arm, on armed
  deal), double-tap = back (`POST /oracle/back`; the reverse; nothing on waits), shake on armed = a draw (random,
  three distinct cards, never the previous row as a set; `POST /oracle/draw {"cards":[a,b,c]}` forces one). No
  timers by default; `hold_ms` (5 min) is the idle timeout back to waits. `/status.oracle` = `{cards, state,
  cards_drawn, card, page, reading}`: states `waits | armed | shuffle | three | lean | detail | hold` (older ones
  read as waits); `page`
  0–4 in `lean`, 0–2 in `detail`; `card` the detail card; `reading` that screen's text in `lean` / `detail`, the
  whole paragraph otherwise.
- **The screens' layout** (§5f.9–§5f.12; `OracleScreens`, `OracleCompositor`, framebuffer coordinates, mirrored
  pixel for pixel by the virtual clip and Home's preview):
  - **The hint** is one ▶ (8 × 9, the accent; `OracleScreens.paintHint`) in the BOOT corner — the top-right button
    with the picture upright and the USB end on the right: normally its right edge 8 px from the right edge and its
    top row at y 4, pointing right; flipped its left edge 8 px from the left edge and its bottom row at y 235,
    pointing left — inside a 24 × 16 corner reserve where nothing else is drawn (`cornerReserve(flipped:)`); on every
    screen but the shuffle, moving live on a flip. No words (`[hint.*]` stay in the bundles, unused).
  - **Cards** (108×206): *three*, *hold* and the shuffle at y 0, x 52, 214, 376 in both orientations, with the
    keyword row `K[A] K[B] K[C]` (160×34, centres under the cards, pasted whole: the tiles don't overlap) at y 206,
    x 26, 188, 350 on *three* and *hold* (none on the shuffle, none when the item has no keys); the back (*waits*,
    *armed*) and the *detail*'s card at y 17, x 8 normally, x 420 flipped. The corner reserve stays clear in both
    orientations.
  - **Text boxes** (224 rows: 16…239 normally, 0…223 flipped): full width x 8…528 (the lean screens, a detail without
    its card) and beside a card x 124…528 normally / x 8…412 flipped (the prompts, the detail); lines wrapped by
    `PixelClipKit/Text/TextWrap.swift` (the mirror of `core/include/textlay.h`, PROTOCOL §5c.1) and centred.
  - **As big as fits**: every text screen in the largest face whose page holds it — large, else normal, else
    compact; a detail loses its card only when even compact doesn't fit beside it (`OracleReaderTests` prints the
    count of briefs and lean screens per face and size as `TAROT_FACES`). The "and" screen's one-page test (§5f.7)
    is the normal face in the full-width box of the normal orientation (520 × 224, `OracleScreens.fitsLeanPage`), so
    the composer's texts and the fixtures don't depend on the face a screen is drawn in.
  `PIXELCLIP_TAROT_FLOW_PNG=<dir>` writes the whole draw in both orientations (`normal/`, `flipped/`).
- **On Home.** While the Tarot is Now: **Arm** on waits (`/oracle/turn`), then **Deal** (`/oracle/draw`) and Back
  once armed; while a draw shows **Back** and **Turn** (fast lane first, never retried over Wi‑Fi); on the virtual
  clip, shaking the iPhone deals once armed. The extra says "Hold your question. Press once to arm the deck, then
  shake." `OracleReadingCard`: once the
  row is drawn, the three cards with their keywords, the five lean lines in a large serif (the one on the clip
  highlighted), the three briefs (the one on the clip highlighted during the details), then the whole paragraph.
- **Virtual clip.** `OracleMachine` and `OracleCompositor` as the firmware; validation as the firmware's: `cards`
  ≥ 3, `font` required (422 `unknown_font`), `font_big` optional, unknown bundle 422 `unknown_text`, `reader` ≠ `id`
  or a bundle without `[prompt]` / a card's reading 422 `invalid_playlist`, a bad forced row 422 `invalid_cards`;
  the deck (and named keys) absent 422 `unknown_asset`, a deck other than 108×206 or keys other than 160×34 ×
  cards 422 `invalid_playlist`; no keys: no keyword row; `notes` accepted and ignored; deleting the bundle, D or K
  takes the item out; 409 `not_showing`.
- **Credits**: Settings ▸ Advanced ▸ About (`TarotCredits`).

### UI test

`UITests/HomeSmokeTests.swift`: Home → Send (the photo picker, cancelled) → Write → Playlist → Settings →
back; and an Extra (Scenes ▸ Fire) sent in the background with **Sent** and Undo in the send-status capsule, then Undo;
and Write's bouncing words to Now and to the playlist.

## Under the hood

The plumbing is PixelClipKit: the clients, sync and the firmware protocol. Some notes below name earlier screens
(the Clip tab, the send sheet, Tonight) where a mechanism first showed; the same mechanisms now run behind Home's
status line, the Sender's toasts and the playlist.

- **Now and the playlist.** `NowOnClip` holds what the last Send put on the clip (one level of Undo,
  persisted). `PlaylistStore` holds the playlist: untimed entries rotate a minute each while it's on
  (Now plays first, so a Send shows at once), a timed entry is a one-off `queue[]` entry for 60 s.
  `ClipDocument` composes both (`PlaylistSchedule` + `PlaylistComposer`, PixelClipKit) into the one document
  every send PUTs. An older Tonight store, if one is found, moves into the playlist once.
- **"Changes to send"** is one fingerprint of the composed document (+ asset hashes), recorded by
  `ClipDocument.markSent` after any successful send.
- **Strips.** Text & Marquee's Scroll and LED Sign styles export one wide frame (`is_strip`, 537–8192 px)
  that the clip scrolls itself, plus a `scroll` block on the playlist item (speed, direction, gap; the
  rotation item's passes become `loops`; as a lone Now it scrolls endlessly). A 20-character marquee is ~60 KB (LED dots ~160 KB) instead of megabytes. Typewriter,
  bounce, ticker, still (and a scroll on a coloured background, whose gaps would be black on the clip)
  stay frame based. `StripScroller` is the single definition of the scroll maths (engine, virtual clip,
  `ClipScreenPreview`, library timings).
- **Created items** (source `created`) keep their recipe in `create.json`; Edit reopens them in Draw,
  Text or Quick Cards and saving replaces the item.
- **Bluetooth doorbell (PROTOCOL §3).** `PixelClipDoorbell` (PixelClipKit/Bluetooth, CoreBluetooth through the
  `DoorbellRadio` seam, `CoreBluetoothRadio` on the device) scans for the clip's service UUID, connects,
  reads `status`/`info`, writes `0x01` to `wake` (with response) and waits for the `session_active`
  flag, then drops the link (Bluetooth is never held during Wi‑Fi). States: idle → scanning →
  found(name, rssi) → waking → accepted (the write was acknowledged) → hotspotUp, or
  failed(bluetoothOff · unauthorized · notFound (8 s) · lowBattery (status flag or ATT error 0x80) ·
  writeFailed). The scan stops at the first match; when the Clip tab's Nearby poll already holds a
  link, a wake neither scans nor connects nor re-reads the status (the notified one is used; a cached
  "session active" is re-read, since skipping the write on a stale one would leave the Wi‑Fi off) and
  writes at once. Every UUID and byte layout is in
  `PixelClipBLE.swift`, copied from `firmware/components/ble/include/pixelclip_ble_uuids.h` (`PixelClipBLETests`
  compares the two). `HotspotJoiner.connect()` = `wakeAndJoin()`: the `GET /status` probe runs
  alongside the ring (already on the clip's Wi‑Fi → done, the ring is cut short), and join attempts
  start as soon as the wake is *accepted* (every 0.5 s for up to 12 s while the access point starts)
  rather than after `session_active`; notFound / Bluetooth off / not allowed / write refused → join anyway (the
  button may have been pressed) and, if that fails, the usual "hold the button" problem; low battery →
  stop (`SendProblem.tooLowToWake`). The send sheet shows it as its first row ("Waking PixelClip over
  Bluetooth"; a skipped row when it falls back), and Connect uses the same call.
  Scanning only happens in the foreground: the Clip tab peeks on appear and every 30 s while visible
  ("Nearby · 64 %" card from the status notifications, never prompting for permission — the first
  Connect does), and drops the link when hidden or backgrounded. Its End Session writes `0x02` when a
  link is up (a session the button started), else `POST /session/end`. `VirtualDoorbell` does the
  same against the virtual clip (resolves at once and starts its session).
- **Faster sends.** Each step of a send is timed (`SendTimeline`, PixelClipKit/Sync): the send sheet shows
  "wake 0.02 s · join 0.09 s · connect 0.19 s · upload 0.07 s · total 0.37 s (end 0.29 s after)" under
  the steps in Debug builds (and in the "Done" toast), and every build logs it with `Logger`
  (subsystem = the app's bundle id, category `send`; Console.app on a device build). What makes it shorter:
  - **A remembered network.** `NEHotspotConfiguration` is installed with `joinOnce = false`, so iOS asks
    to join `PixelClip-…` only the first time. If the system refuses a remembered configuration
    (`HotspotJoinError.refused`: system configuration / invalid / unknown), the joiner falls back to
    join-once at once and stays join-once for the app's life. Settings ▸ Advanced ▸ **Forget Clip**
    removes it (`NEHotspotConfigurationManager.removeConfiguration` for every configured `PixelClip-…` SSID
    and the prefix) and the clock records.
  - **Bluetooth reuse and overlap** (see the doorbell above): the Nearby link is reused, the scan exits on
    the first match, the probe runs alongside the ring and the join starts at the acknowledged write.
  - **No-ops skipped** (`SendSkipRules`, PixelClipKit/Sync): `POST /time` only when the first `/status` says
    `time.synced` is false, its time zone or clock (> 2 s) differs from the iPhone's, or this iPhone
    hasn't synced that clip in the last 10 minutes (UserDefaults `clockSyncedAt.<device id>`: the clip
    doesn't report when it was synced); `PUT /playlist` only when the composed document differs from the
    clip's `GET /playlist` (compared parsed; never skipped with `from_word`, an upload replacing an asset
    or a deletion). The sheet's rows say "clock already right", "Already on the clip".
  - **Close on success.** When the last upload (or the skipped playlist) succeeds the sheet closes with a
    "Done" toast and `ClipSession.endSessionInBackground` reads the new state and ends the session;
    errors there are silent (the clip times out anyway), and the next send or connect waits for it
    (`settle()`). A send with any failure keeps the sheet open as before. "Show for a minute" closes the
    same way.
  - Measured on the simulator against the virtual clip (60 ms per request, 400 kB/s): resending an
    unchanged plan 0.80 s → 0.38–0.41 s; a first send to a fresh clip 5.27 s → 4.94 s (upload-bound).
    The virtual doorbell and joiner are instant, so the big savings — no join prompt after the first
    time, no 1.5 s probe timeout before the ring, no scan/connect when the Nearby link is up, and the
    access point's start overlapping the join — only show on the real clip.
- **Bluetooth fast lane** (PROTOCOL §3b, firmware/README.md "BLE fast lane"). Small requests go over the
  doorbell's Bluetooth link, with no hotspot: the clip's screen never leaves its content and no "WiFi:"
  splash shows. PixelClipKit pieces:
  - `BLEFrameCodec` / `BLEFrameReassembler` (PixelClipKit/Bluetooth): frames of at most MTU−3 bytes, header
    bit 7 first / bit 6 last / bits 0–5 sequence mod 64; sequence gaps, stray continuations and oversize
    messages are refused. `FastLaneRequest` (`METHOD SP path LF [body]`), `FastLaneResponse`
    (`STATUS SP LF [body]`), `FastLaneRoute` (the bulk allow-list, idempotence). Tests replay the golden
    vectors read from `firmware/scripts/ble_api.py` itself, plus its round trips, wrap and gap cases.
    The `req`/`rsp` UUIDs and framing constants are pinned against `pixelclip_ble_uuids.h`.
  - `BLETransport`: over a `FastLaneLink` (the doorbell's peripheral via `CoreBluetoothRadio`, which now
    also discovers `req`/`rsp`; or `VirtualFastLane`). Subscribes to `rsp`, sends one request at a time
    (the rest queue), writes frames without response at `maximumWriteValueLength(for: .withoutResponse)`
    pacing on `canSendWriteWithoutResponse` / `peripheralIsReady`, reassembles the answer, retries a
    429 / 503 once after 300 ms, and gives up after 5 s with a clean reset (late frames of the abandoned
    answer are dropped). Each exchange is logged (`Logger` category `fastlane`, `FASTLANE …` on the Debug
    console): "PUT /playlist → 200, 599 B up in 4 frames, 11 B back, 0.08 s (MTU 185)".
  - `FastLaneClipClient`: every `ClipClient` endpoint over the transport, same JSON, same `ClipError`s as
    `HTTPClipClient`; the bulk routes and a `413 use_wifi` answer throw `FastLaneError.needsWiFi`.
  - `SmartClipClient` (what `ClipSession.client` is). **Routing rules**, per request:
    1. Wi‑Fi session open (joined) → HTTP. Everything, always: once Wi‑Fi is up nothing goes back to
       Bluetooth.
    2. Bulk (`PUT /assets/{id}`, `PUT /texts/{id}`, `POST /ota`, `GET /screenshot`, `GET /assets/{id}`,
       `GET /batlog`) → open Wi‑Fi (doorbell + hotspot) → HTTP.
    3. Otherwise, with Settings ▸ Advanced ▸ Bluetooth Wake on, the fast lane (linking to the nearby clip through the
       doorbell's scan if needed). No link (Bluetooth off, out of range, firmware without `req`/`rsp`) or
       `413 use_wifi` → open Wi‑Fi → HTTP, same request.
    4. A Bluetooth exchange that breaks off midway (timeout, dropped link) is resent over Wi‑Fi only for
       idempotent routes; `POST /next`, `/prev`, `/imu/calibrate` then fail as "can't reach" (the clip may
       already have acted).
    `ClipLinkBroker` (Sources/Model) answers the app's side: Wi‑Fi open = joined; the fast lane = the
    doorbell's link; opening Wi‑Fi = `HotspotJoiner.connect()`, or the running send sheet's own steps.
  - **Sends.** `SyncController` links over Bluetooth first. A send with only small
    requests (playlist-only changes, show of a picture already there, the clock,
    brightness, config, a scene as Now, reader controls) completes entirely over Bluetooth: the sheet shows
    a **Bluetooth** badge, "Reach PixelClip over Bluetooth", the join row skipped ("Not needed: it all went over
    Bluetooth"), each row's duration at its end, and no session to end afterwards (the new state is read
    over Bluetooth). New pictures or texts open Wi‑Fi mid-send in the join row (badge "Bluetooth + Wi‑Fi"),
    then everything goes over HTTP and the session ends in the background as before.
  - **Clip tab.** The Nearby card shows the live status notifications (battery, what's on screen, Wi‑Fi on
    or off) and, when linked with the fast lane, **Quick Actions**: Next, Show Now (what PixelClip plays now, a
    picture already on the clip; a picture it lacks opens the send sheet), End (when its Wi‑Fi
    is on) and a brightness slider (live, coalesced; stored on release). Settings' clip section (name,
    brightness, screen stays on, always reachable, timeouts, Bluetooth Wake = `ble_wake`) reads and writes
    over the fast lane without a Wi‑Fi session ("Linked over Bluetooth · changes apply without Wi‑Fi");
    turning `ble_wake` off over Bluetooth loses its answer by design and counts as applied. Tonight's
    "Sync now" sets the clock over Bluetooth first.
  - **Virtual clip.** `VirtualFastLane` is the clip's end: it reassembles frames, runs the request through
    a route table on `VirtualClipClient` with `VirtualClipClient.transport = .bluetooth` (needs the clip to
    be heard; never starts a session or touches the idle timer; requests land in `fastLaneLog`, not
    `requestLog`), answers 400 `bad_frame` / 413 `use_wifi` / 429 like the firmware, and paces itself like
    a phone link (`.realistic`: MTU 185, 4 frames per 30 ms connection event, 15 ms handler, 0.7 s to link).
    `VirtualDoorbell` hands it out and re-reads its status every 2 s while linked. Settings ▸ Advanced ▸ Debug ▸
    **Simulate BLE Unavailable** (`-PixelClipNoBluetooth`) makes the clip unheard over Bluetooth, so the
    simulator exercises the Wi‑Fi path.
  - **Measured** (virtual clip): resending an unchanged plan over the fast lane takes 0.31 s in all, with 0 HTTP
    requests. The virtual Wi‑Fi path models neither the clip's 2 s "WiFi:" splash nor the iOS join (several
    seconds on the real clip), both of which the fast lane skips. Real-hardware numbers are still to be measured
    (firmware/README.md "BLE fast lane" lists estimates).
- **Motion sensor calibration** (Settings ▸ Sand falls the wrong way; firmware extension `GET /imu`,
  `POST /imu/calibrate`, see firmware/README.md "IMU bench check"). `CalibrationSheet` opens a session
  if needed (the normal connect flow, Bluetooth wake included), polls `GET /imu` at 4 Hz and draws the
  gravity as a ball on a clip outline (a dashed ring marks where it should settle). Step 1 "Hold PixelClip
  upright, screen facing you, like it's in hair", step 2 "Lay it flat on its back, screen up": once the
  readings have been still (within 0.06 g over 0.7 s) and square (~1 g on one axis) for 3 seconds
  (3·2·1 on screen) the step is posted (`upright`, `faceup`). Step 2 doesn't count while it's still
  held in the first pose ("Now lay it on its back…"), which would only earn a `calibration_failed`.
  Step 3 says what changed in plain words (`AxisMapChange`: "Down is now down · Before, sand fell to the
  right") with the matrix under a disclosure, and **Test with Sand** makes the sand scene Now and sends.
  `CalibrationWizard` (PixelClipKit/Motion) is the state machine; `CalibrationProblem` words the errors:
  422 `not_still` (Try Again), `ambiguous_pose` (per-step "hold it straight up" / "lay it flat"),
  `calibration_failed` (Start Over from step 1: the clip discarded both), 409 `no_imu` (final), 404
  (firmware without the endpoint: "Update PixelClip first"), lost connection (Reconnect). **Reset
  Calibration** (`{"step":"reset"}`) asks first. The wizard ends the session it opened when closed
  (not when Test with Sand follows: the send ends it). The virtual clip has a pretend chip mounted a
  quarter turn off (`VirtualClipClient.imuMounting`; uncalibrated, upright reads "right"), the firmware's
  derivation (`IMUAxisMap.calibrate`) and errors; its gravity follows the iPhone's own accelerometer
  (`DeviceTilt`, CoreMotion, only while the wizard is open) on a device, else a simulated pose (upright
  (0, 1, 0); in the simulator the wizard "turns" it for step 2).
- **Screen on during sessions.** With `display_during_upload` on (the default), brightness, Next,
  Show Now and screenshots are live and the copy says so; the old "the screen rests" copy returns
  when the clip reports the panel-off mode (`ClipConfig.screenStaysOn`).
- **Failures in plain words.** `SendProblem` (PixelClipKit/Sync) maps the joiner's `JoinFailure`
  (declined, wrong password, not found, no answer), the clip's HTTP status/error code (413 full,
  422 rejected, with the picture's *name*), a dropped connection after a near-cutoff battery reading
  (the clip ended the session to save power) and protocol mismatches to a title, a message and
  whether Connection Help applies. The send sheets, Connect and the clock sync all
  use it; no raw error string reaches the screen.
- **Battery.** `BatteryReading` is the one rule: icon by quarter, orange under 20 %, red under 10 %
  (or within 80 mV of the 3.5 V Wi‑Fi cutoff), a green bolt on USB, and a rough wear estimate from
  the 5 h full-charge figure. `BatteryGlyph` draws it in the accessory bar, the Clip tab and the send
  sheet; under 20 % the Clip tab shows a gentle "charge soon" banner.
- **Size budget.** Frame-based animations are capped at `ClipBudget.maxAnimationBytes` (4 MB) until
  the firmware pans stills on-device: every frame is stored whole. Ken Burns measures an average
  frame for the chosen move with the real encoder and only offers length × frame-rate combinations
  that fit (default: the largest), the crop editor disables Add over the limit, and the creators
  refuse to save over it. Strips and stills are never limited.
- **Bundled fonts.** Text & Marquee offers the iOS fonts plus 23 Google Fonts families under the SIL
  Open Font License 1.1 (5.96 MB): Retro & Pixel (Press Start 2P, Silkscreen, VT323, DotGothic16,
  Pixelify Sans, Tiny5), Display (Bungee, Monoton, Bebas Neue, Rubik Mono One, Righteous, Orbitron,
  Audiowide, Unica One, Abril Fatface, Major Mono Display), Script (Pacifico, Lobster, Dancing Script,
  Caveat) and Editorial (Playfair Display, Space Grotesk, Fredoka). `python3 -I ../tools/fonts/fetch_fonts.py`
  downloads them from github.com/google/fonts (`ofl/` only, licence checked in METADATA.pb and OFL.txt,
  magic bytes checked, 6 MB budget) into `Sources/Resources/Fonts/<Family>/` with each family's
  `OFL.txt`, and writes `Fonts/FONTS.json`, its Swift twin `PixelClipKit/Text/BundledFonts.swift` (faces,
  weights, italics: the picker's weight/italic controls come from it) and the `UIAppFonts` block in
  `project.yml`; PostScript names are confirmed with CoreText (`--check` re-verifies offline). The
  folder ships as a folder reference (`PixelClip.app/Fonts/…`) so the per-family `OFL.txt` files don't
  collide. Bundled families count as installed when their faces resolve by PostScript name, not via
  `UIFont.familyNames`: iOS keeps a private CoreUI "Bebas Neue" that hides ours from the family list.
  Permanent Marker was skipped (Apache 2.0, not OFL). The LED Sign style switches to Press Start 2P
  (else Silkscreen) the first time it's chosen in an editor session, unless the font is already a
  pixel face. Credits & Licenses lists every family (in its own face) with its copyright line and
  bundled OFL text. `BundledFontsTests` checks manifest ⇄ Swift ⇄ Info.plist, the files and licences,
  that every PostScript name resolves (UIFont on the simulator, CoreText on macOS) and that the
  catalogue offers them.
- **Reader (PROTOCOL §5c).** Library ▸ Add ▸ Read… lists saved texts (`ReaderStore`, Application
  Support/Reader): paste, Files (.txt/.md/.epub), a link (`TextImporter`: Markdown stripping, EPUB spine +
  nav/NCX chapters through a small ZIP reader, readability-style article extraction from HTML), or the
  **PixelClipShare** extension (Safari/Notes ▸ Share ▸ PixelClip; it writes JSON into the App Group
  `group.com.example.pixelclip` inbox, Safari's preprocessing JS adds the page HTML; the app imports on
  becoming active). `RSVPText`/`RSVPTiming` are line-for-line ports of `core/src/rsvp_tok.c` (word index,
  title break, §5c factors, Spritz ORP), `ReaderPreview` of `rsvp_paint.c` (layout, ticks, pause mark,
  "fin" card). `ReaderFontRenderer` renders any catalogue typeface into four glyph atlases
  (`reader-font-<hash>-{n,na,c,ca}`, 210 glyphs; normal = largest size where a 12-glyph word fits with
  its ORP on x = 230, compact = 20 glyphs) plus the font document; the white-ORP option points the
  document's accent keys at the white atlases (`reader-font-<hash>-w`). Reader items are Now or live in Tonight's
  layer (rotation extras, "Until finished"; moments), so every sender composes them; `SyncController`
  first puts their texts/fonts on the clip (`ReaderStore.prepare` → `ReaderPusher.ensure`), and the
  sync's orphan clean-up protects `reader-font-` atlases. Send/Read Now are `SyncRequest.reader`
  (Read Now = the reading becomes Now, `from_word` on that send only; Add to Tonight = a rotation item). The virtual clip stores texts and
  fonts, validates like the firmware (422 `unknown_text`/`unknown_font`, 409 `no_reader`) and reads on
  its panel with pause/resume/seek.
- **Live scenes allow-list.** The firmware's `/scenes` still lists all six; the app only offers
  `SceneCatalog.enabledIDs` (sand, water, snow, fire, balls — "lava" is left out of the app). Tonight's moment sheet, the "Live Scene" add menu and the virtual clip's
  catalogue all read it.

## Settings map

Home ▸ ⚙︎ (`SettingsView`), one screen, then Advanced (`AdvancedSettingsView`) for everything technical:

| Where | What | Stored |
|---|---|---|
| Clip | Brightness (live) · Auto-rotate (Upside down under it when off) · Battery | on the clip (`PUT /config`, over the fast lane when nothing is open) |
| If something's off | Can't find the clip? (help sheet) · Sand falls the wrong way (the calibration wizard) · Advanced | — |
| Advanced | name, screen on while receiving, Wi‑Fi always on, Wi‑Fi timeout, sleep level, Bluetooth wake, hotspot password, forget the clip's Wi‑Fi, Send log, reset the motion sensor, firmware update, battery log (+ reset), the clip's raw status, About, Debug (virtual clip, Debug builds) | on the clip or in UserDefaults |

## Simulator: the virtual clip

In the simulator the **virtual clip** is on by default (Settings ▸ Advanced ▸ Debug ▸ Virtual Clip, Debug builds only). It is an
in-memory emulation of the device — storage, playlist, config, clock, scenes, the tonight
queue and a playback engine that renders the screen — so every flow works with no hardware. It
mirrors the firmware's documented behaviour (error codes, 409 rules, the display staying on during an
upload session — or off with `display_during_upload:false` —, the Bluetooth doorbell, 60 s "show now",
time windows and queue firing). Its state lives for the app's
lifetime; "Reset Virtual Clip" wipes it.

What it emulates, normatively (PROTOCOL §4, §5b–§5g):
- Queue entries play one at a time in `at` order for their full `duration_ms` (default 60 s, default
  transition fade); an entry that would start more than 600 s late is skipped; nothing fires while the
  clock is unsynced or during an upload session (any request opens one; `POST /session/end` closes it,
  and entries that came due fire then if still within 600 s). Windowed items are inactive while unsynced.
- Windows accept `"24:00"` as `until` only; `from == until` is a 422 (and refused by the planner).
- Strips: 240 px tall, one frame, 537–8192 px wide; `GET /assets` reports `"strip":true`; a strip item
  scrolls a 536-px window at `px_per_s` (10–400) with `gap_px` of black between repeats, for `loops`
  passes (travel `536 + loops·width + (loops−1)·gap_px`) or `duration_ms`; without `scroll` it shows its
  first 536 px.

### Debug launch arguments

All are Debug-only (demos, screenshots and UI tests). Pass them after `./build.sh run` (or to `simctl launch`).

| Argument | Effect |
|---|---|
| `-PixelClipDemo` | seed sample items (if the library is empty), send the composed document to the virtual clip |
| `-PixelClipPlaylistDemo` | a playlist of three things (a photo, a message, a one-off at 21:30) |
| `-PixelClipScreen send\|draw\|write\|playlist\|settings\|calibrate\|advanced` | open that screen (`send`: the crop screen on a sample photo) |
| `-PixelClipScreen tarot\|scenes\|loops\|reader` | open that Extra (`tarotreadings`, `tarotcard`: Edit readings, L'Étoile's editor) |
| `-PixelClipScreen add\|resend\|cantfind\|share` | the playlist's Add something, the re-send sheet, Can't find the clip?, the share extension's sheet |
| `-PixelClipReaderDemo` | three Reader texts |
| `-PixelClipTarot [-PixelClipTarotDraw a,b,c\|any\|armed [-PixelClipTarotTurns k]]` | the Tarot as Now on the virtual clip, drawn (that row, or at random) and turned k times, or only armed |
| `-PixelClipFreshClip` | reset the virtual clip after `-PixelClipDemo` (the next Send uploads everything) |
| `-PixelClipOff` | the virtual clip is away (sends wait: "Can't reach the clip — will retry") |
| `-PixelClipSendPending [-PixelClipBackAfter s]` | with `-PixelClipOff`: a send waiting for the clip (the capsule), the clip back in range after s seconds (the next 10 s look sends it) |
| `-PixelClipWiFiOff` | its Wi‑Fi is off but it's nearby (small sends go over the fast lane) |
| `-PixelClipNoBluetooth` | the virtual clip isn't heard over Bluetooth (the Wi‑Fi path) |
| `-PixelClipBattery <pct>[usb]` | the virtual clip's battery, e.g. `15`, `60usb` |
| `-PixelClipFlipped` | the virtual clip with its screen turned 180° |
| `-PixelClipSmokeItems` | one library item of every kind |
| `-PixelClipLandscape` | turn Draw sideways once it's open |

### Firmware alignment and gaps

Strip support was landing in `firmware/` (storage, playlist parser, player) while this pass was made,
uncommitted; the app follows it: strips are one frame, 240 px tall, **537–8192 px** wide (a short
marquee is padded with black to 537); every `scroll` key is optional (80 px/s, left, 0 gap, 1 pass);
`gap_px` ≤ 2000; the pass length is `(loops−1)·(width+gap) + width + 536` px; `right` mirrors the
motion; the only active rotation item plays on without restarting (a strip as an endless tape).
Still different or unverified:
- Nothing strip-related has run on hardware yet; the firmware also needs a free PSRAM block of
  `width × 480` bytes (up to 3.9 MB) to scroll a strip and skips it otherwise — the virtual clip
  doesn't model memory.
- While the panel is off (upload session) the firmware's off-screen preview of a right-moving strip is
  its last 536 px; the virtual clip shows the first.

## Device: the real clip

1. `DEVICE_ID=<udid> ./build.sh device` with your team set (see Bundle id and signing; first time: Xcode may need
   to register the device and add the Hotspot Configuration capability to the App ID — `-allowProvisioningUpdates`
   does it).
2. In the app, just Send. The first time iOS asks for Bluetooth; small sends go over the Bluetooth fast
   lane, and new pictures wake the clip's Wi‑Fi (it shows “WiFi: PixelClip-XXXX” and starts its SoftAP), iOS
   asks to join “PixelClip-…” (the first time only: the network is remembered), and the app talks HTTP to
   `192.168.4.1`. The toast says "Sent" and the app ends the session in the background.
3. Without Bluetooth (off, not allowed, or no answer within 8 s) hold BOOT ≥ 1.5 s first, as before.

The virtual-clip toggle defaults to off on a device (and doesn't exist in Release). The hotspot
password the app uses lives in Settings ▸ Advanced (default `pixelclip-2026`).

**Entitlements / Info.plist** (all in `project.yml`):
- `com.apple.developer.networking.HotspotConfiguration` — `NEHotspotConfiguration` by SSID prefix
  `PixelClip-`, remembered (`joinOnce = false`; join-once if refused). This entitlement needs a **paid developer team** (see Bundle id and signing).
- `NSLocalNetworkUsageDescription` and ATS `NSAllowsLocalNetworking` (the clip speaks plain HTTP on
  its own WPA2 network; IP-literal hosts are outside ATS anyway).
- `NSPhotoLibraryUsageDescription` (live-photo video from the picker) and
  `NSPhotoLibraryAddUsageDescription` (Save Image from a screenshot's share sheet).
- `NSBluetoothAlwaysUsageDescription` (the doorbell). Scanning for the Clip tab stays foreground only.
- No background modes: the app drops its Bluetooth link when it goes to the background and does nothing there.
- French translations of all of them in `Sources/Resources/fr.lproj/InfoPlist.strings` (English in
  `en.lproj`, keep them in step with `project.yml`). Joining the hotspot and notifications have no
  Info.plist strings: iOS words those prompts itself.
- `ITSAppUsesNonExemptEncryption = false` (no export-compliance question when uploading a build).
- iPhone only (`TARGETED_DEVICE_FAMILY = 1`). `UISupportedInterfaceOrientations` lists portrait and
  both landscapes; the app delegate narrows that per screen (see Landscape below), so everything
  but the creators stays portrait. The iPad-only list with all four orientations stays: without
  upside-down somewhere the archive still warns "All interface orientations must be supported unless
  the app requires full screen" (`UIRequiresFullScreen` is deprecated in iOS 26), and it never
  applies to an iPhone-only app.
- `PrivacyInfo.xcprivacy`: no tracking or collection; UserDefaults (CA92.1) and file timestamps
  (C617.1, Discover's cache trims its own files by modification date).

## Landscape (Draw)

The app is portrait except Draw, which may turn sideways.

- **How orientation is controlled.** `OrientationLock` (PixelClipKit/Layout, no UIKit) holds the claims of
  the screens on screen; `.allowsLandscape(.draw / .text / .cards)` claims on appear and releases on
  disappear (order-independent tokens), the most recent claim wins, and with none the mask is
  portrait. `AppDelegate` (`@UIApplicationDelegateAdaptor`, Sources/App/Orientation.swift) returns
  that mask from `supportedInterfaceOrientationsFor:`, and every change calls
  `setNeedsUpdateOfSupportedInterfaceOrientations()` on the view controllers (deferred to the end of
  a running push/pop: re-reading orientations mid-transition left the tab bar hidden). Leaving an
  editor while the phone is sideways drops landscape from the mask and iOS rotates back itself. The
  app never rotates on its own: `UIWindowScene.requestGeometryUpdate` runs only from Draw's "Rotate
  for a bigger canvas" (the one-time portrait hint, then a small button in the canvas corner) and
  the rail's "Rotate to Portrait".
- **Draw in landscape.** One axis-switching layout (`AnyLayout`), so the canvas view, its zoom and
  any stroke survive the turn. The canvas fits at the largest whole step that fits its area both
  ways (`CanvasZoom.fitStep`: 3 device px per canvas px on the iPhone 18 Pro, i.e. 536 × 240 pt,
  1.5× the portrait canvas across and 2.25× its area; step 4 would need 715 pt of the 750 pt safe
  width with no rail). A rotation keeps the zoom relative to Fit and the same point centred
  (`CanvasZoom.carriedStep`). Tools are a rail on the leading edge (Canvas Settings ▸ Tools on the
  Right for left-handed drawing): colour & size (a popover with swatches, the colour picker and the
  tool's options), the 11 tools, undo/redo, onion skin, play, back to portrait; three 44-pt columns,
  or two when that buys a zoom step (SE-class, `CanvasZoom.railColumns`). The frames are a 48-pt
  strip along the bottom (collapses to a 32-pt line with the frame/size readout), with the zoom
  readout, the frame rate and the clip preview as a thumbnail at its end; tapping it enlarges the
  preview from that corner. Pencil, finger, pinch and two-finger pan are the same UIKit canvas in
  both orientations.
- In landscape there's no room for the big buttons: Send (or Add) sits in the navigation bar.

## Bundle id and signing

Everything is set in `ios/project.yml` (XcodeGen regenerates the Xcode project from it on every `./build.sh`):

- `options.bundleIdPrefix` is `com.example`; the targets' `PRODUCT_BUNDLE_IDENTIFIER`s are `com.example.pixelclip` (the
  app), `com.example.pixelclip.share` (the share extension) and `com.example.pixelclip.uitests`. Change all of them to a
  prefix you own before building for a device. `build.sh`'s `device` command launches the app by its bundle id, so
  keep the one in `build.sh` in step.
- The app and the share extension share the App Group `group.com.example.pixelclip` (the `MediaInbox` /
  `ReaderInbox` hand-over); change it everywhere it is named: both targets' entitlements in `project.yml`,
  `Sources/PixelClip.entitlements`, `ShareExtension/PixelClipShare.entitlements` and the code (search for
  `group.com.example.pixelclip`).
- `DEVELOPMENT_TEAM` is empty: set your own team id in the `settings.base` block (or in Xcode for a local
  build). Simulator builds and `./build.sh test` don't need a team.
- The Hotspot Configuration entitlement (`com.apple.developer.networking.HotspotConfiguration`, used to join the
  clip's `PixelClip-XXXX` network) is only available to a **paid** Apple Developer Program team; a free personal team
  can't sign a device build with it.

## Design notes

- **Accent: soft violet** (`#C6A2FF` in dark mode, `#8445CE` in light mode; in PixelClipKit as `BrandPalette` /
  `RGBAColor.accent`, in the firmware as `UI_ACCENT`), so the app, the icon (dot-matrix Zo/né) and the clip's
  system screens share one colour. It is
  RGB565-exact (`C51F`), so the clip shows it without dithering, and it stays luminous on the
  true-black, dark-first UI (10.0:1 on black, 8.1:1 on `#1C1C1E`). The light-mode sibling keeps the
  same OKLCH hue (301°) but is deep enough for text, tints and filled buttons on white: 5.64:1 on
  `#FFFFFF` and 5.05:1 on grouped `#F2F2F7`. Labels on accent fills use `OnAccent`: black on the
  bright dark-mode violet (10.0:1), white on the deep light-mode one (5.64:1). Derived `dim`
  (`#52416B`, the unlit n), `glow` (`#DECBFF`) and `pressed` (`#9C82C6` / `#6B38A5`) complete the set.
  System orange stays the warning colour (battery low, stale, failed).
- **ClipScreenPreview** is the single way anything is shown: true black, 536:240, continuous corners,
  a faint bezel and, in dark mode, a blurred spill of the screen's own light. It only ever displays
  quantised RGB565 frames (decoded `.hca` or `ClipRenderer` output), so previews are exactly what the
  clip shows. Brightness dims like an OLED (less light, still black).
- **Crop editor**: the picture tracks the fingers 1:1 (pinch zooms about the fingers), flings carry
  their velocity with Apple's exponential deceleration, limits rubber-band, rotation snaps to right
  angles with a haptic, and every intermediate frame goes through the real renderer (model-driven
  animation, not view interpolation).
- **PixelClip's tokens** live in `Sources/Views/Theme.swift` (`Z2` colours and springs, `Z2Press`,
  `Z2PrimaryButton` / `Z2QuietButton` / `Z2SendButtons`, `Z2Chip`, `z2Card`, `Z2Row`). Sheets open
  from what was tapped (`matchedTransitionSource` + `.navigationTransition(.zoom)`).
- **Shared components**: `Router` (`App/Router.swift`) + zoom transitions; in `Sources/Views/Components.swift`
  `SectionHeader`,
  `PressableStyle`, the card surface (`FeatureCard`, on `secondarySystemGroupedBackground`, since every screen sits
  on the grouped background and `.background.secondary` vanished on it in light mode), 34 pt tinted icon tiles,
  glass / glassProminent buttons at `.large`, `ContentUnavailableView` empty
  states, insetGrouped settings lists, privacy manifest, `make_icon.swift`.
- **Deliberately absent**: search, background URLSession (uploads are short, foreground, on the clip's Wi‑Fi),
  iPad layouts (iPhone only; portrait except Draw, which also works sideways).
