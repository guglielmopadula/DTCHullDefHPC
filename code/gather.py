"""
Collect every sample folder into $RUN_ROOT/results, in the layout compute_sas.py reads:

    results/forces/forces_<i>.dat      copies of each force.dat
    results/ffd_weights/weights_<i>.npy
    results/ffd_weights/weights.npy    stacked weights of the DONE samples, by seed
    results/Y.npy                      drag of the same samples, same order
    results/indices.npy                which seeds the rows of weights.npy / Y.npy are
    results/mask_ffd.npy
    results/summary.csv                one line per sample: status, drag, surface check

    python gather.py <RUN_ROOT> <first> <n> <n_avg>
"""
import csv
import json
import os
import shutil
import sys

import numpy as np


def load_force(path):
    # OpenFOAM >= v2006 writes plain columns; older versions wrap vectors in ( )
    with open(path) as f:
        rows = [l.replace("(", " ").replace(")", " ").split()
                for l in f if l.strip() and not l.lstrip().startswith("#")]
    return np.array(rows, dtype=float)


def drag(data, n_avg):
    """Same definition as compute_sas.load_drag_py: |mean of total_x| over the tail."""
    n = min(n_avg, data.shape[0])
    return abs(data[-n:, 1].mean()), n


def convergence(data, n):
    """pressure and viscous parts of the drag over the last n rows, and how
    settled the drag is: std over the window and the difference between the
    means of its two halves (a converged run has drift << sample-to-sample spread)."""
    x = -data[-n:, 1]
    h = n // 2
    return {"drag_pressure": abs(data[-n:, 4].mean()), "drag_viscous": abs(data[-n:, 7].mean()),
            "drag_std": x.std(), "drag_drift": abs(x[h:].mean() - x[:h].mean())}


def main(root, first, n, n_avg):
    runs, res = os.path.join(root, "runs"), os.path.join(root, "results")
    for d in ("forces", "ffd_weights"):
        os.makedirs(os.path.join(res, d), exist_ok=True)

    rows, W, Y, idx, mask = [], [], [], [], None
    for i in range(first, first + n):
        sd = os.path.join(runs, f"sample_{i:03d}")
        r = {"seed": i, "status": "MISSING"}
        if os.path.isdir(sd):
            try:
                r["status"] = open(os.path.join(sd, "STATUS")).read().strip()
            except OSError:
                r["status"] = "NO_STATUS"
            chk = os.path.join(sd, "surface_check.json")
            if os.path.exists(chk):
                c = json.load(open(chk))
                r.update({k: c[k] for k in ("n_inverted", "rel_defect", "rel_defect_stl",
                                            "max_displacement")})
            mm = os.path.join(sd, "mesh_morph.json")
            if os.path.exists(mm):
                r["mesh_max_displacement"] = json.load(open(mm))["max_displacement"]
            wf = os.path.join(sd, "ffd_weights", f"weights_{i}.npy")
            if os.path.exists(wf):
                shutil.copy(wf, os.path.join(res, "ffd_weights"))
                if mask is None and os.path.exists(os.path.join(sd, "mask_ffd.npy")):
                    mask = np.load(os.path.join(sd, "mask_ffd.npy"))
            ff = os.path.join(sd, "force.dat")
            if r["status"] == "DONE" and os.path.exists(ff):
                shutil.copy(ff, os.path.join(res, "forces", f"forces_{i}.dat"))
                data = load_force(ff)
                r["drag"], r["n_avg_used"] = drag(data, n_avg)
                r["n_iterations"] = data.shape[0]
                r.update(convergence(data, r["n_avg_used"]))
                W.append(np.load(wf)); Y.append(r["drag"]); idx.append(i)
        rows.append(r)

    cols = ["seed", "status", "drag", "drag_pressure", "drag_viscous", "drag_std", "drag_drift",
            "n_iterations", "n_avg_used", "n_inverted",
            "rel_defect", "rel_defect_stl", "max_displacement", "mesh_max_displacement"]
    with open(os.path.join(res, "summary.csv"), "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        wr.writeheader(); wr.writerows(rows)

    if mask is not None:
        np.save(os.path.join(res, "mask_ffd.npy"), mask)
    if W:
        np.save(os.path.join(res, "ffd_weights", "weights.npy"), np.vstack(W))
        np.save(os.path.join(res, "Y.npy"), np.array(Y))
        np.save(os.path.join(res, "indices.npy"), np.array(idx))

    st = {}
    for r in rows:
        st[r["status"]] = st.get(r["status"], 0) + 1
    print("status:", ", ".join(f"{k} {v}" for k, v in sorted(st.items())))
    folded = sum(1 for r in rows if r.get("n_inverted", 0) > 0)
    print(f"{len(idx)} samples in weights.npy / Y.npy; {folded} hulls have inverted triangles")
    short = [r["seed"] for r in rows if r.get("n_iterations", n_avg) < n_avg]
    if short:
        print(f"note: {len(short)} samples have fewer than {n_avg} iterations, "
              f"drag averaged over what exists")
    done = [r for r in rows if "drag_drift" in r]
    if len(done) > 1:
        drift = float(np.median([r["drag_drift"] for r in done]))
        spread = float(np.std([r["drag"] for r in done]))
        print(f"drag: std between samples {spread:.3f} N; median drift within a run "
              f"(two halves of the last {n_avg} iterations) {drift:.3f} N")
        if drift > 0.5 * spread:
            print("WARNING: the runs have not settled: much of the spread between samples "
                  "is solver noise (see drag_drift in summary.csv)")
    print(f"results in {res}")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
