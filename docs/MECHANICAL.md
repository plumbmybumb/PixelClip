# Mechanical facts: Waveshare ESP32-S3-AMOLED-1.91 (non-touch, "-M" model)

_Written 2026-10-10. Source: Waveshare's STEP model of the board, `esp32-s3-amoled-1_91-M.stp` (a Creo export dated 2025-03-21, 6.1 MB, from the dimension-drawing archive linked in HARDWARE.md "Sources"; not included in this repository). Reproduce with `python3 -I docs/mechanical/step_extract.py <path to>/esp32-s3-amoled-1_91-M.stp [--solids] [--circles] [--pouch=31x20] [--svg out.svg]`. Top view: `docs/mechanical/board-top.svg` (+ `.png`). **UNCONFIRMED** = not derivable from the model; measure the physical board before cutting plastic._

## 1. How this was extracted, and how far to trust it

- Pure text parse (stdlib only). The file is a proper assembly, so no clustering was needed: 14 `PRODUCT`s, 18 `NEXT_ASSEMBLY_USAGE_OCCURRENCE` placements, each with an `ITEM_DEFINED_TRANSFORMATION`. Every part's `VERTEX_POINT`s were transformed into the root frame (child-to-parent matrix = B x A^-1). **Confidence: high** for bounding boxes of planar/prismatic parts (exact to the 0.001 mm of the file); arcs that bulge past their end vertices are not in the box (sub-0.1 mm effect here).
- Holes come from `CIRCLE` entities whose axis is the board normal. One hole (X'=7.5, Y'=17.5) is modelled as a spline ring with no `CIRCLE`; the script finds it from the vertex ring (d = 2.0). Hole **plating is not in the model** (UNCONFIRMED).
- The model is a **derivative**: the PCB solid is named `ESP32-S3-2INCH-PCBA-20240524` (Waveshare reused a 2-inch board model; the product `..._PCB-0522` is an empty placeholder). The display is one lumped solid (`ESP32-S3-AMOLED-1_91-V0`) with internal steps; glass, panel, FPC and frame are not separate. No colours/materials, no silkscreen, no pin or button labels. Treat all numbers as nominal CAD, not as measured hardware (UNCONFIRMED against the real board: check with calipers).

**Board frame used below** (mm, right-handed, shown in the SVG): origin = bottom-left corner of the display-module outline in the top view; **X'** along the long edge to the right (USB-C end is at high X'), **Y'** along the short edge upward, **Z'** = board normal, positive toward the viewer on the display side. In the STEP root frame: X' = z + 24.46, Y' = x + 12.25, Z' = y + 3.30. "Back" = the side opposite the display; all connectors, buttons, the TF slot and the battery connector are on the back.

## 2. What this resolves in HARDWARE.md section 6

| HARDWARE.md row | Now |
|---|---|
| Board outline 57.5 x 24.5 (secondary source) | **Confirmed as the display-module outline** (57.50 x 24.50). The PCB itself is **56.51 x 23.51 x 1.60**, inset 0.49 mm on all sides, corner radius 0.51. USB-C protrudes to X' = 58.0. |
| Thickness | PCB 1.60; display module top 4.00 above the PCB top face; whole board 9.00 (no header) or 13.90 (header fitted). |
| Mounting holes | 4 x M2 (d 2.0), pitch 38.0 x 10.5, see section 4. |
| Battery connector position / pin 1 | Position found (section 5). **Pin 1 UNCONFIRMED** (symmetric, unlabelled part). |
| USB-C side | **Short edge at +X', back (underside) mounted**, centred on the long axis. |
| Display active area (derived 44.3 x 19.8) | Model window is **44.22 x 19.80**, matching the derivation. |

## 3. Outline and stack-up (Z' = 0 at the lowest display-module face)

| Item | X' range | Y' range | Z' range | Size (X' x Y' x Z') |
|---|---|---|---|---|
| Display module (V0), corner R 1.00 | 0.00 .. 57.50 | 0.00 .. 24.50 | 0.00 .. 4.20 | 57.50 x 24.50 x 4.20 |
| PCB body, corner R 0.507 | 0.49 .. 57.01 | 0.49 .. 24.01 | -1.40 .. 0.20 | 56.51 x 23.51 x 1.60 |
| Whole assembly, headers off | 0.00 .. 58.00 | 0.00 .. 24.50 | -4.80 .. 4.20 | 58.00 x 24.50 x 9.00 |
| Whole assembly, headers on | 0.00 .. 58.00 | 0.00 .. 24.50 | -9.70 .. 4.20 | 58.00 x 24.50 x 13.90 |

- Display top: outer lip at Z' 4.20 (0.4 mm inset from the module outline), a 0.05 mm recessed window at 4.15, steps at 4.05/3.90 near the edges. The top is effectively flat; nothing on the front is taller than 4.20.
- PCB front side: components up to Z' 1.0 sit inside cavities of the display solid (not modelled separately).
- Tallest back items (headers off): BAT connector -4.80, buttons -4.70, USB-C -4.65, hex stud ends -4.40, TF slot -4.05, small ICs -2.4 to -3.2. 2.54 mm header (if fitted): plastic body Z' -3.9..-1.4, pin tails down to **-9.70**.

## 4. Display, mounting holes, headers

| Feature | X' | Y' | Size | Notes |
|---|---|---|---|---|
| Active window | 2.35 .. 46.57 (centre 24.46) | 2.35 .. 22.15 (centre 12.25) | 44.22 x 19.80 | Margins: 2.35 each long side and the -X' end; **10.93 on the USB end**. Centre sits 4.29 toward -X' from the module centre. |
| Hole H1 | 7.50 | 7.00 | d 2.00 | |
| Hole H2 | 7.50 | 17.50 | d 2.00 | spline ring in STEP |
| Hole H3 | 45.50 | 7.00 | d 2.00 | |
| Hole H4 | 45.50 | 17.50 | d 2.00 | |
| Pin-hole rows (2.54 pitch) | 1.80 .. 50.06 (20 holes) | 3.36 and 21.14 | d 0.89 | row spacing 17.78; header body X' 0.53..51.33, 2.54 wide |

- Hole pattern 38.0 (X') x 10.5 (Y'), symmetric about Y' = 12.25, centred at X' = 26.5. From the PCB corner (0.49, 0.49): 7.01/45.01 by 6.51/17.01. All four holes lie under the display window; the model fits a **M2 hex standoff (3 mm AF, 3.46 across corners, 3 mm body)** in each: male thread Z' -1.40..1.60, hex body Z' **-4.40..-1.40** on the back, tapped about 2 mm deep from the free end (d 2.0 hole, Z' -4.30..-2.40). Whether retail boards ship with the studs is UNCONFIRMED.
- Not mounting holes: the four (1.0, 1.0)-style arcs at the PCB corners (R 0.507), the d 0.89 pin-hole rows, the d 0.5 to 0.55 pads near X' 20.6..21.1 (TF) and 50.6..55.8 (USB-C), and the d 1.3 to 3.0 bosses inside the display solid.

## 5. Back-side parts (all Z' below the PCB underside at -1.40)

| Part (model name) | X' | Y' | Z' | Notes |
|---|---|---|---|---|
| USB-C (`TYPE-C_16PIN-9X3X7_3`) | 50.40 .. 58.00 | 7.78 .. 16.72 | -4.65 .. -1.49 | 8.94 wide x 3.16 high shell; opening centre Y' 12.25, **Z' -3.07**; faces +X'; sticks out 0.50 past the module and 1.0 past the PCB. |
| Button A | 51.88 .. 56.33 | 1.50 .. 4.05 | -4.70 .. -0.90 | centre (54.10, 2.78); flat 4.1 x 2.55 face at Z' -4.70. Tabs reach Y' 0.65..4.65. |
| Button B | 51.88 .. 56.33 | 20.45 .. 23.00 | -4.70 .. -0.90 | centre (54.10, 21.73). Mirror of A. |
| Battery connector (`HP1_25MM-2P-SMT-HORIZONTAL`, 1.25 mm, 2P) | 40.74 .. 45.94 | 8.42 .. 16.08 | -4.80 .. -1.40 | housing X' 40.74..44.94, SMT tails to 45.94; contacts at Y' 11.62 and 12.87 (centre 12.25); **mouth faces -X'** (cable leaves toward the board centre; inferred from the keyed mouth face at 40.74 and tails at +X'). 3.40 high. |
| TF slot (`TF-CARD-BASE_SMT`) | 20.59 .. 26.09 | 6.50 .. 17.90 | -4.05 .. -1.40 | 5.5 x 11.4 x 2.65. A real microSD slot is about 15 mm deep, so the model probably shows a truncated body; insertion side UNCONFIRMED. |
| Shield/IC blocks `CORE01`, `CORE`, `C3` | 9.79..19.69 / 27.39..32.49 / 0.66..2.66 | 7.30..17.20 / 9.70..14.80 / 7.01..14.01 | to -2.4 / -3.2 / -2.4 | Names are CAD labels only; function UNCONFIRMED. |
| 2.54 mm headers (2 x 1x20), if fitted | 0.53 .. 51.33 | 2.09..4.63 and 19.87..22.41 | -9.70 .. 1.60 | The "-M" SKU has them (HARDWARE.md); the base SKU does not. |

- **Which button is BOOT and which is RESET: UNCONFIRMED from this model.** The two switches are identical unlabelled solids placed at mirror positions. Check the silkscreen (schematic: B1 = BOOT, R10 = RESET). [`BUILD.md`](BUILD.md) step 5 places BOOT top-right and RESET bottom-right (picture upright, USB end on the right) and gives a quick test to confirm it on your board; this model can neither confirm nor contradict that.
- Both buttons are pressed from the back (flat actuator face toward -Z'). Pressing direction is inferred from the geometry (UNCONFIRMED).
- **Pin 1 of the battery connector is UNCONFIRMED**; the model is mirror-symmetric. Keep the multimeter polarity check from HARDWARE.md section 8.

## 6. What this means for the hair clip

**Do not cover:** the active window (X' 2.35..46.57, Y' 2.35..22.15 on the front), the USB-C opening (back, +X' end face), the two button faces (back, around X' 54.1, Y' 2.8 and 21.7), the TF slot if you ever use it, and the battery connector mouth (-X' side, free cable run of about 10 mm).

**Where a clip can grip**
- Best: do not grip the PCB at all. Screw a printed carrier to the four M2 standoffs and put the hair-gripping mechanism (barrette back, spring clip, comb) on the carrier. That avoids clamping the glass.
- Edge lips on the front are possible only along the long edges and the -X' end: the bezel outside the window is 2.35 mm, and the module top is inset 0.4, so keep a lip to **1.8 mm or less** over the edge. The +X' end has 10.9 mm of bezel but the USB plug lives there, so keep it open.
- Do not clamp between front and back at X' > 40: the battery connector, USB-C and buttons make the back uneven (down to Z' -4.8).

**Where a 20 x 31 x 4 mm pouch cell fits**

_Written for the 220 mAh cell the project started with. The released case holds the 500 mAh 602040 cell (about 41 x 20 x 6 mm) flat under the board instead; see [`PARTS.md`](PARTS.md) and [`../case/README.md`](../case/README.md)._
- It fits behind the board with the 31 mm side along X' and the 20 mm side across Y' (it leaves 2.25 mm per side of the 24.5 mm width). Script result, headers off, studs ignored: the only thing under a 31 x 20 footprint is the TF slot (Z' -4.05) plus lower ICs, and the footprint X' 9.0..40.0 sits between the studs (X' 6..9) and the battery connector (X' 40.74) with under 1 mm of slack. Do not count on that nesting.
- Simple robust plan: cell fully below Z' -4.8 with 0.5 mm foam, so any X' position works and it never touches the connector, buttons or studs. Stack: display 4.2 + back parts 4.8 = 9.0, plus 0.5 foam, plus cell 4.0 (allow 4.5 for swelling), plus a 1.2 mm tray floor gives about **15 mm**. Nesting the cell at X' 9..40 against the TF slot saves about 0.75 mm.
- **Headers fitted:** the two header bodies leave only 15.24 mm between them (Y' 4.63..19.87), narrower than the 20 mm cell, and the pin tails go to Z' -9.70. Either leave the headers off, or trim the tails flush with the plastic (Z' -3.9), or add 5.8 mm to the stack. The cell lead (red/black) should exit toward the connector (+X' end).

**Mounting holes for a printed carrier:** all four, H1 to H4 at (7.5, 7.0), (7.5, 17.5), (45.5, 7.0), (45.5, 17.5) in the display-module frame, M2. A plate that sits on the stud ends is at Z' -4.40, which clears everything except the three parts deeper than that (battery connector -4.80, buttons -4.70, USB-C -4.65, all at X' > 40.7). So either keep the plate short (X' < 40) and fix the +X' studs with separate lugs that route around the connector (Y' < 8.4 or > 16.1 at X' 44..47), or cut windows. Screw length: plate thickness + at most 2 mm into the tapped stud (an M2 x 4 or x 5 with a 2 mm plate), UNCONFIRMED thread depth. Clearance hole d 2.4 to 2.6.

**USB-C clearance for charging:** the shell opening is 8.94 wide x 3.16 high, centred at Y' 12.25, Z' -3.07, face at X' 58.0. A typical Type-C plug overmould is about 7 to 8 mm high and 12 to 16 mm wide (generic figure, UNCONFIRMED for your cable), so cut the carrier or case end with an **opening at least 16 x 9 mm centred on (Y' 12.25, Z' -3.07)**, and keep **at least 15 mm of straight clear run** beyond X' = 58 plus room for the cable bend. The simplest option is to end the carrier at X' <= 57 so the shell sticks out. Note the buttons sit at Y' 0.65..4.65 and 19.85..23.85 (X' <= 56.4), so a wide end window does not hurt them but a full end wall would hide them.

## 7. Open items (UNCONFIRMED, need the physical board or a drawing)

1. Real PCB outline versus the model (56.51 x 23.51 vs the 57.5 x 24.5 Waveshare quotes).
2. Display stack height (4.0 above the PCB top is from a lumped solid).
3. Which button is BOOT and which is RESET (from the model; see the note in section 5); button actuation side.
4. Battery connector pin 1 and the cable direction on the real part.
5. TF slot depth and insertion direction.
6. Whether the hex standoffs and header come with your board, and the hole plating.
