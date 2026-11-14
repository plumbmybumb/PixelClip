#!/usr/bin/env python3
"""Fetch the bundled marquee fonts (SIL Open Font License only) from the google/fonts repository.

    python3 -I tools/fonts/fetch_fonts.py            # download again and verify against FONTS.json
    python3 -I tools/fonts/fetch_fonts.py --check    # re-verify what is already on disk (no network)
    python3 -I tools/fonts/fetch_fonts.py --update   # accept new or changed files (after moving PIN)

Downloads come from one commit of google/fonts (PIN below), never from a moving branch. For each family
in FAMILIES it reads `ofl/<dir>/METADATA.pb`, refuses anything whose licence is not "OFL", downloads the
static TTFs (Regular, plus Bold / Italic / Bold Italic when the family has them; the variable TTFs for
variable-only families) and the family's OFL.txt, checks the TrueType/OpenType magic bytes and that
OFL.txt is the SIL Open Font License 1.1, then parses each font's `name`, `OS/2` and `fvar` tables for
the family name, PostScript names, weights and italics.

What is downloaded must be what the repository already vouches for: every font's SHA-256 is compared
with the one recorded in FONTS.json and every OFL.txt with the copy on disk, and a file that differs
(or that FONTS.json has never seen) stops the run. `--update` is how a maintainer accepts a change on
purpose: move PIN to a commit you have looked at, run with `--update`, and review the diff of FONTS.json.
File names come from the remote METADATA.pb, so they are checked before they are used in a path: a
plain `.ttf` / `.otf` name, no directories.

Writes (paths relative to the repo root):
  ios/Sources/Resources/Fonts/<Family>/*.ttf + OFL.txt     the files the app bundles (folder reference)
  ios/Sources/Resources/Fonts/FONTS.json                   manifest: families, faces, files, sizes
  ios/PixelClipKit/Sources/PixelClipKit/Text/BundledFonts.swift      the same manifest as Swift (catalogue faces)
  ios/project.yml                                          the UIAppFonts list between the fonts markers

Python 3 standard library only. Cross-checks PostScript names with `fc-scan` when it is installed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
FONTS_DIR = os.path.join(REPO, "ios", "Sources", "Resources", "Fonts")
SWIFT_OUT = os.path.join(REPO, "ios", "PixelClipKit", "Sources", "PixelClipKit", "Text", "BundledFonts.swift")
PROJECT_YML = os.path.join(REPO, "ios", "project.yml")
# The google/fonts commit every download comes from (2026-11-14). The 25 bundled fonts and their OFL.txt
# are byte-identical to this commit's. To take newer fonts: change it to a commit you have reviewed, then
# run with --update.
PIN = "cc39c4c2c304bc368c9b7c311ea2bcc6013299fe"
RAW = "https://raw.githubusercontent.com/google/fonts/" + PIN + "/ofl/{dir}/{file}"
BUDGET_BYTES = 6 * 1024 * 1024

# (google/fonts directory under ofl/, FontMood case in PixelClipKit, files to leave out)
FAMILIES: list[tuple[str, str, tuple[str, ...]]] = [
    # Retro & Pixel
    ("pressstart2p", "pixel", ()),
    ("silkscreen", "pixel", ()),
    ("vt323", "pixel", ()),
    ("dotgothic16", "pixel", ()),
    ("pixelifysans", "pixel", ()),
    # Tiny5's italic is a second ~same-size variable file; the upright is enough for a pixel face.
    ("tiny5", "pixel", ("Tiny5-Italic[BLED,JITT,ROND,wdth,wght].ttf",)),
    # Display
    ("bungee", "display", ()),
    ("monoton", "display", ()),
    ("bebasneue", "display", ()),
    ("rubikmonoone", "display", ()),
    ("righteous", "display", ()),
    ("orbitron", "display", ()),
    ("audiowide", "display", ()),
    ("unicaone", "display", ()),
    ("abrilfatface", "display", ()),
    ("majormonodisplay", "display", ()),
    # Script
    ("pacifico", "script", ()),
    ("lobster", "script", ()),
    ("dancingscript", "script", ()),
    ("caveat", "script", ()),
    # Not OFL (Apache 2.0, lives under apache/ in google/fonts): listed so the skip is explicit.
    ("permanentmarker", "script", ()),
    # Editorial
    ("playfairdisplay", "editorial", ()),
    ("spacegrotesk", "editorial", ()),
    ("fredoka", "editorial", ()),
]

STATIC_WANTED = {(400, "normal"), (700, "normal"), (400, "italic"), (700, "italic")}
FONT_MAGIC = (b"\x00\x01\x00\x00", b"OTTO", b"true")
CSS_TO_CT = {100: -0.8, 200: -0.6, 300: -0.4, 400: 0.0, 500: 0.23, 600: 0.3, 700: 0.4, 800: 0.56, 900: 0.62}


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def fetch(url: str) -> bytes | None:
    req = urllib.request.Request(url, headers={"User-Agent": "pixelclip-fetch-fonts/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


# MARK: METADATA.pb (text protobuf; only the fields we need)

def parse_metadata(text: str) -> dict:
    meta = {"name": None, "license": None, "designer": None, "fonts": []}
    current = None
    depth = 0
    for raw in text.splitlines():
        line = raw.strip()
        if line.endswith("{"):
            depth += 1
            if depth == 1 and line.startswith("fonts"):
                current = {}
            continue
        if line == "}":
            if depth == 1 and current is not None:
                meta["fonts"].append(current)
                current = None
            depth -= 1
            continue
        m = re.match(r'(\w+):\s*"?(.*?)"?$', line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        if depth == 0 and key in ("name", "license", "designer"):
            meta[key] = value
        elif depth == 1 and current is not None:
            current[key] = int(value) if key == "weight" else value
    return meta


# MARK: sfnt parsing (name, OS/2, head, fvar)

class Font:
    def __init__(self, data: bytes):
        if data[:4] not in FONT_MAGIC:
            raise ValueError("not a TrueType/OpenType file (magic %r)" % data[:4])
        self.data = data
        num = struct.unpack(">H", data[4:6])[0]
        self.tables = {}
        for i in range(num):
            tag, _, off, length = struct.unpack(">4sIII", data[12 + 16 * i: 28 + 16 * i])
            self.tables[tag.decode("latin-1")] = (off, length)
        self.names = self._names()

    def table(self, tag: str) -> bytes | None:
        if tag not in self.tables:
            return None
        off, length = self.tables[tag]
        return self.data[off: off + length]

    def _names(self) -> dict[int, str]:
        t = self.table("name")
        out: dict[int, str] = {}
        if t is None:
            return out
        _, count, storage = struct.unpack(">HHH", t[:6])
        fallback: dict[int, str] = {}
        for i in range(count):
            pid, eid, lid, nid, length, off = struct.unpack(">HHHHHH", t[6 + 12 * i: 18 + 12 * i])
            raw = t[storage + off: storage + off + length]
            if pid == 3 and eid in (0, 1, 10):
                s = raw.decode("utf-16-be", "replace")
                if lid == 0x409 or nid not in out:
                    out[nid] = s
            elif pid == 1 and eid == 0:
                fallback.setdefault(nid, raw.decode("mac_roman", "replace"))
        for k, v in fallback.items():
            out.setdefault(k, v)
        return out

    def name(self, nid: int) -> str | None:
        return self.names.get(nid)

    @property
    def family(self) -> str:
        return self.name(16) or self.name(1) or ""

    @property
    def subfamily(self) -> str:
        return self.name(17) or self.name(2) or "Regular"

    @property
    def weight_class(self) -> int:
        t = self.table("OS/2")
        return struct.unpack(">H", t[4:6])[0] if t else 400

    @property
    def italic(self) -> bool:
        t = self.table("OS/2")
        if t and struct.unpack(">H", t[62:64])[0] & 1:
            return True
        h = self.table("head")
        return bool(h and struct.unpack(">H", h[44:46])[0] & 2)

    def fvar(self) -> tuple[list[dict], list[dict]] | None:
        t = self.table("fvar")
        if t is None:
            return None
        _, _, axes_off, _, axis_count, axis_size, inst_count, inst_size = struct.unpack(">HHHHHHHH", t[:16])
        axes = []
        for i in range(axis_count):
            p = axes_off + i * axis_size
            tag, mn, df, mx, _, nid = struct.unpack(">4siiiHH", t[p: p + 20])
            axes.append({"tag": tag.decode("latin-1"), "min": mn / 65536, "default": df / 65536, "max": mx / 65536})
        instances = []
        base = axes_off + axis_count * axis_size
        for i in range(inst_count):
            p = base + i * inst_size
            sub_nid, _ = struct.unpack(">HH", t[p: p + 4])
            coords = [struct.unpack(">i", t[p + 4 + 4 * a: p + 8 + 4 * a])[0] / 65536 for a in range(axis_count)]
            ps_nid = None
            if inst_size >= 4 + 4 * axis_count + 2:
                ps_nid = struct.unpack(">H", t[p + 4 + 4 * axis_count: p + 6 + 4 * axis_count])[0]
            instances.append({"name": self.name(sub_nid) or "", "coords": dict(zip([a["tag"] for a in axes], coords)),
                              "ps": self.name(ps_nid) if ps_nid not in (None, 0xFFFF) else None})
        return axes, instances


def ct_weight(css: float) -> float:
    """CSS weight (100…900) → CoreText weight trait (-1…1), interpolated between Apple's steps."""
    keys = sorted(CSS_TO_CT)
    css = max(keys[0], min(keys[-1], css))
    for lo, hi in zip(keys, keys[1:]):
        if lo <= css <= hi:
            f = (css - lo) / (hi - lo)
            return round(CSS_TO_CT[lo] + f * (CSS_TO_CT[hi] - CSS_TO_CT[lo]), 3)
    return 0.0


def faces_for(font: Font, file_name: str) -> list[dict]:
    fv = font.fvar()
    italic = font.italic
    if fv is None:
        style = font.subfamily
        return [{"postScriptName": font.name(6), "style": style, "weight": font.weight_class,
                 "ctWeight": ct_weight(font.weight_class), "italic": italic, "file": file_name}]
    axes, instances = fv
    defaults = {a["tag"]: a["default"] for a in axes}
    out, seen = [], set()
    for inst in instances:
        # Only the plain weight ladder: every other axis (width, roundness, bleed…) at its default.
        if any(abs(v - defaults[t]) > 1e-3 for t, v in inst["coords"].items() if t != "wght"):
            continue
        wght = inst["coords"].get("wght", font.weight_class)
        # CoreText's naming (what UIFont(name:) takes): the default instance is the font's own
        # PostScript name (name ID 6); others use the instance's postScriptNameID when the fvar has
        # one, else "<name ID 6>_<subfamily without spaces>" (e.g. "SpaceGrotesk-Light_Bold").
        is_default = all(abs(v - defaults[t]) <= 1e-3 for t, v in inst["coords"].items())
        if is_default:
            ps = font.name(6)
        else:
            ps = inst["ps"] or "%s_%s" % (font.name(6), re.sub(r"[^A-Za-z0-9]", "", inst["name"]))
        if ps in seen:
            continue
        seen.add(ps)
        out.append({"postScriptName": ps, "style": inst["name"], "weight": int(round(wght)),
                    "ctWeight": ct_weight(wght), "italic": italic, "file": file_name})
    return out


def verify_ofl(text: str) -> bool:
    t = text.upper()
    return "SIL OPEN FONT LICENSE" in t and "VERSION 1.1" in t


def copyright_line(ofl: str) -> str:
    for line in ofl.splitlines():
        if line.strip().lower().startswith("copyright"):
            return line.strip()
    return ""


def local_name(remote: str) -> str:
    """'SpaceGrotesk[wght].ttf' → 'SpaceGrotesk-VF.ttf' (no brackets in bundle paths)."""
    return re.sub(r"\[[^\]]*\]", "-VF", remote).replace("--VF", "-VF")


SAFE_REMOTE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_\-]*(\[[A-Za-z0-9,]+\])?\.(ttf|otf)")
SAFE_LOCAL_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_\-]*\.(ttf|otf)")


def safe_remote_name(name: object) -> str:
    """A font file name from the remote METADATA.pb, or SystemExit. It ends up in a URL and (through
    local_name) in a path on disk, so it must be a bare file name: letters, digits, '-', '_', an optional
    '[axes]' group and a font extension. No '/', no '\\', no '..', no leading dot."""
    if not isinstance(name, str) or name != os.path.basename(name) or not SAFE_REMOTE_NAME.fullmatch(name):
        raise SystemExit("refusing font file name %r from METADATA.pb" % (name,))
    if not SAFE_LOCAL_NAME.fullmatch(local_name(name)):
        raise SystemExit("refusing font file name %r (it would be stored as %r)" % (name, local_name(name)))
    return name


def inside(folder: str, name: str) -> str:
    """os.path.join(folder, name), having checked that it stays inside folder."""
    path = os.path.realpath(os.path.join(folder, name))
    if os.path.dirname(path) != os.path.realpath(folder):
        raise SystemExit("refusing to write %r outside %s" % (name, folder))
    return path


def recorded() -> tuple[dict[str, str], bool]:
    """({'Family/File.ttf': sha256} from the FONTS.json on disk, whether there is one)."""
    path = os.path.join(FONTS_DIR, "FONTS.json")
    if not os.path.exists(path):
        return {}, False
    with open(path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    return {f["file"]: f["sha256"] for fam in manifest["families"] for f in fam["files"]}, True


CT_SWIFT = r"""
import CoreText
import Foundation
for path in CommandLine.arguments.dropFirst() {
    let descs = (CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor]) ?? []
    for d in descs {
        let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String ?? ""
        let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String ?? ""
        print("\(path)\t\(fam)\t\(ps)")
    }
}
"""


def coretext_names(paths: list[str]) -> dict[str, set[tuple[str, str]]] | None:
    """{path: {(family, postscript)}} as CoreText sees each file (macOS with a Swift toolchain), else None."""
    swift = shutil.which("swift") or (shutil.which("xcrun") and "xcrun")
    if not swift or sys.platform != "darwin":
        return None
    work = tempfile.mkdtemp(prefix="pixelclip-ct-")
    try:
        src = os.path.join(work, "ct.swift")
        with open(src, "w") as fh:
            fh.write(CT_SWIFT)
        cmd = ([swift] if swift != "xcrun" else ["xcrun", "swift"]) + [src] + paths
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=300, cwd=work)
        if out.returncode != 0:
            log("note: CoreText check failed to run: %s" % out.stderr.strip()[:200])
            return None
        result: dict[str, set[tuple[str, str]]] = {p: set() for p in paths}
        for line in out.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) == 3 and parts[0] in result:
                result[parts[0]].add((parts[1], parts[2]))
        return result
    finally:
        shutil.rmtree(work, ignore_errors=True)


def fc_scan_names(path: str) -> set[str] | None:
    exe = shutil.which("fc-scan")
    if not exe:
        return None
    out = subprocess.run([exe, "--format", "%{postscriptname}\n", path], capture_output=True, text=True, timeout=60)
    return {l.strip() for l in out.stdout.splitlines() if l.strip()}


def cross_check(families: list[dict]) -> None:
    """The manifest's family + PostScript names must be exactly what CoreText (i.e. UIFont) reports.
    Without CoreText, fc-scan is consulted (its names for unnamed variable instances differ, so only notes)."""
    paths = [os.path.join(FONTS_DIR, f["file"]) for fam in families for f in fam["files"]]
    ct = coretext_names(paths)
    for fam in families:
        want = {x["postScriptName"] for x in fam["faces"]}
        fam_paths = [os.path.join(FONTS_DIR, f["file"]) for f in fam["files"]]
        if ct is not None:
            seen = set().union(*(ct[p] for p in fam_paths))
            families_seen = {f for f, _ in seen}
            if families_seen != {fam["family"]}:
                raise SystemExit("%s: CoreText reports family %s" % (fam["family"], sorted(families_seen)))
            missing = want - {ps for _, ps in seen}
            if missing:
                raise SystemExit("%s: CoreText does not know %s (it has %s)" % (fam["family"], sorted(missing), sorted(seen)))
            continue
        names = set()
        for p in fam_paths:
            names |= fc_scan_names(p) or set()
        if names and want - names:
            log("note: fc-scan names %s differently (%s); CoreText was not available to confirm"
                % (fam["family"], sorted(want - names)))
    log("PostScript names checked with %s" % ("CoreText" if ct is not None else "fc-scan" if shutil.which("fc-scan") else "nothing (name tables only)"))


# MARK: main

def build(check_only: bool, update: bool = False) -> int:
    if not re.fullmatch(r"[0-9a-f]{40}", PIN):
        raise SystemExit("PIN must be a full 40-character commit id, not a branch or a tag")
    families, skipped = [], []
    known, have_manifest = recorded()
    if not check_only and not update and not have_manifest:
        raise SystemExit("no FONTS.json to verify downloads against; run with --update to start one")
    staging = tempfile.mkdtemp(prefix="pixelclip-fonts-")
    try:
        for d, mood, excluded in FAMILIES:
            if check_only:
                entry = check_existing(d, mood)
                if entry:
                    families.append(entry)
                continue
            meta_bytes = fetch(RAW.format(dir=d, file="METADATA.pb"))
            if meta_bytes is None:
                skipped.append({"directory": d, "reason": "not under ofl/ in google/fonts (licence is not OFL)"})
                log("skip %s: not under ofl/" % d)
                continue
            meta = parse_metadata(meta_bytes.decode("utf-8"))
            if meta["license"] != "OFL":
                skipped.append({"directory": d, "reason": "METADATA licence is %s, not OFL" % meta["license"]})
                log("skip %s: licence %s" % (d, meta["license"]))
                continue
            ofl_bytes = fetch(RAW.format(dir=d, file="OFL.txt"))
            ofl = ofl_bytes.decode("utf-8", "replace") if ofl_bytes else ""
            if not verify_ofl(ofl):
                skipped.append({"directory": d, "reason": "OFL.txt missing or not the SIL OFL 1.1"})
                log("skip %s: OFL.txt not verified" % d)
                continue
            remote = [f for f in meta["fonts"] if f.get("filename") not in excluded]
            for f in remote:
                safe_remote_name(f.get("filename"))
            if not remote:
                raise SystemExit("%s: METADATA.pb lists no font files" % d)
            variable = [f for f in remote if "[" in f["filename"]]
            if variable:
                chosen = list(dict.fromkeys(f["filename"] for f in variable))
            else:
                chosen = [f["filename"] for f in remote if (f.get("weight"), f.get("style")) in STATIC_WANTED]
                if not chosen:  # no Regular at all (single odd weight): take the first
                    chosen = [remote[0]["filename"]]
            fonts = []
            for fname in chosen:
                data = fetch(RAW.format(dir=d, file=urllib.request.quote(fname)))
                if data is None:
                    raise SystemExit("missing %s/%s" % (d, fname))
                fonts.append((fname, data, Font(data)))  # Font() checks the magic bytes
            family = fonts[0][2].family
            folder = re.sub(r"[^A-Za-z0-9]", "", family)
            if not folder:
                raise SystemExit("%s: no usable family name in %s" % (d, fonts[0][0]))
            # Nothing is accepted that the repository doesn't already vouch for, unless --update says so.
            if not update:
                on_disk = os.path.join(FONTS_DIR, folder, "OFL.txt")
                if not os.path.exists(on_disk) or open(on_disk, "rb").read() != ofl_bytes:
                    raise SystemExit("%s: the downloaded OFL.txt is not the one on disk (--update accepts it)" % d)
                for fname, data, _ in fonts:
                    key = "%s/%s" % (folder, local_name(fname))
                    got = hashlib.sha256(data).hexdigest()
                    if known.get(key) != got:
                        raise SystemExit("%s: SHA-256 %s is not the %s recorded in FONTS.json (--update accepts it)"
                                         % (key, got, known.get(key) or "one (the file is new)"))
            stage = inside(staging, folder)
            os.makedirs(stage, exist_ok=True)
            with open(inside(stage, "OFL.txt"), "wb") as fh:
                fh.write(ofl_bytes)  # byte-for-byte as published
            files, faces = [], []
            for fname, data, font in fonts:
                if font.family != family:
                    log("warning: %s reports family %r, expected %r" % (fname, font.family, family))
                ln = local_name(fname)
                with open(inside(stage, ln), "wb") as fh:
                    fh.write(data)
                files.append({"file": "%s/%s" % (folder, ln), "source": RAW.format(dir=d, file=fname),
                              "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                              "variable": font.fvar() is not None})
                faces.extend(faces_for(font, "%s/%s" % (folder, ln)))
            families.append({"family": family, "folder": folder, "directory": d, "mood": mood,
                             "designer": meta.get("designer") or "", "license": "SIL Open Font License 1.1",
                             "licenseFile": "%s/OFL.txt" % folder, "copyright": copyright_line(ofl),
                             "files": files, "faces": sort_faces(faces)})
            log("ok   %-20s %7d bytes  %s" % (family, sum(f["bytes"] for f in files), ", ".join(f["postScriptName"] for f in faces)))
        total = sum(f["bytes"] for fam in families for f in fam["files"]) + \
            sum(os.path.getsize(os.path.join(staging if not check_only else FONTS_DIR, fam["licenseFile"])) for fam in families)
        if total > BUDGET_BYTES:
            raise SystemExit("bundle is %.2f MB, over the %.1f MB budget" % (total / 1e6, BUDGET_BYTES / 1e6))
        if not check_only:
            if os.path.isdir(FONTS_DIR):
                shutil.rmtree(FONTS_DIR)
            shutil.copytree(staging, FONTS_DIR)
        cross_check(families)
        manifest = {"generatedBy": "tools/fonts/fetch_fonts.py",
                    "source": "https://github.com/google/fonts (ofl/)",
                    "commit": PIN,
                    "license": "SIL Open Font License 1.1 (OFL.txt in each family folder)",
                    "totalBytes": total, "families": families, "skipped": skipped}
        if check_only:
            old = json.load(open(os.path.join(FONTS_DIR, "FONTS.json")))
            manifest["skipped"] = old.get("skipped", [])
            manifest["commit"] = old.get("commit", PIN)  # where the files on disk came from
        with open(os.path.join(FONTS_DIR, "FONTS.json"), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        write_swift(manifest)
        write_project_yml(manifest)
        log("total %d bytes (%.2f MB) in %d families; skipped: %s"
            % (total, total / 1e6, len(families), ", ".join(s["directory"] for s in manifest["skipped"]) or "none"))
        return 0
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def read_text(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def sort_faces(faces: list[dict]) -> list[dict]:
    return sorted(faces, key=lambda f: (f["weight"], f["italic"], f["postScriptName"]))


def check_existing(d: str, mood: str) -> dict | None:
    """--check: rebuild a family's manifest entry from the files on disk (still verifying them)."""
    path = os.path.join(FONTS_DIR, "FONTS.json")
    old = {f["directory"]: f for f in json.load(open(path))["families"]} if os.path.exists(path) else {}
    if d not in old:
        return None
    fam = old[d]
    if not verify_ofl(read_text(os.path.join(FONTS_DIR, fam["licenseFile"]))):
        raise SystemExit("%s: OFL.txt is not the SIL OFL 1.1" % fam["family"])
    faces = []
    for f in fam["files"]:
        data = open(os.path.join(FONTS_DIR, f["file"]), "rb").read()
        if hashlib.sha256(data).hexdigest() != f["sha256"]:
            raise SystemExit("%s changed on disk" % f["file"])
        faces.extend(faces_for(Font(data), f["file"]))
    fam = dict(fam, mood=mood, faces=sort_faces(faces))
    return fam


def swift_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_swift(manifest: dict) -> None:
    lines = [
        "// GENERATED by tools/fonts/fetch_fonts.py from ios/Sources/Resources/Fonts/FONTS.json. Do not edit;",
        "// re-run the script (BundledFontsTests checks this file against the manifest).",
        "",
        "/// Open-licensed (SIL OFL 1.1) families the app bundles under `Fonts/` and registers via `UIAppFonts`.",
        "public enum BundledFonts {",
        "    public static let families: [BundledFontFamily] = [",
    ]
    for fam in manifest["families"]:
        faces = ",\n".join(
            "            FontFace(postScriptName: %s, styleName: %s, weight: %s, italic: %s)"
            % (swift_str(f["postScriptName"]), swift_str(f["style"]), repr(float(f["ctWeight"])), "true" if f["italic"] else "false")
            for f in fam["faces"])
        files = ", ".join(swift_str(f["file"]) for f in fam["files"])
        lines.append("        BundledFontFamily(family: %s, mood: .%s, folder: %s, copyright: %s, files: [%s], faces: [\n%s,\n        ])," % (
            swift_str(fam["family"]), fam["mood"], swift_str(fam["folder"]), swift_str(fam["copyright"]), files, faces))
    lines += ["    ]", "", "    /// Bytes of fonts + licences in the bundle.",
              "    public static let totalBytes = %d" % manifest["totalBytes"], "}", ""]
    with open(SWIFT_OUT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def write_project_yml(manifest: dict) -> None:
    text = read_text(PROJECT_YML)
    begin, end = "# BEGIN UIAppFonts (tools/fonts/fetch_fonts.py)", "# END UIAppFonts"
    m = re.search(r"^( *)" + re.escape(begin) + r".*?^ *" + re.escape(end) + r"\n", text, re.M | re.S)
    if not m:
        log("note: no UIAppFonts markers in project.yml; add them under info.properties")
        return
    ind = m.group(1)
    body = [ind + begin, ind + "UIAppFonts:"]
    body += ["%s  - Fonts/%s" % (ind, f["file"]) for fam in manifest["families"] for f in fam["files"]]
    body.append(ind + end)
    text = text[: m.start()] + "\n".join(body) + "\n" + text[m.end():]
    with open(PROJECT_YML, "w", encoding="utf-8") as fh:
        fh.write(text)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="re-verify files already on disk, no network")
    ap.add_argument("--update", action="store_true",
                    help="accept downloads that differ from FONTS.json or are new to it (after moving PIN)")
    args = ap.parse_args()
    if args.check and args.update:
        ap.error("--check reads nothing from the network, so there is nothing to --update")
    sys.exit(build(args.check, args.update))
