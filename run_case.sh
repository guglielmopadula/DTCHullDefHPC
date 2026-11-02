#!/bin/bash
# Mesh and solve one DTC case:
#     run_case.sh <caseDir> <nProcs> [endTime] [keepFields] [writeInterval]
#
# Meshing is the case's Allrun (surfaceFeatureExtract, blockMesh, 6 x
# topoSet/refineMesh, snappyHexMesh, checkMesh); solving is Allrun_bak, with
# the 0/ directory restored from 0.orig first (Allrun_bak alone would fail:
# the case ships only 0.orig).  Needs the OpenFOAM environment loaded.
set -eo pipefail
case_dir="${1:?caseDir}"; np="${2:?nProcs}"; end_time="${3:-}"; keep="${4:-1}"
write_interval="${5:-$end_time}"
cd "$case_dir"
. "${WM_PROJECT_DIR:?OpenFOAM not loaded}/bin/tools/RunFunctions"

step() { echo "$1" > LAST_STEP; echo "== $1  $(date +%T)"; }

# --- decomposition: the case's own decomposeParDict, unchanged ---------------
step decomposeParDict
nsub="$(foamDictionary -entry numberOfSubdomains -value system/decomposeParDict)"
if [ "$nsub" != "$np" ]; then
    echo "ERROR: decomposeParDict has $nsub subdomains but the job has $np ranks;" \
         "set NPROCS=$nsub in config.sh" >&2
    exit 1
fi
echo "decomposition: $nsub subdomains," \
     "$(foamDictionary -entry method -value system/decomposeParDict)"

# --- run length -----------------------------------------------------------------
if [ -n "$end_time" ]; then
    step controlDict
    foamDictionary -entry endTime -set "$end_time" system/controlDict > /dev/null
    foamDictionary -entry writeInterval -set "$write_interval" system/controlDict > /dev/null
    echo "endTime $end_time, writeInterval $write_interval"
fi

# --- mesh (serial) -------------------------------------------------------------
step surfaceFeatureExtract; runApplication surfaceFeatureExtract
step blockMesh;             runApplication blockMesh
for i in 1 2 3 4 5 6; do
    step "topoSet.$i";    runApplication -s "$i" topoSet -dict "system/topoSetDict.$i"
    step "refineMesh.$i"; runApplication -s "$i" refineMesh -dict system/refineMeshDict -overwrite
done
step snappyHexMesh;         runApplication snappyHexMesh -overwrite
step checkMesh
checkMesh > log.checkMesh 2>&1 || true            # reported, not fatal
grep -E "Mesh OK|Failed [0-9]+ mesh checks" log.checkMesh || true

# --- solve (parallel) ------------------------------------------------------------
step restore0Dir;           restore0Dir
step setFields;             runApplication setFields
step decomposePar;          runApplication decomposePar
step renumberMesh;          runParallel renumberMesh -overwrite
step "$(getApplication)";   runParallel "$(getApplication)"

if [ "$keep" = "1" ]; then
    step reconstructPar;    runApplication reconstructPar -latestTime
fi
rm -rf processor*                                  # saves space and inodes on $SCRATCH

[ -s postProcessing/forces/0/force.dat ] || { step "forces-missing"; exit 1; }
step finished
