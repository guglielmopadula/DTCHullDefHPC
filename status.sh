#!/bin/bash
# Progress of the samples:  ./status.sh      (-v lists the failed ones with their step)
PIPE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PIPE_HOME/config.sh"

echo "run root         $RUN_ROOT"
echo "base mesh        $(cat "$BASE_MESH_DIR/STATUS" 2>/dev/null || echo MISSING)"
declare -A count; failed=()
for ((i = FIRST_SAMPLE; i < FIRST_SAMPLE + N_SAMPLES; i++)); do
    d="$RUN_ROOT/runs/$(printf 'sample_%03d' "$i")"
    if [ -f "$d/STATUS" ]; then s="$(cat "$d/STATUS")"; else s="PENDING"; fi
    count["${s%%:*}"]=$(( ${count["${s%%:*}"]:-0} + 1 ))
    [[ "$s" == FAILED* ]] && failed+=("$i:${s#FAILED:}")
done
for k in "${!count[@]}"; do printf '%-16s %d\n' "$k" "${count[$k]}"; done | sort
if [ ${#failed[@]} -gt 0 ]; then
    ids="$(printf '%s\n' "${failed[@]}" | cut -d: -f1 | paste -sd, -)"
    [ "$1" = "-v" ] && printf '  failed %s\n' "${failed[@]}"
    if printf '%s\n' "${failed[@]}" | grep -q ':continue:'; then
        echo "resubmit the failed continuations with: ./submit.sh --continue $ids"
    else
        echo "resubmit the failed ones with: ./submit.sh $ids"
    fi
fi
squeue -u "$USER" -n dtc_ffd_mesh,dtc_ffd,dtc_ffd_cont,dtc_ffd_gather -h -o '%.18i %.10T %.10M %R' 2>/dev/null | head -25
