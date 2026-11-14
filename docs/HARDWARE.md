# Hardware reference: Waveshare ESP32-S3-AMOLED-1.91 (non-touch)

> **Which cell this page assumes.** This page was written around the 220 mAh 402030 cell the project started with
> (section 8). The build later moved to a 500 mAh 602040 cell rated 0.5 A, which is what [`PARTS.md`](PARTS.md)
> and [`BUILD.md`](BUILD.md) specify. Unless a figure below says otherwise, C-rates, runtimes and the "0.2 A" rating
> are for the 220 mAh cell. For the 500 mAh cell: the unmodified 1 kOhm R1 (about 1 A) is about 2 C, 4.7 kOhm
> (about 210 mA) is about 0.4 C, and 9.1 kOhm (about 110 mA) about 0.2 C.

_Written 2026-10-10, before the first bring-up. Sources are listed at the end. **UNCONFIRMED** = could not be verified from the schematic, demo code or datasheets; measure or check before relying on it. "Schematic" = Waveshare's published schematic (one page, no revision number; link under Sources). "Demo" = Waveshare's demo repository (link under Sources). Neither is included in this repository._

## 0. Key findings (read first)

| Common assumption about this board | Finding |
|---|---|
| RTC chip on board | **No RTC IC in the schematic.** The wiki intro says "onboard RTC" but names no part and shows no I2C RTC, 32 kHz crystal or RTC interrupt. The only I2C device is the QMI8658C. The XTAL_32K pins are unconnected. Timekeeping is the ESP32-S3 internal RTC timer (RC-based). RTC part number and interrupt: **UNCONFIRMED, probably absent**. |
| RM67162 display driver | Waveshare's product page and resources page say RM67162. The Waveshare demo drives the panel with the `esp_lcd_sh8601` component. Both are MIPI-DCS-style QSPI controllers. Use the demo init sequence (section 4). |
| PWR button / power-path IC | **No PWR button, no power latch, no power switch.** Only BOOT (GPIO0) and RESET (EN). Power path is a discrete diode plus P-MOSFET. |
| Battery ADC may exist | Yes: GPIO1 through a 100k/100k divider (always connected). |
| Charge current | The PL4054 PROG resistor is 1 kOhm, nominally about 1 A. That is about 4.5 C for a 220 mAh cell and about 2 C for the 500 mAh reference cell. It flows whenever USB and the cell are both connected; software cannot stop it. See section 3. |
| Flash 16 MB / PSRAM 8 MB | Confirmed from part numbers (section 5). |

## 1. Block diagram in words

- USB-C (CC1/CC2 each 5.1k to GND, so it is a plain 5 V sink) feeds net `USB VCC`. D+/D- go straight to GPIO20/GPIO19, the ESP32-S3 native USB Serial/JTAG (flash and console, no UART bridge).
- `USB VCC` feeds (a) the PL4054 charger input (`VBUS-B`) and (b) `VSYS` through diode D1 (1N4148). The battery (`BAT`) feeds `VSYS` through P-MOSFET Q1 (APM2307), which is on whenever USB is absent.
- `VSYS` feeds the 3.3 V LDO U1 (5-pin, VIN/GND/EN/BYP/VOUT; part number not printed on the schematic). U1 output is `VCC3.3`, which powers the MCU, flash, IMU, SD slot, display logic and the display boost converter.
- TPS65137AS (U4) boosts 3.3 V into the AMOLED supplies ELVDD (positive) and ELVSS (negative). Its CTRL pin is the net `OL_EN`, which goes to the display FPC (P2 pin 40). No MCU GPIO drives it (section 4).
- MCU: ESP32-S3R8 (dual LX7, in-package 8 MB octal PSRAM), 40 MHz crystal, W25Q128 16 MB SPI flash on the SPI0/1 pins, chip antenna (an IPEX connector footprint with 0R select resistors also exists).
- Peripherals: display on a QSPI bus (GPIO 6/47/18/7/48/5 plus RST on 17); QMI8658C IMU on I2C (GPIO39/40) with INT1/INT2 on GPIO45/46; TF slot sharing GPIO8/9/42 (and 47 on one revision) with the display connector nets; BOOT on GPIO0; RESET on EN; battery divider on GPIO1; Pico-style 2x20 header (H1/H2) exposing the spare GPIOs, UART0, USB and power nets.
- Charge LED L1 (red, via 470R from USB VCC to the PL4054 CHRG pin) is hardware-driven, not a GPIO. There is **no user LED on any GPIO**.

## 2. Pin map

Verified two ways: the schematic's pin-allocation table (bottom right) and the Waveshare demo sources (`03_LVGL_V8_Test`, `02_I2C_QMI8658`, `04_SD_Card`, `01_ADC_Test`). They agree except where noted.

| GPIO | Function | Header pin | Notes |
|---|---|---|---|
| 0 | BOOT button to GND | H1-4 | Strapping. No external pull-up drawn; rely on the internal pull-up (and the RTC pull-up for deep-sleep wake). |
| 1 | BAT_ADC (ADC1_CH0) | H1-5 | Divider 100k/100k: **Vbat = 2 x Vpin**. C26 100 nF on the node. Demo: 12 dB attenuation, curve-fitting calibration, value x 2. |
| 2 | free | H1-6 | |
| 3 | free (strapping: JTAG source) | H1-7 | Avoid external loads at boot. |
| 4 | free | H2-10 | |
| 5 | LCD QSPI D3 (schematic net "DB1") | none | Demo `LCD_DATA3`. |
| 6 | LCD CS | none | |
| 7 | LCD QSPI D1 (schematic net "DCX_RS") | none | Demo `LCD_DATA1`. |
| 8 | SD MISO (rev V1) / SD D0 (rev V2); also display SDO net | none | See SD note below. |
| 9 | SD CS (V1) / SD CLK (V2); also display TE net | none | Display TE (tearing effect) is not used by the demo. |
| 10-14 | free | H2-9, H1-9..12 | GPIO10 = H2-9; GPIO11, 12, 13, 14 = H1-9, 10, 11, 12. |
| 15 | free | H1-14 | |
| 16 | free | H2-7 | |
| 17 | LCD RESET (demo `LCD_RST`, via R13 0R to the panel reset net, which has R12 10k pull-up and C21 1 uF) | H2-6 | The schematic table lists GPIO17 as "OUT/free" and the header exposes it, but the demo uses it as display reset. Do not reuse it. |
| 18 | LCD QSPI D0 (schematic net "RD_SDI") | none | Demo `LCD_DATA0`. |
| 19 / 20 | USB D- / D+ | H1-15 / H1-16 | Native USB. |
| 21 | free | H1-17 | |
| 26 | In-package PSRAM CS (SPICS1) | H1-19 | Wired to the header but **reserved**. `sdkconfig`: `SPIRAM_CS_IO=26`, `SPIRAM_CLK_IO=30`. |
| 27-32 | In-package flash/PSRAM SPI | none | Reserved. |
| 33-37 | Octal PSRAM data[4:7] and DQS | H1-20 (33), H2-20 (34), H2-19 (35), H2-17 (36), H2-16 (37) | Datasheet v2.2 section 2.4 lists GPIO33-37 as the upper data lines and DQS for 8-line SPI. With ESP32-S3R8 they are consumed by the PSRAM. Treat as **reserved** (confidence: medium-high; Espressif module docs say 35-37 are unusable on R8 parts, 33/34 follow from the same rule). |
| 38 | free | H2-15 | |
| 39 | I2C SCL (IMU; the touch variant shares it for the touch IC) | H2-14 | Demo `I2C_MASTER_SCL_IO 39`, 300 kHz. JTAG MTCK function by default. |
| 40 | I2C SDA (IMU) | H2-12 | Demo `I2C_MASTER_SDA_IO 40`. |
| 41 | TP_INT (touch variant only) | none | Routed only to the display FPC. Unused on this non-touch board. |
| 42 | SD MOSI / SD CMD | none | R14 10k pull-up to 3V3. |
| 43 / 44 | UART0 TX / RX | H1-1 / H1-2 | Console if USB-JTAG console is not used. |
| 45 | QMI8658C INT1 | none | **Strapping pin** (VDD_SPI). |
| 46 | QMI8658C INT2 | none | **Strapping pin** (ROM log / boot mode). |
| 47 | LCD QSPI CLK (schematic net "WRX_SCL"); also SD CLK on rev V1 | none | |
| 48 | LCD QSPI D2 (schematic net "DB0") | none | Demo `LCD_DATA2`. |

QSPI display mapping used by the demo: CS=6, CLK=47, D0=18, D1=7, D2=48, D3=5, RST=17, no backlight pin (`BK_LIGHT -1`).

**IMU I2C address:** QMI8658C is 0x6A or 0x6B depending on SA0. The demo probes both and then uses 0x6B; the schematic drawing shows SDO/SA0 labelled GND, which would be 0x6A. **UNCONFIRMED: probe both.** IMU interrupt pins are INT1=GPIO45, INT2=GPIO46.

**RTC:** none found (section 0). RTC interrupt pin: none.

**SD card revisions:** the schematic (and the demo's non-default `#else` branch) uses SPI mode, with SD CLK shared with display CLK on GPIO47, CS=9, MISO=8, MOSI=42. The demo's default (`VersionControl_V2`) uses SDMMC 1-bit with CLK=9, CMD=42, D0=8, leaving 47 for the display only. Which revision our board is: **UNCONFIRMED**. This project does not use the TF slot: do not insert a card, and keep GPIO8/9/42 as inputs or unused.

**GPIOs genuinely free for us (safe, on header):** 2, 3 (strapping, avoid pulling at boot), 4, 10, 11, 12, 13, 14, 15, 16, 21, 38. GPIO0 is the button. That is 12 spare pins; only H1/H2 positions above matter if a header is soldered (the base SKU 28872 ships without headers; the "-M" SKU has them).

## 3. Power

| Item | Finding |
|---|---|
| Charger | **PL4054** (PL1, 5-pin SOT-23, TP4054/LTC4054 family linear charger, 4.2 V). Input `VBUS-B` from USB VCC. CHRG pin drives LED L1 through 470R. No MCU status line. PL4054 datasheet not found; the 4054-family relation is I_charge = 1000 / R_PROG(kOhm) (confirmed for STC4054 and LP4054; for PL4054 itself **UNCONFIRMED**). |
| Charge current | R1 = **1 kOhm** on PROG, so roughly **1000 mA programmed** (thermally throttled in practice, TP4054-class max is about 800 mA). For a 220 mAh cell that is 3.6 to 4.5 C, far above the usual 0.5 C standard / 1 C max. **Do not charge the 220 mAh cell from this board unmodified.** Fix: change R1 to about 9.1 kOhm (about 110 mA, 0.5 C for 220 mAh) or 4.7 kOhm (about 210 mA, about 1 C for 220 mAh, about 0.4 C for the 500 mAh reference cell, the value [`PARTS.md`](PARTS.md) specifies). Check the cell's own datasheet. Confirm real current with a USB meter. |
| Charge/run independence | The charger sees USB VCC directly and connects to the BAT node, while the system load hangs on VSYS through D1. The board runs from USB while the cell charges. **The charger is not under software control**: no GPIO enables or disables it, so whenever USB is connected and a cell is plugged in, the cell charges at the current R1 sets, including during flashing and debugging. |
| Battery connector | Waveshare product page: "3.7V MX1.25 lithium battery recharge/discharge header" (2 pins, MX1.25 = Molex Picoblade-style 1.25 mm). Schematic symbol BAT1: pin 1 to net BAT, pin 2 to GND. **Physical pin order, silkscreen polarity: UNCONFIRMED.** Many LiPo leads are wired opposite to Waveshare's convention. **Check polarity with a meter before connecting.** |
| Battery protection | None on the board (no DW01/protection IC in the schematic). The cell must have its own protection circuit (PCM). Firmware must still stop at about 3.3 V. |
| Power path | `VSYS` = USB through D1 (1N4148, so about 4.3 to 4.4 V at light load, lower at 300 mA) or BAT through Q1 (APM2307 P-MOSFET). Q1 gate: R9 1k from USB VCC, R11 10k to GND. USB absent: gate at 0 V, Q1 on, VSYS = Vbat minus I x Rds(on). USB present: gate about 4.5 V, Q1 off. MOSFET pin/body-diode orientation **UNCONFIRMED**; the standard behaviour is as above. Gate divider draws 5/11k = 0.45 mA, only while USB is attached. |
| 3.3 V LDO | U1, 5-pin with BYP. **Part number not printed on the schematic: UNCONFIRMED** (so dropout, current rating and quiescent current are UNCONFIRMED). EN is pulled up to VSYS through R2 10k and is brought out on header **H2-4 (`3V3_EN`)**. Because it is a **linear** regulator, battery current equals 3.3 V rail current plus LDO quiescent; there is no buck gain. Input caps C10 10 uF, output C11 10 uF, bypass C14 100 nF. |
| Hardware power switch / latch | **None.** `3V3_EN` on H2-4 can be pulled to GND (for example a slide switch on the clip) to shut the LDO off, which is the only true hard-off. CHIP_UP/EN on H2-11 is the reset line (R7 10k, C17 1 uF). |
| Buttons | BOOT (B1) to GPIO0 to GND. RESET (R10) pulls EN to GND. **No PWR button.** Behaviour: hold BOOT while pressing RESET (or while powering up) to enter the ROM download mode; otherwise BOOT is a normal GPIO input. |
| USB unplugged, battery attached | Q1 turns on and the board runs from the battery. Charger input floats, so no charging. There is no off state: the board draws power until the cell is empty or the firmware deep-sleeps. |
| Always-on drains | Battery divider R6+R8 = 200k across BAT, **no switch**: 15 uA at 3.0 V, 21 uA at 4.2 V. PL4054 BAT-pin leakage with no USB: UNCONFIRMED (about a few uA in the 4054 family). |
| Brownout risk | The likely failure is LDO dropout (part unknown) when the cell is low and WiFi bursts sag it, not the ESP32-S3 brownout detector. |

## 4. Display

| Item | Finding |
|---|---|
| Panel | 1.91 inch AMOLED, 536 x 240 (240 x 536 portrait native), 65K colour (RGB565) in use, 16.7 M colour capable. Waveshare lists 350 cd/m2 typical, contrast 100000:1. |
| Controller | Product page: **RM67162**. Demo code: `esp_lcd_sh8601` component. Treat as **RM67162-class**, driven with the demo's SH8601 driver. The RM67162 datasheet on the resources page (Raydium Rev 0.5, Feb 2016) is for the 480x480 variant and has **no current figures**; it does define 0x51 WRDISBV, 0x28/0x29, 0x10/0x11, 0x4F deep standby, and a SWIRE pin for an external power IC. |
| Interface | QSPI (4 data lines); mode pins IM0/IM1 are strapped on the board (exact levels not read). SPI2_HOST in the demo. Frame memory is **inside the controller**: static content needs no refresh from the host, so the MCU can sleep while the display holds the image. |
| Init sequence (demo) | `0x11` sleep out (120 ms), `0x36 F0` (rotate to landscape), `0x3A 55` (RGB565), `0x2A 0000 0217` (cols 0-535), `0x2B 0000 00EF` (rows 0-239), `0x51 00`, `0x29` display on, `0x51 FF`. The sample also contains an optional `0x44` (tear scanline), `0x35` (TE on) and `0x53 20` (brightness control on) in the driver's built-in table. |
| Brightness | **Available by command**: `0x51` write display brightness, 0x00 to 0xFF (RM67162 datasheet). No PWM backlight pin (`BK_LIGHT -1`). Use it for fades and for the app's brightness cap. |
| Rails | Logic and VCI from VCC3.3 (P2 pins IOVCC, VCI). AMOLED power from U4 TPS65137AS (VIN = VCC3.3, 4.7 uH inductors L4/L5): positive ELVDD, negative ELVSS. |
| Separate power enable? | The boost converter's CTRL pin (`OL_EN`) goes to the display FPC pin 40 only; **no MCU GPIO drives it** and no pull is drawn on the schematic. It is therefore presumably driven by the display module/controller (the RM67162 datasheet's power IC control pin is SWIRE, and OL_EN is not documented). **UNCONFIRMED.** Practical consequence: there is no GPIO to cut AMOLED power. Use `0x28` (display off) then `0x10` (sleep in) and measure the real current. Deep standby (`0x4F`) is defined in the RM67162 datasheet; whether the SH8601 build honours it is UNCONFIRMED. |

## 5. Flash and PSRAM (resolved)

| Item | Finding |
|---|---|
| Flash | **U3 = Winbond W25Q128** (schematic) = 128 Mbit = **16 MB**, SPI (QIO capable), on VCC3.3 via the SPI0/1 pins. |
| PSRAM | **ESP32-S3R8** (U2) = 8 MB octal SPI PSRAM in package (datasheet v2.2 table of variants: 8 MB, Octal SPI, 3.3 V, -40 to 65 C). |
| Demo sdkconfig | `07_FactoryProgram`: `ESPTOOLPY_FLASHSIZE_16MB`, QIO at 80 MHz, `SPIRAM_MODE_OCT`, type auto. The 2 MB/4 MB values in the small samples (`01_ADC_Test`, `05_WIFI_STA`, and so on) are only the stock ESP-IDF defaults the sample authors did not bother to change, and they limit the image size, not the chip. Our `sdkconfig` must set 16 MB flash, octal PSRAM, 80 MHz. |
| Confidence | **High** (flash part number and chip variant are printed on the schematic and the factory project agrees). The first flash will also report the true size via `esptool flash_id`; check once. |
| Max operating temperature | S3R8 is rated to 65 C ambient: keep the clip out of hot sun and hair dryers. |

## 6. Mechanical

| Item | Finding |
|---|---|
| Board outline | About **57.5 x 24.5 mm** for the non-touch version (CNX Software, secondary source: medium confidence). The touch version is about 59.6 x 28.5 mm. Official outline drawings are images in `Esp32-s3-amoled-1_91-M.zip`, which I did not download (needs your OK). Thickness: UNCONFIRMED. |
| Display active area | Not stated in the text. **Derived**: 536 x 240 px, 1.91 inch diagonal gives about 0.083 mm pixel pitch, so about **44.3 x 19.8 mm**. The product page says "CNC metal case" (the shipped case, not our clip). |
| Mounting holes | **UNCONFIRMED** (in the dimension drawing). |
| Battery connector position | **UNCONFIRMED** (drawing). |
| USB-C side | **UNCONFIRMED** (drawing). The headers H1/H2 (2 x 20, Pico layout) run along the long edges. |
| Connectors | USB-C, MX1.25 battery header, TF slot, 2 x 20 header footprints, IPEX/chip antenna selection. |

Action: download the dimension ZIP (with your approval) and fill rows marked UNCONFIRMED.

## 7. What this means for a 220 mAh hair clip

_The figures in this section are for the 220 mAh cell; the released build uses 500 mAh (see the note at the top). Its own runtime estimate is in [`PARTS.md`](PARTS.md)._

Budget logic: the 3.3 V rail comes from a linear LDO, so **battery mA = rail mA + LDO quiescent**. Datasheet figures below are for the bare chip at 3.3 V, 25 C; the S3R8 variant draws more than the non-PSRAM numbers (the datasheet says so), and the AMOLED numbers are **my estimates, not datasheet values** (no panel current spec is available). Replace them with measurements on the real board.

| State | Expected battery current | Basis |
|---|---|---|
| Display on, **dark** content, CPU 80 MHz active, WiFi off | ~40-65 mA | SoC 80 MHz modem-sleep WAITI 22.0 mA (clocks gated) to 36.1 mA (clocks on), single core busy 28-43 mA (datasheet Table 5-9), plus panel+boost ~8-20 mA at moderate brightness (UNCONFIRMED estimate). |
| Display on, **bright/white**, CPU active | ~110-200 mA | Panel+boost 70-130 mA estimate (UNCONFIRMED); a 20-80 mA display delta is the optimistic figure. White at full brightness is the worst case: forbid it with the app brightness cap. |
| Display on dark, CPU in **light sleep** (static content) | ~10-25 mA | Panel dominates. Light sleep 240 uA plus 140 uA for 8 MB octal PSRAM (datasheet Table 5-10 note 1). The controller keeps the image in its own RAM. |
| Display off (0x28 + 0x10), CPU active 80 MHz | ~25-40 mA | Datasheet Table 5-9. |
| Display off, light sleep | ~0.5-1 mA | 240 uA + 140 uA + divider 21 uA + LDO/flash/IMU quiescent (UNCONFIRMED). |
| WiFi SoftAP, display off | ~100-140 mA average | RX 88 mA (HT20) / 91 mA (HT40) always on in AP mode (an AP cannot power-save), plus CPU 22-36 mA; bursts per below. |
| WiFi TX peaks (datasheet, 100% duty, 3.3 V) | 340 mA @21 dBm 802.11b; 291 mA @19 dBm 54 Mbps; 283 mA @18.5 dBm HT20 MCS7; 286 mA @18 dBm HT40 MCS7 | Datasheet Table 5-7. Above the cell's 0.2 A continuous rating (1.4 to 1.7 C bursts). |
| Deep sleep (firmware off state) | ~0.05-0.3 mA | SoC 7-8 uA (Table 5-10) + divider 15-21 uA + W25Q128 standby (about 25 uA typical per Winbond, from memory, UNCONFIRMED) + LDO Iq (UNCONFIRMED) + QMI8658C if left running (UNCONFIRMED) + display module leakage (UNCONFIRMED). A full cell would last weeks, not years. |

Runtime sanity (usable about 85% of 220 mAh = 187 mAh): 50 mA gives about 3.7 h; 15 mA (light sleep, dark content) gives about 12 h; WiFi AP at 120 mA gives about 1.5 h, so a 2-minute session costs about 4 mAh.

### Recommendations

1. **Fix the charge current before first charge.** Replace R1 (1k) with about 9.1k (about 110 mA) or at least 4.7k (about 210 mA). Verify with an inline USB meter. Until then, charge the cell with a separate 0.5 C charger.
2. **Verify battery polarity with a meter** before plugging the MX1.25 lead; re-crimp or swap pins if needed. Confirm the cell has a protection circuit (the board has none).
3. **Bulk capacitor**: 220-470 uF low-ESR (polymer tantalum or polymer aluminium, 6.3 V) right at the battery connector, on the BAT/VSYS side of Q1 and the LDO, not on the 3.3 V rail. If thickness limits the clip, use 2 to 4 x 47-100 uF X5R 0805 ceramics in parallel (derate for DC bias, so count on about 40%). The board only has 22 uF (C13, on USB VCC) and 10 uF at the LDO in and out. The cell's own ESR plus Q1 plus the LDO dropout are what sag under 300 mA bursts.
4. **WiFi**: `esp_wifi_set_max_tx_power(32)` (about 8 dBm; units 0.25 dBm) or 44 (11 dBm) for a phone half a metre away; HT20 only (`esp_wifi_set_bandwidth`), 11g/n, a fixed channel, `max_connection = 1`, 802.11b disabled. Expect peak current well below the 283-340 mA table values, but this is UNCONFIRMED: measure. Consider keeping the display off during sessions on small cells, and abort the session if Vbat < ~3.5 V.
5. **Display**: no hardware enable exists, so the only knobs are `0x51` brightness, `0x28` display off and `0x10` sleep in. Send them before light/deep sleep. After `0x10`, wait 120 ms before `0x11` (RM67162 datasheet note).
6. **Idle**: static content, CPU 80 MHz, light sleep between frames (the controller holds the image); wake from GPIO0 for the button.
7. **Never use GPIO26-37** (PSRAM), GPIO17 (display reset), GPIO47/48/5/6/7/18 (display), GPIO8/9/42 (SD/display nets); keep GPIO45/46 untouched (strapping, IMU interrupts) and GPIO0/3 clean at boot.
8. **Battery gauge**: `Vbat = 2 x ADC(GPIO1)` at 12 dB, one-shot, with curve-fitting calibration. Sample sparsely (the divider itself is always on). While USB is attached the BAT node sits at the charger voltage, so the reading is not state-of-charge. Calibrate empirically: log voltage against time over a full discharge.
9. **Hard off**: optionally wire a small slide switch from H2-4 (`3V3_EN`) to GND (about 0 uA from the LDO side; the 200k divider and charger leakage remain). This replaces the missing PWR switch and removes the always-on deep-sleep drain.
10. **Timekeeping**: with no RTC IC, system time uses the internal RTC slow clock during sleep. Expect noticeably worse accuracy than a crystal (internal RC, calibrated against the 40 MHz crystal at wake; error magnitude **UNCONFIRMED**, plausibly tens of seconds per day). While the CPU is awake, esp_timer follows the 40 MHz crystal (tens of ppm). Re-sync time from the phone on every connection and treat clock-driven content (scheduled items, timed rows) as accurate to the minute only while the clip was recently synced.
11. **GPIO0 wake**: no external pull-up is drawn, so enable the RTC pull-up (`rtc_gpio_pullup_en`) and use ext0/ext1 wake on low level before entering deep sleep.

## Sources

- Schematic (Waveshare): https://files.waveshare.com/wiki/ESP32-S3-AMOLED-1.91/ESP32-S3-AMOLED-1.91.pdf (not included in this repository).
- Waveshare wiki: https://docs.waveshare.com/ESP32-S3-AMOLED-1.91 and Resources page https://docs.waveshare.com/ESP32-S3-AMOLED-1.91/Resources-And-Documents
- Waveshare product page (MX1.25 header, RM67162, 350 cd/m2): https://www.waveshare.com/esp32-s3-amoled-1.91.htm
- Waveshare demo repo: https://github.com/waveshareteam/ESP32-S3-AMOLED-1.91 (not included; files `02_Example/ESP-IDF/07_FactoryProgram/**`, `03_LVGL_V8_Test`, `01_ADC_Test`, `02_I2C_QMI8658`, `04_SD_Card`, `06_WIFI_AP`).
- ESP32-S3 datasheet v2.2 (Tables 5-7, 5-9, 5-10; GPIO restrictions; variant table): https://documentation.espressif.com/esp32-s3_datasheet_en.pdf
- RM67162 datasheet (Raydium, Rev 0.5): https://files.waveshare.com/wiki/common/RM67162.pdf
- QMI8658C datasheet: https://files.waveshare.com/wiki/common/QMI8658C_datasheet_rev_0.9.pdf
- Dimension drawings (not downloaded): https://files.waveshare.com/wiki/ESP32-S3-AMOLED-1.91/Esp32-s3-amoled-1_91-M.zip
- Board size (secondary source): https://www.cnx-software.com/2024/10/22/esp32-s3-board-features-1-91-inch-amoled-display-and-qmi8658-6-axis-motion-sensor/
- 4054-family charge current formula: STC4054 https://www.st.com/resource/en/datasheet/stc4054.pdf and LP4054 https://www.lowpowersemi.com/storage/files/2023-05/1a8d7aac98bab67705c58652b8895561.pdf (PL4054 datasheet not located).

## 8. The battery first purchased (added 2026-10-10)

_History: this is the first cell bought for the project. The build later moved to a 500 mAh 602040 cell sold under
the same name (0.5 A, protection PCB), with R1 changed to 4.7 kOhm; see [`PARTS.md`](PARTS.md). The polarity check
and the low-battery behaviour below apply to both cells._

HXJNLDC 402030 LiPo, 3.7 V nominal / 4.2 V full, 220 mAh (0.81 Wh), 4 × 20 × 31 mm, 5 g, JST-style 1.25 mm 2-pin
connector, red = +, black = −. Listing states **maximum current 0.2 A** and a built-in protection PCB (Seiko IC:
overcharge, over-discharge, overcurrent, short circuit).

| Implication | Detail |
|---|---|
| Charge current | The pack protection does **not** limit charge current to a safe value: 4054-class chargers push ~1 A with R1 = 1 kΩ, and protection-IC overcurrent thresholds are typically 1–3 A. **R1 must still be changed (9.1 kΩ ≈ 110 mA = 0.5 C) or the cell charged externally at ≤ 110 mA.** |
| Over-discharge cutoff | The protection IC will hard-cut the cell around 2.5–3.0 V; the board then browns out abruptly and the ESP32 cannot shut down cleanly. Firmware must deep-sleep before that so the pack never reaches its own cutoff. As built, the firmware has a hard floor at **3.40 V** and, by default, sleeps at **8 %** on its own scale, where 0 % is 3.40 V; 8 % is about **3.66 V** (`firmware/components/power/power.c`; the percentage is the `low_battery_pct` config setting). Deep-sleep draw (~10 µA board + 20 µA divider + protection IC) still drains a 220 mAh cell in ~6–8 months: unplug for long storage. |
| 0.2 A max discharge | That is a 1 C rating, not a hard trip. WiFi TX peaks of ~0.3 A for a few ms will not trip protection but will sag the cell; mitigations in §7 (TX power cap, display off during WiFi, 470–1000 µF bulk capacitor on VSYS/BAT) all apply. Steady-state display-on draw (≈ 60–100 mA) is comfortably inside the rating. |
| Connector polarity | **Check before plugging in.** Waveshare 1.25 mm battery headers are frequently wired opposite to Amazon packs. With a multimeter: the board pin that beeps to GND (USB shell, any GND header pin) must receive the **black** wire. If reversed, swap the crimp contacts in the plug housing (lift the retention tab with a pin) rather than cutting wires. The schematic names pin 1 = BAT, pin 2 = GND, but the physical orientation is UNCONFIRMED (§6). |
| Mechanical | 20 × 31 mm footprint vs a ≈ 57.5 × 24.5 mm board: it fits behind the board. Pouch cells must not be bent, pierced or clamped by the clip spring; leave 1 mm of foam between cell and clip. |

## 9. IMU orientation (bench, 2026-10-11)

The QMI8658C is mounted rotated 90° relative to the screen: with the stock axis map, gravity read as +X (things "fell" to the right) when the clip was upright. `CONFIG_PIXELCLIP_IMU_SWAP_XY=y` fixes it (sand falls down, confirmed on the bench). Face-up sign not yet confirmed; the app's calibration wizard (`POST /imu/calibrate`) stores a per-device map in NVS if needed.
