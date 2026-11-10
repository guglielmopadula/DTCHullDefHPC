#!/bin/bash
# One array task = continue one finished sample from its latest fields to END_TIME.
# Submitted by ./submit.sh --continue, which passes the #SBATCH options.
#
# Needs a sample finished with KEEP_FIELDS=1 (its last time directory holds the
# fields).  The sample folder is kept; force.dat becomes the rows of the earlier
# run up to the restart time followed by the new rows, so the drag history is
# continuous.  The LTS settings (MAX_CO, ...) of the current config apply to
# the new part.
set -eEo pipefail
: "${PIPE_HOME:?PIPE_HOME not set, submit with submit.sh --continue}"
source "$PIPE_HOME/config.sh"
source "$PIPE_HOME/env.sh"

i="${SLURM_ARRAY_TASK_ID:?not an array task}"
id="$(printf '%03d' "$i")"
RUN="$RUN_ROOT/runs/sample_$id"

if [ ! -d "$RUN/DTCHull" ] || [ ! -f "$RUN/force.dat" ]; then
    echo "ERROR: sample $id has no finished case in $RUN to continue" >&2
    exit 1
fi
cd "$RUN"

step="setup"
trap 'echo "FAILED:continue:$step" > "$RUN/STATUS"; echo "sample $id FAILED at step: continue:$step" >&2' ERR

last=$(awk '!/^#/ && NF {t = $1} END {print t + 0}' force.dat)
if awk -v s="$last" -v e="$END_TIME" 'BEGIN{exit !(s >= e)}'; then
    echo "sample $id already at iteration $last >= END_TIME $END_TIME, skipping"
    echo DONE > STATUS
    exit 0
fi

echo RUNNING > STATUS
echo "sample $id: continue from iteration $last to $END_TIME on $(hostname)," \
     "job ${SLURM_ARRAY_JOB_ID}_${i}, $(date)"

step="openfoam_env"
load_openfoam
step="openfoam"
if ! DECOMP_METHOD="$DECOMP_METHOD" MAX_CO="$MAX_CO" MAX_ALPHA_CO="$MAX_ALPHA_CO" RDT_DAMPING="$RDT_DAMPING" \
     bash "$PIPE_HOME/run_case.sh" continue "$RUN/DTCHull" "$NPROCS" "$END_TIME" "$KEEP_FIELDS" "$WRITE_INTERVAL"; then
    step="openfoam:$(cat "$RUN/DTCHull/LAST_STEP" 2>/dev/null || echo unknown)"
    false
fi

# --- joined force history: earlier rows up to the restart time + the new rows --
step="collect"
start=$(ls -d DTCHull/postProcessing/forces/*/ | xargs -n1 basename | sort -g | tail -1)
new="DTCHull/postProcessing/forces/$start/force.dat"
awk -v s="$start" '/^#/ || !NF || $1 + 0 <= s + 0' force.dat > force.dat.tmp
awk '!/^#/ && NF' "$new" >> force.dat.tmp
mv force.dat.tmp force.dat
echo "force.dat: $(grep -vc '^#' force.dat) iterations"

# the earlier fields are superseded by the new ones (saves space on $SCRATCH)
if [ "$KEEP_FIELDS" = "1" ] && [ -d "DTCHull/$END_TIME" ] && [ "$start" != "0" ] && [ "$start" != "$END_TIME" ]; then
    rm -rf "DTCHull/$start"
fi

echo DONE > STATUS
echo "sample $id continued to $END_TIME, $(date)"
