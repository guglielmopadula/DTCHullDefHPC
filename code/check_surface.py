"""
Sanity check of one deformed hull, run from the sample folder after mv_points.py:

    python check_surface.py <seed>

Rebuilds the deformation from ffd_weights/weights_<seed>.npy and mask_ffd.npy
and writes surface_check.json with

    n_inverted        surface triangles whose orientation flipped (self-folding)
    rel_defect        relative volume change, float64 deformation
    rel_defect_stl    relative volume change of the float32 STL actually written
    max_displacement  largest vertex displacement, in metres
    folded            n_inverted > 0
"""
import json
import sys

import numpy as np

from my_ffd import FFD, read_surface, surface_volume
from mv_points import BOX_LENGTH, BOX_ORIGIN, STL_IN, STL_OUT


def normals(points, tris):
    p = points[tris]
    return np.cross(p[:, 1] - p[:, 0], p[:, 2] - p[:, 0])


def main(seed):
    mask = np.load("mask_ffd.npy")                       # (nx, ny, nz, 3)
    w = np.zeros(mask.shape)
    w[mask] = np.load(f"ffd_weights/weights_{seed}.npy")

    mesh = read_surface(STL_IN)
    P = mesh.points
    T = np.asarray(mesh.cells_dict["triangle"], dtype=np.int64)

    ffd = FFD(BOX_ORIGIN, BOX_LENGTH, [s - 1 for s in mask.shape[:3]], w)
    Q = ffd.ffd(P)
    touched = ffd.inside_box(P)[T].any(axis=1)
    flipped = (normals(Q, T) * normals(P, T)).sum(axis=1) < 0
    n_inv = int((flipped & touched).sum())

    v_ref = surface_volume(P, T)
    out = read_surface(STL_OUT)                          # what snappyHexMesh will see
    v_stl = surface_volume(out.points, np.asarray(out.cells_dict["triangle"]))

    res = {
        "seed": seed,
        "n_triangles_in_box": int(touched.sum()),
        "n_inverted": n_inv,
        "folded": n_inv > 0,
        "rel_defect": (surface_volume(Q, T) - v_ref) / v_ref,
        "rel_defect_stl": (v_stl - v_ref) / v_ref,
        "max_displacement": float(np.linalg.norm(Q - P, axis=1).max()),
        "weights_min": float(w[mask].min()),
        "weights_max": float(w[mask].max()),
    }
    with open("surface_check.json", "w") as f:
        json.dump(res, f, indent=2)
    print(f"seed {seed}: {n_inv} inverted triangles, volume defect "
          f"{res['rel_defect']:.2e} (STL {res['rel_defect_stl']:.2e}), "
          f"max displacement {res['max_displacement']:.4f} m")
    if n_inv:
        print("WARNING: the deformed hull folds onto itself")


if __name__ == "__main__":
    main(int(sys.argv[1]))
