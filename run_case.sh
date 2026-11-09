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
set -eo pipefail
mode="${1:?usage: run_case.sh mesh|solve <caseDir> ...}"
case_dir="${2:?caseDir}"
cd "$case_dir"
. "${WM_PROJECT_DIR:?OpenFOAM not loaded}/bin/tools/RunFunctions"

step() { echo "$1" > LAST_STEP; echo "== $1  $(date +%T)"; }

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

    # --- decomposition: the case's own decomposeParDict, unchanged -----------
    step decomposeParDict
    nsub="$(foamDictionary -entry numberOfSubdomains -value system/decomposeParDict)"
    if [ "$nsub" != "$np" ]; then
        echo "ERROR: decomposeParDict has $nsub subdomains but the job has $np ranks;" \
             "set NPROCS=$nsub in config.sh" >&2
        exit 1
    fi
    echo "decomposition: $nsub subdomains," \
         "$(foamDictionary -entry method -value system/decomposeParDict)"

    # --- run length ------------------------------------------------------------
    if [ -n "$end_time" ]; then
        step controlDict
        foamDictionary -entry endTime -set "$end_time" system/controlDict > /dev/null
        foamDictionary -entry writeInterval -set "$write_interval" system/controlDict > /dev/null
        echo "endTime $end_time, writeInterval $write_interval"
    fi

    # --- LTS controls (empty = keep the case's value) -------------------------
    step fvSolution
    for kv in "maxCo=${MAX_CO:-}" "maxAlphaCo=${MAX_ALPHA_CO:-}" "rDeltaTDampingCoeff=${RDT_DAMPING:-}"; do
        k="${kv%%=*}"; v="${kv#*=}"
        [ -n "$v" ] && foamDictionary -entry "PIMPLE/$k" -set "$v" system/fvSolution > /dev/null
        echo "PIMPLE/$k $(foamDictionary -entry "PIMPLE/$k" -value system/fvSolution)"
    done

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

*)
    echo "ERROR: unknown mode '$mode' (mesh or solve)" >&2; exit 1 ;;
esac
