"""
Random free-form deformation of the DTC hull triangulated surface.

Instead of deforming the OpenFOAM volume mesh ('constant/polyMesh/points'),
this script reads the triangulated surface

    constant/triSurface/DTC-scaled.stl

with meshio, applies a Bernstein FFD to the vertices that fall inside the
lattice box, and writes the deformed surface back out.  The mesh topology
(the triangle connectivity) is untouched; only vertex coordinates change, so
snappyHexMesh can be re-run on the result.

Usage:
    python mv_points.py <seed> [--scale S]   # random weights, std S (default 0.02)
    python mv_points.py <i> --weights weights.npy [--no-fix]   # row i of a stored (N, 86) array

The random weights are a truncated normal (+-3 std) in units of the box length;
for a given seed they only scale with S, so the shapes keep their direction.
"""
import sys

import numpy as np
import scipy.special
from scipy.stats import truncnorm
from my_ffd import FFD_volume_fixer, FFD, read_surface, write_surface
import meshio
STL_IN = "DTCHull_bak/constant/triSurface/DTC-scaled.stl"
STL_OUT = "DTCHull/constant/triSurface/DTC-scaled.stl"

BOX_ORIGIN = np.array([5.80, -0.10, -0.05])
BOX_LENGTH = np.array([0.50, 0.10, 0.33])
# Width (m) of the zone outside the box over which the displacement of the
# free edge [4, 4, :] (on the box surface) is ramped to zero; see my_ffd.FFD.
# The same value deforms the STL (mv_points, check_surface) and the volume
# mesh (morph_mesh), so the hull patch of the mesh matches the STL.
FFD_TAPER = 0.20
# The STL is the full hull but the mesh only its y <= 0 half: the box face
# y = 0 is the centreplane, and the y > 0 side of the STL gets the mirrored
# deformation, so the deformed STL stays symmetric.
MIRROR_Y = 0.0

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

CHUNK = 200000


# ---------------------------------------------------------------------------
# STL I/O
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    nx = 5
    ny = 5
    nz = 5
    i = int(sys.argv[1])
    np.random.seed(i)
    scale = float(sys.argv[sys.argv.index("--scale") + 1]) if "--scale" in sys.argv else 0.02

    mesh = read_surface(STL_IN)
    points = mesh.points
    tris = mesh.cells_dict["triangle"]

    tmp = truncnorm.rvs(a=-3, b=3, scale=scale,size=(3, nx, ny, nz))
    mask = np.zeros((3, nx, ny, nz), dtype=bool)
    mask[:] = True
    # Freeze the outer layer of control points on all six faces, so the
    # deformation vanishes at the lattice boundary and the bulb blends
    # continuously into the untouched hull.
    tmp[:, 0, :, :] = 0
    mask[:, 0, :, :] = False
    tmp[:, -1, :, :] = 0
    mask[:, -1, :, :] = False
    tmp[:, :, 0, :] = 0
    mask[:, :, 0, :] = False
    tmp[:, :, -1, :] = 0
    mask[:, :, -1, :] = False
    tmp[:, :, :, 0] = 0
    mask[:, :, :, 0] = False
    tmp[:, :, :, -1] = 0
    mask[:, :, :, -1] = False
    tmp[0, -1, -1, :] = truncnorm.rvs(a=-3, b=3, scale=scale,size=(nz,))
    mask[0, -1, -1, :] = True

    # Optionally replace the random weights with stored ones (row i of an
    # (N, 86) array, or a single (86,) vector), in the saved (nx, ny, nz, 3) order.
    if "--weights" in sys.argv:
        w = np.load(sys.argv[sys.argv.index("--weights") + 1])
        w = w[i] if w.ndim == 2 else w
        grid = np.zeros((nx, ny, nz, 3))
        grid[np.transpose(mask, (1, 2, 3, 0))] = w
        tmp = np.transpose(grid, (3, 0, 1, 2))

    if "--no-fix" not in sys.argv:
        fixer = FFD_volume_fixer(STL_IN, BOX_ORIGIN, BOX_LENGTH, taper=FFD_TAPER,
                                  mirror_y=MIRROR_Y)
        tmp, info = fixer(tmp, mask)
        print(f"volume defect {info['relative_defect_initial']:.3e} -> "
              f"{info['relative_defect_final']:.1e} over {info['n_free']} free weights")

    ffd = FFD(BOX_ORIGIN, BOX_LENGTH, [nx - 1, ny - 1, nz - 1],
              np.moveaxis(tmp, 0, -1), taper=FFD_TAPER, mirror_y=MIRROR_Y)
    n_in = len(ffd.support(points)[0])
    points_def = ffd.ffd(points)
    moved = np.linalg.norm(points_def - points, axis=1)
    print(f"{n_in} of {len(points)} surface vertices inside the lattice or its taper zone, "
          f"max displacement {moved.max():.5f}")

    write_surface(STL_OUT, mesh, points_def)
    print(f"Deformed surface written to {STL_OUT}")

    # Save in the (nx, ny, nz, 3) layout, so the columns of the weight vector
    # match the flat non-zero positions of mask_ffd.npy.
    tmp = np.transpose(tmp, (1, 2, 3, 0))
    mask = np.transpose(mask, (1, 2, 3, 0))
    np.save("mask_ffd.npy", mask)
    np.save("ffd_weights/weights_{}.npy".format(i),
            tmp.reshape(-1)[mask.reshape(-1)])
