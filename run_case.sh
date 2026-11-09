#!/bin/bash
# OpenFOAM steps of the pipeline; needs the OpenFOAM environment loaded.
#
#     run_case.sh mesh  <caseDir>
#         the case's Allrun meshing: surfaceFeatureExtract, blockMesh,
#         6 x topoSet/refineMesh, snappyHexMesh, checkMesh.  Run once, on the
#         undeformed hull, by mesh_base.slurm; every sample morphs a copy.
#
#     [MAX_CO=.. MAX_ALPHA_CO=.. RDT_DAMPING=..] \
#     run_case.sh solve <caseDir> <nProcs> [endTime] [keepFields] [writeInterval]
#         checkMesh of the morphed mesh (inverted cells are fatal), then
#         Allrun_bak with 0/ restored from 0.orig first (Allrun_bak alone would
#         fail: the case ships only 0.orig): setFields, decomposePar,
#         renumberMesh, the solver, reconstructPar.
#
#     [MAX_CO=.. MAX_ALPHA_CO=.. RDT_DAMPING=..] \
#     run_case.sh continue <caseDir> <nProcs> <endTime> [keepFields] [writeInterval]
#         restarts a finished case from its latest reconstructed time (needs
#         keepFields=1 in the first run): decomposePar -latestTime, renumberMesh,
#         the solver from that time to endTime, reconstructPar.  The forces of
#         the new part go to postProcessing/forces/<start time>/force.dat; logs
#         get the suffix .<start time>.
set -eo pipefail
mode="${1:?usage: run_case.sh mesh|solve|continue <caseDir> ...}"
case_dir="${2:?caseDir}"
cd "$case_dir"
. "${WM_PROJECT_DIR:?OpenFOAM not loaded}/bin/tools/RunFunctions"

step() { echo "$1" > LAST_STEP; echo "== $1  $(date +%T)"; }

check_decomposition() {    # the case's own decomposeParDict, unchanged
    step decomposeParDict
    local nsub
    nsub="$(foamDictionary -entry numberOfSubdomains -value system/decomposeParDict)"
    if [ "$nsub" != "$1" ]; then
        echo "ERROR: decomposeParDict has $nsub subdomains but the job has $1 ranks;" \
             "set NPROCS=$nsub in config.sh" >&2
        exit 1
    fi
    echo "decomposition: $nsub subdomains," \
         "$(foamDictionary -entry method -value system/decomposeParDict)"
}

set_run_length() {         # <endTime> <writeInterval>
    step controlDict
    foamDictionary -entry endTime -set "$1" system/controlDict > /dev/null
    foamDictionary -entry writeInterval -set "$2" system/controlDict > /dev/null
    echo "endTime $1, writeInterval $2"
}

set_lts() {                # LTS controls from the environment; empty = keep the case's value
    step fvSolution
    local kv k v
    for kv in "maxCo=${MAX_CO:-}" "maxAlphaCo=${MAX_ALPHA_CO:-}" "rDeltaTDampingCoeff=${RDT_DAMPING:-}"; do
        k="${kv%%=*}"; v="${kv#*=}"
        [ -n "$v" ] && foamDictionary -entry "PIMPLE/$k" -set "$v" system/fvSolution > /dev/null
        echo "PIMPLE/$k $(foamDictionary -entry "PIMPLE/$k" -value system/fvSolution)"
    done
}

latest_time() {            # largest numeric time directory other than 0
    ls -d [0-9]* 2>/dev/null | grep -E '^[0-9.e+-]+$' | sort -g | tail -1
}

case "$mode" in
mesh)
    step surfaceFeatureExtract; runApplication surfaceFeatureExtract
    step blockMesh;             runApplication blockMesh
    for i in 1 2 3 4 5 6; do
        step "topoSet.$i";    runApplication -s "$i" topoSet -dict "system/topoSetDict.$i"
        step "refineMesh.$i"; runApplication -s "$i" refineMesh -dict system/refineMeshDict -overwrite
    done
    step snappyHexMesh;         runApplication snappyHexMesh -overwrite
    step checkMesh
    checkMesh > log.checkMesh 2>&1 || true        # reported, not fatal
    grep -E "Mesh OK|Failed [0-9]+ mesh checks" log.checkMesh || true
    step finished
    ;;

solve)
    np="${3:?nProcs}"; end_time="${4:-}"; keep="${5:-1}"; write_interval="${6:-$end_time}"

    check_decomposition "$np"
    foamDictionary -entry startFrom -set startTime system/controlDict > /dev/null
    [ -n "$end_time" ] && set_run_length "$end_time" "$write_interval"
    set_lts

    # --- morphed mesh: inverted cells are fatal, other failed checks reported --
    step checkMesh
    checkMesh > log.checkMesh 2>&1 || true
    grep -E "Mesh OK|Failed [0-9]+ mesh checks" log.checkMesh || true
    if grep -qE "Zero or negative cell volume|Error in face pyramids" log.checkMesh; then
        echo "ERROR: the morphed mesh has inverted cells (log.checkMesh)" >&2
        exit 1
    fi

    # --- solve (parallel) ------------------------------------------------------
    step restore0Dir;           restore0Dir
    step setFields;             runApplication setFields
    step decomposePar;          runApplication decomposePar
    step renumberMesh;          runParallel renumberMesh -overwrite
    step "$(getApplication)";   runParallel "$(getApplication)"

    if [ "$keep" = "1" ]; then
        step reconstructPar;    runApplication reconstructPar -latestTime
    fi
    rm -rf processor*                              # saves space and inodes on $SCRATCH

    [ -s postProcessing/forces/0/force.dat ] || { step "forces-missing"; exit 1; }
    step finished
    ;;

continue)
    np="${3:?nProcs}"; end_time="${4:?endTime}"; keep="${5:-1}"; write_interval="${6:-$end_time}"
    step restart-time
    start="$(latest_time)"
    if [ -z "$start" ] || [ ! -f "$start/alpha.water" ]; then
        echo "ERROR: no reconstructed fields to restart from in $case_dir" \
             "(the first run needs KEEP_FIELDS=1)" >&2
        exit 1
    fi
    if awk -v s="$start" -v e="$end_time" 'BEGIN{exit !(s+0 >= e+0)}'; then
        echo "ERROR: the case is already at time $start >= endTime $end_time" >&2
        exit 1
    fi
    echo "restart from time $start to $end_time"

    check_decomposition "$np"
    foamDictionary -entry startFrom -set latestTime system/controlDict > /dev/null
    set_run_length "$end_time" "$write_interval"
    set_lts

    # leftovers of an interrupted attempt from the same start time
    rm -rf processor* "postProcessing/forces/$start"
    rm -f log.*."$start"

    step decomposePar;          runApplication -s "$start" decomposePar -latestTime
    step renumberMesh;          runParallel -s "$start" renumberMesh -overwrite
    step "$(getApplication)";   runParallel -s "$start" "$(getApplication)"
    if [ "$keep" = "1" ]; then
        step reconstructPar;    runApplication -s "$start" reconstructPar -latestTime
    fi
    rm -rf processor*

    [ -s "postProcessing/forces/$start/force.dat" ] || { step "forces-missing"; exit 1; }
    step finished
    ;;

*)
    echo "ERROR: unknown mode '$mode' (mesh, solve or continue)" >&2; exit 1 ;;
esac
