#!/usr/bin/env python3
"""
Average x-force and stacked FFD weights of every finished sample.

For each $RUN_ROOT/runs/sample_XXX with STATUS = DONE it reads force.dat,
averages total_x (column 1) over the last N_AVG rows, and loads
ffd_weights/weights_<i>.npy.  Written to this folder (or --out):

    force_x.npy      mean total_x over the last N_AVG iterations (signed, N)
    Y.npy            |force_x|, the drag as compute_sas.py expects it
    weights.npy      stacked FFD weights, same row order (n_samples, 86)
    indices.npy      seed of each row
    collect.csv      seed, force_x, rows in force.dat

Usage (on a login node):
    venv/bin/python collect.py                 # last 500 iterations, RUN_ROOT from config.sh
    venv/bin/python collect.py --n-avg 500 --root $SCRATCH/dtc_ffd --out results_dir
"""
import argparse
import csv
import glob
import os
import re
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def from_config(name, default):
    """value of a variable in config.sh, as bash expands it."""
    cfg = os.path.join(HERE, "config.sh")
    if not os.path.exists(cfg):
        return default
    try:
        out = subprocess.run(["bash", "-c", f'source "{cfg}" >/dev/null 2>&1; echo "${name}"'],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        return out or default
    except Exception:
        return default


def load_force(path):
    with open(path) as f:
        rows = [l.replace("(", " ").replace(")", " ").split()
                for l in f if l.strip() and not l.lstrip().startswith("#")]
    return np.array(rows, dtype=float)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=from_config("RUN_ROOT", os.path.expandvars("$SCRATCH/dtc_ffd")),
                    help="RUN_ROOT of the pipeline (default: from config.sh)")
    ap.add_argument("--n-avg", type=int, default=500, help="iterations averaged (default 500)")
    ap.add_argument("--out", default=HERE, help="output folder (default: this folder)")
    a = ap.parse_args()

    dirs = sorted(glob.glob(os.path.join(a.root, "runs", "sample_*")),
                  key=lambda d: int(re.findall(r"\d+", os.path.basename(d))[-1]))
    if not dirs:
        sys.exit(f"ERROR: no sample folders in {a.root}/runs")

    fx, W, idx, rows, skipped = [], [], [], [], {}
    for d in dirs:
        i = int(re.findall(r"\d+", os.path.basename(d))[-1])
        try:
            status = open(os.path.join(d, "STATUS")).read().strip()
        except OSError:
            status = "NO_STATUS"
        force = os.path.join(d, "force.dat")
        weights = os.path.join(d, "ffd_weights", f"weights_{i}.npy")
        if status != "DONE" or not os.path.exists(force) or not os.path.exists(weights):
            skipped.setdefault(status if status != "DONE" else "DONE but files missing", []).append(i)
            continue
        data = load_force(force)
        if data.shape[0] < a.n_avg:
            skipped.setdefault(f"fewer than {a.n_avg} rows", []).append(i)
            continue
        f = data[-a.n_avg:, 1].mean()
        fx.append(f); W.append(np.load(weights)); idx.append(i)
        rows.append({"seed": i, "force_x": f, "rows": data.shape[0]})

    for why, ids in skipped.items():
        print(f"skipped ({why}): {len(ids)} -> " + ",".join(map(str, ids[:20])) + (" ..." if len(ids) > 20 else ""))
    if not idx:
        sys.exit("ERROR: no finished samples to collect")
    W = np.vstack(W)
    os.makedirs(a.out, exist_ok=True)
    np.save(os.path.join(a.out, "force_x.npy"), np.array(fx))
    np.save(os.path.join(a.out, "Y.npy"), np.abs(np.array(fx)))
    np.save(os.path.join(a.out, "weights.npy"), W)
    np.save(os.path.join(a.out, "indices.npy"), np.array(idx))
    with open(os.path.join(a.out, "collect.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["seed", "force_x", "rows"]); w.writeheader(); w.writerows(rows)

    print(f"{len(idx)} samples: mean of total_x over the last {a.n_avg} iterations, "
          f"weights {W.shape} -> {a.out}")
    print(f"force_x range {min(fx):.4g} .. {max(fx):.4g}")


if __name__ == "__main__":
    main()
