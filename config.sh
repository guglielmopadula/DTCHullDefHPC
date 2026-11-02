# ---------------------------------------------------------------------------
# DTC hull FFD sampling pipeline -- configuration for CINECA Leonardo
# Sourced by every other script.  Edit the values below, nothing else.
# ---------------------------------------------------------------------------

# --- Slurm ------------------------------------------------------------------
ACCOUNT="CHANGE_ME"            # your project account (see: saldo -b)
PARTITION="dcgp_usr_prod"      # CPU partition (112 cores/node); OpenFOAM is CPU-only.
                               # boost_usr_prod also works but leaves the GPUs idle
QOS="normal"                   # normal: up to 24 h, 16 nodes per job
NPROCS=8                       # MPI ranks; must equal numberOfSubdomains in the
                               # case's decomposeParDict (8, hierarchical (2 2 2))
WALLTIME="24:00:00"            # per sample: serial meshing + 4000 iterations (max for QOS normal)
MEM="32G"                      # per job (one node); empty = Slurm default per core
MAX_CONCURRENT=20              # array throttle: samples running at once

GATHER_PARTITION="lrd_all_serial"   # budget-free serial partition
GATHER_WALLTIME="00:30:00"

# --- Samples ----------------------------------------------------------------
FIRST_SAMPLE=0
N_SAMPLES=100                  # samples FIRST_SAMPLE .. FIRST_SAMPLE+N_SAMPLES-1
                               # (random seeds, or rows of WEIGHTS_FILE)

# --- Storage ----------------------------------------------------------------
# One folder per sample: $RUN_ROOT/runs/sample_XXX
# $SCRATCH is purged for files not accessed in 40 days: copy results/ away.
RUN_ROOT="${SCRATCH:?SCRATCH is not set}/dtc_ffd"

# --- Simulation -------------------------------------------------------------
END_TIME=4000                  # LTS iterations (the shipped controlDict says 100)
WRITE_INTERVAL=""              # empty = write fields only at END_TIME; e.g. 100 keeps
                               # every 100th iteration (~40x the disk per sample)
KEEP_FIELDS=1                  # 1 = reconstruct and keep the final fields, 0 = forces only
SKIP_FOLDED=0                  # 1 = do not simulate hulls with inverted triangles
N_AVG=500                      # iterations averaged for the drag in Y.npy (as compute_sas.py)

# --- Weights ----------------------------------------------------------------
WEIGHTS_FILE=""                # empty = random weights (seed = sample index);
                               # an ABSOLUTE path to a .npy of shape (N, 86):
                               # sample i uses row i (columns in mask_ffd.npy order)
WEIGHTS_NO_FIX=0               # 1 = use the loaded weights without the volume fix

# --- Software ---------------------------------------------------------------
# OpenFOAM: either Leonardo's module (openfoam+ is OpenFOAM.com; v2512 in Nov 2026) ...
# An 'SHSTK and AVX512_FP16' error means the build does not match the node's CPU:
# try the other partition, another module (module av openfoam) or FOAM_BASHRC.
OPENFOAM_MODULES="profile/eng openfoam+"   # loaded in order; check: module av openfoam
# ... or your own build: set this to its etc/bashrc and the modules are skipped
FOAM_BASHRC=""                 # e.g. "$WORK/OpenFOAM-v2506/etc/bashrc"

PYTHON_MODULE="python"         # check with: module av python
