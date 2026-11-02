#!/bin/bash
# One-time setup, run on a Leonardo login node from inside this folder:
#     ./setup.sh /path/to/DTCHull_bak.zip      (or an unpacked DTCHull_bak folder)
#
# - installs the base case as ./DTCHull_bak, without the generated mesh
# - builds a Python venv with numpy, scipy and meshio
# - runs mv_points.py for seed 0 as a smoke test
set -eo pipefail
PIPE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPE_HOME
source "$PIPE_HOME/config.sh"
source "$PIPE_HOME/env.sh"

src="${1:?usage: ./setup.sh /path/to/DTCHull_bak.zip}"
base="$PIPE_HOME/DTCHull_bak"

# --- base case ---------------------------------------------------------------
if [ -e "$base" ]; then
    echo "Base case already present: $base (delete it to reinstall)"
else
    tmp="$(mktemp -d)"
    if [ -d "$src" ]; then cp -r "$src" "$tmp/"; else unzip -q "$src" -d "$tmp"; fi
    found="$(find "$tmp" -maxdepth 2 -type d -name DTCHull_bak | head -1)"
    [ -n "$found" ] || { echo "ERROR: no DTCHull_bak folder in $src" >&2; exit 1; }
    mv "$found" "$base"; rm -rf "$tmp"
    # blockMesh / surfaceFeatureExtract regenerate these in every sample
    rm -rf "$base/constant/polyMesh" "$base/constant/extendedFeatureEdgeMesh" \
           "$base"/processor* "$base/0" "$base"/log.* "$base/postProcessing" \
           "$base/.vscode" "$base/miao.foam"
    chmod -R a-w "$base"      # every sample reads the undeformed hull from here
    echo "Base case installed: $base"
fi
[ -f "$base/constant/triSurface/DTC-scaled.stl" ] || { echo "ERROR: hull STL missing" >&2; exit 1; }

# --- Python ------------------------------------------------------------------
if [ ! -x "$PIPE_HOME/venv/bin/python" ]; then
    module purge
    [ -n "$PYTHON_MODULE" ] && module load $PYTHON_MODULE
    python3 -m venv "$PIPE_HOME/venv"
    "$PIPE_HOME/venv/bin/pip" install -q --upgrade pip
    "$PIPE_HOME/venv/bin/pip" install -q numpy scipy meshio
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
