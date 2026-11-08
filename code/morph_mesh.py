"""
Morph the volume mesh of one sample with its FFD weights, instead of remeshing.

Run from the sample folder after mv_points.py, once the undeformed base mesh has
been copied to <case>/constant/polyMesh:

    python morph_mesh.py <seed> [case]        (case defaults to DTCHull)

Every mesh point inside the FFD box (and in its taper zone) is moved by the
same map that deformed the STL, so the hull patch follows the deformed hull
and the surrounding cells follow it smoothly; the topology, and therefore the
discretisation, is the same for every sample.  Writes mesh_morph.json.
"""
import json
import sys

import numpy as np

from foam_points import read_points, write_points
from my_ffd import FFD
from mv_points import BOX_LENGTH, BOX_ORIGIN, FFD_TAPER, MIRROR_Y


def main(seed, case="DTCHull"):
    mask = np.load("mask_ffd.npy")                       # (nx, ny, nz, 3)
    w = np.zeros(mask.shape)
    w[mask] = np.load(f"ffd_weights/weights_{seed}.npy")  # already volume-corrected

    P, layout = read_points(f"{case}/constant/polyMesh/points")
    ffd = FFD(BOX_ORIGIN, BOX_LENGTH, [s - 1 for s in mask.shape[:3]], w, taper=FFD_TAPER, mirror_y=MIRROR_Y)
    Q = ffd.ffd(P)
    write_points(layout, Q)

    d = np.linalg.norm(Q - P, axis=1)
    res = {
        "seed": seed,
        "points_file": layout["path"],
        "format": layout["format"],
        "n_points": int(len(P)),
        "n_in_box": int(ffd.inside_box(P).sum()),
        "n_moved": int((d > 0).sum()),
        "max_displacement": float(d.max()),
        "taper": FFD_TAPER,
    }
    with open("mesh_morph.json", "w") as f:
        json.dump(res, f, indent=2)
    print(f"seed {seed}: moved {res['n_moved']} of {res['n_points']} mesh points "
          f"({layout['format']}), max displacement {res['max_displacement']:.4f} m")


if __name__ == "__main__":
    main(int(sys.argv[1]), *sys.argv[2:3])
