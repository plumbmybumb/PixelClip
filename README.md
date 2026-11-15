# PixelClip

A small AMOLED screen you wear as a hair clip, and the iPhone app that feeds it.

<p align="center">
  <img src="case/renders/pixelclip-case-three-quarter.png" alt="The PixelClip case: a rounded tray and lid with an oval window over the screen" width="560">
  <img src="case/renders/pixelclip-case-exploded.png" alt="Exploded view: the lid lifted off the tray, one key out on each side" width="300">
</p>

PixelClip is everything you need to build one: firmware for an off-the-shelf ESP32-S3 display board, a SwiftUI
companion app, a 3-D printable case, a parts list and a build guide. The phone does the heavy work (cropping,
dithering, text rendering, encoding); the clip decompresses and shows what it is sent, runs from a small LiPo
cell (about 5.5 hours by the project's estimate, not yet measured), and needs no internet.

<p align="center">
  <img src="docs/images/app-home.png" alt="The app's home screen" width="230">
  <img src="docs/images/app-scenes.png" alt="Choosing a live scene" width="230">
  <img src="docs/images/app-tarot.png" alt="The Tarot oracle" width="230">
</p>

## Build one

| Step | What you do | Where to look |
|---|---|---|
| 1 | **Get the parts**: one display board, one small LiPo cell, one resistor, a hair clip | [`docs/PARTS.md`](docs/PARTS.md) |
| 2 | **Print the case**: tray, lid and two side keys in PETG, no supports | [`case/README.md`](case/README.md) |
| 3 | **Flash the firmware** over USB-C | [Build the firmware](#build-the-firmware) |
| 4 | **Prepare the board and assemble**: make room for the cell, check the battery polarity, close the case | [`docs/BUILD.md`](docs/BUILD.md) |
| 5 | **Install the app** on your iPhone and send a first picture | [Build the app](#build-the-app) |

[`docs/BUILD.md`](docs/BUILD.md) walks through all of it in order, 21 short steps from an empty bench to a clip in
your hair. No hardware yet? The app runs in the iOS simulator against a built-in virtual clip, so you can try
everything first.

**Before you start**, read [what has and has not been tested](docs/BUILD.md#what-has-and-has-not-been-tested).
This is a hobby project documented from one working clip. In particular, the board's charger must be slowed down
with a resistor change before it charges a cell this small, and that change is computed, not measured.

## What the clip can show

- **Pictures and animations** in a playlist, with cuts or fades (`.hca`, a simple RLE format for RGB565 frames).
- **Scrolling strips**: wide images that move across the screen as a marquee.
- **Live scenes** that react to movement through the on-board IMU: sand, water, snow, fire, lava, bouncing balls,
  and your own words tumbling about.
- **Reader**: speed reading of a text you send, one word at a time.
- **Tarot oracle**: shake to draw three cards (Jean Dodal's Tarot de Marseille, 1701) and read them on the clip.
- **Scheduling**: time windows and a one-shot queue ("show this at nine tonight").
- **Boards**: a list of timed row pictures that scrolls and drops rows as their time passes. The firmware and
  protocol support it; the app has no screen that builds one yet.

The phone talks to the clip over **Bluetooth LE** for small requests and over the clip's own **WiFi hotspot** for
uploads. The wire contract is [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## Hardware

- **Board**: Waveshare ESP32-S3-AMOLED-1.91, the non-touch version. ESP32-S3R8 (8 MB PSRAM), 16 MB flash, a
  1.91-inch 536 × 240 AMOLED (RM67162 over QSPI), a QMI8658C IMU, a BOOT button, USB-C, and a LiPo charger.
- **Battery**: a single-cell LiPo on the board's battery connector. Development used a protected 500 mAh cell
  (size 602040) rated for 0.5 A. Read the charge-current notes in [`docs/PARTS.md`](docs/PARTS.md) before choosing
  a cell: as shipped, the board's charger is set for about 1 A.
- **Case**: a snap-together tray and lid, about 80 × 33 × 15 mm, with two captive side keys over the board's
  buttons. No screws, no supports. STL files for printing, STEP files and the parametric Fusion script for
  editing, renders and print settings are in [`case/`](case/README.md).
- **One mismatch to know about**: the lid's window is an oval, which hides about 6 % of the picture at the four
  corners, while the firmware and app draw to the full rectangular screen. Keep important detail out of the
  extreme corners, or remix the lid with a rectangular window.

The full list with specifications is [`docs/PARTS.md`](docs/PARTS.md). Pin map, power path and panel details:
[`docs/HARDWARE.md`](docs/HARDWARE.md); board measurements: [`docs/MECHANICAL.md`](docs/MECHANICAL.md).

## Repository layout

| Path | What it is |
|---|---|
| `firmware/` | ESP-IDF v5.5 project for the clip. Details: [`firmware/README.md`](firmware/README.md) |
| `core/` | Portable C11 library shared by the firmware and the host tools (decoder, scenes, reader, oracle, board). Details: [`core/README.md`](core/README.md) |
| `tools/` | Host command-line tools (`hcaenc`, `hcadec`, `hcainfo`, previews) and test fixtures |
| `ios/` | The iPhone app (XcodeGen, Swift 6, iOS 26) and its engine package `PixelClipKit`. Details: [`ios/README.md`](ios/README.md) |
| `case/` | The 3-D printable case: STEP and STL files, renders, print settings. Details: [`case/README.md`](case/README.md) |
| `docs/` | Parts list ([`PARTS.md`](docs/PARTS.md)), build guide ([`BUILD.md`](docs/BUILD.md)), protocol, hardware and mechanical notes |

## Build the firmware

You need [ESP-IDF v5.5](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/get-started/index.html)
installed (the commands below assume `~/esp/esp-idf`).

```sh
source ~/esp/esp-idf/export.sh
cd firmware
idf.py build                                  # first run downloads three managed components
ls /dev/cu.usbmodem*                          # the board's native USB port (macOS naming)
idf.py -p /dev/cu.usbmodemXXXX flash monitor  # exit the monitor with Ctrl-]
```

If the board does not show up as a serial port, hold BOOT, tap RESET, release BOOT, flash, then press RESET.
`firmware/scripts/flash.sh` wraps build, flash and a boot check in one command.

After flashing, the clip shows an idle screen. Hold BOOT for about two seconds to open its hotspot
(`PixelClip-XXXX`), or let the app wake it over Bluetooth.

Host-side checks that need no hardware:

```sh
# core library and tools: unit tests, fixtures
cmake -S core -B build/core && cmake --build build/core && ctest --test-dir build/core
# firmware host test (BLE framing)
cmake -S firmware/test_host -B build/fw-host && cmake --build build/fw-host && ctest --test-dir build/fw-host
# the HTTP API end to end against a local mock of the clip
python3 firmware/scripts/mock_clip.py 18080 &
SKIP_WIFI=1 CLIP=http://127.0.0.1:18080 firmware/scripts/e2e.sh
```

## Build the app

You need a Mac with Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `ios/project.yml`; do not edit it by hand.

```sh
cd ios
./build.sh          # generate the project and build for the simulator
./build.sh run      # build, install and launch in the simulator
./build.sh test     # package tests on macOS, then package and UI tests in the simulator
```

In the simulator the app talks to a built-in **virtual clip**, so you can try everything without hardware.
`SIM_NAME` (default `iPhone 17`) or `SIM_UDID` picks the simulator.

### Your own bundle id and signing team

The project ships with placeholders. Before building for a real iPhone, edit `ios/project.yml`:

1. **Team**: set `DEVELOPMENT_TEAM` (under `settings.base`) to your Apple team id.
2. **Bundle ids**: change `bundleIdPrefix` from `com.example`, and the three `PRODUCT_BUNDLE_IDENTIFIER` values
   (`com.example.pixelclip`, `.share`, `.uitests`). Keep `BUNDLE_ID` in `ios/build.sh` in step.
3. **App Group**: change `group.com.example.pixelclip` everywhere it appears (both entitlements blocks in
   `project.yml`, the two `.entitlements` files, and the Swift sources; search for the string).

Then:

```sh
xcrun devicectl list devices                 # find your iPhone's id
DEVICE_ID=<id> ./build.sh device             # build, install and launch on it
```

Joining the clip's hotspot from the app uses the Hotspot Configuration entitlement, which needs a paid Apple
Developer membership. More detail: "Bundle id and signing" in [`ios/README.md`](ios/README.md).

## Things to know before you wear it

PixelClip is a hobby device with deliberately simple local radio links and no cloud. Treat the clip as public:
assume that anyone standing near you could interfere with it, and do not put anything on it you would mind a
stranger seeing or replacing.

- **Bluetooth is open.** There is no pairing. Anyone within Bluetooth range who speaks the protocol
  ([`docs/PROTOCOL.md`](docs/PROTOCOL.md) §3) can wake the clip's hotspot, read its status and playlist, change
  brightness, orientation, the clock and other settings, and rearrange or delete what is stored on it. They
  cannot read or set the hotspot password over Bluetooth, and pictures, texts and firmware only travel over
  WiFi.
- **The hotspot password guards your content, and the app gives your clip its own.** Every clip starts with the
  same published default (`pixelclip-2026`). The first time the app sends something over WiFi it replaces the
  default with a random password, keeps it in the iPhone's Keychain and tells you once; there is nothing to
  type. Someone who knows the password can join the hotspot (and can open it over Bluetooth) and send any
  content, so until that first send the clip is as open as the default makes it.
  - *A second phone:* copy the password from Settings ▸ Advanced on the first phone and enter it there on the
    second.
  - *Without the app:* join the clip's hotspot from a computer and set one yourself. It takes 8 to 63 printable
    ASCII characters, applies from the next session, and can never be read back from the clip.

    ```sh
    curl -X PUT -H 'Content-Type: application/json' \
         -d '{"ap_password":"your-own-long-passphrase"}' http://192.168.4.1/config
    ```

  - *If the password is lost:* press the clip's button five times quickly, then hold it while the clip shows
    "Reset WiFi password?". The password goes back to the default and everything stored stays. The app then
    offers to set the clip up again. Anyone holding the clip can do this too.
- **A firmware update needs a press of the clip's button.** Updates are checked by hash only, not signed, so
  the clip refuses one unless its button is pressed while it shows "Update?". Someone who has joined the hotspot
  cannot install firmware without touching the clip.
- **Traffic is plain HTTP** inside the clip's own WPA2 network. There is no TLS.
- **The clip can be recognised.** It advertises a fixed Bluetooth address and a name unique to your unit, so
  someone who wants to follow one particular clip from place to place can.
- **The app trusts what looks like a clip.** It talks to the first device that advertises PixelClip's Bluetooth
  service, so a device imitating a clip nearby could receive the small requests the app sends over Bluetooth.
  Pictures and texts go over WiFi, and once your clip has its own password the phone no longer joins a network
  that only knows the default, except in the minutes right after the first setup or if you tap "Set up again".
- **Physical access is full access.** Anyone holding the clip with a USB cable can read and replace everything
  on it. Secure boot and flash encryption are off on purpose: they burn one-time fuses and can lock a hobbyist
  out of their own board.
- **Batteries.** A LiPo cell worn on the head needs care: use a protected cell, change the charge resistor before
  charging from the board ([`docs/BUILD.md`](docs/BUILD.md)), and do not charge it unattended.

The review behind this list, with what was fixed, what is still open and what has only been tested on a
computer so far, is [`docs/SECURITY-AUDIT.md`](docs/SECURITY-AUDIT.md). Found a security problem? Please report it privately: see
[`SECURITY.md`](SECURITY.md).

## Licence and credits

PixelClip's own code, content and case design files are released under the [MIT licence](LICENSE).

Bundled third-party material keeps its own terms:

- `tools/third_party/stb_image.h`: Sean Barrett's stb_image, MIT or public domain
  (`tools/third_party/LICENSE-stb_image.txt`).
- `ios/Sources/Resources/Fonts/`: open fonts under the SIL Open Font License 1.1; each family's folder has its
  `OFL.txt`, and `FONTS.json` lists them.
- `ios/Sources/Resources/Tarot/dodal/`: the trumps of Jean Dodal's Tarot de Marseille (Lyon, c. 1701), from the
  Bibliothèque nationale de France's scans via Wikimedia Commons; public domain. Provenance:
  [`ios/Sources/Resources/Tarot/SOURCES.md`](ios/Sources/Resources/Tarot/SOURCES.md).
- `firmware/components/display/display.c`: the RM67162 panel initialisation commands are taken from Waveshare's
  ESP32-S3-AMOLED-1.91 demo.
- `firmware/components/ui/font5x7.c` and `tools/common/dotfont5x7.h`: the classic, widely circulated 5 × 7 bitmap
  character table; no known claim on it.
- The firmware build downloads Espressif's ESP-IDF components and `esp_lcd_sh8601`, `joltwallet/littlefs` and
  `espressif/mdns` from the ESP Component Registry, each under its own licence.

The 20 starter animation loops in `ios/Sources/Resources/Starter/` are original to this project, generated
procedurally, and released under the same MIT licence. The case files come with no warranty; see
[`case/README.md`](case/README.md). The full list of credits is [`docs/CREDITS.md`](docs/CREDITS.md).

The tarot reading texts are original to this project. The way the three cards are read follows the structural
method described in *The Way of Tarot* by Alejandro Jodorowsky and Marianne Costa.
