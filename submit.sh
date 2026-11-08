#!/bin/bash
# Submit the base mesh (once), the sample array and the gather job that runs after it.
#     ./submit.sh            all samples from config.sh
#     ./submit.sh 7,12,40-45 only these indices (finished samples are skipped anyway)
set -eo pipefail
PIPE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PIPE_HOME/config.sh"

[ "$ACCOUNT" != "CHANGE_ME" ] || { echo "ERROR: set ACCOUNT in config.sh (saldo -b)" >&2; exit 1; }
[ -d "$PIPE_HOME/DTCHull_bak" ] && [ -x "$PIPE_HOME/venv/bin/python" ] \
    || { echo "ERROR: run ./setup.sh first" >&2; exit 1; }

range="${1:-$FIRST_SAMPLE-$((FIRST_SAMPLE + N_SAMPLES - 1))}"

# stored weights: every sample opens the file from its own folder, so the path
# must be absolute; and the highest index submitted must have a row
if [ -n "$WEIGHTS_FILE" ]; then
    case "$WEIGHTS_FILE" in
        /*) ;;
        *) echo "ERROR: WEIGHTS_FILE must be an absolute path (got '$WEIGHTS_FILE')" >&2; exit 1 ;;
    esac
    [ -r "$WEIGHTS_FILE" ] || { echo "ERROR: cannot read $WEIGHTS_FILE" >&2; exit 1; }
    top=$(echo "$range" | tr ',' '\n' | sed 's/.*-//' | sort -n | tail -1)
    "$PIPE_HOME/venv/bin/python" - "$WEIGHTS_FILE" "$top" <<'EOF' || exit 1
import sys, numpy as np
w = np.load(sys.argv[1]); top = int(sys.argv[2])
w2 = w[None] if w.ndim == 1 else w
if w2.ndim != 2 or w2.shape[1] != 86:
    sys.exit(f"ERROR: {sys.argv[1]} has shape {w.shape}; expected (N, 86)")
if w.ndim == 2 and top >= len(w):
    sys.exit(f"ERROR: {sys.argv[1]} has {len(w)} rows but sample {top} is submitted")
print(f"weights   : {sys.argv[1]}, shape {w.shape}")
EOF
fi

mkdir -p "$RUN_ROOT/runs" "$RUN_ROOT/logs"

mem_opt=(); [ -n "$MEM" ] && mem_opt=(--mem="$MEM")

# the undeformed mesh every sample morphs: made once per RUN_ROOT
dep=()
if [ "$(cat "$RUN_ROOT/base_mesh/STATUS" 2>/dev/null)" = "DONE" ]; then
    echo "base mesh : $RUN_ROOT/base_mesh (done)"
else
    mid="$(cat "$RUN_ROOT/logs/base_mesh.jobid" 2>/dev/null || true)"
    if [ -n "$mid" ] && squeue -h -j "$mid" 2>/dev/null | grep -q .; then
        echo "base mesh : job $mid still queued or running, the samples wait for it"
    else
        mid=$(sbatch --parsable \
            --job-name=dtc_ffd_mesh \
            --account="$ACCOUNT" --partition="$PARTITION" --qos="$QOS" \
            --time="$WALLTIME" --nodes=1 --ntasks=1 --cpus-per-task=1 "${mem_opt[@]}" \
            --output="$RUN_ROOT/logs/base_mesh.%j.out" \
            --export=ALL,PIPE_HOME="$PIPE_HOME" \
            "$PIPE_HOME/mesh_base.slurm")
        mid="${mid%%;*}"
        echo "$mid" > "$RUN_ROOT/logs/base_mesh.jobid"
        echo "base mesh : job $mid, the samples start when it succeeds"
    fi
    dep=(--dependency=afterok:"$mid")
fi

jid=$(sbatch --parsable \
    --job-name=dtc_ffd \
    --account="$ACCOUNT" --partition="$PARTITION" --qos="$QOS" \
    --time="$WALLTIME" --nodes=1 --ntasks="$NPROCS" --cpus-per-task=1 "${mem_opt[@]}" \
    --array="${range}%${MAX_CONCURRENT}" "${dep[@]}" \
    --output="$RUN_ROOT/logs/sample_%a.%A.out" \
    --export=ALL,PIPE_HOME="$PIPE_HOME" \
    "$PIPE_HOME/run_sample.slurm")
jid="${jid%%;*}"

gid=$(sbatch --parsable \
    --job-name=dtc_ffd_gather \
    --account="$ACCOUNT" --partition="$GATHER_PARTITION" \
    --time="$GATHER_WALLTIME" --ntasks=1 \
    --dependency=afterany:"$jid" \
    --output="$RUN_ROOT/logs/gather.%j.out" \
    --export=ALL,PIPE_HOME="$PIPE_HOME" \
    "$PIPE_HOME/gather.slurm")

echo "samples   : array job $jid, indices $range (max $MAX_CONCURRENT at once)"
echo "gather    : job $gid, runs after the array finishes"
echo "runs      : $RUN_ROOT/runs/sample_XXX"
echo "progress  : ./status.sh"
