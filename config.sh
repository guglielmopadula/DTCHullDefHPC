# ---------------------------------------------------------------------------
# DTC hull FFD sampling pipeline -- configuration for CINECA Leonardo
# Sourced by every other script.  Edit the values below, nothing else.
# ---------------------------------------------------------------------------

# --- Slurm ------------------------------------------------------------------
ACCOUNT="CHANGE_ME"            # your project account (see: saldo -b)
PARTITION="dcgp_usr_prod"      # CPU partition (112 cores/node); OpenFOAM is CPU-only.
                               # boost_usr_prod also works but leaves the GPUs idle
QOS="normal"                   # normal: up to 24 h, 16 nodes per job
NPROCS=32                      # MPI ranks per sample = subdomains
DECOMP_METHOD="scotch"         # written into decomposeParDict with numberOfSubdomains =
                               # NPROCS; empty = the case's own (hierarchical (2 2 2), so
                               # NPROCS must be 8)
WALLTIME="24:00:00"            # per job (one sample, or its continuation; the one base-mesh
                               # job); max for QOS normal
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
# Every sample in a RUN_ROOT morphs the same base mesh ($RUN_ROOT/base_mesh);
# a new mesh setup needs a new RUN_ROOT.  (dtc_ffd held the remeshed runs.)
# dtc_ffd_morph: first morphed run (tutorial LTS settings, not converged);
# dtc_ffd_pilot: the 4-sample convergence pilot.
RUN_ROOT="${SCRATCH:?SCRATCH is not set}/dtc_ffd_conv"
BASE_MESH_DIR="${SCRATCH}/dtc_ffd_morph/base_mesh"
                               # empty = $RUN_ROOT/base_mesh; another run's base_mesh
                               # reuses its mesh (same base case and snappyHexMeshDict)

# --- Simulation -------------------------------------------------------------
END_TIME=16000                 # LTS iterations (written into the case's controlDict); the
                               # pilot settled near 13000-14000 with the LTS values below
WRITE_INTERVAL=""              # empty = write fields only at END_TIME; e.g. 100 keeps
                               # every 100th iteration (~40x the disk per sample)
KEEP_FIELDS=1                  # 1 = reconstruct and keep the final fields, 0 = forces only
SKIP_FOLDED=0                  # 1 = do not simulate hulls with inverted triangles
N_AVG=2000                     # last iterations averaged for the drag in Y.npy; summary.csv
                               # also reports the drift between the two halves of this window
# LTS controls of the case (PIMPLE in system/fvSolution); empty = the case's value
# (tutorial: 10, 5, 0.5).  With the tutorial values the drag still wanders by
# +-0.3 N after 4000 iterations; with these it converges (pilot: drift < 0.02 N).
MAX_CO=3
MAX_ALPHA_CO=1
RDT_DAMPING=0.2                # rDeltaTDampingCoeff

# --- Weights ----------------------------------------------------------------
FFD_SCALE=0.05                 # std of the random weights, in box lengths (truncated at
                               # 3 std).  0.02: hull moves 2-3.5 mm; 0.05: 6-9 mm, morphed
                               # mesh as good as the base; 0.1: 11-18 mm, some meshes reach
                               # 85 deg non-orthogonality; 0.2: hulls fold
WEIGHTS_FILE=""                # empty = random weights (seed = sample index);
                               # an ABSOLUTE path to a .npy of shape (N, 86):
                               # sample i uses row i (columns in mask_ffd.npy order)
WEIGHTS_NO_FIX=0               # 1 = use the loaded weights without the volume fix

# --- Software ---------------------------------------------------------------
# OpenFOAM: either Leonardo's module (openfoam+ is OpenFOAM.com) ...
# An 'SHSTK and AVX512_FP16' error means the build does not match the node's CPU:
# try the other partition, another module (module av openfoam) or FOAM_BASHRC.
OPENFOAM_MODULES="profile/eng openfoam+/2106"   # loaded in order; check: module av openfoam
# ... or your own build: set this to its etc/bashrc and the modules are skipped
FOAM_BASHRC=""                 # e.g. "$WORK/OpenFOAM-v2506/etc/bashrc"

PYTHON_MODULE="python"         # check with: module av python

# --- Overrides --------------------------------------------------------------
# PIPE_CONFIG=pilot.conf ./submit.sh  (and ./status.sh) sources that file after
# this one, so a test run changes a few values without editing this file.
if [ -n "$PIPE_CONFIG" ]; then
    case "$PIPE_CONFIG" in /*) ;; *) PIPE_CONFIG="$PIPE_HOME/$PIPE_CONFIG" ;; esac
    source "$PIPE_CONFIG" || { echo "ERROR: cannot read PIPE_CONFIG=$PIPE_CONFIG" >&2; return 1 2>/dev/null || exit 1; }
    export PIPE_CONFIG                 # absolute, for the jobs
fi
BASE_MESH_DIR="${BASE_MESH_DIR:-$RUN_ROOT/base_mesh}"
