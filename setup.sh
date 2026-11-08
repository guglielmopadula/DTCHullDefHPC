#!/bin/bash
# One-time setup, run on a Leonardo login node from inside this folder:
#     ./setup.sh                               base case from $FOAM_TUTORIALS
#     ./setup.sh /path/to/DTCHull_bak.zip      or from your own zip / folder
#
# - installs the base case as ./DTCHull_bak, without any generated mesh: by
#   default the DTCHull tutorial of the OpenFOAM in OPENFOAM_MODULES /
#   FOAM_BASHRC (multiphase/interFoam/RAS/DTCHull), with the hull STL from
#   resources/geometry, unpacked to constant/triSurface/DTC-scaled.stl
# - builds a Python venv with numpy, scipy and meshio
# - runs mv_points.py for seed 0 as a smoke test
set -eo pipefail
PIPE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPE_HOME
source "$PIPE_HOME/config.sh"
source "$PIPE_HOME/env.sh"

src="${1:-}"
base="$PIPE_HOME/DTCHull_bak"
stl="$base/constant/triSurface/DTC-scaled.stl"

# --- base case ---------------------------------------------------------------
if [ -e "$base" ]; then
    echo "Base case already present: $base (delete it to reinstall)"
else
    tmp="$(mktemp -d)"
    if [ -z "$src" ]; then
        load_openfoam
        tut="${FOAM_TUTORIALS:?FOAM_TUTORIALS not set by the OpenFOAM environment}"
        case_src="$tut/multiphase/interFoam/RAS/DTCHull"
        [ -d "$case_src" ] || { echo "ERROR: no tutorial $case_src" >&2; exit 1; }
        cp -r "$case_src" "$tmp/DTCHull_bak"
        mkdir -p "$tmp/DTCHull_bak/constant/triSurface"
        if ! ls "$tmp"/DTCHull_bak/constant/triSurface/DTC-scaled.stl* >/dev/null 2>&1; then
            geo="$tut/resources/geometry/DTC-scaled.stl.gz"
            [ -f "$geo" ] || { echo "ERROR: hull STL not found: $geo" >&2; exit 1; }
            cp "$geo" "$tmp/DTCHull_bak/constant/triSurface/"
        fi
        echo "Base case from $case_src ($WM_PROJECT_DIR)"
    elif [ -d "$src" ]; then
        cp -r "$src" "$tmp/"
    else
        unzip -q "$src" -d "$tmp"
    fi
    found="$(find "$tmp" -maxdepth 2 -type d -name DTCHull_bak | head -1)"
    [ -n "$found" ] || { echo "ERROR: no DTCHull_bak folder in $src" >&2; exit 1; }
    # the Python steps read the plain STL
    gz="$found/constant/triSurface/DTC-scaled.stl.gz"
    [ -f "$gz" ] && [ ! -f "${gz%.gz}" ] && gunzip "$gz"
    rm -f "$gz"
    mv "$found" "$base"; rm -rf "$tmp"
    # the base mesh job regenerates these
    rm -rf "$base/constant/polyMesh" "$base/constant/extendedFeatureEdgeMesh" \
           "$base"/processor* "$base/0" "$base"/log.* "$base/postProcessing" \
           "$base/.vscode" "$base/miao.foam"
    chmod -R a-w "$base"      # every sample reads the undeformed hull from here
    echo "Base case installed: $base"
fi
[ -f "$stl" ] || { echo "ERROR: hull STL missing: $stl" >&2; exit 1; }
nsub="$(sed -n 's/^ *numberOfSubdomains *\([0-9]*\);.*/\1/p' "$base/system/decomposeParDict")"
[ "$nsub" = "$NPROCS" ] || echo "WARNING: decomposeParDict has $nsub subdomains," \
    "config.sh has NPROCS=$NPROCS; set them equal or every sample fails"

# --- Python ------------------------------------------------------------------
# Leonardo's python module also loads py-pip, which puts its own pip on
# PYTHONPATH; with that set, the venv's pip imports half of itself from there
# and fails (ImportError: cannot import name 'cli').  So the venv is built and
# filled with PYTHONPATH unset, and it is (re)built whenever the packages do not
# import, not only when it is missing (a failed attempt leaves a broken one).
venv_py() { env -u PYTHONPATH PYTHONNOUSERSITE=1 "$PIPE_HOME/venv/bin/python" "$@"; }
if ! venv_py -c "import numpy, scipy, meshio" 2>/dev/null; then
    module purge
    [ -n "$PYTHON_MODULE" ] && module load $PYTHON_MODULE
    env -u PYTHONPATH python3 -m venv --clear "$PIPE_HOME/venv"
    venv_py -m pip install -q --upgrade pip
    venv_py -m pip install -q numpy scipy meshio
fi
load_python
"$PY" -c "import numpy, scipy, meshio; print('python ok:', numpy.__version__, scipy.__version__, meshio.__version__)"

# --- smoke test: deform seed 0 exactly as a job would ----------------------
t="$(mktemp -d)"
( cd "$t" && mkdir -p ffd_weights DTCHull/constant/triSurface \
  && ln -s "$base" DTCHull_bak \
  && "$PY" "$PIPE_HOME/code/mv_points.py" 0 \
  && "$PY" "$PIPE_HOME/code/check_surface.py" 0 )
rm -rf "$t"

mkdir -p "$RUN_ROOT"
echo
echo "Setup done.  Set ACCOUNT in config.sh, then: ./submit.sh"
