# PixelClip case generator for Autodesk Fusion: tray, lid and the two captive side keys for a
# Waveshare ESP32-S3-AMOLED-1.91 (non-touch) board with a flat cell taped under it.
#
#   * Every fit number is a Fusion user parameter (Modify > Change Parameters): the board/cell channel, PCB
#     ledges, centring ribs, USB tunnel and stops, captive key pockets and slots, lid tabs, barbed latches and
#     their slots, charm holes and the tray/lid split.
#   * The outer shell is a loft through cross-sections of a barrel (vertical at the waist, rounding in to the
#     top and bottom flats) with curvature-continuous corners and oval noses; every surface that hangs over air
#     is within 45 deg of vertical for PETG (tray printed floor down, lid printed face down).
#   * The window is a superellipse oval (exponent WIN_N) ringed with bead bumps.
#
# Run it in a NEW Fusion design document (parametric mode), from Utilities > Scripts and Add-Ins or any Python
# console that has the Fusion API:
#     import adsk.core, adsk.fusion
#     des = adsk.fusion.Design.cast(adsk.core.Application.get().activeProduct)
#     exec(open("/path/to/pixelclip_case.py").read()); build(des)
# It creates the components Shell, Tray, Lid, Key A and Key B. After changing a parameter, run build(des)
# again: it regenerates the bodies from the parameters.
#
# Frame: the board frame in mm (Fusion works in cm internally). Origin at the display module's corner, X along
# the long edge (USB-C end at high X), Y across, Z the board normal (display side up). See docs/MECHANICAL.md.
import math
try:
    import adsk.core, adsk.fusion
except ImportError:                                  # the shell model also runs outside Fusion (checks)
    adsk = None

# ------------------------------------------------------------------ parameters (name, value, unit, note)
PARAMS = [
    # board + cell (measured)
    ("MOD_X1", 57.5, "mm", "display module end"), ("MOD_Y1", 24.5, "mm", "display module width"),
    ("DISPLAY_TOP", 4.20, "mm", "glass top"), ("STACK", 13.46, "mm", "glass to wrapped cell bottom"),
    ("BAT_T", 6.0, "mm", "cell thickness (model)"),
    ("USB_YC", 12.25, "mm", "USB-C centre Y"), ("USB_ZC", -3.07, "mm", "USB-C centre Z"),
    ("BUTTON_X", 54.10, "mm", "side switch X"), ("STEM_Y0", 0.65, "mm", "switch plunger tip, Y0 side"),
    ("STEM_Y1", 23.85, "mm", "switch plunger tip, Y1 side"),
    ("STEM_Z0", -4.05, "mm", "plunger bottom"), ("STEM_Z1", -2.05, "mm", "plunger top"),
    ("PCB_Z0", -1.40, "mm", "PCB underside (model)"), ("PCB_Y0", 0.49, "mm", "PCB long edge"),
    ("PCB_Y1", 24.01, "mm", "PCB long edge"),
    # channel, heights, split
    ("CL", 0.2, "mm", "board channel clearance"), ("RAIL_T", 0.5, "mm", "rails/hood over the display"),
    ("Z_PART", 3.2, "mm", "tray/lid split height"), ("FAR_CAP_X", -1.6, "mm", "lid's far-end cap starts"),
    ("FAR_STEP_Z", 1.6, "mm", "lid's far-end cap bottom"), ("LID_X1", 60.6, "mm", "lid's USB end"),
    ("BOARD_DROP", 0.48, "mm", "ledges + inner skins lowered"),
    # PCB ledges and centring ribs
    ("LEDGE_X0", 1.0, "mm", ""), ("LEDGE_X1", 50.0, "mm", ""), ("LEDGE_REACH", 1.3, "mm", "under the PCB edge"),
    ("RIB_X1", 4.0, "mm", "centring rib"), ("RIB_X2", 20.0, "mm", "centring rib"), ("RIB_X3", 36.0, "mm", "centring rib"),
    ("RIB_PROUD", 0.15, "mm", ""), ("RIB_R", 0.4, "mm", ""), ("RIB_Z0", 0.3, "mm", ""),
    # USB tunnel, cove, stops, charm holes
    ("USB_W", 13.0, "mm", "tunnel"), ("USB_H", 8.0, "mm", "tunnel"), ("USB_R", 1.5, "mm", "tunnel"),
    ("COVE_X", 64.4, "mm", "plug overmold cove"), ("COVE_W", 16.0, "mm", ""), ("COVE_H", 10.0, "mm", ""),
    ("COVE_R", 3.0, "mm", ""), ("COVE_FILLET", 0.0, "mm", "G2 round on the cove's side walls (0 = none: Fusion can't fit one)"),
    ("CHARM_X", 65.0, "mm", "jump-ring holes"), ("CHARM_D", 2.0, "mm", ""),
    ("STOP_Z0", 0.3, "mm", "module end stops"), ("STOP_Y", 5.0, "mm", ""),
    # captive keys
    ("CAP_CL", 0.15, "mm", "key clearance in slots/pocket"), ("CAP_FLANGE_R", 3.75, "mm", ""),
    ("CAP_FLANGE_T", 0.7, "mm", ""), ("CAP_TRAVEL", 0.5, "mm", "free travel inward"),
    ("CAP_PUSH_EXT", 0.2, "mm", "pusher lengthening"), ("CAP_MARK_W", 0.6, "mm", "notch"), ("CAP_MARK_D", 0.5, "mm", ""),
    ("CAP_KEY_FLANGE_TOP", 0.3, "mm", ""), ("CAP_KEY_CHAMFER", 0.45, "mm", "key face chamfer"),
    ("CAP_INNER_T", 0.45, "mm", "inner skin"), ("CAP_INNER_IN", 0.4, "mm", "inner skin into the channel"),
    ("CAP_INNER_TOP0", -0.3, "mm", "inner skin top before BOARD_DROP"),
    ("CAP_PUSH_W", 2.5, "mm", "pusher bar width"),
    ("CAP_PUSH_Z0", -5.8, "mm", "pusher bottom"),
    ("CAP_PUSH_Z1", -2.4, "mm", "pusher top: 1.0 under the PCB at its model height"),
    ("CAP_TAB_GAP", 0.45, "mm", "lid tab to the key's shaft (0.9 gave about 1.2 mm play; 0.1 printed as zero play)"),
    ("CAP_TAB_END", 0.6, "mm", "lid tab to the flange (keeps the keys from seizing)"),
    ("KEY_DROP", 0.0, "mm", "lower the keys (0.48 was tried: the board does not sit that low and the keys missed)"),
    ("CAP_KEY_PROUD", 0.5, "mm", "key face, extra beyond BTN_PROUD"),
    ("BTN_SHAFT_R", 3.0, "mm", "6 mm key face"), ("BTN_PROUD", 0.4, "mm", ""), ("BTN_PRE", 0.3, "mm", ""),
    ("KEY_SHRINK_A", 0.10, "mm", "key A (1 notch) slimmed all round"),
    ("KEY_SHRINK_B", 0.16, "mm", "key B (2 notches) slimmed all round (0.06 bound)"),
    # barbed latches and spring bars
    ("SNAP_T", 0.9, "mm", "latch thickness"), ("SNAP_H", 0.6, "mm", "barb depth"), ("SNAP_CL", 0.1, "mm", ""),
    ("SNAP_LEAD_DEG", 30.0, "", "barb lead-in angle"), ("SNAP_FLAT", 0.4, "mm", ""),
    ("SNAP_RET", 45.0, "", "barb catch angle (deg)"), ("SNAP_PRE", -0.05, "mm", "seat (negative = clearance)"),
    ("SNAP_SLOT_CL", 0.2, "mm", ""), ("SNAP_LEN", 7.0, "mm", "latch length"),
    ("FAR_LATCH_X", -1.45, "mm", ""), ("FAR_LATCH_Y0", 1.9, "mm", "|Y - YC| span"), ("FAR_LATCH_Y1", 7.0, "mm", ""),
    ("USB_LATCH_X", 60.6, "mm", ""), ("USB_LATCH_Y0", 0.0, "mm", ""), ("USB_LATCH_Y1", 4.0, "mm", ""),
    ("USB_LATCH_WEB", 0.6, "mm", ""),
    ("SIDE_LIP_X0", 7.5, "mm", ""), ("SIDE_LIP_X1", 14.3, "mm", ""), ("SIDE_LIP_GAP", 0.5, "mm", ""),
    ("MID_LIP_X0", 24.0, "mm", "one side only"), ("MID_LIP_X1", 34.0, "mm", ""),
    ("BAR_T", 0.7, "mm", "spring bar"), ("BAR_H", 0.45, "mm", ""), ("BAR_CL", 0.1, "mm", ""),
    ("BAR_RET", 45.0, "", "deg"), ("BAR_GAP", 0.6, "mm", ""), ("BAR_POST_W", 1.5, "mm", ""),
    ("BAR_POST_T", 1.2, "mm", ""), ("BAR_BARB_L", 3.0, "mm", ""), ("SIDE_BAR_X0", 42.8, "mm", ""),
    ("SIDE_BAR_X1", 57.6, "mm", ""), ("SIDE_BAR_GAP", 0.5, "mm", ""), ("SIDE_BAR_HT", 1.8, "mm", ""),
    ("SIDE_BAR_BARB_X", 47.0, "mm", ""),
    ("PRY_W", 3.0, "mm", "fingernail notch"), ("PRY_D", 0.9, "mm", ""), ("PRY_DROP", 1.0, "mm", ""),
    # window and beads
    ("WIN_N", 3.0, "", "superellipse exponent"), ("WIN_X0", 0.6, "mm", ""), ("WIN_X1", 48.32, "mm", ""),
    ("WIN_Y0", 1.2, "mm", ""), ("WIN_Y1", 23.3, "mm", ""), ("BEAD_R", 0.85, "mm", ""), ("BEAD_PITCH", 2.0, "mm", ""),
    # jewel on the far nose
    ("JEWEL_X", -6.0, "mm", ""), ("STONE_A", 2.2, "mm", "along"), ("STONE_B", 3.8, "mm", "across"),
    ("STONE_H", 0.8, "mm", "dome"), ("PEARL_R", 0.4, "mm", ""), ("PEARL_GAP", 0.75, "mm", "ring out from the stone"),
    ("PEARL_SINK", 0.4, "mm", "centre on the surface: the lower half is buried"),
    # outer shell (see shell model below)
    ("SH_L_FAR", 40.15, "mm", "half length, far end"), ("SH_L_USB", 40.6, "mm", "half length, USB end (cove horns)"),
    ("SH_W0", 16.35, "mm", "half width at the waist"),
    ("SH_P", 12.0, "", "plan exponent along (the ends are elliptic: W ~ sqrt near the tips)"),
    ("SH_NU", 4.0, "", "barrel above the waist"), ("SH_NL", 3.0, "", "barrel below the waist"),
    ("SH_SLOPE", 42.0, "", "steepest overhang at the flats, deg from vertical"),
    ("SH_DT", 29.2, "mm", "top flat half length"), ("SH_NOSE_M", 2.5, "", "nose superellipse"),
    ("SH_RHO_TOP", 0.5, "mm", "top edge blend over the lid"), ("SH_RHO_BOT", 0.35, "mm", "bottom edge blend"),
    ("SH_RHO_FAR", 8.0, "mm", "corner blends on the far nose (top and bottom)"),
    ("SH_RHO_USB", 3.5, "mm", "corner blends on the USB nose (the cove horns limit it)"),
    ("SH_BLEND_CAP", 0.6, "", "blends at most this fraction of the section's height near the tips"),
]


class K:
    """Constants (mm) read from the user parameters, plus derived values."""


def load_params(des=None, overrides=None, reset=False):
    """Read the user parameters (adding any that are missing; reset=True puts every one back to its default
    and drops parameters this script no longer uses); without a design, use the defaults."""
    if des is not None:
        ups = des.userParameters
        if reset:
            names = {n for n, _, _, _ in PARAMS}
            for p in [ups.item(i) for i in range(ups.count)]:
                if p.name not in names and not p.dependentParameters.count:
                    p.deleteMe()
        for name, val, unit, note in PARAMS:
            p = ups.itemByName(name)
            expr = ("%r %s" % (val, unit)).strip() if unit else repr(val)
            if p is None:
                ups.add(name, adsk.core.ValueInput.createByString(expr), unit, note)
            elif reset:
                p.expression = expr
                p.comment = note
        for name, val, unit, note in PARAMS:
            v = ups.itemByName(name).value
            setattr(K, name, v * 10.0 if unit == "mm" else v)
    else:
        for name, val, unit, note in PARAMS:
            setattr(K, name, val)
    for name, val in (overrides or {}).items():
        setattr(K, name, val)
    k = K
    k.YC = 12.25
    k.CHAN = (-k.CL, 58.0 + k.CL, -k.CL, k.MOD_Y1 + k.CL)
    k.XM = (k.CHAN[0] + k.CHAN[1]) / 2
    k.BAT_TOP = k.DISPLAY_TOP - k.STACK + k.BAT_T
    k.Z_FL = k.BAT_TOP - k.BAT_T - 0.15
    k.Z_BOT = k.Z_FL - 0.6
    k.Z_RAIL0 = k.DISPLAY_TOP + 0.05
    k.Z_TOP = k.Z_RAIL0 + k.RAIL_T
    k.Z_W = k.USB_ZC
    k.BTN_ZC = (k.STEM_Z0 + k.STEM_Z1) / 2 - k.KEY_DROP      # on the plunger (the board sits at its model height)
    k.CAP_INNER_TOP = k.CAP_INNER_TOP0 - k.BOARD_DROP
    k.LEDGE_ZT = k.PCB_Z0 - k.BOARD_DROP
    k.STOP_Z1 = k.Z_PART - 0.1
    k.RIB_Z1 = k.Z_PART - 0.1
    k.SNAP_LEAD = k.SNAP_H / math.tan(math.radians(k.SNAP_LEAD_DEG))
    k.FAR = k.SH_W0 + 3.0                      # |Y - YC| beyond the outer shell (open-ended cuts start here)
    _shell_derived()
    return k


# ------------------------------------------------------------------ outer shell model (pure Python)
# A section at X = x is the barrel |y - YC| <= W(x) * sigma(z) cut to Zbot(x) <= z <= Ztop(x), corners blended
# by a C2 polynomial smooth-max (curvature-continuous):
#   W(x)     plan at the waist, W0 * sqrt(1 - |dx/L|^p): straight-ish sides, elliptic ends
#   sigma(z) 1 at the waist (vertical wall), superellipse quadrants to the flats, SH_SLOPE from vertical there
#   Ztop(x)  Z_TOP over the board, then the oval nose sqrt(1 - s^m) (m > 2: leaves the flat G2; elliptic at
#            the tip, like the plan and the bottom arc, so the end closes evenly to a point)
#   Zbot(x)  Z_BOT, then a circular arc leaving the bed at (90 - SH_SLOPE) deg, vertical at the tip
def _shell_derived():
    k = K
    s = math.tan(math.radians(k.SH_SLOPE))
    def H_for(n, dz):
        lo, hi = dz, 5 * dz
        for _ in range(80):
            H = (lo + hi) / 2
            t = math.atan((s * H / k.SH_W0) ** (1 / (2 - 2 / n)))
            z = H * math.sin(t) ** (2 / n)
            lo, hi = (H, hi) if z < dz else (lo, H)
        return (lo + hi) / 2
    k.SH_HU = H_for(k.SH_NU, k.Z_TOP - k.Z_W)
    k.SH_HL = H_for(k.SH_NL, k.Z_W - k.Z_BOT)
    k.SH_R = (k.Z_W - k.Z_BOT) / math.cos(math.radians(k.SH_SLOPE))


def _L(x):
    return K.SH_L_USB if x > K.XM else K.SH_L_FAR


def _DB(x):
    return _L(x) - K.SH_R * (1 - math.sin(math.radians(K.SH_SLOPE)))


def plan_w(x):
    u = min(abs(x - K.XM) / _L(x), 1.0)
    return K.SH_W0 * math.sqrt(1 - u ** K.SH_P)


def sigma(z):
    if z >= K.Z_W:
        t, n = min((z - K.Z_W) / K.SH_HU, 1.0), K.SH_NU
    else:
        t, n = min((K.Z_W - z) / K.SH_HL, 1.0), K.SH_NL
    return (1 - t ** n) ** (1 / n)


OVERSHOOT = 0.0      # > 0 while lofting: sections run past the flats, which are then cut exactly


def ztop(x):
    a = abs(x - K.XM)
    if a <= K.SH_DT:
        return K.Z_TOP + OVERSHOOT
    s = min((a - K.SH_DT) / (_L(x) - K.SH_DT), 1.0)
    return K.Z_W + (K.Z_TOP - K.Z_W) * math.sqrt(1 - s ** K.SH_NOSE_M) + OVERSHOOT * (1 - s) ** 2


def zbot(x):
    a = abs(x - K.XM)
    L, DB = _L(x), _DB(x)
    if a <= DB:
        return K.Z_BOT - OVERSHOOT
    a = min(a, L)
    t = (a - DB) / (L - DB)
    return K.Z_W - math.sqrt(max(0.0, K.SH_R ** 2 - (a - (L - K.SH_R)) ** 2)) - OVERSHOOT * (1 - t) ** 2


def _ramp(x, k0, k1, a0):
    t = min(max((abs(x - K.XM) - a0) / 4.0, 0.0), 1.0)
    return k0 + (k1 - k0) * t * t * (3 - 2 * t)


def _smax(a, b, k):
    h = max(k - abs(a - b), 0.0) / k
    return max(a, b) + h ** 3 * k / 6


def section_f(x, y, z):
    w = plan_w(x)
    e = 1e-3
    dsig = (sigma(z + e) - sigma(z - e)) / (2 * e)
    f = (abs(y - K.YC) - w * sigma(z)) / math.sqrt(1 + (w * dsig) ** 2)
    zt, zb = ztop(x), zbot(x)
    size = min(zt - zb, 2 * w)                       # blends shrink with the section near the tips
    rn = K.SH_RHO_USB if x > K.XM else K.SH_RHO_FAR
    f = _smax(f, z - zt, min(_ramp(x, K.SH_RHO_TOP, rn, K.SH_DT + 1.4), K.SH_BLEND_CAP * size) + 1e-6)
    a0 = _DB(x) - 2.0
    return _smax(f, zb - z, min(_ramp(x, K.SH_RHO_BOT, rn, a0), K.SH_BLEND_CAP * size) + 1e-6)


def outer_hw(x, z):
    """|y - YC| of the outer surface at (x, z) (bisection on the section function)."""
    lo, hi = 0.0, K.SH_W0 + 8
    if section_f(x, K.YC, z) >= 0:
        return 0.0
    for _ in range(50):
        m = (lo + hi) / 2
        lo, hi = (m, hi) if section_f(x, K.YC + m, z) < 0 else (lo, m)
    return lo


def section_pts(x, n=120, dense=600):
    """n points (y, z) round the section at x, from the top centre toward +y, spaced by arc length with extra
    density where the curve turns (the corner blends)."""
    zt, zb = ztop(x), zbot(x)
    zc = (zt + zb) / 2
    raw = []
    for i in range(dense):
        th = 2 * math.pi * i / dense
        dy, dz = math.sin(th), math.cos(th)
        lo, hi = 0.0, K.SH_W0 + 30.0
        for _ in range(42):
            r = (lo + hi) / 2
            if section_f(x, K.YC + r * dy, zc + r * dz) < 0:
                lo = r
            else:
                hi = r
        r = (lo + hi) / 2
        raw.append((K.YC + r * dy, zc + r * dz))
    # weight = arc length * (1 + c * turning)
    m = len(raw)
    seg = []
    for i in range(m):
        a, b, c = raw[i - 1], raw[i], raw[(i + 1) % m]
        l = math.hypot(c[0] - b[0], c[1] - b[1])
        t1 = math.atan2(b[1] - a[1], b[0] - a[0]); t2 = math.atan2(c[1] - b[1], c[0] - b[0])
        turn = abs((t2 - t1 + math.pi) % (2 * math.pi) - math.pi)
        seg.append(l + 2.5 * turn)
    tot = sum(seg)
    out, acc, j = [], 0.0, 0
    for i in range(n):
        target = tot * i / n
        while acc + seg[j] < target:
            acc += seg[j]; j += 1
        f = (target - acc) / seg[j] if seg[j] > 0 else 0
        a, b = raw[j], raw[(j + 1) % m]
        out.append((a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1])))
    return out


def stations():
    Dt, XM = K.SH_DT, K.XM
    mid = [XM - Dt + 2 * Dt * i / 12 for i in range(13)]
    nose = lambda L, m: [Dt + (L - 0.04 - Dt) * math.sin(i / m * math.pi / 2) for i in range(1, m + 1)]
    xs = [XM - a for a in reversed(nose(K.SH_L_FAR, 15))] + mid + \
         [XM + a for a in nose(K.SH_L_USB, 15)]
    for xk in (XM - _DB(XM - 1), XM + _DB(XM + 1)):     # where the bottom starts to curve up
        xs = [x for x in xs if abs(x - xk) > 0.25] + [xk]
    return sorted(xs)


# ------------------------------------------------------------------ temporary-B-rep geometry (mm in, cm inside)
TBM = None


def _p(x, y, z):
    return adsk.core.Point3D.create(x / 10.0, y / 10.0, z / 10.0)


def _v(x, y, z):
    return adsk.core.Vector3D.create(x, y, z)


def box(x0, x1, y0, y1, z0, z1):
    x0, x1 = sorted((x0, x1)); y0, y1 = sorted((y0, y1)); z0, z1 = sorted((z0, z1))
    obb = adsk.core.OrientedBoundingBox3D.create(_p((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), _v(1, 0, 0),
                                                 _v(0, 1, 0), (x1 - x0) / 10, (y1 - y0) / 10, (z1 - z0) / 10)
    return TBM.createBox(obb)


def obox(c, ldir, wdir, l, w, h):
    obb = adsk.core.OrientedBoundingBox3D.create(_p(*c), _v(*ldir), _v(*wdir), l / 10, w / 10, h / 10)
    return TBM.createBox(obb)


def cyl(p0, p1, r, r1=None):
    return TBM.createCylinderOrCone(_p(*p0), r / 10, _p(*p1), (r if r1 is None else r1) / 10)


def sphere(c, r):
    return TBM.createSphere(_p(*c), r / 10)


def _bool(a, b, t):
    if not TBM.booleanOperation(a, b, t):
        raise RuntimeError("boolean failed")
    return a


def fuse(a, b):
    return _bool(a, b, adsk.fusion.BooleanTypes.UnionBooleanType)


def cut(a, b):
    return _bool(a, b, adsk.fusion.BooleanTypes.DifferenceBooleanType)


def common(a, b):
    return _bool(a, b, adsk.fusion.BooleanTypes.IntersectionBooleanType)


def fuse_all(bodies):
    out = None
    for b in bodies:
        out = b if out is None else fuse(out, b)
    return out


def copy(b):
    return TBM.copy(b)


def prism(pts, axis, a0, a1):
    """Convex polygon pts in the plane across axis ('x': (y, z), 'y': (x, z)) from a0 to a1, built as the
    intersection of half-space slabs (one per edge)."""
    a0, a1 = sorted((a0, a1))
    q = []
    for p in pts:                                    # drop repeated points
        if not q or math.hypot(p[0] - q[-1][0], p[1] - q[-1][1]) > 1e-9:
            q.append(p)
    if math.hypot(q[0][0] - q[-1][0], q[0][1] - q[-1][1]) < 1e-9:
        q.pop()
    cu = sum(p[0] for p in q) / len(q); cv = sum(p[1] for p in q) / len(q)
    BIG = 200.0
    out = None
    am = (a0 + a1) / 2
    for i in range(len(q)):
        (u0, v0), (u1, v1) = q[i], q[(i + 1) % len(q)]
        eu, ev = u1 - u0, v1 - v0
        L = math.hypot(eu, ev); eu, ev = eu / L, ev / L
        nu, nv = -ev, eu                             # a normal; make it point inward
        if (cu - u0) * nu + (cv - v0) * nv < 0:
            nu, nv = -nu, -nv
        mu, mv = (u0 + u1) / 2 + nu * BIG / 2, (v0 + v1) / 2 + nv * BIG / 2
        if axis == "x":
            c, ld, wd = (am, mu, mv), (0, eu, ev), (0, nu, nv)
        else:
            c, ld, wd = (mu, am, mv), (eu, 0, ev), (nu, 0, nv)
        slab = obox(c, ld, wd, BIG, BIG, a1 - a0)
        out = slab if out is None else common(out, slab)
    return out


def rrect_x(x0, yc, zc, w, h, r, depth):
    """Rounded rectangle (w along Y, h along Z, corner r) from x0 along +X by depth."""
    x1 = x0 + depth
    b = fuse(box(x0, x1, yc - w / 2 + r, yc + w / 2 - r, zc - h / 2, zc + h / 2),
             box(x0, x1, yc - w / 2, yc + w / 2, zc - h / 2 + r, zc + h / 2 - r))
    for sy in (-1, 1):
        for sz in (-1, 1):
            cy, cz = yc + sy * (w / 2 - r), zc + sz * (h / 2 - r)
            b = fuse(b, cyl((x0, cy, cz), (x1, cy, cz), r))
    return b


# ------------------------------------------------------------------ the inside: channel, keys, latches
def _cap_y(sgn):
    k = K
    y_in = k.CHAN[2] if sgn > 0 else k.CHAN[3]
    y_pi = y_in - sgn * (k.CAP_INNER_T - k.CAP_INNER_IN)
    y_po = y_pi - sgn * (k.CAP_FLANGE_T + k.CAP_TRAVEL)
    return y_po, y_pi, y_in + sgn * k.CAP_INNER_IN


def _u_slot(r, ya, yb, z_top):
    a, b = sorted((ya, yb))
    return fuse(cyl((K.BUTTON_X, a, K.BTN_ZC), (K.BUTTON_X, b, K.BTN_ZC), r),
                box(K.BUTTON_X - r, K.BUTTON_X + r, a, b, K.BTN_ZC, z_top))


def _push_slot(ya, yb, z_top=None):
    k = K
    a, b = sorted((ya, yb))
    w = k.CAP_PUSH_W / 2 + k.CAP_CL
    return box(k.BUTTON_X - w, k.BUTTON_X + w, a, b, k.CAP_PUSH_Z0 - k.CAP_CL, k.Z_PART + 1 if z_top is None else z_top)


def captive_cuts(sgn):
    k = K
    y_po, y_pi, _ = _cap_y(sgn)
    far = k.YC - sgn * k.FAR
    pocket = _u_slot(k.CAP_FLANGE_R + k.CAP_CL, y_po, y_pi + sgn * 0.01, k.Z_PART + 1)
    slot = _u_slot(k.BTN_SHAFT_R + k.CAP_CL, far, y_po + sgn * 0.01, k.Z_PART + 1)
    y_in = k.CHAN[2] if sgn > 0 else k.CHAN[3]
    return fuse(fuse(pocket, slot), _push_slot(y_po, y_in + sgn * 0.5))


def captive_inner_skin(sgn):
    k = K
    _, y_pi, y_is = _cap_y(sgn)
    w = k.CAP_FLANGE_R + k.CAP_CL + 0.6
    a, b = sorted((y_pi, y_is))
    skin = box(k.BUTTON_X - w, min(k.BUTTON_X + w, k.CHAN[1]), a, b, k.BTN_ZC - w, k.CAP_INNER_TOP)
    return cut(skin, _push_slot(a - 0.1, b + 0.1, k.CAP_INNER_TOP + 1))


def captive_tab(sgn):
    k = K
    y_po, _, _ = _cap_y(sgn)
    r = k.BTN_SHAFT_R + k.CAP_CL - 0.05
    far = k.YC - sgn * k.FAR
    a, b = sorted((far, y_po - sgn * k.CAP_TAB_END))
    tab = box(k.BUTTON_X - r, k.BUTTON_X + r, a, b, k.BTN_ZC + 1.5, k.Z_PART + 0.01)
    return cut(tab, cyl((k.BUTTON_X, a - 1, k.BTN_ZC), (k.BUTTON_X, b + 1, k.BTN_ZC), k.BTN_SHAFT_R + k.CAP_TAB_GAP))


def captive_key(sgn, shrink, marks):
    """The key at rest (flange against the pocket's outer face); flat face CAP_KEY_PROUD + BTN_PROUD - 0.1
    proud of the LOCAL outer surface at the key's axis."""
    k = K
    y_po, y_pi, _ = _cap_y(sgn)
    stem = k.STEM_Y0 if sgn > 0 else k.STEM_Y1
    y_tip = stem - sgn * (k.BTN_PRE - k.CAP_PUSH_EXT)
    y_end = k.YC - sgn * (outer_hw(k.BUTTON_X, k.BTN_ZC) + k.BTN_PROUD - 0.1 + k.CAP_KEY_PROUD)
    r, c = k.BTN_SHAFT_R - shrink, k.CAP_KEY_CHAMFER
    a, b = sorted((y_end + sgn * c, y_po))
    key = fuse(cyl((k.BUTTON_X, a, k.BTN_ZC), (k.BUTTON_X, b, k.BTN_ZC), r),
               cyl((k.BUTTON_X, y_end, k.BTN_ZC), (k.BUTTON_X, y_end + sgn * c, k.BTN_ZC), r - c, r))
    f0, f1 = sorted((y_po, y_po + sgn * k.CAP_FLANGE_T))
    rf = k.CAP_FLANGE_R - shrink
    flange = common(cyl((k.BUTTON_X, f0, k.BTN_ZC), (k.BUTTON_X, f1, k.BTN_ZC), rf),
                    box(-50, 120, -50, 80, k.Z_BOT - 1, k.CAP_KEY_FLANGE_TOP))
    key = fuse(key, flange)
    p0, p1 = sorted((y_po + sgn * (k.CAP_FLANGE_T - 0.01), y_tip))
    pw = k.CAP_PUSH_W / 2 - shrink
    key = fuse(key, box(k.BUTTON_X - pw, k.BUTTON_X + pw, p0, p1, k.CAP_PUSH_Z0 + shrink, k.CAP_PUSH_Z1))
    mw, md = k.CAP_MARK_W, k.CAP_MARK_D
    for i in range(marks):                          # notches in the flange rim, bottom left
        a = math.radians(225 + (i - (marks - 1) / 2) * 25)
        cx, cz = k.BUTTON_X + rf * math.cos(a), k.BTN_ZC + rf * math.sin(a)
        # a box (+-mw/2 in X, f0-0.1..f1+0.1 in Y, +-md in Z) rotated about +Y by (90 - a) deg
        rot = math.radians(-math.degrees(a) + 90)
        ux = (math.cos(rot), 0, -math.sin(rot))     # the box's X axis after rotating about +Y
        uz = (math.sin(rot), 0, math.cos(rot))
        key = cut(key, obox((cx, (f0 + f1) / 2, cz), ux, (0, 1, 0), mw, f1 - f0 + 0.2, 2 * md))
    return key


def centring_ribs():
    k = K
    out = []
    for y_wall, sg in ((k.CHAN[2], 1), (k.CHAN[3], -1)):
        yc = y_wall + sg * (k.RIB_PROUD - k.RIB_R)
        for x in (k.RIB_X1, k.RIB_X2, k.RIB_X3):
            r, proud, z0, z1 = k.RIB_R, k.RIB_PROUD, k.RIB_Z0, k.RIB_Z1
            yr = sorted((y_wall - sg * 0.3, y_wall + sg * proud))
            rib = common(cyl((x, yc, z0), (x, yc, z1), r), box(x - r, x + r, yr[0], yr[1], z0, z1))
            rib = cut(rib, box(x - r - 1, x + r + 1, *sorted((y_wall - sg * 1, y_wall + sg * 1)), z1 - proud, z1 + 1))
            lead = common(cyl((x, yc, z1 - proud), (x, yc, z1), r, r - proud), box(x - r, x + r, yr[0], yr[1], z1 - proud, z1))
            out.append(fuse(rib, lead))
    return fuse_all(out)


def snap(face_c, n, span, z_root, length, behind=1.0):
    """Barbed latch hanging from the lid and the slot + groove it clicks into."""
    k = K
    ax, sg = n
    other = "y" if ax == "x" else "x"
    zb = z_root - length
    cot = 1 / math.tan(math.radians(k.SNAP_RET))
    zr = zb + k.SNAP_LEAD + k.SNAP_FLAT
    d = lambda q: face_c + sg * q
    plate = [(d(-k.SNAP_T), zb), (d(0), zb), (d(0), z_root + 0.01), (d(-k.SNAP_T), z_root + 0.01)]
    barb = [(d(0), zb), (d(k.SNAP_H), zb + k.SNAP_LEAD), (d(k.SNAP_H), zr), (d(0), zr + k.SNAP_H * cot)]
    s0, s1 = span
    latch = fuse(prism(plate, other, s0, s1), prism(barb, other, s0 + 0.3, s1 - 0.3))
    slot = [(d(-k.SNAP_T - behind), zb - k.SNAP_SLOT_CL), (d(k.SNAP_CL), zb - k.SNAP_SLOT_CL),
            (d(k.SNAP_CL), z_root + 0.01), (d(-k.SNAP_T - behind), z_root + 0.01)]
    zg = zr - k.SNAP_PRE
    groove = [(d(k.SNAP_CL - 0.01), zb - k.SNAP_SLOT_CL), (d(k.SNAP_H + 0.1), zb - k.SNAP_SLOT_CL),
              (d(k.SNAP_H + 0.1), zg - 0.1 * cot), (d(k.SNAP_CL - 0.01), zg + (k.SNAP_H - k.SNAP_CL + 0.01) * cot)]
    cutb = fuse(prism(slot, other, s0 - k.SNAP_SLOT_CL, s1 + k.SNAP_SLOT_CL), prism(groove, other, s0, s1))
    return latch, cutb


def spring_bar(face_c, n, span, z_root, h, behind=0.5, barb_at=None):
    k = K
    ax, sg = n
    other = "y" if ax == "x" else "x"
    zt = z_root - k.BAR_GAP
    zb = zt - h
    cot = 1 / math.tan(math.radians(k.BAR_RET))
    d = lambda q: face_c + sg * q
    s0, s1 = span
    pw, pt = k.BAR_POST_W, k.BAR_POST_T
    post = [(d(-pt), zb), (d(0), zb), (d(0), z_root + 0.01), (d(-pt), z_root + 0.01)]
    bar = [(d(-k.BAR_T), zb), (d(0), zb), (d(0), zt), (d(-k.BAR_T), zt)]
    zr = zb + k.SNAP_LEAD + k.SNAP_FLAT
    barb = [(d(0), zb), (d(k.BAR_H), zb + k.SNAP_LEAD), (d(k.BAR_H), zr), (d(0), zr + k.BAR_H * cot)]
    m, bl = (s0 + s1) / 2 if barb_at is None else barb_at, k.BAR_BARB_L
    part = fuse_all([prism(post, other, s0, s0 + pw), prism(post, other, s1 - pw, s1), prism(bar, other, s0, s1),
                     prism(barb, other, m - bl / 2, m + bl / 2)])
    slot = [(d(-pt - behind), zb - k.SNAP_SLOT_CL), (d(k.BAR_CL), zb - k.SNAP_SLOT_CL),
            (d(k.BAR_CL), z_root + 0.01), (d(-pt - behind), z_root + 0.01)]
    zg = zr - k.SNAP_PRE
    groove = [(d(k.BAR_CL - 0.01), zb - k.SNAP_SLOT_CL), (d(k.BAR_H + 0.1), zb - k.SNAP_SLOT_CL),
              (d(k.BAR_H + 0.1), zg - 0.1 * cot), (d(k.BAR_CL - 0.01), zg + (k.BAR_H - k.BAR_CL + 0.01) * cot)]
    cutb = fuse(prism(slot, other, s0 - k.SNAP_SLOT_CL, s1 + k.SNAP_SLOT_CL),
                prism(groove, other, m - bl / 2 - 0.3, m + bl / 2 + 0.3))
    return part, cutb


def snaps():
    """All the lid's clips and their tray cuts: [(lid part, tray cut), ...]."""
    k = K
    out = []
    span = (k.SIDE_BAR_X0, k.SIDE_BAR_X1)
    out.append(spring_bar(k.CHAN[2] - k.SIDE_BAR_GAP - k.BAR_T, ("y", -1), span, k.Z_PART, k.SIDE_BAR_HT, barb_at=k.SIDE_BAR_BARB_X))
    out.append(spring_bar(k.CHAN[3] + k.SIDE_BAR_GAP + k.BAR_T, ("y", 1), span, k.Z_PART, k.SIDE_BAR_HT, barb_at=k.SIDE_BAR_BARB_X))
    out.append(snap(k.CHAN[3] + k.SIDE_LIP_GAP + k.SNAP_T, ("y", 1), (k.MID_LIP_X0, k.MID_LIP_X1), k.Z_PART, k.SNAP_LEN))
    for sg in (-1, 1):
        sp = sorted((k.YC + sg * k.FAR_LATCH_Y0, k.YC + sg * k.FAR_LATCH_Y1))
        out.append(snap(k.FAR_LATCH_X, ("x", -1), sp, k.FAR_STEP_Z, k.SNAP_LEN))
    u0, u1 = k.USB_LATCH_Y0, k.USB_LATCH_Y1
    for sp in ((u0, u1), (2 * k.YC - u1, 2 * k.YC - u0)):
        out.append(snap(k.USB_LATCH_X, ("x", 1), sp, k.Z_PART, k.SNAP_LEN, k.USB_LATCH_X - k.SNAP_T - k.CHAN[1] - k.USB_LATCH_WEB))
    out.append(snap(k.CHAN[2] - k.SIDE_LIP_GAP - k.SNAP_T, ("y", -1), (k.SIDE_LIP_X0, k.SIDE_LIP_X1), k.Z_PART, k.SNAP_LEN))
    out.append(snap(k.CHAN[3] + k.SIDE_LIP_GAP + k.SNAP_T, ("y", 1), (k.SIDE_LIP_X0, k.SIDE_LIP_X1), k.Z_PART, k.SNAP_LEN))
    return out


def pcb_ledges(snap_cuts):
    k = K
    out = []
    for y_wall, y_edge in ((k.CHAN[2], k.PCB_Y0 + k.LEDGE_REACH), (k.CHAN[3], k.PCB_Y1 - k.LEDGE_REACH)):
        w = abs(y_edge - y_wall) + 0.3
        sg = 1 if y_edge > y_wall else -1
        yw = y_wall - sg * 0.3
        zt = k.LEDGE_ZT
        out.append(prism([(yw, zt), (y_edge, zt), (y_edge, zt - 0.4), (yw, zt - 0.4 - w)], "x", k.LEDGE_X0, k.LEDGE_X1))
    led = fuse(out[0], out[1])
    for c in snap_cuts:                              # none over the latch slots
        bb = c.boundingBox
        if bb.minPoint.z * 10 < k.LEDGE_ZT:
            led = cut(led, box(bb.minPoint.x * 10 - 0.3, bb.maxPoint.x * 10 + 0.3, bb.minPoint.y * 10 - 3,
                               bb.maxPoint.y * 10 + 3, -50, 50))
    return led


def jewel():
    """Cabochon on the far nose: an ellipsoid dome on a short upright girdle, ringed with pearls; every
    pearl stands on a 45 deg cone so nothing hangs over air when the tray prints floor-down."""
    k = K
    jx = k.JEWEL_X
    z = ztop(jx)
    tilt = math.atan((ztop(jx + 0.05) - ztop(jx - 0.05)) / 0.1)     # seated square to the sloping nose
    stone = sphere((0, 0, 0), 1.0)
    m = adsk.core.Matrix3D.create()
    m.setCell(0, 0, k.STONE_A); m.setCell(1, 1, k.STONE_B); m.setCell(2, 2, k.STONE_H)
    TBM.transform(stone, m)                          # unit sphere (1 mm) -> ellipsoid
    stone = common(stone, box(-5, 5, -5, 5, 0, 5))   # upper half, on an upright girdle below
    girdle = TBM.createEllipticalCylinderOrCone(_p(0, 0, -3), k.STONE_B / 10, k.STONE_A / 10,
                                                _p(0, 0, 0), k.STONE_B / 10, _v(0, 1, 0))
    stone = fuse(stone, girdle)
    mr = adsk.core.Matrix3D.create()
    mr.setToRotation(-tilt, _v(0, 1, 0), adsk.core.Point3D.create(0, 0, 0))
    TBM.transform(stone, mr)
    mv = adsk.core.Matrix3D.create(); mv.translation = _v(jx / 10, k.YC / 10, z / 10)
    TBM.transform(stone, mv)
    out = [stone]
    ru, rv = k.STONE_A + k.PEARL_GAP, k.STONE_B + k.PEARL_GAP
    # pearls evenly spaced by arc length round the ellipse
    pts = [(ru * math.cos(2 * math.pi * i / 720), rv * math.sin(2 * math.pi * i / 720)) for i in range(720)]
    seg = [math.hypot(pts[(i + 1) % 720][0] - pts[i][0], pts[(i + 1) % 720][1] - pts[i][1]) for i in range(720)]
    tot = sum(seg)
    npearl = int(tot / (2 * k.PEARL_R + 0.15))
    acc, j = 0.0, 0
    pr = k.PEARL_R
    for i in range(npearl):
        t = tot * i / npearl
        while acc + seg[j] < t:
            acc += seg[j]; j += 1
        px, py = jx + pts[j][0] * math.cos(tilt), k.YC + pts[j][1]
        pz = ztop(px) - k.PEARL_SINK
        out.append(sphere((px, py, pz), pr))
        zc = pz - pr * math.sqrt(0.5)                # 45 deg cone tangent to the pearl below its equator
        rc = pr * math.sqrt(0.5)
        out.append(cyl((px, py, zc), (px, py, zc - 0.45), rc, rc + 0.45))
    return fuse_all(out)


# ------------------------------------------------------------------ Fusion document plumbing
def _comp(des, name):
    root = des.rootComponent
    for occ in root.occurrences:
        if occ.component.name == name:
            return occ.component
    occ = root.occurrences.addNewComponent(adsk.core.Matrix3D.create())
    occ.component.name = name
    return occ.component


def _clear(des, name):
    root = des.rootComponent
    for occ in list(root.occurrences):
        if occ.component.name == name:
            occ.deleteMe()


def _add_body(comp, tbody, name):
    bf = comp.features.baseFeatures.add()
    bf.name = name
    bf.startEdit()
    comp.bRepBodies.add(tbody, bf)
    bf.finishEdit()
    body = comp.bRepBodies.item(comp.bRepBodies.count - 1)
    body.name = name
    return body


def build_shell(des, n=120):
    """Loft the outer shell through the cross-sections (component 'Shell', body 'Shell'): the sections run
    OVERSHOOT past the flats and an intersect cuts the top and bottom exactly flat."""
    global OVERSHOOT
    _clear(des, "Shell")
    comp = _comp(des, "Shell")
    planes = comp.constructionPlanes
    li = comp.features.loftFeatures.createInput(adsk.fusion.FeatureOperations.NewBodyFeatureOperation)
    xs = stations()
    def plane_at(x):
        pi = planes.createInput()
        pi.setByOffset(comp.yZConstructionPlane, adsk.core.ValueInput.createByReal(x / 10))
        return planes.add(pi)
    OVERSHOOT = 0.06
    tip0 = comp.sketches.add(plane_at(K.XM - K.SH_L_FAR))
    sp0 = tip0.sketchPoints.add(tip0.modelToSketchSpace(_p(K.XM - K.SH_L_FAR, K.YC, K.Z_W)))
    li.loftSections.add(sp0)
    for x in xs:
        sk = comp.sketches.add(plane_at(x))
        sk.isComputeDeferred = True
        pts = adsk.core.ObjectCollection.create()
        for y, z in section_pts(x, n):
            pts.add(sk.modelToSketchSpace(_p(x, y, z)))
        spl = sk.sketchCurves.sketchFittedSplines.add(pts)
        spl.isClosed = True
        sk.isComputeDeferred = False
        li.loftSections.add(sk.profiles.item(0))
    tip1 = comp.sketches.add(plane_at(K.XM + K.SH_L_USB))
    sp1 = tip1.sketchPoints.add(tip1.modelToSketchSpace(_p(K.XM + K.SH_L_USB, K.YC, K.Z_W)))
    li.loftSections.add(sp1)
    OVERSHOOT = 0.0
    loft = comp.features.loftFeatures.add(li)
    loft.name = "Shell loft"
    body = loft.bodies.item(0)
    body.name = "Shell"
    pi = planes.createInput()
    pi.setByOffset(comp.xYConstructionPlane, adsk.core.ValueInput.createByReal(K.Z_BOT / 10))
    pl = planes.add(pi); pl.name = "Bottom flat"
    sk = comp.sketches.add(pl); sk.name = "Flats"
    sk.sketchCurves.sketchLines.addTwoPointRectangle(sk.modelToSketchSpace(_p(-30, -30, K.Z_BOT)),
                                                      sk.modelToSketchSpace(_p(90, 60, K.Z_BOT)))
    ei = comp.features.extrudeFeatures.createInput(sk.profiles.item(0), adsk.fusion.FeatureOperations.IntersectFeatureOperation)
    ei.setDistanceExtent(False, adsk.core.ValueInput.createByString("%r mm" % (K.Z_TOP - K.Z_BOT)))
    ei.participantBodies = [body]
    fl = comp.features.extrudeFeatures.add(ei)
    fl.name = "Flats"
    return comp.bRepBodies.itemByName("Shell")


def shell_body(des):
    return _comp(des, "Shell").bRepBodies.itemByName("Shell")


def build_tray(des):
    k = K
    env = copy(shell_body(des))
    keep = fuse_all([box(-50, 120, -50, 80, k.Z_BOT - 1, k.Z_PART), box(-50, k.FAR_CAP_X, -50, 80, k.Z_BOT - 1, k.Z_TOP + 5),
                     box(k.LID_X1, 120, -50, 80, k.Z_BOT - 1, k.Z_TOP + 5)])
    keep = cut(keep, box(k.FAR_CAP_X, k.CHAN[0], -50, 80, k.FAR_STEP_Z, k.Z_PART))
    t = common(env, keep)
    t = cut(t, box(k.CHAN[0], k.CHAN[1], k.CHAN[2], k.CHAN[3], k.Z_FL, k.Z_PART + 1))          # channel
    t = cut(t, rrect_x(k.CHAN[1] - 1, k.USB_YC, k.USB_ZC, k.USB_W, k.USB_H, k.USB_R, 20))       # USB tunnel
    t = cut(t, rrect_x(k.COVE_X, k.USB_YC, k.USB_ZC, k.COVE_W, k.COVE_H, k.COVE_R, 20))         # cove
    hx, r = k.CHARM_X, k.CHARM_D / 2
    kk = r / math.sqrt(2)
    for y0, y1 in ((k.YC - k.FAR - 3, k.YC), (k.YC, k.YC + k.FAR + 3)):                         # charm holes
        hole = fuse(cyl((hx, y0, k.USB_ZC), (hx, y1, k.USB_ZC), r),
                    prism([(hx - kk, k.USB_ZC + kk), (hx + kk, k.USB_ZC + kk), (hx, k.USB_ZC + r * math.sqrt(2))], "y", y0, y1))
        t = cut(t, hole)
    for y0, y1 in ((k.CHAN[2], k.STOP_Y), (k.MOD_Y1 - k.STOP_Y, k.CHAN[3])):                     # module end stops
        t = fuse(t, box(k.MOD_X1 + k.CL, k.CHAN[1] + 0.01, y0, y1, k.STOP_Z0, k.STOP_Z1))
    for sgn in (1, -1):
        t = cut(t, captive_cuts(sgn))
        t = fuse(t, captive_inner_skin(sgn))
    sn = snaps()
    t = fuse(t, pcb_ledges([c for _, c in sn]))
    t = fuse(t, centring_ribs())
    t = fuse(t, jewel())
    for _, c in sn:
        t = cut(t, c)
    t = cut(t, box(k.FAR_CAP_X - k.PRY_D, k.FAR_CAP_X + 0.01, k.YC - k.PRY_W / 2, k.YC + k.PRY_W / 2,
                   ztop(k.FAR_CAP_X) - k.PRY_DROP, k.Z_TOP + 1))                               # pry notch
    _clear(des, "Tray")
    comp = _comp(des, "Tray")
    body = _add_body(comp, t, "Tray")
    if K.COVE_FILLET > 0:
        cove_round(comp, body)
    return comp.bRepBodies.item(comp.bRepBodies.count - 1)


def cove_round(comp, body):
    """G2 round where the cove's side walls meet the outer shell (not its ceiling: that edge prints as a bridge
    and a round there would hang over air; not its floor, where the nose underneath is too thin for one)."""
    k = K
    edges = adsk.core.ObjectCollection.create()
    for e in body.edges:
        if e.faces.count != 2:
            continue
        f0, f1 = e.faces.item(0), e.faces.item(1)
        kinds = {f0.geometry.surfaceType, f1.geometry.surfaceType}
        if adsk.core.SurfaceTypes.NurbsSurfaceType not in kinds:
            continue
        p = e.pointOnEdge
        x, y, z = p.x * 10, p.y * 10, p.z * 10
        if x > k.COVE_X + 0.5 and abs(abs(y - k.USB_YC) - k.COVE_W / 2) < 0.01 and abs(z - k.USB_ZC) < k.COVE_H / 2 - k.COVE_R:
            edges.add(e)
    if edges.count == 0:
        return None
    for expr in ("COVE_FILLET", "COVE_FILLET * 0.75", "COVE_FILLET * 0.5"):    # largest that fits
        fi = comp.features.filletFeatures.createInput()
        fi.isG2 = True
        fi.addConstantRadiusEdgeSet(edges, adsk.core.ValueInput.createByString(expr), False)
        try:
            f = comp.features.filletFeatures.add(fi)
        except RuntimeError:
            continue
        f.name = "Cove round"
        return f
    return None


def build_lid(des):
    k = K
    env = copy(shell_body(des))
    f = common(env, fuse(box(k.FAR_CAP_X, k.LID_X1, -50, 80, k.Z_PART, k.Z_TOP + 5),
                         box(k.FAR_CAP_X, k.CHAN[0], -50, 80, k.FAR_STEP_Z, k.Z_TOP + 5)))
    f = cut(f, box(k.CHAN[0], k.CHAN[1], k.CHAN[2], k.CHAN[3], k.Z_PART - 1, k.Z_RAIL0))
    for sgn in (1, -1):
        f = fuse(f, common(captive_tab(sgn), copy(shell_body(des))))
    for part, _ in snaps():
        f = fuse(f, part)
    _clear(des, "Lid")
    comp = _comp(des, "Lid")
    body = _add_body(comp, f, "Lid")
    window_and_beads(comp, body)
    return body


def window_pts(n=360):
    k = K
    cx, cy = (k.WIN_X0 + k.WIN_X1) / 2, (k.WIN_Y0 + k.WIN_Y1) / 2
    a, b, e = (k.WIN_X1 - k.WIN_X0) / 2, (k.WIN_Y1 - k.WIN_Y0) / 2, k.WIN_N
    out = []
    for i in range(n):
        t = 2 * math.pi * i / n
        c, s = math.cos(t), math.sin(t)
        out.append((cx + a * math.copysign(abs(c) ** (2 / e), c), cy + b * math.copysign(abs(s) ** (2 / e), s)))
    return out


def bead_centres():
    k = K
    p = window_pts(7200)
    seg = [math.hypot(p[(i + 1) % len(p)][0] - p[i][0], p[(i + 1) % len(p)][1] - p[i][1]) for i in range(len(p))]
    tot = sum(seg)
    m = int(tot // k.BEAD_PITCH)
    out, acc, j = [], 0.0, 0
    for i in range(m):
        t = tot * i / m
        while acc + seg[j] < t:
            acc += seg[j]; j += 1
        f = (t - acc) / seg[j]
        a, b = p[j], p[(j + 1) % len(p)]
        out.append((a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1])))
    return out


def window_and_beads(comp, body):
    """Oval window (superellipse) cut through the lid's rails, then the beads round its edge (Fusion
    timeline features, so the window shape and the beads stay editable)."""
    k = K
    planes = comp.constructionPlanes
    pi = planes.createInput()
    pi.setByOffset(comp.xYConstructionPlane, adsk.core.ValueInput.createByReal((k.Z_RAIL0 - 1) / 10))
    pl = planes.add(pi); pl.name = "Window plane"
    sk = comp.sketches.add(pl); sk.name = "Window"
    pts = adsk.core.ObjectCollection.create()
    for x, y in window_pts(240):
        pts.add(sk.modelToSketchSpace(_p(x, y, k.Z_RAIL0 - 1)))
    spl = sk.sketchCurves.sketchFittedSplines.add(pts); spl.isClosed = True
    ext = comp.features.extrudeFeatures
    ei = ext.createInput(sk.profiles.item(0), adsk.fusion.FeatureOperations.CutFeatureOperation)
    ei.setDistanceExtent(False, adsk.core.ValueInput.createByString("%r mm" % (k.Z_TOP - k.Z_RAIL0 + 2)))
    ei.participantBodies = [body]
    w = ext.add(ei); w.name = "Oval window"
    pi = planes.createInput()
    pi.setByOffset(comp.xYConstructionPlane, adsk.core.ValueInput.createByReal(k.Z_RAIL0 / 10))
    pl2 = planes.add(pi); pl2.name = "Bead plane"
    sb = comp.sketches.add(pl2); sb.name = "Beads"
    sb.isComputeDeferred = True
    for x, y in bead_centres():
        sb.sketchCurves.sketchCircles.addByCenterRadius(sb.modelToSketchSpace(_p(x, y, k.Z_RAIL0)), k.BEAD_R / 10)
    sb.isComputeDeferred = False
    profs = adsk.core.ObjectCollection.create()
    for pr in sb.profiles:
        profs.add(pr)
    ei = ext.createInput(profs, adsk.fusion.FeatureOperations.JoinFeatureOperation)
    ei.setDistanceExtent(False, adsk.core.ValueInput.createByString("RAIL_T"))
    ei.participantBodies = [body]
    b = ext.add(ei); b.name = "Beads"


def build_keys(des):
    for name, shrink, marks in (("Key A", K.KEY_SHRINK_A, 1), ("Key B", K.KEY_SHRINK_B, 2)):
        _clear(des, name)
        _add_body(_comp(des, name), captive_key(1, shrink, marks), name)


def build(des, stages=("params", "shell", "tray", "lid", "keys")):
    global TBM
    TBM = adsk.fusion.TemporaryBRepManager.get()
    load_params(des)
    if "shell" in stages:
        build_shell(des)
    if "tray" in stages:
        build_tray(des)
    if "lid" in stages:
        build_lid(des)
    if "keys" in stages:
        build_keys(des)
