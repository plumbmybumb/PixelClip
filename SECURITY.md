# Security policy

PixelClip is a hobby project: a small screen worn as a hair clip, its firmware, an iPhone app and a printable case.
It is maintained on a best-effort basis. There is no security team, no bug bounty and no promised
response time, but reports are welcome and will be read.

## Reporting a vulnerability

Please report security problems **privately**, through GitHub's private vulnerability reporting on this
repository: open the **Security** tab and choose **Report a vulnerability**. That keeps the report between you and
the maintainers until a fix or a documentation change is ready.

Please do not open a public issue for a vulnerability, and do not attach core dumps, serial logs or screenshots
taken from a clip you use. A core dump is an image of the clip's memory and can contain its WiFi password and any
text that was on it.

A useful report says which part is affected (firmware, app, host tools, protocol), the commit you looked at, what
an attacker needs (radio range, the hotspot password, physical access) and what they can then do.

## In scope

- The firmware in `firmware/` and the shared C library in `core/`.
- The iPhone app and its package in `ios/`.
- The host tools and scripts in `tools/` and `firmware/scripts/`.
- The radio protocol as described in [`docs/PROTOCOL.md`](docs/PROTOCOL.md), and any place where the
  documentation describes the clip as safer than it is.

## Out of scope

- Bugs in ESP-IDF, the ESP Component Registry components, iOS or the Waveshare board itself. Please report those
  upstream; tell us too if PixelClip uses them in a way that makes things worse.
- Attacks that need the clip in hand (see below).
- Limitations the [README](README.md) already documents, unless you can show they are worse than it says.
- The printed case. Its files carry no warranty (see [`case/README.md`](case/README.md#licence-and-no-warranty));
  battery and charging safety is covered in [`docs/BUILD.md`](docs/BUILD.md#safety).

## The security model in brief

The [README](README.md) describes what the clip does and does not protect, and is the place to read before you
wear one. The principles behind it:

- **Local radio links only.** The app and the clip talk to each other directly, over Bluetooth Low Energy and the
  clip's own WiFi hotspot. Anyone within radio range can reach those links; how much they can do there is set out
  in the README.
- **No cloud.** There is no PixelClip server, account or internet service; the clip needs no internet, and the app
  sends what the clip shows straight to the clip.
- **Physical access is full access.** Whoever holds the clip can reflash it over USB and get at what is stored on
  it. The project does not try to defend against someone who has the clip in hand.
- **Treat the clip as public.** Do not put anything on it that you would not be comfortable with a stranger
  nearby reading.
