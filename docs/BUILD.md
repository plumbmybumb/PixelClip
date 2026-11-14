# Build guide

From an empty bench to a clip in your hair. Parts and tools are in [`PARTS.md`](PARTS.md); board facts are in
[`HARDWARE.md`](HARDWARE.md) and [`MECHANICAL.md`](MECHANICAL.md).

## What has and has not been tested

Be clear about this before you start. "Reference build" below means the clip built while the project was
developed.

**Done on real hardware:** the firmware and the app on the board; running from the 500 mAh cell; the motion
sensor's axis mapping; printing this case in PETG, fitting the board and cell, and keys that click the board's
switches with the lid on.

**Not done or not measured:**

- **The charge-resistor change.** It is computed from a datasheet formula for related chargers. The project's
  records do not show it being done, and the charge current was never measured.
- A full day of wear on battery with the final firmware. Runtime figures are estimates.
- How the hair clip is fixed to this version of the case (step 17).
- Drop strength. An earlier print with fewer walls cracked near a key after a few drops from head height; the
  stronger print settings in [`../case/README.md`](../case/README.md) are the response, and they have not been
  drop-tested.
- Many board details in [`HARDWARE.md`](HARDWARE.md) are marked **UNCONFIRMED**: they come from Waveshare's
  schematic and demo code, not from measurement.

Where this guide says **Not documented**, the project's notes are silent. Make your own call, carefully.

## Read this before you connect a cell

> [!WARNING]
> **USB charges the cell whenever both are connected.** The board's charger is hardware: any time a USB cable is
> plugged in while the cell is connected, it charges the cell. Software cannot switch this off. With the board's
> original R1 the charge current is about 1 A by the project's calculation (never measured), twice the 500 mAh
> cell's 0.5 A rating. **Until R1 is changed (step 9), unplug the cell before every USB connection**, including
> flashing, the serial monitor and the scripts in `firmware/scripts/`.

The steps below are ordered so the cell is first connected only after R1 has been changed and with USB unplugged
(steps 9 and 12).

---

## Part 1: check and flash the board

### 1. Check the board lights up

Plug the new board into a computer with a USB-C data cable, before you change anything on it. The factory
program should light the screen.

*Why:* a board can boot perfectly and still have a dead panel. During development one board passed every
firmware check over USB while its screen never lit. Find that out before you cut, solder or flash anything.

### 2. Install ESP-IDF v5.5

Follow Espressif's [getting-started guide for v5.5](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/get-started/index.html).
The repository's commands assume it lives in `~/esp/esp-idf`.

Use the `v5.5` release tag (ESP-IDF 5.5.0, the version recorded in
[`../firmware/dependencies.lock`](../firmware/dependencies.lock)), for example
`git clone -b v5.5 --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf`. The component manifest
accepts newer versions, but 5.5.0 is the one the lock file records.

### 3. Build and flash the firmware

The full instructions are in [`../firmware/README.md`](../firmware/README.md). The minimum:

```sh
source ~/esp/esp-idf/export.sh
cd firmware
idf.py set-target esp32s3     # once
idf.py build                  # the first run downloads three components
ls /dev/cu.usbmodem*          # the board's native USB port (macOS naming)
idf.py -p /dev/cu.usbmodemXXXX flash monitor   # exit the monitor with Ctrl-]
```

Or run `firmware/scripts/flash.sh`, which builds, flashes and prints a PASS/FAIL boot check.

If the board does not show up as a port: hold BOOT, tap RESET, release BOOT, flash, then press RESET. After a
flash the board can also stay in download mode with a dark screen; press RESET.

### 4. Check the first boot

`scripts/flash.sh` should end with `RESULT: PASS`, including an `IMU: QMI8658C at 0x..` line. Then **look at the
screen**: it should show the idle screen ("Send me something" with a sparkle).

*Why look:* a PASS does not prove the panel lights. The firmware cannot read the panel back.

### 5. Find BOOT and RESET

The two side buttons sit near the USB end, one on each long edge. Check the silkscreen: the schematic calls BOOT
`B1` and RESET `R10`. This guide places BOOT top-right and RESET bottom-right, with the picture upright and the
USB end on the right, but the board's CAD model cannot tell the two switches apart
([`MECHANICAL.md`](MECHANICAL.md) §5 marks it **UNCONFIRMED**). Confirm it on your board: with `idf.py monitor`
running (no cell connected yet), press one button briefly. RESET restarts the chip and the monitor shows a fresh
boot log; a short press on BOOT does not.

- **BOOT** is the only button the software reads. Short press: next item. Long press (1.5 to 6 s): open the
  WiFi hotspot. Hold 6 s or more: power off. Double taps and a few special cases (reader, tarot) are in
  [`../firmware/README.md`](../firmware/README.md), "Using the clip".
- **RESET** restarts the chip at once. Software cannot see it.

---

## Part 2: prepare the board

The cell lies flat directly against the back of the board. Everything below makes room for it. Do these steps
**after** the board has passed steps 1 to 4, so you know any later fault came from the work.

### 6. Remove the pin headers

If your board has the two rows of 2.54 mm pin headers, remove them. Their pins stick out about 9.7 mm below the
display, and their plastic bodies leave only 15.24 mm between the rows, less than the cell's 20 mm width.

The reference board had its header plastic and pins removed, leaving a short 4-pin block on each side at the USB
end. Another note describes the headers on that board as "trimmed flush". **Not documented:** exactly what must
remain for the case to close. Remove as much as you can.

Cover any cut pin ends on the back of the board with Kapton tape so they cannot touch the cell.

### 7. Remove the microSD slot

Desolder the microSD slot from the back of the board. It stands about 2.65 mm off the board, right where the cell
lies. The firmware does not use the card slot.

Work carefully around it. On the reference board a small resistor beside the slot cracked during this step
(probably the card's unused pull-up); the board still passed its checks afterwards.

### 8. Remove the two far-end standoffs

The board's four mounting holes can carry small M2 hex standoffs on the back (the reference board had them;
whether every retail board does is not confirmed). Remove the two at the end **away from** the USB port; the cell
lies there. Leave the two near the USB end.

**Not documented:** whether the standoffs also help hold the display module to the board. Check yours before
removing them.

### 9. Change the charge resistor R1 to 4.7 kΩ

The board's PL4054 charger has its charge current set by R1 on its PROG pin. R1 is 1 kΩ, which programs about
1 A: twice the 500 mAh cell's 0.5 A rating. Replace it with a 4.7 kΩ 0603 resistor for about 210 mA (about 0.4 C,
roughly 2.7 h for a full charge).

- **Status:** required before the cell is ever connected while USB is plugged in. "Charging from the board" is not
  a separate act: the charger runs by itself whenever both are connected (see the warning below). **Computed, not
  measured:** the 1000 / R(kΩ) relation is confirmed for other 4054-family chargers, not for the PL4054 (its
  datasheet was not found), and the reference build's records do not show the swap being done.
- **Not documented:** where R1 sits on the physical board. Find it from Waveshare's schematic (linked in
  [`HARDWARE.md`](HARDWARE.md), "Sources") at the charger's PROG pin, and confirm it measures about 1 kΩ before
  you lift it.
- If you have an inline USB power meter, measure the charge current with a partly discharged cell attached.
- Until R1 is changed, charge the cell only with a separate LiPo charger at no more than 0.5 C (250 mA for
  500 mAh).

> [!WARNING]
> Any time USB is connected while the cell is plugged in, the board charges the cell, and software cannot switch
> this off. If you leave this step for later, unplug the cell before every USB connection, including flashing,
> until R1 is changed. Once the case is closed that means opening it first.

### 10. Re-check the board

Plug USB in again (still no cell connected) and run `NOFLASH=1 firmware/scripts/flash.sh` (reset and capture
only). Expect `RESULT: PASS` and a lit screen, as in step 4. The reference board was checked the same way after it was stripped.

---

## Part 3: the battery

### 11. Check the cell's polarity with a meter

Do this for every cell, every time. Waveshare's battery header and many retail LiPo leads use opposite pin
orders, and the board's pin 1 is not marked.

1. Set the meter to continuity.
2. Touch one probe to the USB-C shell (ground) and the other to each contact of the board's battery header in
   turn. The contact that beeps is ground.
3. The cell's **black** wire must land on that contact.
4. If the plug is wired the other way round, swap the two crimp contacts in the plug housing (lift each retention
   tab with a pin) rather than cutting the wires.

**Not documented:** whether the reference cell needed swapping.

### 12. Connect the cell and run on battery

1. Check the cell has its own protection circuit (the listing or datasheet should say so). The board has no
   battery protection.
2. Unplug USB from the board.
3. Plug the cell into the board's battery header. The clip starts and runs from the cell.

> [!WARNING]
> From here on, plugging in USB charges the cell. If R1 is still the original 1 kΩ (step 9 not done), unplug the
> cell before every USB connection, including flashing and any of the scripts in `firmware/scripts/`.

There is no power switch: as soon as the cell is connected the board draws power. "Off" is the firmware's deep
sleep (hold BOOT 6 s), which still draws a little.

---

## Part 4: the case

### 13. Print the case

Files: [`../case/stl/`](../case/stl/) (`pixelclip-case-tray.stl`, `pixelclip-case-lid.stl`,
`pixelclip-case-key-a.stl`, `pixelclip-case-key-b.stl`). Print one tray, one lid and two of each key.

Settings, orientation and reasons: [`../case/README.md`](../case/README.md). In short: PETG, 0.4 mm nozzle,
0.16 mm layers, 6 walls, 40 % gyroid, no supports, keys face down on a **textured** plate (keys have come
unstuck from a smooth plate). About 17.5 g in total.

*Why 0.16 mm:* the key and latch fits were tuned on that layer height, and other heights round the small gaps
differently.

### 14. Wrap the cell and tape it under the board

1. Wrap the cell in Kapton tape.
2. Lay it flat against the back of the board, under the display area, with its lead at the USB end so the wire
   meets the plug directly. The 41 mm cell ends just short of the battery plug and does not overhang the board.
3. Tape it in place with Kapton (or thin double-sided tape). The case allows only about 0.15 mm for tape under
   the cell.

The cell is held by tape and by the case. It is never glued and never carries load.

**Not documented:** whether any foam or padding goes between the cell and the tray floor in this case. An early
design note asked for 1 mm of foam between the cell and a clip spring; this case leaves no room for that.

### 15. Fit the keys

Do this **before** the board goes in: each key's pusher has to slide past the switch from the inside.

1. Take one key A (one notch on the flange rim).
2. Drop it into its pocket inside one long wall of the tray, near the USB end, face outward through the slot in
   the outer wall.
3. Repeat on the other side.

If a key binds or does not move freely once the case is closed, use the looser key B (two notches) instead.

### 16. Fit the board and close the lid

1. Lower the board into the tray, display up, cell underneath, USB-C toward the tray's USB opening. It rests on
   ledges along both long walls, and small ribs centre it.
2. Check both keys still move.
3. Set the lid on, line it up, and press it straight down until the latches click all round.
4. Press each key: you should feel the switch click. Press RESET once to confirm it restarts the clip; press BOOT
   to step through content.

To open the case, put a fingernail or a small flat screwdriver in the notch at the far end where lid and tray
meet, lever the far end up first, then lift the lid off.

**About the window:** the lid's oval window hides about 6 % of the picture, at the four corners. The firmware and
app in this repository do not yet lay content out around that window, so keep important detail away from the
corners of anything you send.

If you printed the lid in a clear or translucent filament, a strip of black tape over the screen's ribbon area at
the USB end hides it.

### 17. Attach the hair clip

**Not documented for this case.** The project chose alligator hair clips. For earlier case designs the notes say:
glue the alligator clip flat to the underside of the floor, clear of the keys, with E6000 or two-part epoxy (clear
epoxy or clear UV glue for a clear case), scuffing both surfaces first. Their size, number and position on this
tray were never written down, and glue adhesion on PETG was not recorded.

Whatever you use:

- Keep the clip's spring and any clamping force off the cell side of the floor. The floor is thin, and a pouch
  cell must not be bent, pierced or squeezed.
- Keep the USB cove, the keys and the pry notch clear.

The tray has a 2 mm hole through each side of the USB cove for a jump ring and a charm. The firmware turns the
picture 180° by itself when the clip is worn upside down, so either way up works.

---

## Part 5: the app

### 18. Build and install the app

Follow [`../ios/README.md`](../ios/README.md). The minimum, on a Mac with Xcode 26 or later:

1. `brew install xcodegen`
2. In `ios/project.yml`, set your team id and change the bundle ids and the App Group from `com.example` to a
   prefix you own (details in the root [`README.md`](../README.md) and in `ios/README.md`, "Bundle id and signing").
3. `xcrun devicectl list devices` to find your iPhone, then from `ios/`: `DEVICE_ID=<id> ./build.sh device`.

Joining the clip's WiFi needs the Hotspot Configuration entitlement, which needs a **paid** Apple Developer
membership. To try the app without hardware, `./build.sh run` uses a built-in virtual clip in the simulator.

### 19. Send a first picture

1. Open the app and tap **Send**, pick a photo, frame it, and send it.
2. The first time, iOS asks for Bluetooth. Small requests go over Bluetooth; pictures wake the clip's WiFi, and
   iOS asks to join `PixelClip-XXXX` (once; it is remembered).
3. The picture appears on the clip.

If Bluetooth is off or the clip does not answer, hold BOOT for 1.5 s or more to open the hotspot first.

### 20. Change the hotspot password

Every clip starts with the same published WiFi password. Set your own on the clip with the `ap_password` config
key, then enter the same password in the app under Settings ▸ Advanced ▸ Hotspot password. See the root
[`README.md`](../README.md), "Things to know before you wear it".

### 21. Check the motion sensor

Send a live scene such as sand and tilt the clip. If the sand falls the wrong way, run Settings ▸ "Sand falls
the wrong way" in the app; it stores a correction on the clip.

---

## Charging and everyday care

**Charging.** Only after step 9. Any USB connection with the cell plugged in is a charge, whatever you plugged in
for; until R1 is changed, unplug the cell first (see "Read this before you connect a cell"). Plug a USB-C cable
into the cove at the end of the clip; the plug's moulded head fits into the cove. The clip keeps running while it
charges. A red LED on the board is driven by the charger
itself, not by the software (it may not show through the case). The battery level the app reports is not
meaningful while USB is plugged in, because the battery line then sits at the charger's voltage.

**Power off and on.** Hold BOOT for 6 s or more: the clip says "bye" and sleeps. A short press on BOOT wakes it.

**Low battery.** At about 8 % (about 3.66 V) the clip shows "Battery low" for 10 s and goes to sleep; it also
sleeps below 3.40 V, before the cell's own protection would cut it off abruptly. WiFi sessions are refused below
3.5 V. The percentage is on the firmware's own scale, where 0 % is 3.40 V (`firmware/components/power/power.c`),
and 8 % is the default of the `low_battery_pct` setting.

**"Battery trouble / check the plug".** The firmware shows this and sleeps after five short battery runs in a row
that ended in power-loss restarts. Open the case and check the battery plug and lead. During development one
unexplained total power loss on battery happened; the battery lead, plug or cell protection was suspected and
never pinned down.

**Runtime.** About 5.5 h of always-on wear is the project's estimate, not a measurement. The clip logs its own
battery voltage every 60 s; see [`../firmware/README.md`](../firmware/README.md), "Battery logger", to measure
yours.

**Storage.** Sleep is not off: the board keeps drawing a small current, enough to drain the cell over weeks to
months (an estimate). For long storage, open the case and unplug the cell.

## Safety

A LiPo cell worn on the head needs care, and parts of this build were never measured (see "What has and has not
been tested"), including the charge current after the R1 change. At the least:

- **Use a protected cell.** The board has no battery protection of its own.
- **Check polarity with a meter** on every new cell before plugging it in.
- **Change R1 before the cell and USB are ever connected together**, and confirm the current if you can.
  Unmodified, the board charges at about twice this cell's rating, and it charges whenever USB and the cell are
  both connected; software cannot stop it.
- **Do not charge unattended**, and do not charge while the clip is in your hair.
- **Never bend, pierce or clamp the cell.** Keep clip springs and glue off it. Stop using a cell that has swollen,
  been punctured or got hot.
- **Insulate the back of the board** where header pins were cut, so nothing sharp touches the cell.
- **Keep it cool.** The chip is rated to 65 °C ambient. Keep the clip out of hot sun, hot cars and hair-dryer
  heat; PETG survives these better than PLA, the electronics less so.
- **Know the radio link is local and unencrypted** beyond the hotspot's WPA2 password. See the root
  [`README.md`](../README.md).

## Troubleshooting

| Symptom | Try |
|---|---|
| No `/dev/cu.usbmodem*` port | Hold BOOT, tap RESET, release BOOT, then flash. Check the cable carries data. (Unplug the cell first if R1 is unchanged.) |
| Dark screen right after flashing | The chip may still be in download mode: press RESET. |
| `PASS` but the screen stays dark | The panel may be faulty; see step 1. |
| A key does nothing | Check the key moves freely; try the looser key B. |
| The lid leaves a gap over the board | Something under the board is holding it up: the cell, extra tape, or leftover header pins (see "Choosing substitutes" in [`PARTS.md`](PARTS.md)). |
| The clip restarts during WiFi on battery | A bulk capacitor at the battery input is the documented fix ([`HARDWARE.md`](HARDWARE.md) §7); the case has no room reserved for it. |
| Sand falls sideways | Step 21. |
