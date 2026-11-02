#!/bin/bash
# One array task = one FFD sample: deform the hull, mesh, solve.
# Submitted by submit.sh, which passes all #SBATCH options on the command line.
#
# Output folder $RUN_ROOT/runs/sample_XXX:
#   DTCHull/                   the deformed OpenFOAM case
#   ffd_weights/weights_i.npy  FFD weights (columns follow mask_ffd.npy)
#   mask_ffd.npy               free-component mask, (nx, ny, nz, 3)
#   surface_check.json         inverted triangles, volume defect, max displacement
#   force.dat                  copy of postProcessing/forces/0/force.dat
#   STATUS                     RUNNING | DONE | FAILED:<step> | SKIPPED_FOLDED
#   log.*                      logs of the Python steps
set -eEo pipefail                    # -E: the ERR trap also fires inside functions
: "${PIPE_HOME:?PIPE_HOME not set, submit with submit.sh}"
source "$PIPE_HOME/config.sh"
source "$PIPE_HOME/env.sh"

i="${SLURM_ARRAY_TASK_ID:?not an array task}"
id="$(printf '%03d' "$i")"
RUN="$RUN_ROOT/runs/sample_$id"

if [ "$(cat "$RUN/STATUS" 2>/dev/null)" = "DONE" ]; then
    echo "sample $id already done, skipping"; exit 0
fi

# a previous failed attempt is wiped: OpenFOAM's runApplication refuses to
# overwrite existing logs, and a half-meshed case is not worth recovering
rm -rf "$RUN"
mkdir -p "$RUN/ffd_weights"
cd "$RUN"

step="setup"
trap 'echo "FAILED:$step" > "$RUN/STATUS"; echo "sample $id FAILED at step: $step" >&2' ERR
echo RUNNING > STATUS
echo "sample $id on $(hostname), job ${SLURM_ARRAY_JOB_ID}_${i}, $(date)"

ln -s "$PIPE_HOME/DTCHull_bak" DTCHull_bak          # undeformed hull, read-only
cp -r "$PIPE_HOME/DTCHull_bak" DTCHull
chmod -R u+w DTCHull

# --- 1. deform the hull --------------------------------------------------------
step="mv_points"
load_python
mv_args=()
[ -n "$WEIGHTS_FILE" ] && mv_args+=(--weights "$WEIGHTS_FILE")
[ "$WEIGHTS_NO_FIX" = "1" ] && mv_args+=(--no-fix)
"$PY" "$PIPE_HOME/code/mv_points.py" "$i" "${mv_args[@]}" > log.mv_points 2>&1
step="check_surface"
"$PY" "$PIPE_HOME/code/check_surface.py" "$i" > log.check_surface 2>&1
cat log.check_surface

if [ "$SKIP_FOLDED" = "1" ] && grep -q '"folded": true' surface_check.json; then
    echo SKIPPED_FOLDED > STATUS
    echo "sample $id has inverted triangles, not simulated (SKIP_FOLDED=1)"
    exit 0
fi

# --- 2. mesh and solve ------------------------------------------------------------
step="openfoam_env"
load_openfoam
step="openfoam"
# runs inside a subshell so a failure inside reports the OpenFOAM step itself
if ! bash "$PIPE_HOME/run_case.sh" "$RUN/DTCHull" "$NPROCS" "$END_TIME" "$KEEP_FIELDS" "$WRITE_INTERVAL"; then
    step="openfoam:$(cat "$RUN/DTCHull/LAST_STEP" 2>/dev/null || echo unknown)"
    false
fi

step="collect"
cp DTCHull/postProcessing/forces/0/force.dat force.dat
echo DONE > STATUS
echo "sample $id done, $(date)"
