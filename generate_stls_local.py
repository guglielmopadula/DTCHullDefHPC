#!/usr/bin/env python3
"""
Serial, laptop-side generation of the deformed hulls - no OpenFOAM, no Slurm.

For every seed it runs code/mv_points.py and code/check_surface.py exactly as
the Leonardo jobs do, and collects the results in one folder:

    <out>/stl/DTC-scaled_<i>.stl           deformed hull, seed i (zero-padded)
    <out>/ffd_weights/weights_<i>.npy      FFD weights (columns follow mask_ffd.npy)
    <out>/ffd_weights/weights.npy          stacked, rows sorted by seed
    <out>/mask_ffd.npy
    <out>/checks/surface_check_<i>.json    inverted triangles, volume defect, displacement
    <out>/logs/sample_<i>.log              output of both scripts
    <out>/summary.csv                      one line per seed

With --mesh <meshed case> (the undeformed case after snappyHexMesh, e.g. the
cluster's $RUN_ROOT/base_mesh/DTCHull) every seed also morphs that volume mesh
with code/morph_mesh.py, as the jobs do:

    <out>/meshes/sample_<i>/constant/polyMesh   morphed points; the other
                                                polyMesh files and system/
                                                are links to the base case
    <out>/checks/mesh_morph_<i>.json            mesh points moved, max displacement

Each meshes/sample_<i> is a case that checkMesh (or paraFoam) can open.

Usage:
    python generate_stls_local.py --base path/to/DTCHull_bak --out deformed
    python generate_stls_local.py --base DTCHull_bak.zip --first 0 --n 100
    python generate_stls_local.py ... --force       # redo seeds already done
    python generate_stls_local.py ... --mesh base_mesh/DTCHull

Needs numpy, scipy and meshio (pip install numpy scipy meshio).
"""
import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import time
import zipfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CODE = os.path.join(HERE, "code")
STL_REL = os.path.join("constant", "triSurface", "DTC-scaled.stl")


def find_stl(base, work):
    """Undeformed hull from a DTCHull_bak folder, its zip, or the STL itself."""
    if base.lower().endswith(".stl"):
        return base
    if base.lower().endswith(".zip"):
        with zipfile.ZipFile(base) as z:
            name = next((n for n in z.namelist()
                         if n.replace("\\", "/").endswith("constant/triSurface/DTC-scaled.stl")),
                        None)
            if name is None:
                sys.exit(f"ERROR: no constant/triSurface/DTC-scaled.stl in {base}")
            dst = os.path.join(work, "undeformed.stl")
            with z.open(name) as src, open(dst, "wb") as out:
                shutil.copyfileobj(src, out)
            return dst
    path = os.path.join(base, STL_REL)
    if not os.path.isfile(path):
        sys.exit(f"ERROR: {path} not found")
    return path


def make_mesh_case(base, case):
    """case/constant/polyMesh with a copy of the base points (to be morphed) and
    links to every other polyMesh file and to system/, so it costs one points file."""
    shutil.rmtree(case, ignore_errors=True)
    pm_src = os.path.join(base, "constant", "polyMesh")
    pm = os.path.join(case, "constant", "polyMesh")
    os.makedirs(pm)
    for name in os.listdir(pm_src):
        src = os.path.join(pm_src, name)
        if name in ("points", "points.gz"):
            shutil.copy(src, os.path.join(pm, name))
        else:
            os.symlink(src, os.path.join(pm, name))
    os.symlink(os.path.join(base, "system"), os.path.join(case, "system"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="DTCHull_bak",
                    help="DTCHull_bak folder, DTCHull_bak.zip, or the undeformed STL")
    ap.add_argument("--out", default="deformed_stls", help="output folder")
    ap.add_argument("--first", type=int, default=0, help="first seed")
    ap.add_argument("--n", type=int, default=100, help="number of seeds")
    ap.add_argument("--force", action="store_true", help="redo seeds already generated")
    ap.add_argument("--scale", type=float, default=0.02,
                    help="std of the random FFD weights (FFD_SCALE in config.sh)")
    ap.add_argument("--mesh", help="meshed undeformed case to morph for every seed")
    a = ap.parse_args()
    base_mesh = None
    if a.mesh:
        base_mesh = os.path.abspath(a.mesh)
        if not os.path.isdir(os.path.join(base_mesh, "constant", "polyMesh")):
            sys.exit(f"ERROR: no constant/polyMesh in {base_mesh}")

    out = os.path.abspath(a.out)
    for d in ("stl", "ffd_weights", "checks", "logs") + (("meshes",) if base_mesh else ()):
        os.makedirs(os.path.join(out, d), exist_ok=True)

    # mv_points.py uses paths relative to its working directory:
    #   reads  DTCHull_bak/constant/triSurface/DTC-scaled.stl
    #   writes DTCHull/constant/triSurface/DTC-scaled.stl, mask_ffd.npy,
    #          ffd_weights/weights_<i>.npy
    work = os.path.join(out, "_work")
    for d in ("DTCHull_bak/constant/triSurface", "DTCHull/constant/triSurface", "ffd_weights"):
        os.makedirs(os.path.join(work, d), exist_ok=True)
    ref = os.path.join(work, "DTCHull_bak", STL_REL)
    if not os.path.exists(ref):
        shutil.copy(find_stl(a.base, work), ref)

    env = dict(os.environ)
    env["PYTHONPATH"] = CODE + os.pathsep + env.get("PYTHONPATH", "")
    width = max(3, len(str(a.first + a.n - 1)))

    rows, t0 = [], time.time()
    for k, i in enumerate(range(a.first, a.first + a.n)):
        tag = f"{i:0{width}d}"
        stl = os.path.join(out, "stl", f"DTC-scaled_{tag}.stl")
        chk = os.path.join(out, "checks", f"surface_check_{tag}.json")
        wts = os.path.join(out, "ffd_weights", f"weights_{i}.npy")
        mjs = os.path.join(out, "checks", f"mesh_morph_{tag}.json")
        case = os.path.join(out, "meshes", f"sample_{tag}")
        row = {"seed": i}
        needed = (stl, chk, wts) + ((mjs,) if base_mesh else ())

        if not a.force and all(os.path.exists(p) for p in needed):
            row.update(json.load(open(chk)), status="done (kept)")
            if base_mesh:
                row["mesh_max_displacement"] = json.load(open(mjs))["max_displacement"]
        else:
            log_path = os.path.join(out, "logs", f"sample_{tag}.log")
            steps = [["mv_points.py", str(i), "--scale", str(a.scale)], ["check_surface.py", str(i)]]
            if base_mesh:
                make_mesh_case(base_mesh, case)
                steps.append(["morph_mesh.py", str(i), case])
            with open(log_path, "w") as log:
                status = "ok"
                for script, *args in steps:
                    r = subprocess.run([sys.executable, os.path.join(CODE, script), *args],
                                       cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT)
                    if r.returncode:
                        status = f"FAILED:{script}"
                        break
            if status == "ok":
                shutil.move(os.path.join(work, "DTCHull", STL_REL), stl)
                shutil.move(os.path.join(work, "ffd_weights", f"weights_{i}.npy"), wts)
                shutil.move(os.path.join(work, "surface_check.json"), chk)
                shutil.copy(os.path.join(work, "mask_ffd.npy"), os.path.join(out, "mask_ffd.npy"))
                row.update(json.load(open(chk)))
                if base_mesh:
                    shutil.move(os.path.join(work, "mesh_morph.json"), mjs)
                    row["mesh_max_displacement"] = json.load(open(mjs))["max_displacement"]
            row["status"] = status

        rows.append(row)
        el = time.time() - t0
        print(f"[{k + 1}/{a.n}] seed {i}: {row['status']}"
              + (f", {row['n_inverted']} inverted triangles, "
                 f"max displacement {row['max_displacement']:.4f} m"
                 + (f" (mesh {row['mesh_max_displacement']:.4f} m)"
                    if "mesh_max_displacement" in row else "")
                 if "n_inverted" in row else "")
              + f"   ({el:.0f}s elapsed)", flush=True)

    # stacked weights, in seed order, for every seed that has them
    ok = [r["seed"] for r in rows if os.path.exists(os.path.join(out, "ffd_weights", f"weights_{r['seed']}.npy"))]
    if ok:
        np.save(os.path.join(out, "ffd_weights", "weights.npy"),
                np.vstack([np.load(os.path.join(out, "ffd_weights", f"weights_{i}.npy")) for i in ok]))

    cols = ["seed", "status", "n_inverted", "folded", "rel_defect", "rel_defect_stl",
            "max_displacement", "mesh_max_displacement", "weights_min", "weights_max"]
    with open(os.path.join(out, "summary.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader(); w.writerows(rows)

    failed = [r["seed"] for r in rows if str(r["status"]).startswith("FAILED")]
    folded = [r["seed"] for r in rows if r.get("n_inverted", 0) > 0]
    print(f"\n{len(rows) - len(failed)} of {len(rows)} hulls generated, "
          f"{len(folded)} with inverted triangles")
    if folded:
        print("folded seeds:", ", ".join(map(str, folded)))
    if failed:
        print("FAILED seeds (see logs/):", ", ".join(map(str, failed)))
    print(f"results in {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
