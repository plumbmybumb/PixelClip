# Parts list

Everything needed to build one PixelClip: the board, a cell, one resistor, a printed case and something to hold
it in hair. The step-by-step guide is [`BUILD.md`](BUILD.md).

"Reference build" below means the clip this project was developed on. Where these notes say something was
**not documented**, the project's records are silent on it: decide it yourself, and check before you rely on it.

## Electronics

| Item | Specification to match | Qty | What it is for | Notes |
|---|---|---|---|---|
| Display board | Waveshare **ESP32-S3-AMOLED-1.91**, **non-touch** version. ESP32-S3R8 (8 MB PSRAM), 16 MB flash, 1.91-inch 536 × 240 AMOLED, QMI8658C IMU, USB-C, PL4054 LiPo charger, 2-pin 1.25 mm battery header. Board 57.5 × 24.5 mm (display module outline). | 1 | The whole clip: screen, processor, radio, motion sensor, charger. | Product page: <https://www.waveshare.com/esp32-s3-amoled-1.91.htm>. The touch version is a different size (about 59.6 × 28.5 mm) and does not fit the case. Waveshare sells it with and without pin headers ([`HARDWARE.md`](HARDWARE.md) §2 names SKU 28872 as the one without); the reference build started from a board with headers fitted and removed them. |
| LiPo cell | Single cell, 3.7 V nominal / 4.2 V full, **500 mAh**, size **602040** (sold as about **41 × 20 × 6 mm**), maximum current **0.5 A**, **with its own protection circuit** (PCM), 2-pin **1.25 mm** connector. | 1 | Power when unplugged. | The reference cell was sold under the name HXJNLDC (602040, 500 mAh, 0.5 A, protection PCB with a Seiko IC). The board has **no battery protection of its own**, so the cell's PCM is the only protection. Expected wear time about 5.5 h always-on: an estimate, not a measured figure. |
| Charge-current resistor | **4.7 kΩ**, **0603** SMD. The reference build ordered Panasonic **ERJ-3EKF4701V**. | 1 (they come in strips; a spare helps) | Replaces the board's R1 (1 kΩ), which programs the charger to about 1 A, twice the cell's 0.5 A rating. The charger runs whenever USB and the cell are both connected; software cannot switch it off. 4.7 kΩ gives about 210 mA (about 0.4 C for 500 mAh, roughly 2.7 h to charge). | **Computed, not measured.** The 1000 / R(kΩ) formula is confirmed for other 4054-family chargers, not for the PL4054 itself, and the project's records do not show the swap being done or the resulting current being measured. A 9.1 kΩ part gives about 110 mA if you prefer a gentler charge. See [`HARDWARE.md`](HARDWARE.md) §3. |
| USB-C cable | USB-C with data lines (not a charge-only cable). | 1 | Flashing the firmware and charging. | The board uses the ESP32-S3's native USB; there is no separate serial chip. The case's USB end has a cove so a plug's moulded head reaches the socket; a very wide plug head may not seat fully (not tested with a range of cables). |

### Optional electronics (not part of the reference build as far as recorded)

| Item | Specification | What it is for | Notes |
|---|---|---|---|
| Bulk capacitor | 220–470 µF low-ESR, 6.3 V (polymer), or 2–4 × 47–100 µF X5R 0805 ceramics | Smooths WiFi current bursts at the battery input. | Recommended in [`HARDWARE.md`](HARDWARE.md) §7 as a fix *if* the clip resets during WiFi. The project's notes do not record one being fitted, and the case has no space reserved for it. |
| Slide switch | Any small switch from header pin H2-4 (`3V3_EN`) to GND | A true hard-off (the board has no power switch). | Described in [`HARDWARE.md`](HARDWARE.md) §3 and §7. Not recorded as fitted, and the case has no opening for it. Without it, "off" is the firmware's deep sleep, which still draws a little current. |

## Printed parts

Files: [`../case/stl/`](../case/stl/). Print settings and orientation: [`../case/README.md`](../case/README.md).

| Item | File | Qty to print | Qty used | Notes |
|---|---|---|---|---|
| Tray | `pixelclip-case-tray.stl` | 1 | 1 | Holds the board and cell. Outside of the assembled case: about 79.8 × 32.7 × 15.0 mm (about 34.3 mm across the key faces). |
| Lid | `pixelclip-case-lid.stl` | 1 | 1 | Oval window over the screen; presses down onto barbed latches on the tray. The oval hides about 6 % of the picture at the four corners. |
| Key A | `pixelclip-case-key-a.stl` | 2 | 2 of A *or* 2 of B | Captive side key, slimmed 0.10 mm all round. One notch in the flange rim marks it. |
| Key B | `pixelclip-case-key-b.stl` | 2 | | Same key slimmed 0.16 mm (two notches): looser. Print both and keep the pair that moves freely and clicks. Which variant the reference build ended up using is not documented. |

Material: **PETG**. Tray, lid and two of each key together weigh about **17.5 g** with the settings below.
Reference settings: 0.4 mm nozzle, 0.16 mm layers, 6 walls, 40 % gyroid infill, no supports, textured build plate
(the keys print face down and stick poorly to a smooth plate). Details and reasons in
[`../case/README.md`](../case/README.md).

PLA is not recommended: silk PLA versions of earlier case designs broke at their snap latches, and PLA softens
around 55–60 °C (a hot car, a hair dryer held close).

## Fasteners, adhesives and consumables

The case has no screws: the lid snaps on and the keys are held captive between tray and lid.

| Item | Specification | Qty | What it is for | Notes |
|---|---|---|---|---|
| Kapton (polyimide) tape | Thin; the case allows about 0.15 mm of tape under the cell | a few cm | Wrapping the cell, taping it flat under the board, and insulating the back of the board where header pins were cut. | The reference cell is Kapton-wrapped and taped to the board. The cell is not glued and does not carry any load. |
| Thin double-sided tape | About 0.1 mm | optional | Alternative way to hold the cell flat under the board. | Named in the assembly notes of an earlier case design; not documented for this case. |
| Black tape | Any thin black tape | optional | Covering the screen's ribbon area at the USB end if you print the lid in a clear or translucent filament. | From the notes for an earlier clear-resin case; the inactive strip at the USB end of the glass holds the ribbon fold. |
| Adhesive for the hair clip | **Not documented for this case.** Earlier case designs named E6000 or two-part epoxy (clear epoxy or clear UV glue for a clear case), on scuffed surfaces. | small amount | Fixing the hair clip to the underside of the tray. | How well these hold on PETG was not recorded. |

## Hair-attachment hardware

| Item | Specification | Qty | What it is for | Notes |
|---|---|---|---|---|
| Alligator hair clip | **Size not documented.** The arm width and thickness were never measured. | **not documented** | Holding the clip in hair. | The project chose alligator clips. How they attach to this case version (glue, position, how many) is not documented; see [`BUILD.md`](BUILD.md) step 17. Keep any clip spring from pressing on the cell. |
| Jump ring (optional) | 0.8–1 mm wire, to pass a 2 mm hole | 1–2 | Hanging a charm. | The tray has a 2 mm charm hole through each side of the USB cove. |

## Tools

| Tool | What for | Notes |
|---|---|---|
| Computer with ESP-IDF **v5.5** | Building and flashing the firmware. | The `v5.5` release tag (5.5.0, the version in `firmware/dependencies.lock`; see [`BUILD.md`](BUILD.md) step 2). The repository's commands use macOS port names (`/dev/cu.usbmodem*`). See [`../firmware/README.md`](../firmware/README.md). |
| Mac with **Xcode 26** or later and XcodeGen | Building the iPhone app. | See [`../ios/README.md`](../ios/README.md). |
| iPhone on **iOS 26** or later | Running the app. | |
| Paid Apple Developer Program membership | Signing the app with the Hotspot Configuration entitlement it uses to join the clip's WiFi. | A free personal team cannot sign a device build with that entitlement. |
| Multimeter with continuity beeper | Checking the battery lead's polarity against the board's connector. | Required. |
| Soldering equipment fine enough for 0603 parts | Swapping R1, removing or trimming the pin headers, removing the microSD slot. | The project's notes do not say which iron, hot-air station or method was used. |
| Flush cutters | Trimming header pins. | |
| Calipers | Checking the cell and the printed parts. | The case was fitted to measured parts; your cell may differ. |
| Fine pin or needle | Lifting a crimp contact's retention tab if the battery plug's polarity must be swapped. | |
| Inline USB power meter | Confirming the real charge current after the R1 change. | Recommended. The reference build had none, so the charge current was never measured. |
| FDM 3D printer, 0.4 mm nozzle, textured plate | Printing the case. | |
| Fingernail or small flat screwdriver | Opening the lid at its pry notch. | |

## Choosing substitutes

**May vary**

- **Cell brand.** Any 500 mAh 602040-class cell with a protection circuit and a 1.25 mm 2-pin plug, rated for at
  least the charge current you set with R1 (about 210 mA with 4.7 kΩ).
- **Smaller cells.** They fit in length and width, but set the charge current to suit: a 220 mAh cell wants
  9.1 kΩ (about 110 mA). [`HARDWARE.md`](HARDWARE.md) §8 discusses the 220 mAh cell the project started with.
- **Filament colour and brand**, as long as it is PETG. A clear or translucent filament shows the ribbon area at the
  USB end of the screen; cover it with black tape.
- **The resistor's brand.** Any 4.7 kΩ 0603 thick-film part.

**Must not vary**

- **Board version.** Only the non-touch ESP32-S3-AMOLED-1.91. The case is fitted to its outline to about 0.2 mm.
- **Cell thickness.** The case was tuned around the real cell, which is thinner than its nominal 6 mm: in the case
  model a full 6.0 mm cell sits about 0.3 mm into the floor clearance. The measured stack in the reference build,
  from the top of the glass to the bottom of the Kapton-wrapped cell, is 13.46 mm. Measure your cell: if it is a
  full 6 mm thick or more, it is likely to hold the lid open.
- **Cell length and width.** The cell lies directly under the board and ends just short of the battery plug.
  Anything longer than about 41 mm or wider than 20 mm has not been tried and will probably not fit.
- **Cell protection.** The board has none. Never use a bare cell without a protection circuit.
- **Connector polarity.** Waveshare's battery header and many retail LiPo leads use opposite pin orders, and the
  board's pin 1 is not marked. Check every new cell with a meter before plugging it in
  ([`BUILD.md`](BUILD.md) step 11). A reversed cell can destroy the board.
- **Connector type.** The board header is a 1.25 mm pitch, 2-pin type (Waveshare calls it MX1.25, a Molex
  PicoBlade-style connector). Cell listings describe their plug as "JST-style 1.25 mm". Whether the reference
  cell's plug mated as delivered is not documented, so check that yours does before you buy several.
- **Charge current.** Do not charge any cell from the board until R1 is changed to suit it. The board charges the
  cell whenever USB and the cell are both connected, and software cannot stop it, so until then unplug the cell
  before every USB connection, flashing included ([`BUILD.md`](BUILD.md), "Read this before you connect a cell").
