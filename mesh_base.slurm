#!/bin/bash
# Meshes the undeformed hull once, in $RUN_ROOT/base_mesh/DTCHull.
# Submitted by submit.sh when the base mesh is missing; the sample array waits
# for it (afterok) and morphs a copy of constant/polyMesh in every sample.
#
#   base_mesh/DTCHull/   meshed undeformed case (log.snappyHexMesh, log.checkMesh)
#   base_mesh/STATUS     RUNNING | DONE | FAILED:<step>
#
# To remesh (other snappyHexMeshDict, other base case): delete base_mesh/ and
# use a new RUN_ROOT, so that every sample in a run shares the same mesh.
set -eEo pipefail
: "${PIPE_HOME:?PIPE_HOME not set, submit with submit.sh}"
source "$PIPE_HOME/config.sh"
source "$PIPE_HOME/env.sh"

B="$RUN_ROOT/base_mesh"
if [ "$(cat "$B/STATUS" 2>/dev/null)" = "DONE" ]; then
    echo "base mesh already done: $B"; exit 0
fi
rm -rf "$B"
mkdir -p "$B"
cd "$B"

step="setup"
trap 'echo "FAILED:$step" > "$B/STATUS"; echo "base mesh FAILED at step: $step" >&2' ERR
echo RUNNING > STATUS
echo "base mesh on $(hostname), job ${SLURM_JOB_ID}, $(date)"

cp -r "$PIPE_HOME/DTCHull_bak" DTCHull
chmod -R u+w DTCHull

step="openfoam_env"
load_openfoam
step="mesh"
if ! bash "$PIPE_HOME/run_case.sh" mesh "$B/DTCHull"; then
    step="mesh:$(cat "$B/DTCHull/LAST_STEP" 2>/dev/null || echo unknown)"
    false
fi
[ -f DTCHull/constant/polyMesh/points ] || [ -f DTCHull/constant/polyMesh/points.gz ] \
    || { step="mesh:no-points"; false; }

echo DONE > STATUS
echo "base mesh done, $(date)"
