# -*- coding: utf-8 -*-
"""Material Symbols SVG path -> ASS drawing commands, in a 0..24 box."""
import glob, io, os, re

NUM = re.compile(r"[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?")
TOK = re.compile(r"([MmLlHhVvQqTtZz])|([-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?)")

def tokens(d):
    out = []
    for m in TOK.finditer(d):
        out.append(m.group(1) if m.group(1) else float(m.group(2)))
    return out

def to_ass(d, vb):
    """vb = (min_x, min_y, w, h). Output y grows downward, box is 0..24."""
    minx, miny, w, h = vb
    sx, sy = 24.0 / w, 24.0 / h

    def pt(x, y):
        return ((x - minx) * sx, (y - miny) * sy)

    ts = tokens(d)
    i = 0
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    prev_q = None
    out = []
    cmd = None
    while i < len(ts):
        if isinstance(ts[i], str):
            cmd = ts[i]
            i += 1
            if cmd in "Zz":
                out.append("c")
                cur = start
                prev_q = None
                continue
        rel = cmd.islower()
        c = cmd.upper()

        def take(n):
            nonlocal i
            vals = ts[i:i + n]
            i += n
            return vals

        if c == "M":
            x, y = take(2)
            if rel:
                x, y = cur[0] + x, cur[1] + y
            cur = start = (x, y)
            out.append("m %s %s" % fmt(pt(x, y)))
            cmd = "l" if rel else "L"   # further pairs are line-tos
            prev_q = None
        elif c == "L":
            x, y = take(2)
            if rel:
                x, y = cur[0] + x, cur[1] + y
            cur = (x, y)
            out.append("l %s %s" % fmt(pt(x, y)))
            prev_q = None
        elif c == "H":
            x, = take(1)
            if rel:
                x = cur[0] + x
            cur = (x, cur[1])
            out.append("l %s %s" % fmt(pt(*cur)))
            prev_q = None
        elif c == "V":
            y, = take(1)
            if rel:
                y = cur[1] + y
            cur = (cur[0], y)
            out.append("l %s %s" % fmt(pt(*cur)))
            prev_q = None
        elif c in ("Q", "T"):
            if c == "Q":
                qx, qy, x, y = take(4)
                if rel:
                    qx, qy = cur[0] + qx, cur[1] + qy
                    x, y = cur[0] + x, cur[1] + y
            else:
                x, y = take(2)
                if rel:
                    x, y = cur[0] + x, cur[1] + y
                if prev_q:
                    qx = 2 * cur[0] - prev_q[0]
                    qy = 2 * cur[1] - prev_q[1]
                else:
                    qx, qy = cur
            # quadratic -> cubic, exactly
            c1 = (cur[0] + 2.0 / 3 * (qx - cur[0]), cur[1] + 2.0 / 3 * (qy - cur[1]))
            c2 = (x + 2.0 / 3 * (qx - x), y + 2.0 / 3 * (qy - y))
            out.append("b %s %s %s %s %s %s" % (fmt(pt(*c1)) + fmt(pt(*c2)) + fmt(pt(x, y))))
            prev_q = (qx, qy)
            cur = (x, y)
        else:
            raise SystemExit("unhandled command %r" % cmd)
    return " ".join(out)

def fmt(p):
    def one(v):
        s = "%.2f" % v
        s = s.rstrip("0").rstrip(".")
        return s if s not in ("-0", "") else "0"
    return (one(p[0]), one(p[1]))

def convert(path):
    s = io.open(path, encoding="utf-8").read()
    vb = [float(x) for x in re.split(r"[ ,]+", re.search(r'viewBox="([^"]+)"', s).group(1).strip())]
    ds = re.findall(r'd="([^"]*)"', s)
    return " ".join(to_ass(d, vb) for d in ds)

if __name__ == "__main__":
    for f in sorted(glob.glob("mdi/*.svg")):
        name = os.path.basename(f)[:-4]
        print(name, "->", convert(f)[:70], "...")
