"""
Read and write an OpenFOAM polyMesh/points file (vectorField), ascii or binary,
optionally gzip-compressed (points.gz).  Only the coordinates are replaced on
writing: the header and everything around the list are kept byte for byte, so
the file stays in the format, precision and arch the mesh was written with.
"""
import gzip
import io
import os
import re

import numpy as np

_LIST = re.compile(rb"(?:\s|//[^\n]*\n|/\*.*?\*/)*(\d+)\s*\(", re.S)


def read_points(path):
    """(points (N, 3) float64, layout) - pass layout to write_points."""
    if not os.path.exists(path) and os.path.exists(path + ".gz"):
        path += ".gz"
    gz = path.endswith(".gz")
    with (gzip.open if gz else open)(path, "rb") as f:
        raw = f.read()

    head = re.search(rb"FoamFile\s*\{(.*?)\}", raw, re.S)
    if head is None:
        raise ValueError(f"{path}: no FoamFile header")
    fmt = re.search(rb"format\s+(\w+)\s*;", head.group(1))
    fmt = fmt.group(1).decode() if fmt else "ascii"
    arch = re.search(rb'arch\s+"([^"]*)"', head.group(1))
    arch = arch.group(1).decode() if arch else "LSB;label=32;scalar=64"

    m = _LIST.match(raw, head.end())
    if m is None:
        raise ValueError(f"{path}: no list after the header")
    n, start = int(m.group(1)), m.end()          # start: just after '('

    if fmt == "binary":
        size = 4 if "scalar=32" in arch else 8
        dtype = np.dtype((">" if "MSB" in arch else "<") + f"f{size}")
        end = start + 3 * n * size
        if raw[end:end + 1] != b")":
            raise ValueError(f"{path}: binary list of {n} points does not end where expected")
        pts = np.frombuffer(raw[start:end], dtype=dtype).reshape(n, 3).astype(np.float64)
    else:
        dtype = None
        end = raw.rindex(b")")                   # closes the list; the trailer has none
        body = raw[start:end].translate(bytes.maketrans(b"()", b"  ")).decode()
        pts = np.fromstring(body, sep=" ")
        if pts.size != 3 * n:
            raise ValueError(f"{path}: expected {n} points, read {pts.size / 3:g}")
        pts = pts.reshape(n, 3)

    layout = {"path": path, "gz": gz, "format": fmt, "dtype": dtype,
              "prefix": raw[:start], "suffix": raw[end:], "n": n}
    return pts, layout


def write_points(layout, points):
    """Write points (same count) back to layout['path'], atomically."""
    points = np.asarray(points, dtype=np.float64)
    if points.shape != (layout["n"], 3):
        raise ValueError(f"expected ({layout['n']}, 3) points, got {points.shape}")
    if layout["format"] == "binary":
        body = points.astype(layout["dtype"]).tobytes()
    else:
        buf = io.BytesIO()
        np.savetxt(buf, points, fmt="(%.12g %.12g %.12g)")
        body = b"\n" + buf.getvalue()
    data = layout["prefix"] + body + layout["suffix"]
    tmp = layout["path"] + ".tmp"
    with (gzip.open if layout["gz"] else open)(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, layout["path"])
