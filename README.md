# DTC hull FFD sampling on CINECA Leonardo

Generates free-form deformations (FFD) of the bulb of the Duisburg Test Case (DTC)
container ship, meshes and solves each deformed hull with OpenFOAM (`interFoam`, local
time stepping), and collects the drag together with the FFD weights that produced it.
Each sample is one task of a Slurm job array, in its own folder in `$SCRATCH`.

```
$SCRATCH/dtc_ffd/
  runs/sample_000/ … sample_099/   one complete case per sample
  logs/                            Slurm output, sample_<i>.<jobid>.out
  results/                         written by the gather job
```

## Contents

| file | role |
|---|---|
| `config.sh` | every setting: account, partition, resources, samples, weights, software |
| `setup.sh` | one-time install: base case, Python venv, smoke test |
| `submit.sh` | submits the sample array and the gather job |
| `run_sample.slurm` | one sample: deform, check, mesh, solve |
| `run_case.sh` | the OpenFOAM steps of one case |
| `env.sh` | loads Python and OpenFOAM on the compute nodes |
| `status.sh` | progress, and the failing step of failed samples |
| `gather.slurm`, `code/gather.py` | after the array: `results/` with forces, weights and a summary |
| `collect.py` | mean x-force over the last 500 iterations + stacked weights, to this folder |
| `generate_stls_local.py` | deformed STLs only, on a laptop (no OpenFOAM, no Slurm) |
| `code/mv_points.py` | draws (or loads) the FFD weights, fixes the volume, writes the STL |
| `code/my_ffd.py` | Bernstein FFD and the volume-preserving correction |
| `code/check_surface.py` | inverted triangles, volume defect and displacement of a deformed hull |

The DTC OpenFOAM case (`DTCHull_bak`) is not part of the repository; `setup.sh` installs it
from a zip or folder.

## Quick start

On a login node (`ssh <user>@login.leonardo.cineca.it`):

```bash
git clone <this repository> leonardo_pipeline && cd leonardo_pipeline
./setup.sh /path/to/DTCHull_bak.zip    # base case + venv (numpy, scipy, meshio) + test of sample 0
nano config.sh                         # at least ACCOUNT (saldo -b)
./submit.sh 0                          # one sample first
./status.sh -v                         # progress; failed samples with their step
./submit.sh                            # the rest; finished samples are skipped
venv/bin/python collect.py             # force_x.npy, Y.npy, weights.npy, indices.npy here
```

`./submit.sh 7,12,40-45` submits only those samples. Finished samples are always skipped and
failed ones are wiped and rerun, so resubmitting a range is safe. Do not resubmit a sample
that is still running: a second task for it would restart it.

## One sample (`run_sample.slurm`)

1. copies the base case to `runs/sample_XXX/DTCHull` and links the undeformed one as `DTCHull_bak`
2. `code/mv_points.py <i>` deforms the hull STL inside the FFD box and writes
   `ffd_weights/weights_<i>.npy` and `mask_ffd.npy`
3. `code/check_surface.py <i>` writes `surface_check.json` (inverted triangles, volume defect,
   maximum displacement)
4. `run_case.sh`
   - mesh, serial: surfaceFeatureExtract, blockMesh, 6 x topoSet/refineMesh, snappyHexMesh, checkMesh
   - solve on `NPROCS` ranks: restore0Dir, setFields, decomposePar with the case's own
     `decomposeParDict` (8 subdomains, hierarchical), renumberMesh, interFoam for `END_TIME`
     iterations, reconstructPar
5. copies `postProcessing/forces/0/force.dat` to the sample folder and writes `STATUS`
   (`DONE`, `FAILED:<step>` or `SKIPPED_FOLDED`)

## FFD weights

- 5 x 5 x 5 Bernstein lattice on the box origin (5.80, -0.10, -0.05), size (0.50, 0.10, 0.33) m
- free: the interior 3 x 3 x 3 control points (x, y, z) plus the x-components of the edge
  `[4, 4, :]`, 86 weights in total; the outer layer is frozen, so the hull is unchanged at
  the box boundary
- random draw: truncated normal, standard deviation 0.02 box lengths, cut at +-3 sigma,
  seed = sample index
- every weight set is corrected so that the hull keeps its volume (`code/my_ffd.py`)
- saved order: the (nx, ny, nz, 3) lattice flattened, free entries only (`mask_ffd.npy`)

### Using stored weights

Set an absolute path in `config.sh`; sample `i` then uses row `i`:

```bash
WEIGHTS_FILE="/leonardo_work/<project>/weights.npy"   # shape (N, 86), mask_ffd.npy column order
WEIGHTS_NO_FIX=0                                      # 1 = use them exactly, without the volume fix
```

`submit.sh` checks the path, the shape and that every submitted index has a row. Weights
written by this pipeline are already volume-corrected, so the fix leaves them unchanged.
By hand: `python code/mv_points.py 7 --weights weights.npy [--no-fix]`.

## Settings (`config.sh`)

| | default | |
|---|---|---|
| `PARTITION` | `dcgp_usr_prod` | CPU nodes; `boost_usr_prod` works but leaves the GPUs idle |
| `NPROCS` | 8 | must equal `numberOfSubdomains` of the case; checked before solving |
| `WALLTIME` / `MEM` | 24:00:00 / 32G | per sample; check with `seff <jobid>_0` |
| `MAX_CONCURRENT` | 20 | samples running at once |
| `END_TIME` | 4000 | LTS iterations |
| `WRITE_INTERVAL` | = `END_TIME` | fields written at the end only |
| `KEEP_FIELDS` | 1 | 0 = keep forces only |
| `SKIP_FOLDED` | 0 | 1 = do not simulate self-intersecting hulls |
| `OPENFOAM_MODULES` | `profile/eng openfoam+` | or `FOAM_BASHRC` for your own build |

## Results

`collect.py` (run any time, on a login node) writes to this folder:

| file | |
|---|---|
| `force_x.npy` | mean `total_x` over the last 500 iterations, signed |
| `Y.npy` | its absolute value, the drag |
| `weights.npy` | FFD weights, same row order, (n, 86) |
| `indices.npy` | sample index of each row |
| `collect.csv` | sample, force, iterations in `force.dat` |

Only samples with `STATUS = DONE` and at least 500 iterations are included; the others are
listed. `--n-avg`, `--root` and `--out` change the window, the run folder and the output.

The gather job writes a similar set to `$SCRATCH/dtc_ffd/results/`, plus copies of every
`force.dat` and `summary.csv` with the surface checks.

## Deformed hulls on a laptop

```bash
pip install numpy scipy meshio
python generate_stls_local.py --base DTCHull_bak.zip --out deformed_stls --n 100
```

Writes `stl/DTC-scaled_<i>.stl`, the weights, `checks/surface_check_<i>.json` and
`summary.csv`, using the same `code/` as the cluster jobs (about 5 s per hull).

## Troubleshooting

| symptom | cause |
|---|---|
| `FAILED:mv_points` | `runs/sample_XXX/log.mv_points`; with stored weights usually a relative path or wrong shape |
| `FAILED:openfoam_env` | module not found: `module av openfoam`, set `OPENFOAM_MODULES` or `FOAM_BASHRC` |
| `SHSTK and AVX512_FP16` in the log | the OpenFOAM build does not match the node's CPU: other partition or module |
| `FAILED:openfoam:<step>` | `runs/sample_XXX/DTCHull/log.<step>` |
| sample skipped as `DONE` | an earlier run is in the way: clear `runs/` or set another `RUN_ROOT` |

`$SCRATCH` deletes files not accessed for 40 days: copy what you keep to `$WORK`.

Reference for the DTC: el Moctar, O., Shigunov, V., Zorn, T. (2012). Duisburg Test Case:
Post-Panamax container ship for benchmarking. Ship Technology Research 59(3), 50-64.
