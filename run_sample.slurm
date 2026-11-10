#!/bin/bash
# One array task = one FFD sample: deform the hull, morph the base mesh, solve.
# Submitted by submit.sh, which passes all #SBATCH options on the command line.
#
# Output folder $RUN_ROOT/runs/sample_XXX:
#   DTCHull/                   the deformed OpenFOAM case
#   ffd_weights/weights_i.npy  FFD weights (columns follow mask_ffd.npy)
#   mask_ffd.npy               free-component mask, (nx, ny, nz, 3)
#   surface_check.json         inverted triangles, volume defect, max displacement
#   mesh_morph.json            mesh points moved, max displacement of the volume mesh
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
[ -d "$RUN" ] && chmod -R u+w "$RUN"     # copies of the read-only DTCHull_bak
rm -rf "$RUN"
mkdir -p "$RUN/ffd_weights"
cd "$RUN"

step="setup"
trap 'echo "FAILED:$step" > "$RUN/STATUS"; echo "sample $id FAILED at step: $step" >&2' ERR
echo RUNNING > STATUS
echo "sample $id on $(hostname), job ${SLURM_ARRAY_JOB_ID}_${i}, $(date)"

# the undeformed mesh, made once by mesh_base.slurm (submit.sh makes the
# array wait for it)
step="base_mesh"
BASE_MESH="$BASE_MESH_DIR/DTCHull/constant/polyMesh"
if [ "$(cat "$BASE_MESH_DIR/STATUS" 2>/dev/null)" != "DONE" ]; then
    echo "ERROR: no finished base mesh in $BASE_MESH_DIR (submit with submit.sh)" >&2
    false
fi

step="copy_case"
ln -s "$PIPE_HOME/DTCHull_bak" DTCHull_bak          # undeformed hull, read-only
cp -r "$PIPE_HOME/DTCHull_bak" DTCHull
chmod -R u+w DTCHull                 # cp keeps DTCHull_bak's read-only modes
cp -r "$BASE_MESH" DTCHull/constant/polyMesh

# --- 1. deform the hull --------------------------------------------------------
step="mv_points"
load_python
mv_args=()
if [ -n "$WEIGHTS_FILE" ]; then mv_args+=(--weights "$WEIGHTS_FILE")
else mv_args+=(--scale "$FFD_SCALE"); fi
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

# --- 2. morph the base mesh with the same FFD ---------------------------------
step="morph_mesh"
"$PY" "$PIPE_HOME/code/morph_mesh.py" "$i" > log.morph_mesh 2>&1
cat log.morph_mesh

# --- 3. solve -------------------------------------------------------------------
step="openfoam_env"
load_openfoam
step="openfoam"
# runs inside a subshell so a failure inside reports the OpenFOAM step itself
if ! DECOMP_METHOD="$DECOMP_METHOD" MAX_CO="$MAX_CO" MAX_ALPHA_CO="$MAX_ALPHA_CO" RDT_DAMPING="$RDT_DAMPING" \
     bash "$PIPE_HOME/run_case.sh" solve "$RUN/DTCHull" "$NPROCS" "$END_TIME" "$KEEP_FIELDS" "$WRITE_INTERVAL"; then
    step="openfoam:$(cat "$RUN/DTCHull/LAST_STEP" 2>/dev/null || echo unknown)"
    false
fi

step="collect"
cp DTCHull/postProcessing/forces/0/force.dat force.dat
echo DONE > STATUS
echo "sample $id done, $(date)"
