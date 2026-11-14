#!/usr/bin/env python3
"""Capture the clip's USB Serial/JTAG console for N seconds into a file (no TTY needed, unlike
`idf.py monitor`). Survives the port disappearing (re-enumeration, a host that suspends the port) and
reconnects WITHOUT resetting the chip.

usage: serial_capture.py PORT SECONDS OUTFILE [--reset] [--expect-boot] [--quiet]
  PORT      a device path, or a glob such as '/dev/cu.usbmodem*' (re-resolved at every reconnect: the
            bench light-sleep soak makes the port vanish and come back, scripts/sleep_soak.sh)
  --reset   reset the chip once after the first open (RTS pulse with DTR clear, as esptool's hard reset
            over USB) so the capture starts with a fresh boot. This is the ONLY way this script resets the
            chip; opening and reopening the port never does (see "Modem lines" below).
  --expect-boot  the chip was just reset by someone else (esptool after flashing): a boot banner right
            after the first open is expected, no reset warning for it
  --quiet   do not echo the console to stdout
Runs with the ESP-IDF Python (pyserial is part of the IDF environment).

Modem lines and the USB-Serial-JTAG (USJ) reset logic
-----------------------------------------------------
The ESP32-S3's USJ turns the CDC-ACM line state (SET_CONTROL_LINE_STATE: DTR, RTS) into a chip reset:
the chip is held in reset while RTS is asserted and DTR is not, and DTR at the release selects download
mode (GPIO0 strap). DTR=1/RTS=1, DTR=1/RTS=0 and DTR=0/RTS=0 do nothing. That is the logic Espressif's own
tools are written against (esptool reset.py USBJTAGSerialReset: "Calls inverted to go through (1,1) instead
of (0,0)"; esp-idf-monitor serial_reader.open_serial: "set the RTS first to avoid reset") and the TRM's
USB Serial/JTAG chapter; the TRM PDF itself could not be fetched while writing this, so the table is
from those two implementations plus the observation below.

What went wrong before (2026-10-15 capture: both the first open and the reopen after a re-enumeration
logged `rst:0x15 (USB_UART_CHIP_RESET)`): the script preset dtr=False, rts=False and called open().
macOS (and Linux) raise DTR and RTS when a tty is opened, so the line state became (DTR=1, RTS=1); then
pyserial's open() applies the preset DTR first and RTS second: (0,1) = RESET, then (0,0) = release.

The sequence used now (one SET_CONTROL_LINE_STATE per step, never through DTR=0/RTS=1):
  1. serial.Serial() unopened, dtr=True, rts=True preset (= what the OS does on open anyway), exclusive=True
  2. open(): OS -> (1,1); pyserial re-applies DTR=1, RTS=1 -> still (1,1)    [no reset]
  3. rts = False -> (1,0)                                                       [no reset]
  4. dtr = False -> (0,0)                                                       [idle]
Self-check: after every open the script watches 2 s for a ROM boot banner ("ESP-ROM:" / "rst:0x") and, if
one appears without --reset, writes `WARNING: port open caused a reset` into the capture.
"""
import glob
import sys
import time

try:
    import serial
except ImportError:
    print("pyserial missing: run this through the ESP-IDF python (source ~/esp/esp-idf/export.sh)", file=sys.stderr)
    sys.exit(2)

BANNER_WINDOW_S = 2.0
BANNERS = (b"ESP-ROM:", b"rst:0x")


def resolve(port):
    if any(c in port for c in "*?["):
        matches = sorted(glob.glob(port))
        if not matches:
            raise OSError("no port matches " + port)
        return matches[0]
    return port


def open_port(port):
    """Open without ever presenting DTR=0/RTS=1 to the USJ (see the module docstring)."""
    s = serial.Serial()
    s.port = resolve(port)
    s.baudrate = 115200
    s.timeout = 0.2
    s.exclusive = True       # a second opener (idf.py monitor, flash.sh) fails instead of toggling lines too
    s.rtscts = False
    s.dsrdtr = False
    s.dtr = True             # preset = the state the OS puts the lines in on open: pyserial's own
    s.rts = True             # updates inside open() then change nothing
    s.open()
    try:
        s.rts = False        # (1,1) -> (1,0): RTS first, so DTR=0/RTS=1 (reset) never occurs
        s.dtr = False        # (1,0) -> (0,0): idle
    except (serial.SerialException, OSError):
        pass                 # not a modem-control tty (a pty in a test): nothing to sequence
    return s


def hard_reset(s):
    """The explicit reset (--reset): RTS asserted with DTR clear holds the chip in reset."""
    s.dtr = False
    s.rts = True             # (0,1): chip in reset
    time.sleep(0.2)
    s.rts = False            # (0,0): released, DTR clear = normal boot


def main(argv):
    if len(argv) < 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    port, seconds, out = argv[1], float(argv[2]), argv[3]
    reset = "--reset" in argv[4:]
    quiet = "--quiet" in argv[4:]
    expect_boot = "--expect-boot" in argv[4:]
    deadline = time.monotonic() + seconds
    t0 = time.monotonic()
    ser = None
    buf = b""
    watch_until = 0.0        # boot-banner self-check window after an open
    expect_reset = False     # the open was followed by our own --reset
    opens = 0

    def note(f, text):
        stamp = f"[{time.monotonic() - t0:6.2f}] ".encode()
        f.write(stamp + b"[serial_capture: " + text.encode() + b"]\n")
        f.flush()
        if not quiet or text.startswith("WARNING"):
            print(f"[serial_capture: {text}]", file=sys.stderr if text.startswith("WARNING") else sys.stdout)

    with open(out, "wb") as f:
        while time.monotonic() < deadline:
            if ser is None:
                try:
                    ser = open_port(port)
                except (serial.SerialException, OSError, ValueError):
                    time.sleep(0.1)
                    continue
                opens += 1
                expect_reset = expect_boot and opens == 1
                if reset:
                    reset = False
                    expect_reset = True
                    hard_reset(ser)
                if opens > 1:
                    note(f, "port reopened (DTR/RTS sequence without reset)")
                watch_until = time.monotonic() + BANNER_WINDOW_S
            try:
                chunk = ser.read(4096)
            except (serial.SerialException, OSError):
                try:
                    ser.close()
                except Exception:
                    pass
                ser = None
                note(f, "port lost (re-enumeration / host suspended the port / light sleep), reconnecting")
                continue
            if watch_until and time.monotonic() > watch_until:
                watch_until = 0.0
            if not chunk:
                continue
            if watch_until and not expect_reset and any(b in buf + chunk for b in BANNERS):
                watch_until = 0.0
                note(f, "WARNING: port open caused a reset (boot banner within %.0f s of opening)" % BANNER_WINDOW_S)
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                stamp = f"[{time.monotonic() - t0:6.2f}] ".encode()
                f.write(stamp + line.rstrip(b"\r") + b"\n")
                if not quiet:
                    sys.stdout.buffer.write(line.rstrip(b"\r") + b"\n")
                    sys.stdout.flush()
                f.flush()
        if buf:
            f.write(buf + b"\n")
    if ser is not None:
        ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
