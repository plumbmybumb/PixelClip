# PixelClip — the app, built around four verbs

The app is a simple surface for someone who is not technical at all, over the plumbing in PixelClipKit (clients, sync,
firmware protocol). The implementation map (which view does what) is in [`../README.md`](../README.md) ("The app").

## Principles (Apple HIG / "Designing Fluid Interfaces", applied)

- **One home screen, four verbs: Send, Draw, Write, Playlist.** Every other capability is an *Extra*, one tap away.
- **Every screen ends in one big primary button** ("Send to the clip"), with at most one quiet alternative
  ("Add to the playlist instead"). Back at the top. No tab bar, no hamburger, no onboarding tour.
- **Simplicity, not minimalism**: the common path first, advanced things one level deeper (Settings ▸ Advanced).
- **Forgiveness over confirmation**: Undo after every send (puts back what was on the clip). No confirmation
  dialogs; nothing in the app is destructive (removing from the playlist is a swipe, undoable for 5 s with a toast).
- **Feedback on touch-down**, continuous during drags, springs (SwiftUI default springs; `damping 1.0`
  feel for UI, slight bounce only after a flick). Sheets open from the thing you tapped and can be dragged
  down at any moment.
- **Plain words.** "nearby", "can't find the clip, is it on?", "On the clip now", "a minute each". No jargon
  (no "asset", "sync", "fast lane", "hotspot", "session").
- **System font** (SF, Dynamic Type), dark UI (the clip is dark-first), soft violet accent `#C6A2FF`,
  ground `#0E0C14`, card `#1A1726`, text `#F4F1FA`, secondary `#A99CC2`, hairline `#2A2538`. Light mode uses the
  existing light accent `#8445CE` on system backgrounds.
- **The connection is invisible.** BLE doorbell + WiFi fast path exactly as before; the user only ever sees a
  status line and never a connect button. If the clip is not nearby, Send still works: the item is kept and sent
  when the clip shows up ("Will send when the clip is near", with Undo).

## Screens

### Home
- Header: "PixelClip" + status line (the clip's name, "nearby", the battery, with a green dot; or "can't find the clip,
  is it on?" with a grey dot). Gear → Settings.
- Clip preview (536:240, 350 pt wide): what is on the clip now (the Now item, live for scenes and the Tarot via the
  existing ClipScreenPreview). Under it: "On the clip now" + **Undo** pill (visible only when there is something to undo).
- Four tiles, 2×2, 150 pt tall, 22 pt radius: **Send** (accent-filled; "a photo, video or GIF"), **Draw** ("doodle
  on the clip"), **Write** ("a message on the clip"), **Playlist** ("3 things, one after another" / "nothing yet").
- **Extras** row (horizontal, 104×78 cards): Tarot, Scenes, Loops, Reader. Tap → a sheet (see Extras).
- **Recent** strip: thumbnails of the last ~12 things sent (the Library, invisible as a concept). Tap → re-send
  sheet (preview + Send + Add to the playlist). Long-press → Remove from recents.

### Send
- iOS photo picker (PHPicker: photos, videos, Live Photos, GIFs). Then the crop screen: "Drag and pinch the photo
  into the frame", the clip-shaped frame (536:240) over the photo with a dimmed surround and "THE CLIP SEES THIS";
  a video/Live Photo adds a trim bar above the frame (a few seconds, loops on the clip); one toggle
  "Show the whole photo" (fit instead of fill, black bars); **Send to the clip**; "Add to the playlist instead".
- Share extension (PixelClipShare) lands in the same crop screen.

### Draw
- The existing drawing canvas (landscape option kept), then **Send to the clip** / playlist alternative.

### Write
- Live clip preview on top (the text as it will look; "Too long for the screen? It scrolls by itself." — the app
  decides scroll vs still: still if it fits at the chosen look, else a scrolling strip).
- A text box; four looks as chips (Bold, Script, Typewriter, DOTS — four of the bundled fonts); **Send to the clip**;
  "Add to the playlist instead". Nothing else.

### Playlist
- Switch card "Playlist is on / The clip plays these one after another, a minute each".
- The list: thumbnail, name, "1 min" (or "once, at 21:30 · then back to the playlist" for a timed one-off).
  Drag to reorder, swipe to remove, tap → a small sheet with "Play it once at a time" (time picker, on/off).
- **+ Add something** → the same pickers as Home (photo, drawing, message, extra) ending in "Add to the playlist".
- Model: `PlaylistStore`. Each entry plays 60 s in rotation; a timed entry is a one-off queue entry (60 s) and not
  in the rotation. When the playlist is on, the clip rotates; when off, the Now item holds.

### Extras (sheets, each: preview strip, minimal choices, Send, playlist alternative)
- **Tarot** (replaces the 8 Ball, which was dropped): Français / English, text size, "Edit readings ›" (every card:
  keyword, reading and closing line, in both languages), then Send / playlist. Home shows the oracle's controls
  while an oracle is on the clip. (The first design also had a question-card mode and a card of the day; both were
  dropped, see PROTOCOL §5f.6.)
- **Scenes**: five scene cards (sand, water, snow, fire, balls) with a palette chip row.
- **Loops**: the 20 PixelClip pack loops in a grid.
- **Reader**: paste or pick a text, speed chips (250/350/500 wpm), Send. Share-sheet texts land here.

### Settings (one screen)
- **Clip**: Brightness slider (live), Auto-rotate switch (flipped/normal under it when off), Battery
  ("82% · about 7 h left").
- **If something's off**: "Can't find the clip?" (help sheet: hold the top button to turn it off, tap the bottom
  one to turn it on; keep the phone near; Bluetooth on), "Sand falls the wrong way" (calibration wizard),
  **Advanced** (everything technical: clip name, hotspot password, firmware/version, logs, virtual clip,
  reset counters, screen during upload, always-on WiFi, the clip's raw status).

## Gone
Library tab, Create tab and its six creator cards, Clip tab, Discover (emoji/art/Lottie/space), the item editor
beyond cropping, Tonight's windows and moments UI, onboarding tour, PixelClip pack screen, Reader screen, Scroll/Still
choice, Brighter, every "connect" button.
