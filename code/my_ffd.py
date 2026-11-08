# import numpy as np
import scipy.special
import numpy as np
import meshio

CHUNK = 200000

STL_IN = "DTCHull_bak/constant/triSurface/DTC-scaled.stl"
STL_OUT = "DTCHull/constant/triSurface/DTC-scaled.stl"

# ---------------------------------------------------------------------------
# Volume of a triangulated surface
# ---------------------------------------------------------------------------
def surface_volume(points: np.ndarray, tris: np.ndarray) -> float:
    """
    Signed volume swept by the surface, (1/6) sum_T det[p_a, p_b, p_c].

    For a closed, consistently oriented surface this is the enclosed volume.
    For an open one (a half hull cut at the symmetry plane, say) it is the
    volume of the cone subtended from the origin, which differs from the
    enclosed volume by a term depending only on the boundary curve.  Since the
    FFD freezes the outer layer of the lattice and leaves every vertex outside
    the box untouched, that boundary curve never moves, so a *change* in this
    quantity is exactly the change in enclosed volume.  Constraining it is
    therefore equivalent to constraining the displacement, whether or not the
    STL is watertight.
    """
    p = points[tris]
    return float(np.einsum("ti,ti->t",
                           np.cross(p[:, 0], p[:, 1]), p[:, 2]).sum() / 6.0)


def surface_volume_gradient(points: np.ndarray, tris: np.ndarray) -> np.ndarray:
    """dV/dp at every vertex, accumulated over the incident triangles."""
    p = points[tris]
    g = np.empty_like(p)
    g[:, 0] = np.cross(p[:, 1], p[:, 2]) / 6.0
    g[:, 1] = np.cross(p[:, 2], p[:, 0]) / 6.0
    g[:, 2] = np.cross(p[:, 0], p[:, 1]) / 6.0
    out = np.zeros_like(points)
    np.add.at(out, tris.reshape(-1), g.reshape(-1, 3))
    return out

def read_surface(filepath: str) -> meshio.Mesh:
    """
    Read a triangulated surface with meshio.

    Returns the full meshio.Mesh so the cell blocks (and any cell data) can be
    reused when writing the deformed surface back out.  meshio merges the
    duplicated per-facet vertices of an STL into a unique point list, so each
    physical vertex is deformed exactly once.
    """
    mesh = meshio.read(filepath)
    mesh.points = np.asarray(mesh.points, dtype=np.float64)
    return mesh


def write_surface(filepath: str, mesh: meshio.Mesh, points: np.ndarray) -> None:
    """
    Write `points` with the connectivity of `mesh` as a binary STL.

    STL stores coordinates as float32, so the written file is a rounded copy of
    the float64 deformation - that is the format's limitation, not a bug.
    """
    out = meshio.Mesh(np.asarray(points, dtype=np.float64), mesh.cells)
    meshio.write(filepath, out, file_format="stl", binary=True)

# ---------------------------------------------------------------------------
# Free-form deformation
# ---------------------------------------------------------------------------
class FFD:
    """Trivariate Bernstein free-form deformation on an axis-aligned box.

    control_points[i, j, k] is initialised at (i/nx, j/ny, k/nz) in local
    coordinates and initial_deform is added to it, so the displacements are
    expressed in box lengths.

    Points outside the box are not extrapolated (the Bernstein basis is only a
    partition of unity inside it; extrapolating would send the far field to
    infinity).  With taper = 0 they are left unchanged.  With taper > 0 (metres)
    a point at distance r outside the box gets the displacement of its nearest
    point on the box surface, scaled by the C1 ramp h(r / taper),
    h(s) = (1 - s)^2 (1 + 2 s), which is 1 on the box and 0 beyond taper.  This
    matters wherever the displacement does not vanish on the box surface (free
    control points on the outer layer): without it the deformation jumps there,
    which an STL with no vertices on the far side tolerates but a volume mesh
    does not.  Inside the box both variants are the plain FFD, and the map
    stays linear in the control points.

    mirror_y (optional) is a symmetry plane y = mirror_y, normally the box face
    on the ship's centreplane: a point beyond it gets the mirror image of the
    displacement of its reflection, so a full-hull surface deforms
    symmetrically (needs zero y-displacement on that face, which the frozen
    y-components there guarantee).  The half-domain volume mesh has no points
    beyond the plane, so it is unaffected.

    `adjust_volume` corrects the free weights so that the deformation leaves
    the volume enclosed by the surface unchanged.
    """

    def __init__(self, box_origin, box_length, n_control, initial_deform=0, taper=0.0,
                 mirror_y=None):
        self.taper = float(taper)
        self.mirror_y = None if mirror_y is None else float(mirror_y)
        self.box_origin = np.array(box_origin, dtype=np.float64)
        self.box_length = np.array(box_length, dtype=np.float64)
        self.n_control = np.array(n_control, dtype=np.int64)
        self.control_points = np.zeros(
            [n_control[0] + 1, n_control[1] + 1, n_control[2] + 1, 3]
        )
        for i in range(n_control[0] + 1):
            for j in range(n_control[1] + 1):
                for k in range(n_control[2] + 1):
                    self.control_points[i, j, k] = 1 / self.n_control * np.array([i, j, k])

        self.lattice = self.control_points.copy()
        self.initial_deform = initial_deform
        self.control_points = self.control_points + initial_deform

    # -- Bernstein basis ----------------------------------------------------

    def _bernestein_axis(self, t, n):
        """Bernstein basis of degree n evaluated at the (N,) array t -> (N, n+1)."""
        k = np.arange(n + 1)
        return scipy.special.comb(n, k) * t[:, None] ** k * (1 - t[:, None]) ** (n - k)

    def bernestein_point(self, x):
        b_x = self._bernestein_axis(np.atleast_1d(x[0]), self.n_control[0])
        b_y = self._bernestein_axis(np.atleast_1d(x[1]), self.n_control[1])
        b_z = self._bernestein_axis(np.atleast_1d(x[2]), self.n_control[2])
        return np.einsum('i,j,k->ijk', b_x.ravel(), b_y.ravel(), b_z.ravel())

    def bernestein_mesh(self, mesh_points):
        """(nx+1, ny+1, nz+1, N) tensor of basis values."""
        b_x = self._bernestein_axis(mesh_points[:, 0], self.n_control[0])
        b_y = self._bernestein_axis(mesh_points[:, 1], self.n_control[1])
        b_z = self._bernestein_axis(mesh_points[:, 2], self.n_control[2])
        return np.einsum('ni,nj,nk->ijkn', b_x, b_y, b_z)

    # -- box mapping --------------------------------------------------------

    def mesh_to_local_space(self, mesh):
        return (mesh - self.box_origin) / self.box_length

    def mesh_to_global_space(self, mesh):
        return mesh * self.box_length + self.box_origin

    def inside_box(self, mesh, tol=1e-08):
        """Boolean mask of the points lying in the lattice, in global space."""
        local = self.mesh_to_local_space(mesh)
        return np.all((local >= -tol) & (local <= 1.0 + tol), axis=1)

    def support(self, mesh, tol=1e-08):
        """Points the deformation reaches, in global space.

        Returns (idx, u, h, flip): their indices, the local coordinates of the
        point (reflected if beyond mirror_y) clamped to the unit cube, the
        blending weight (1 inside the box, the taper ramp outside) and whether
        it was reflected.  The displacement of point idx[n] is
        h[n] * (apply_to_mesh(u) - u)[n] * box_length, with the y-component
        negated where flip[n].
        """
        mesh = np.array(mesh, dtype=np.float64)
        flip = np.zeros(len(mesh), dtype=bool)
        if self.mirror_y is not None:
            flip = mesh[:, 1] > self.mirror_y
            mesh[flip, 1] = 2 * self.mirror_y - mesh[flip, 1]
        local = self.mesh_to_local_space(mesh)
        inside = np.all((local >= -tol) & (local <= 1.0 + tol), axis=1)
        clamped = np.clip(local, 0.0, 1.0)
        h = inside.astype(np.float64)
        if self.taper > 0:
            r = np.linalg.norm((local - clamped) * self.box_length, axis=1)
            s = np.clip(r / self.taper, 0.0, 1.0)
            h = np.where(inside, 1.0, (1 - s) ** 2 * (1 + 2 * s))
        idx = np.nonzero(h > 0)[0]
        return idx, clamped[idx], h[idx], flip[idx]

    # -- deformation --------------------------------------------------------

    def apply_to_point(self, x):
        return np.sum(
            self.control_points * np.repeat(self.bernestein_point(x)[:, :, :, np.newaxis], 3, axis=3),
            axis=(0, 1, 2),
        )

    def apply_to_mesh(self, mesh_points):
        """Local-space points -> local-space deformed points, in chunks."""
        mesh_points = np.atleast_2d(mesh_points)
        out = np.empty_like(mesh_points)
        for start in range(0, len(mesh_points), CHUNK):
            block = mesh_points[start:start + CHUNK]
            b_x = self._bernestein_axis(block[:, 0], self.n_control[0])
            b_y = self._bernestein_axis(block[:, 1], self.n_control[1])
            b_z = self._bernestein_axis(block[:, 2], self.n_control[2])
            out[start:start + CHUNK] = np.einsum(
                'ni,nj,nk,ijkd->nd', b_x, b_y, b_z, self.control_points, optimize=True
            )
        return out

    def ffd(self, M):
        """Deform the points of M inside the box (and in the taper zone), leave the rest."""
        M = np.asarray(M, dtype=np.float64)
        out = M.copy()
        idx, u, h, flip = self.support(M)
        if len(idx):
            d = h[:, None] * (self.apply_to_mesh(u) - u) * self.box_length
            d[flip, 1] *= -1
            out[idx] += d
        return out

    # -- volume-preserving correction ---------------------------------------

    def weights(self):
        """Control-point displacements, (nx+1, ny+1, nz+1, 3), in box lengths."""
        return self.control_points - self.lattice

    def adjust_volume(self, M, tris, free=None, shares=(1 / 3, 1 / 3, 1 / 3),
                      verbose=False):
        """Adjust the free weights so that the deformation preserves the volume.

        The defect is split into three shares and removed one direction at a
        time.  Each projection is exact, not iterative: the volume is a sum of
        determinants det[p_a, p_b, p_c], and expanding along the d-th
        coordinate shows every term to be linear in the collection of d-th
        coordinates, hence linear in the d-th components of the control points
        once the other two are held fixed.  The minimum-norm change of the free
        d-components producing a prescribed volume change c is then

            dP[..., d] = alpha_d * c / ||alpha_d||^2,   alpha_d = dV / dP[..., d].

        M     : (N, 3) vertices of the undeformed surface, in global space.
        tris  : (T, 3) triangle connectivity, consistently oriented.
        free  : boolean (nx+1, ny+1, nz+1, 3) array of adjustable components;
                by default the ones the caller left non-zero.
        shares: how the defect is split between x, y and z; must sum to one.

        Vertices the deformation does not reach contribute no sensitivity, so
        only those in support() enter the projection, with their taper weight.  The control points are
        modified in place; a dictionary of diagnostics is returned.
        """
        M = np.asarray(M, dtype=np.float64)
        tris = np.asarray(tris, dtype=np.int64)
        if not np.isclose(sum(shares), 1.0):
            raise ValueError("shares must sum to one")

        if free is None:
            free = np.abs(self.weights()) > 0.0
        free = np.asarray(free, dtype=bool)
        if not free.any():
            raise ValueError("no free components: every weight is zero")

        idx, u, h, flip = self.support(M)
        if not len(idx):
            raise ValueError("no surface vertex lies inside the lattice box")
        basis = self.bernestein_mesh(u) * h          # (nx+1, ny+1, nz+1, N_in)

        v_ref = surface_volume(M, tris)
        deformed = self.ffd(M)
        defect = v_ref - surface_volume(deformed, tris)
        initial = abs(defect) / abs(v_ref)

        before = self.weights().copy()
        for d, share in enumerate(shares):
            if share == 0.0:
                continue
            # dV/dP[i,j,k,d] = sum_p B_ijk(u_p) * (dV/dp_p)[d] * box_length[d],
            # the box length entering through the local-to-global map.
            grad = surface_volume_gradient(deformed, tris)[idx]
            grad[flip, 1] *= -1          # reflected points move with -dP[..., 1]
            alpha = np.einsum("ijkp,p->ijk", basis, grad[:, d]) * self.box_length[d]
            alpha = alpha * free[..., d]

            denom = float(np.sum(alpha ** 2))
            if denom == 0.0:
                raise RuntimeError(
                    f"no free component affects the volume in direction {d}")
            self.control_points[..., d] += alpha * (defect * share / denom)

            deformed = self.ffd(M)
            if verbose:
                res = abs(v_ref - surface_volume(deformed, tris)) / abs(v_ref)
                print(f"  after {'xyz'[d]}: relative volume defect {res:.3e}")

        delta = self.weights() - before
        return {
            "relative_defect_initial": initial,
            "relative_defect_final":
                abs(v_ref - surface_volume(deformed, tris)) / abs(v_ref),
            "n_free": int(free.sum()),
            "n_inside": int(len(idx)),
            "delta_norm": float(np.linalg.norm(delta)),
            "delta_max": float(np.abs(delta).max()),
        }

class FFD_volume_fixer:
    """Volume-preserving correction of a weight array, reusing one loaded surface."""

    def __init__(self, stl_in=STL_IN, box_origin=(5.80, -0.10, -0.05),
                 box_length=(0.50, 0.10, 0.33), taper=0.0, mirror_y=None):
        self.taper = float(taper)
        self.mirror_y = mirror_y
        self.mesh = read_surface(stl_in)
        self.points = self.mesh.points
        self.tris = np.asarray(self.mesh.cells_dict["triangle"], dtype=np.int64)
        self.box_origin = np.asarray(box_origin, dtype=np.float64)
        self.box_length = np.asarray(box_length, dtype=np.float64)

    def __call__(self, tmp, mask, shares=(1/3, 1/3, 1/3), verbose=False):
        tmp = np.asarray(tmp, dtype=np.float64)
        n_control = [s - 1 for s in tmp.shape[1:]]
        ffd = FFD(self.box_origin, self.box_length, n_control,
                  np.moveaxis(tmp, 0, -1), taper=self.taper,
                  mirror_y=self.mirror_y)
        info = ffd.adjust_volume(self.points, self.tris,
                                 free=np.moveaxis(mask, 0, -1),
                                 shares=shares, verbose=verbose)
        return np.moveaxis(ffd.weights(), -1, 0), info
