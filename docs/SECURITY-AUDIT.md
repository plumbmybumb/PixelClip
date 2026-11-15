# Security audit, before first publication

This is the record of a security review of PixelClip done before the repository was first made public: what was
looked at, what was found, what was fixed, and what is still open. Source comments that say "security audit
WIFI-3" and the like refer to the ids in the tables below.

The short version for someone deciding whether to wear one is in the root
[`README.md`](../README.md#things-to-know-before-you-wear-it). To report a problem, see
[`SECURITY.md`](../SECURITY.md).

## Verdict

- **The parsers are in good shape.** Fuzzing with memory-error detection found no memory corruption in any
  decoder, parser or renderer.
- **The Bluetooth link is open by design, and that is still true.** There is no pairing, so a stranger in
  range can rearrange or delete what is stored, change settings, drain the battery and recognise the clip again
  later. These are the items marked **Open** below, and the README says so plainly.
- **The two worst outcomes were closed after the audit**, in a way that adds no step to sending: the app now
  gives each clip its own random hotspot password, and the clip refuses a firmware update unless its button is
  pressed. See "Built after the audit" below. Both are tested on a computer only.
- **Everything that could be fixed without changing how the clip is used has been fixed**, including a bug that
  let one small request crash the clip, or crash it on every boot.

## How it was done

Five independent reviews, each reading the code and testing on a computer:

| Area | Method |
|---|---|
| WiFi hotspot, HTTP API, firmware update, configuration, hardening options | Code tracing through the project and ESP-IDF v5.5 sources, disassembly of the built firmware, proofs of concept against the offline mock |
| Bluetooth LE | Code tracing; the request framing fuzzed for 15 million cases under AddressSanitizer and UndefinedBehaviorSanitizer against a reference model |
| Parsers and renderers (`core/`, storage, playlist, player, tools) | Hand review; twelve coverage-guided fuzz targets, about 96 minutes in total, 91–100 % line coverage of `core/` |
| iPhone app | Code tracing; probe tests on macOS; one end-to-end reproduction in the iOS simulator |
| What the repository publishes, and its supply chain | A fresh clone scanned through every commit for secrets and personal data; licences of all bundled material; everything that downloads or runs code at build time |

**What was not done.** Nothing was run on a real clip or over the air. Every firmware behaviour here is established
by reading code, by host tests, by the mock, or by disassembly. The closed-source radio libraries were not
reviewed. Items marked *suspected* need a radio or a device to confirm.

Severity is the reviewer's judgement of harm to a wearer: **Critical**, **High**, **Medium**, **Low**,
**Info**. Status is one of **Fixed**, **Mitigated** (made harder or narrower, not closed), **Open**,
**Accepted** (left as is on purpose), **Not applicable** (did not hold on checking).

## Bluetooth LE

| Id | Severity | Finding | Status |
|---|---|---|---|
| BLE-1 | Critical | No characteristic requires encryption or authentication, so every small request runs for anyone in range. | **Open.** Needs pairing. |
| BLE-2 | High | The hotspot password could be read and changed over Bluetooth. | **Fixed.** No answer on any link contains it, and it cannot be set over Bluetooth. |
| BLE-3 | High | A stranger can change what the screen shows from content already stored (playlist, show now, brightness, orientation, clock, queued items). | **Open.** Needs pairing. |
| BLE-4 | High | A stranger could switch the clip off remotely through the low-battery setting, or lock the owner out through settings and deletes. | **Mitigated.** The low-battery setting is limited to 0–20 %. The rest needs pairing. |
| BLE-5 | High | A stranger can drain the battery by holding the hotspot open or keeping a connection busy. | **Open.** |
| BLE-6 | High | The clip advertises a fixed address and a name unique to the unit, so a wearer can be followed. | **Open.** Needs private addresses, which need bonding. |
| BLE-7 | High | The app connects to the first device advertising the service, with no check that it is the user's clip. | **Open.** |
| BLE-8 | Medium | The newest connection replaces the current one, so a stranger can keep the owner off. | **Open.** |
| BLE-9 | Medium | Status, playlist, stored texts and the motion sensor are readable by anyone. | **Mitigated.** The motion-sensor routes are WiFi-only now. |
| BLE-10 | Low | Queued (long) writes are accepted and may pin buffers (*suspected*). | **Open.** |
| BLE-11 | Low | A replaced connection is not re-checked if ending it fails (*suspected*). | **Open.** |
| BLE-12 | Low | ESP-IDF 5.5.0's Bluetooth controller and host have fixes in later 5.5 releases. | **Mitigated.** `firmware/README.md` recommends 5.5.5 or later for release builds. |
| BLE-13 | Low | The documentation described Bluetooth as only opening the hotspot. | **Fixed.** |
| BLE-14 | Info | Bench-build crash routes are reachable over Bluetooth. | **Accepted.** Bench builds are off by default and not for wearing. |
| BLE-15 | Info | The development scripts connect to the first `PixelClip-…` they hear. | **Accepted.** |

## WiFi hotspot, HTTP API, firmware update

| Id | Severity | Finding | Status |
|---|---|---|---|
| WIFI-1 | Critical | The hotspot password was not a secret: `GET /config` returned it, also over Bluetooth. | **Mitigated.** It is write-only now and kept out of crash dumps, and the app replaces the published default with a random password at its first send over WiFi. A clip that has never been sent to over WiFi, or is used without the app, still has the default. |
| WIFI-2 | High | `POST /ota` installs any image; the sender supplies the hash, and nothing is signed or confirmed on the clip. | **Mitigated.** The clip refuses an image unless its button was pressed while it showed "Update?" (`403 press_button`). Images are still not signed. |
| WIFI-3 | High | Deeply nested JSON overflowed the task stacks: about 200 `[` crashed the clip, and a nested playlist was stored and then crashed it at every boot. | **Fixed.** Nesting is capped at 16, with a build-time check and regression tests. After three early crashes in a row the clip now also sets the stored playlist aside and starts idle. |
| WIFI-4 | Medium | No `Host`, `Origin` or `Content-Type` checks, so a web page open on the phone could send requests to the clip. | **Fixed.** |
| WIFI-5 | Medium | A setting change can lock the owner out, and there is no factory-reset gesture. | **Mitigated.** A button gesture puts the hotspot password back to the default without touching the content. Bluetooth switched off through the settings still needs a WiFi session to switch back on; anything else still needs a USB erase. |
| WIFI-6 | Medium | The access point was thought to still offer the old TKIP cipher. | **Not applicable.** On ESP-IDF 5.5.0 the WiFi library forces CCMP for this mode (checked by disassembly, not on the air). |
| WIFI-7 | Medium | `firmware/scripts/e2e.sh` built shell and Python code from values the clip returns, so an impostor clip could run commands on a contributor's computer. | **Fixed.** The proof of concept no longer executes. |
| WIFI-8 | Low | Slow or stalled clients turned into watchdog resets. | **Fixed** (verified by build only). One client can still hold the single station slot. |
| WIFI-9 | Low | Setting the clock far ahead permanently marks scheduled items as done. | **Open.** The web-page path is closed by WIFI-4. |
| WIFI-10 | Low | Information exposure: motion sensor over Bluetooth, the password inside crash dumps. | **Fixed** for those two. Battery log and text list stay readable. |
| WIFI-11 | Low | ESP-IDF 5.5.0's access-point DHCP server has a known out-of-bounds read (CVE-2026-45160). | **Mitigated.** Build release images with ESP-IDF 5.5.5 or later. |
| WIFI-12 | Low | The phone joins any `PixelClip-…` network that accepts the password it has, so an impostor works while the default is in use. | **Mitigated.** After the first setup the phone holds a random password an impostor does not know, and it does not fall back to the default by itself. |
| WIFI-13 | Info | USB or physical access is complete access. | **Accepted**, and stated in the README. Secure boot and flash encryption burn one-time fuses. |
| WIFI-14 | Info | Cheap compiler and runtime hardening was off. | **Fixed:** stack protector and stack-end watchpoint are on. Heap poisoning is left off until its RAM cost is measured on a clip. |

## Parsers and renderers

| Id | Severity | Finding | Status |
|---|---|---|---|
| PARSE-1 | Critical | The same nested-JSON overflow as WIFI-3, measured independently. | **Fixed.** |
| PARSE-4 | Medium | A Tarot deck replaced at exactly the wrong moment could be decoded past the framebuffer (needs a button press inside a few hundred milliseconds; found by reading, not reproduced). | **Fixed.** |
| PARSE-2 | Low | The free-space check wrapped for a 4 GB `Content-Length`. | **Fixed.** |
| PARSE-3 | Low | An accepted compressed frame could exceed the player's scratch limit, making a lone animation restart forever. | **Fixed.** |
| PARSE-9 | Low | Every oracle item re-read its text bundle, so a crafted playlist cost many seconds of flash reads. | **Fixed.** |
| PARSE-6 | Low | The host tools allocated whatever size a file claimed. | **Fixed.** 16 megapixel limit. |
| PARSE-5, -7, -8 | Info | A board queue entry that never started; two numeric edge cases not reachable on the device. | **Fixed.** |

No memory error was found in any parser or renderer. `stb_image.h` (v2.30) is built PNG-only, and the published
vulnerabilities found for it are in decoders the tool does not link.

## iPhone app

| Id | Severity | Finding | Status |
|---|---|---|---|
| IOS-1 | High | The app joins any network named `PixelClip-…` with the default password and remembers it; it has no way to change the clip's password. | **Mitigated.** The app sets a random password by itself and joins with that. It still joins by name prefix, and uses the default until the first setup. |
| IOS-2 | Medium | Nothing checks that the device answering is the user's clip, over WiFi or Bluetooth. | **Open.** |
| IOS-3 | Medium | One shared item could crash the app at every launch. | **Fixed.** Items are claimed before parsing and never read twice. |
| IOS-4 | Medium | The HTML parser overflowed the stack on deep nesting and had quadratic paths. | **Fixed.** |
| IOS-5 | Medium | Shared links were fetched with no scheme allowlist, size cap, deadline or retry limit. | **Fixed.** A public name that resolves to a private address is not caught. |
| IOS-6, IOS-7 | Low | The EPUB size cap trusted the declared size; Markdown import had quadratic patterns. | **Fixed.** |
| IOS-8 | Low | The hotspot password is stored in UserDefaults, in plain text and in backups. | **Fixed.** It is in the Keychain; an old stored value is moved once. |
| IOS-9 | Low | Data at rest: no file protection class, temporary copies never deleted, raw page HTML kept. | **Mitigated.** Protection classes set, temporary copies removed, pages stripped before storing. Photo originals keep their metadata. |
| IOS-10 | Low | The clip client accepted unbounded responses and followed redirects. | **Fixed.** |
| IOS-11 | Low | The share extension had no size limits and decoded full images for thumbnails. | **Fixed** (build-verified; the share sheet was not driven in a simulator). |
| IOS-12 | Low | A failed send leaves the phone on the clip's network; "sent" state was not tied to a clip. | **Mitigated.** Sent state is per clip now. |
| IOS-13 | Low | The device build was Debug only. | **Fixed.** `./build.sh device-release`. |
| IOS-14 | Low | The font fetcher downloaded from an unpinned branch and used remote file names in paths. | **Fixed.** Pinned to a commit and verified by hash. |
| IOS-15, IOS-16 | Info | Clip-supplied strings were public in the system log; usage strings and the privacy manifest were out of step with the code. | **Fixed.** |
| IOS-17 | Info | Signing identifiers lived in several tracked files. | **Fixed.** One git-ignored `ios/Local.xcconfig`. |

## Repository and supply chain

No secret and no personal data were found in any commit, in text, binaries or metadata. Dependencies are locked
with content hashes, the iOS app has no third-party packages, and no script downloads and runs code.

| Id | Severity | Finding | Status |
|---|---|---|---|
| REL-5 | Medium | The README understated the security model. | **Fixed.** |
| REL-6 | Medium | The build guide did not say that USB plus a connected cell charges at about 1 A before the charge resistor is changed. | **Fixed.** |
| REL-7 | Low | Statements that read as tested, or disagreed between pages. | **Fixed.** |
| REL-8, -9, -17 | Low | Missing provenance and credit lines. | **Fixed.** [`CREDITS.md`](CREDITS.md). |
| REL-11 | Low | `stb_image.h` is one release behind upstream. | **Accepted.** PNG-only, with a size limit. |
| REL-12 | Low | ESP-IDF and the font source were loosely pinned. | **Mitigated.** Fonts pinned; ESP-IDF version recommended in the docs. |
| REL-13, -14 | Low | A builder could commit their signing identifiers, crash dumps or screenshots by accident. | **Fixed.** |
| REL-15 | Low | No vulnerability-reporting route. | **Fixed.** [`SECURITY.md`](../SECURITY.md). |
| REL-18 | Info | A leftover internal codename in build option names. | **Fixed.** |

## Built after the audit

Three things were added after the review, chosen because they close the worst outcomes without adding a step to
an ordinary send:

1. **A private hotspot password per clip.** At its first send over WiFi the app gives the clip a random
   24-character password, keeps it in the Keychain and shows a note once. The clip reports only whether its
   password is still the default (`ap_password_set`), never the password. If the clip reports the default again
   while the phone holds a password, the app stops and asks before using the default, so an imitation clip
   cannot talk the phone into it silently.
2. **A button press to accept a firmware update.** `POST /ota` is refused with `403 press_button` unless the
   clip's button was pressed while it showed "Update?". The permission lasts 120 s, covers one image and ends
   with the WiFi session.
3. **A password-reset gesture.** Five quick presses, then a long press while the clip shows "Reset WiFi
   password?", restore the default password and keep the content.

**How these were checked.** A clean firmware build, host tests of the permission and gesture logic, the
end-to-end script against the offline mock, and the app's unit, simulator and UI tests against its built-in
virtual clip. **None of it has run on a real clip or a real phone.** Not known until it does: how the prompts
look on the panel, whether the presses are comfortable, how iOS behaves when the saved network is installed
again with the new password (the code removes the saved network and adds it again, which should cost one extra
"Join" prompt), and the Keychain on a device.

**What these do not change.** A stranger who has not got the password can still do everything listed as Open
under Bluetooth. Someone who holds the clip can reset its password and allow an update; physical access was
already full access. A clip is as open as the default password until the app's first send over WiFi.

## What would close the remaining open items

1. **Pair once.** Bluetooth pairing with a six-digit code shown on the clip's screen, opened only by a button
   press, after which every Bluetooth request needs the bonded, encrypted link. Closes BLE-1, -3, -4, -5, -8, -9
   and, with private addresses, BLE-6. In the app: remember the bonded clip and talk only to it (BLE-7, IOS-2).
   The hotspot password could then be set over the paired link at pairing time, instead of at the first send.
2. **Signed firmware images**, so that a pressed button is not the only thing between a joined client and the
   firmware (WIFI-2).

Neither has been built. Pairing in particular has to be tried on a real clip with a real phone before it can be
relied on.
