#!/usr/bin/env python3
"""Text-level STEP (ISO 10303-21, AP203/AP214) mechanical extractor.

Usage:  python3 -I docs/mechanical/step_extract.py <file.stp> [--solids] [--circles] [--pouch=31x20]
                [--flip-x] [--flip-n] [--json out.json] [--svg out.svg]

Pure stdlib, no OpenCASCADE.  What it does:
  1. Parses every entity into (TYPE, args) tuples (handles multi-line and
     complex "(A(..)B(..))" entities).
  2. Rebuilds the assembly tree: PRODUCT -> PRODUCT_DEFINITION ->
     SHAPE_DEFINITION_REPRESENTATION (geometry) and NEXT_ASSEMBLY_USAGE_OCCURRENCE
     + CONTEXT_DEPENDENT_SHAPE_REPRESENTATION + ITEM_DEFINED_TRANSFORMATION
     (placement).  Transform of a child into its parent is  B * A^-1  where
     A/B are the two AXIS2_PLACEMENT_3D of the ITEM_DEFINED_TRANSFORMATION.
  3. Per part occurrence: bounding box in ROOT coordinates from the
     VERTEX_POINTs of its MANIFOLD_SOLID_BREPs (exact for planar/prismatic
     parts; arcs bulging past their end vertices are not included, so round
     parts can be under-estimated by < radius*(1-cos)).
  4. Circles whose axis is +-Z (root frame): cluster by (x,y,r) into holes.
Output is plain text tables; all lengths in the file's unit (mm assumed,
checked against LENGTH_UNIT/SI_UNIT prefix).
"""
import re, sys, math, json, collections

TOK = re.compile(r"'(?:[^']|'')*'|#\d+|[-+]?(?:\d+\.?\d*|\.\d+)(?:[Ee][-+]?\d+)?|\.[A-Z_0-9]+\.|[A-Z_][A-Z_0-9]*|[(),$*]")

def parse_args(toks, i):
    """toks[i] is just after '('; returns (list, next_i) consuming ')'."""
    out = []
    while True:
        t = toks[i]
        if t == ')':
            return out, i + 1
        if t == ',':
            i += 1
            continue
        if t == '(':
            sub, i = parse_args(toks, i + 1)
            out.append(sub)
            continue
        if re.match(r'[A-Z_][A-Z_0-9]*$', t) and toks[i + 1] == '(':
            sub, i = parse_args(toks, i + 2)
            out.append((t, sub))
            continue
        if t.startswith('#'):
            out.append(int(t[1:]))
        elif t.startswith("'"):
            out.append(t[1:-1])
        elif t in '$*':
            out.append(None)
        elif t[0] == '.' and t[-1] == '.':
            out.append(t)
        else:
            try:
                out.append(float(t))
            except ValueError:
                out.append(t)
        i += 1

def load(path):
    ents = {}
    buf = []
    in_data = False
    with open(path, errors='replace') as f:
        for line in f:
            if not in_data:
                if line.startswith('DATA;'):
                    in_data = True
                continue
            if line.startswith('ENDSEC'):
                break
            buf.append(line.rstrip('\n'))
            if line.rstrip().endswith(';'):
                s = ''.join(buf); buf = []
                m = re.match(r'\s*#(\d+)\s*=\s*(.*);\s*$', s, re.S)
                if not m:
                    continue
                toks = TOK.findall(m.group(2))
                if toks[0] == '(':          # complex entity
                    args, _ = parse_args(toks, 1)
                    ents[int(m.group(1))] = args   # list of (TYPE,args)
                else:
                    args, _ = parse_args(toks, 2)
                    ents[int(m.group(1))] = [(toks[0], args)]
    return ents

def typ(ents, i): return ents[i][0][0]
def args(ents, i, t=None):
    for tt, a in ents[i]:
        if t is None or tt == t:
            return a
    return None

# ---- linear algebra (4x4 as tuple of rows) --------------------------------
def ident(): return [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
def mul(a, b): return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]
def apply(m, p): return tuple(sum(m[i][k]*p[k] for k in range(3)) + m[i][3] for i in range(3))
def applyd(m, d): return tuple(sum(m[i][k]*d[k] for k in range(3)) for i in range(3))
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def norm(a):
    n = math.sqrt(sum(x*x for x in a)) or 1.0
    return tuple(x/n for x in a)
def inv_rigid(m):
    r = [[m[j][i] for j in range(3)] for i in range(3)]
    t = [-sum(r[i][k]*m[k][3] for k in range(3)) for i in range(3)]
    return [r[0]+[t[0]], r[1]+[t[1]], r[2]+[t[2]], [0,0,0,1]]

class Model:
    def __init__(self, path):
        self.e = load(path)
        e = self.e
        self.unit = 'mm'
        for i, v in e.items():
            for t, a in v:
                if t == 'SI_UNIT' and a and a[0] == '.MILLI.': self.unit = 'mm'
                if t == 'CONVERSION_BASED_UNIT': self.unit = str(a[0])
        self.pt = {i: tuple(args(e, i)[1]) for i in e if typ(e, i) == 'CARTESIAN_POINT'}
        self.dirs = {i: tuple(args(e, i)[1]) for i in e if typ(e, i) == 'DIRECTION'}
        # product tables
        self.prod_name = {}
        for i in e:
            if typ(e, i) == 'PRODUCT': self.prod_name[i] = args(e, i)[0]
        self.form2prod = {i: args(e, i)[2] for i in e if typ(e, i).startswith('PRODUCT_DEFINITION_FORMATION')}
        self.pd2name = {i: self.prod_name[self.form2prod[args(e, i)[2]]]
                        for i in e if typ(e, i) == 'PRODUCT_DEFINITION'}
        self.pds2pd = {i: args(e, i)[2] for i in e if typ(e, i) == 'PRODUCT_DEFINITION_SHAPE'}
        self.pd2rep = {}
        self.srr = collections.defaultdict(list)   # placeholder rep -> related geometry reps (identity)
        for i in e:
            if typ(e, i) == 'SHAPE_REPRESENTATION_RELATIONSHIP':
                a = args(e, i); self.srr[a[2]].append(a[3])
        self.colour = self._colours()
        for i in e:
            if typ(e, i) == 'SHAPE_DEFINITION_REPRESENTATION':
                a = args(e, i)
                pd = self.pds2pd.get(a[0])
                if pd in self.pd2name: self.pd2rep[pd] = a[1]
        # assembly
        self.nauo = {}   # id -> (parent_pd, child_pd)
        for i in e:
            if typ(e, i) == 'NEXT_ASSEMBLY_USAGE_OCCURRENCE':
                a = args(e, i); self.nauo[i] = (a[3], a[4])
        self.children = collections.defaultdict(list)  # parent_pd -> [(child_pd, M child->parent)]
        for i in e:
            if typ(e, i) != 'CONTEXT_DEPENDENT_SHAPE_REPRESENTATION': continue
            rel, pds = args(e, i)
            nauo = args(e, pds)[2]
            parent, child = self.nauo[nauo]
            itd = args(e, rel, 'REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION')[0]
            a_id, b_id = args(e, itd)[2], args(e, itd)[3]
            M = mul(self.place(b_id), inv_rigid(self.place(a_id)))
            self.children[parent].append((child, M))

    def place(self, i):
        a = args(self.e, i, 'AXIS2_PLACEMENT_3D')
        o = self.pt[a[1]]
        z = norm(self.dirs[a[2]]) if a[2] else (0, 0, 1)
        x = norm(self.dirs[a[3]]) if a[3] else (1, 0, 0)
        y = cross(z, x)
        return [[x[0], y[0], z[0], o[0]], [x[1], y[1], z[1], o[1]], [x[2], y[2], z[2], o[2]], [0, 0, 0, 1]]

    def reach(self, start, want):
        """DFS from entity ids; return ids whose TYPE is in `want`."""
        seen, out, st = set(), [], list(start)
        while st:
            i = st.pop()
            if i in seen or i not in self.e: continue
            seen.add(i)
            t = typ(self.e, i)
            if t in want: out.append(i)
            if t in ('STYLED_ITEM', 'OVER_RIDING_STYLED_ITEM', 'PRESENTATION_STYLE_ASSIGNMENT'): continue
            for _, a in self.e[i]:
                self._refs(a, st)
        return out
    def _refs(self, a, st):
        for x in a:
            if isinstance(x, int): st.append(x)
            elif isinstance(x, list): self._refs(x, st)
            elif isinstance(x, tuple): self._refs(x[1], st)

    def _colours(self):
        e = self.e; col = {}
        for i in e:
            if typ(e, i) in ('STYLED_ITEM', 'OVER_RIDING_STYLED_ITEM'):
                a = args(e, i)
                rgb = self.reach([x for x in a[1] if isinstance(x, int)], {'COLOUR_RGB'})
                if rgb and isinstance(a[2], int):
                    c = args(e, rgb[0])
                    col[a[2]] = tuple(round(x, 2) for x in c[1:4])
        return col

    def solid_info(self, sid):
        """(vertices, dominant colour) for one solid in its part frame."""
        v = [self.pt[args(self.e, x)[1]] for x in self.reach([sid], {'VERTEX_POINT'})]
        cnt = collections.Counter()
        if sid in self.colour: cnt[self.colour[sid]] += 100
        for f in self.reach([sid], {'ADVANCED_FACE'}):
            if f in self.colour: cnt[self.colour[f]] += 1
        return v, (cnt.most_common(1)[0][0] if cnt else None)

    def part_geometry(self, pd):
        """(vertices, circles) of a product's own solids, in the part frame."""
        if pd in getattr(self, '_gc', {}): return self._gc[pd]
        self._gc = getattr(self, '_gc', {})
        rep = self.pd2rep.get(pd)
        verts, circles = [], []
        if rep is not None:
            items = list(args(self.e, rep)[1])
            for r2 in self.srr.get(rep, []):          # geometry hanging off a placeholder rep
                items += args(self.e, r2)[1]
            solids = [i for i in items if isinstance(i, int) and typ(self.e, i) in ('MANIFOLD_SOLID_BREP', 'SHELL_BASED_SURFACE_MODEL', 'BREP_WITH_VOIDS', 'MANIFOLD_SURFACE_SHAPE_REPRESENTATION', 'SHELL_BASED_SURFACE_MODEL', 'OPEN_SHELL', 'CLOSED_SHELL')]
            self._solids = getattr(self, '_solids', {})
            self._solids[pd] = solids
            for v in self.reach(solids, {'VERTEX_POINT'}):
                verts.append(self.pt[args(self.e, v)[1]])
            for c in self.reach(solids, {'CIRCLE'}):
                a = args(self.e, c, 'CIRCLE')
                pl = self.place(a[1]); r = a[2]
                circles.append((apply(pl, (0, 0, 0)), applyd(pl, (0, 0, 1)), r))
        self._gc[pd] = (verts, circles)
        return self._gc[pd]

    def occurrences(self, root_pd):
        """Yield (path, pd, M part->root) for every leaf-or-node occurrence."""
        out = []
        def rec(pd, M, path):
            out.append((path, pd, M))
            for child, cm in self.children.get(pd, []):
                rec(child, mul(M, cm), path + [self.pd2name[child]])
        rec(root_pd, ident(), [self.pd2name[root_pd]])
        return out

def bbox(pts):
    if not pts: return None
    return tuple(min(p[k] for p in pts) for k in range(3)), tuple(max(p[k] for p in pts) for k in range(3))

def top_pd(m):
    children = {c for v in m.children.values() for c, _ in v}
    tops = [pd for pd in m.pd2name if pd not in children]
    tops.sort(key=lambda pd: -len(m.children.get(pd, [])))
    return tops[0]

class BoardFrame:
    """Map root coordinates -> board coordinates (X' along the long edge, Y' along the
    short edge, Z' = board normal pointing to the display side), origin at the
    bottom-left corner of the largest flat solid seen in top view (X' right, Y' up).
    Auto-detection: the solid with the largest footprint defines the board plane."""
    def __init__(self, solids, flip_x=False, flip_n=False):
        # solids: list of (name, bbox); pick biggest footprint
        best = None
        for n, (lo, hi) in solids:
            d = [hi[k]-lo[k] for k in range(3)]
            fp = sorted(d)[1]*sorted(d)[2]
            if best is None or fp > best[0]: best = (fp, n, lo, hi, d)
        _, self.ref_name, lo, hi, d = best
        order = sorted(range(3), key=lambda k: d[k])
        self.n, self.w, self.l = order[0], order[1], order[2]
        cen = [(lo[k]+hi[k])/2 for k in range(3)]
        # display side = side of the reference solid relative to the centre of all other solids
        others = [((a[k]+b[k])/2) for nm, (a, b) in solids if nm != self.ref_name for k in [self.n]]
        mean_o = sum(others)/len(others) if others else cen[self.n]
        self.sn = 1 if cen[self.n] >= mean_o else -1
        if flip_n: self.sn = -self.sn
        self.sl = -1 if flip_x else 1
        # right-handed: X' x Y' = Z'  ->  choose sign of short axis
        ex = [0,0,0]; ex[self.l] = self.sl
        ez = [0,0,0]; ez[self.n] = self.sn
        ey = cross(ez, ex)
        self.ex, self.ey, self.ez = tuple(ex), ey, tuple(ez)
        corner = [lo[k] if (self.ex[k]+self.ey[k]+self.ez[k]) >= 0 and k != self.n else hi[k] for k in range(3)]
        # origin: min corner along each primed axis of the reference solid
        pts = [(x, y, z) for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2])]
        self.org = (min(self.dot(self.ex, p) for p in pts), min(self.dot(self.ey, p) for p in pts), min(self.dot(self.ez, p) for p in pts))
    @staticmethod
    def dot(a, b): return sum(a[k]*b[k] for k in range(3))
    def pt(self, p): return (self.dot(self.ex, p)-self.org[0], self.dot(self.ey, p)-self.org[1], self.dot(self.ez, p)-self.org[2])
    def vec(self, v): return (self.dot(self.ex, v), self.dot(self.ey, v), self.dot(self.ez, v))
    def describe(self):
        ax = 'XYZ'
        return (f"board frame from '{self.ref_name}': X' = {'+-'[self.sl<0]}{ax[self.l]}root (long), "
                f"Y' = {'+-'[self.ey[self.w]<0]}{ax[self.w]}root (short), Z' = {'+-'[self.sn<0]}{ax[self.n]}root (up, display side); "
                f"origin at root offset {tuple(round(x,3) for x in self.org)} in primed projections")


LABELS = [('TYPE-C', 'USB-C'), ('SWITCHER', 'BTN'), ('HP1_25', 'BAT conn'), ('TF-CARD', 'TF slot'),
          ('CORE01', 'IC'), ('CORE', 'IC'), ('C3', 'C3'), ('PIN_HEADER', '2.54 header (back)')]

def write_svg(path, parts, bf, boards, mount, pouch, active):
    """Top view (display side up): X' to the right, Y' up.  1 mm = 17 px."""
    K, M = 17.0, 30
    allb = [bbox([bf.pt(q) for q in p[3]]) for p in parts]
    W = max(b[1][0] for b in allb); H = max(b[1][1] for b in allb)
    def X(x): return M + x*K
    S = W*K + 2*M                      # square canvas (also keeps qlmanage thumbnails uncropped)
    Y0 = (S - (H*K + 70)) / 2
    def Y(y): return Y0 + (H - y)*K
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{S*0.75:.0f}" height="{S*0.75:.0f}" viewBox="0 0 {S:.0f} {S:.0f}" font-family="Helvetica,Arial,sans-serif" font-size="13">',
         '<rect width="100%" height="100%" fill="#ffffff"/>']
    def rect(b, **kw):
        a = ' '.join(f'{k.replace("_","-")}="{v}"' for k, v in kw.items())
        o.append(f'<rect x="{X(b[0][0]):.1f}" y="{Y(b[1][1]):.1f}" width="{(b[1][0]-b[0][0])*K:.1f}" height="{(b[1][1]-b[0][1])*K:.1f}" {a}/>')
    def text(x, y, t, anchor='middle', size=12, fill='#222'):
        o.append(f'<text x="{X(x):.1f}" y="{Y(y):.1f}" text-anchor="{anchor}" font-size="{size}" fill="{fill}">{t}</text>')
    ref = next(b for p, b in zip(parts, allb) if p[0][-1] == bf.ref_name)
    rect(ref, rx=1.0*K, fill='#e8edf2', stroke='#456', stroke_width=1.5)
    for p, b in zip(parts, allb):
        if p[0][-1] in boards: rect(b, rx=0.5*K, fill='none', stroke='#789', stroke_width=1.2, stroke_dasharray='6 4')
    if active: rect(active, fill='#111', stroke='#000', fill_opacity=0.85)
    if active: text((active[0][0]+active[1][0])/2, active[1][1]-1.2, f'active area {active[1][0]-active[0][0]:.1f} x {active[1][1]-active[0][1]:.1f}', size=15, fill='#fff')
    if pouch: rect(pouch, fill='#2a7', fill_opacity=0.35, stroke='#2a7', stroke_width=2, stroke_dasharray='8 4')
    for p, b in zip(parts, allb):
        n = p[0][-1]
        lab = next((l for k, l in LABELS if n.startswith(k)), None)
        if n.startswith('HEX_STUDS'):
            cx, cy = (b[0][0]+b[1][0])/2, (b[0][1]+b[1][1])/2
            o.append(f'<circle cx="{X(cx):.1f}" cy="{Y(cy):.1f}" r="{1.73*K:.1f}" fill="none" stroke="#a60" stroke-width="1.2"/>')
        elif lab:
            col = '#c40' if n.startswith('TYPE-C') else '#06a'
            if n.startswith('PIN_HEADER'):
                rect(b, fill='none', stroke='#999', stroke_width=1, stroke_dasharray='2 3')
            else:
                rect(b, fill='#ffffff', fill_opacity=0.78, stroke=col, stroke_width=1.8, stroke_dasharray='' if n.startswith('TYPE-C') else '5 3')
                text((b[0][0]+b[1][0])/2, (b[0][1]+b[1][1])/2 - 0.3, lab, size=11, fill=col)
    for (x, y, d) in mount:
        o.append(f'<circle cx="{X(x):.1f}" cy="{Y(y):.1f}" r="{d/2*K:.1f}" fill="#fff" stroke="#b00" stroke-width="2"/>')
        text(x + 1.0, y + 2.2 if y < H/2 else y - 2.9, f"({x:.1f}, {y:.1f}) d{d:.1f}", size=11, fill='#f66', anchor='middle')
    if pouch: text((pouch[0][0]+pouch[1][0])/2, pouch[0][1]+0.8, 'LiPo 31 x 20 behind board (suggested X 9..40)', size=12, fill='#bfe')
    cap = ["Top view (display side up). X' right, Y' up, origin = display-module corner, 1 mm = 17 px.",
           "Light fill = display module; dashed grey = PCB; dashed blue = back-side parts seen through the board;",
           "red = M2 mounting holes (orange ring = hex stud); solid orange = USB-C; green = suggested LiPo position."]
    for k, t in enumerate(cap):
        o.append(f'<text x="{M}" y="{Y(0) + 28 + 17*k:.0f}" font-size="13" fill="#333">{t}</text>')
    o.append('</svg>')
    open(path, 'w').write('\n'.join(o))

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    flags = {a for a in sys.argv[2:] if a.startswith('--')}
    m = Model(sys.argv[1])
    root = top_pd(m)
    print(f"# unit={m.unit}  entities={len(m.e)}  root={m.pd2name[root]}")
    occ = m.occurrences(root)
    parts, allsolids = [], []
    for path, pd, M in occ:
        verts, circles = m.part_geometry(pd)
        if not verts: continue
        pts = [apply(M, v) for v in verts]
        parts.append((path, pd, M, pts, [(apply(M, c), norm(applyd(M, ax)), r) for c, ax, r in circles]))
        allsolids.append((path[-1], bbox(pts)))
    bf = BoardFrame(allsolids, flip_x='--flip-x' in flags, flip_n='--flip-n' in flags)
    print("# " + bf.describe())
    print("\n## Parts in BOARD frame (X' long / Y' short / Z' up from the reference solid's bottom face; mm)")
    print(f"{'part':34s} {'X0':>7s} {'X1':>7s} {'Y0':>7s} {'Y1':>7s} {'Z0':>7s} {'Z1':>7s}   size X x Y x Z")
    allp = []
    for path, pd, M, pts, circ in parts:
        bp = [bf.pt(p) for p in pts]; allp += bp
        lo, hi = bbox(bp)
        print(f"{path[-1][:34]:34s} {lo[0]:7.2f} {hi[0]:7.2f} {lo[1]:7.2f} {hi[1]:7.2f} {lo[2]:7.2f} {hi[2]:7.2f}   {hi[0]-lo[0]:.2f} x {hi[1]-lo[1]:.2f} x {hi[2]-lo[2]:.2f}")
    lo, hi = bbox(allp)
    print(f"\n## Overall bbox board frame: X' {lo[0]:.2f}..{hi[0]:.2f}, Y' {lo[1]:.2f}..{hi[1]:.2f}, Z' {lo[2]:.2f}..{hi[2]:.2f}  (size {hi[0]-lo[0]:.2f} x {hi[1]-lo[1]:.2f} x {hi[2]-lo[2]:.2f})")
    if '--solids' in flags:
        print("\n## Solids (board frame)")
        for path, pd, M in occ:
            m.part_geometry(pd)
            for sid in getattr(m, '_solids', {}).get(pd, []):
                v, c = m.solid_info(sid)
                b = bbox([bf.pt(apply(M, p)) for p in v])
                if b: print(f"{path[-1][:30]:30s} #{sid:<7d} X'[{b[0][0]:.2f},{b[1][0]:.2f}] Y'[{b[0][1]:.2f},{b[1][1]:.2f}] Z'[{b[0][2]:.2f},{b[1][2]:.2f}]")
    # ---- circles whose axis is the board normal ---------------------------------------
    circ_all = []   # (part, X', Y', r, Z')
    for path, pd, M, pts, circ in parts:
        for c, ax, r in circ:
            a = bf.vec(ax)
            if abs(abs(a[2]) - 1) < 1e-6:
                q = bf.pt(c); circ_all.append((path[-1], q[0], q[1], r, q[2]))
    # (a) mounting-hole candidates: 0.8 <= r <= 1.8, grouped by position
    grp = collections.defaultdict(set)
    ref_fp = (hi[0]-lo[0]) * (hi[1]-lo[1])
    boards = set()
    for path, pd, M, pts, circ in parts:
        b = bbox([bf.pt(q) for q in pts])
        if path[-1] != bf.ref_name and (b[1][0]-b[0][0]) * (b[1][1]-b[0][1]) > 0.5 * ref_fp: boards.add(path[-1])
    pcb_z = []
    for n, x, y, r, z in circ_all:
        if n in boards and 0.8 <= r <= 1.8:
            grp[(round(x, 2), round(y, 2), round(2*r, 2))].add(n[:26]); pcb_z.append(z)
    print(f"\n## Mounting holes in the board PCB part(s) {sorted(boards)} (axis = board normal, 0.8 <= r <= 1.8)")
    for (x, y, d), names in sorted(grp.items()):
        print(f"  X'={x:6.2f} Y'={y:6.2f} d={d:4.2f}")
    # fallback: holes drawn as spline/polyline rings have no CIRCLE entity -> find rings of vertices
    votes = collections.Counter()
    for path, pd, M, pts, circ in parts:
        if path[-1] not in boards or not pcb_z: continue
        lvl = [bf.pt(q) for q in pts]; lvl = [(a, b) for a, b, c in lvl if abs(c - min(pcb_z)) < 0.01]
        lvl = sorted(set((round(a, 3), round(b, 3)) for a, b in lvl))
        for i in range(len(lvl)):
            for j in range(i+1, len(lvl)):
                d = math.hypot(lvl[i][0]-lvl[j][0], lvl[i][1]-lvl[j][1])
                if 1.6 <= d <= 3.6:
                    votes[(round((lvl[i][0]+lvl[j][0])/2, 2), round((lvl[i][1]+lvl[j][1])/2, 2), round(d, 2))] += 1
    known = {(x, y) for (x, y, d) in grp}
    for (x, y, d), v in sorted(votes.items()):
        if v >= 8 and not any(abs(x-kx) < 0.05 and abs(y-ky) < 0.05 for kx, ky in known):
            print(f"  X'={x:6.2f} Y'={y:6.2f} d={d:4.2f}   (vertex ring, {v} diametral pairs; no CIRCLE entity)"); known.add((x, y)); grp[(x, y, d)].add('ring')
    other = sorted({(round(x, 1), round(y, 1), round(2*r, 1)) for n, x, y, r, z in circ_all if n == bf.ref_name and 0.8 <= r <= 1.8})
    print(f"  (the reference solid also has {len(other)} bosses/arcs of d 1.6-3.6 mm; use --circles to list)")
    # (b) pin-hole rows: small circles sharing Y' with constant X' pitch
    rows = collections.defaultdict(set)
    for n, x, y, r, z in circ_all:
        if 0.15 <= r <= 0.7 and n.startswith('ESP32'): rows[(round(y, 2), round(2*r, 2))].add(round(x, 2))
    print("\n## Rows of small holes in the board part (Y', d): count, pitch")
    for (y, d), xs in sorted(rows.items()):
        xs = sorted(xs)
        if len(xs) >= 6:
            gaps = collections.Counter(round(b-a, 2) for a, b in zip(xs, xs[1:]))
            print(f"  Y'={y:6.2f} d={d:4.2f} n={len(xs):2d} X' {xs[0]:.2f}..{xs[-1]:.2f} pitch={gaps.most_common(1)[0][0]}")
    # (c) rounded corners: circles tangent to two edges of their own part bbox
    print("\n## Corner arcs (circle centre = bbox corner + r in both axes), per part")
    for path, pd, M, pts, circ in parts:
        bp = [bf.pt(q) for q in pts]; plo, phi = bbox(bp); found = set()
        for c, ax, r in circ:
            a = bf.vec(ax)
            if abs(abs(a[2]) - 1) > 1e-6 or not (0.2 <= r <= 5): continue
            q = bf.pt(c)
            if (abs(q[0]-plo[0]-r) < .02 or abs(phi[0]-q[0]-r) < .02) and (abs(q[1]-plo[1]-r) < .02 or abs(phi[1]-q[1]-r) < .02):
                found.add((round(q[0], 2), round(q[1], 2), round(r, 3)))
        if len(found) >= 2: print(f"  {path[-1][:34]}: radius {sorted(found)[0][2]} mm at {sorted(found)}")
    if '--circles' in flags:
        print("\n## All normal-axis circles 0.25<=r<=2")
        for n, x, y, r, z in sorted(circ_all):
            if 0.25 <= r <= 2: print(f"  {n[:30]:30s} X'={x:7.2f} Y'={y:7.2f} d={2*r:5.2f} Z'={z:6.2f}")
    best = None; L = W = yb = 0.0
    # ---- back-side depth map and battery pouch fit --------------------------------------
    comp = [(p[0][-1], bbox([bf.pt(q) for q in p[3]])) for p in parts]
    refs = {bf.ref_name}
    pcb = [c for c in comp if c[0] in boards or c[0] == bf.ref_name]   # PCB / display solids
    back = [c for c in comp if c[0] not in boards and c[0] != bf.ref_name]
    if pcb:
        pcb_back = min(pcb_z) if pcb_z else 0.0
        print(f"\n## Back-side clearance (components below the PCB underside Z'={pcb_back:.2f})")
        for ign in ([], ['PIN_HEADER'], ['PIN_HEADER', 'HEX_STUDS']):
            sel = [c for c in back if not any(c[0].startswith(i) for i in ign)]
            lowest = min(sel, key=lambda c: c[1][0][2])
            print(f"  ignoring {str(ign or 'nothing'):32} -> lowest point Z'={lowest[1][0][2]:.2f} ({lowest[0]}); "
                  f"total thickness Z' {lowest[1][0][2]:.2f}..{hi[2]:.2f} = {hi[2]-lowest[1][0][2]:.2f} mm")
        L, W = (float(v) for v in next((a[8:] for a in sys.argv if a.startswith('--pouch=')), '31x20').split('x'))
        yb = (lo[1] + hi[1]) / 2
        print(f"\n## Pouch {L:g} (along X') x {W:g} (along Y') footprint, centred on Y'={yb:.2f}: depth of the deepest part under it")
        for ign in (['PIN_HEADER', 'HEX_STUDS'], ['PIN_HEADER']):
            best = None; x0 = 0.0
            while x0 + L <= hi[0] + 1e-9:
                rect = (x0, x0+L, yb-W/2, yb+W/2)
                d = 0.0; who = None
                for n, (a, b) in back:
                    if any(n.startswith(i) for i in ign): continue
                    if a[0] < rect[1] and b[0] > rect[0] and a[1] < rect[3] and b[1] > rect[2] and a[2] < d:
                        d = a[2]; who = n
                if best is None or d > best[0] + 1e-9: best = (d, x0, who)
                x0 += 0.5
            print(f"  ignoring {ign}: shallowest X' start = {best[1]:.1f} (cell X' {best[1]:.1f}..{best[1]+L:.1f}), lowest obstruction Z'={best[0]:.2f} ({best[2]})")
    if '--svg' in sys.argv:
        out = sys.argv[sys.argv.index('--svg') + 1]
        refb = next(bbox([bf.pt(q) for q in p[3]]) for p in parts if p[0][-1] == bf.ref_name)
        act = None
        # active window: the largest centred planar rectangle on the display's top face is not derivable
        # from vertices alone, so use the 2nd-highest face of the reference solid if present.
        m_ref = next(p for p in parts if p[0][-1] == bf.ref_name)
        lv = collections.defaultdict(list)
        for q in m_ref[3]:
            a = bf.pt(q); lv[round(a[2], 3)].append(a)
        top = sorted(lv)[-1]
        cand = [z for z in sorted(lv) if top - 0.12 < z < top]
        if cand:
            pts_ = lv[cand[-1]]; act = ((min(a[0] for a in pts_), min(a[1] for a in pts_)), (max(a[0] for a in pts_), max(a[1] for a in pts_)))
        pouch_r = None
        if best: pouch_r = ((best[1], yb - W/2), (best[1] + L, yb + W/2))
        write_svg(out, parts, bf, boards, [(x, y, d) for (x, y, d) in sorted(grp) ], pouch_r, act)
    if '--json' in sys.argv:
        out = sys.argv[sys.argv.index('--json') + 1]
        json.dump({'frame': bf.describe(), 'parts': [{'path': p[0], 'bbox': bbox([bf.pt(q) for q in p[3]])} for p in parts]}, open(out, 'w'), indent=1)

if __name__ == '__main__':
    main()
