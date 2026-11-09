# Environment helpers, sourced by the job scripts.  Needs PIPE_HOME.

# batch shells are not login shells: make sure 'module' exists
if ! type module >/dev/null 2>&1; then
    for f in /etc/profile.d/lmod.sh /etc/profile.d/modules.sh /usr/share/lmod/lmod/init/bash; do
        [ -f "$f" ] && { source "$f"; break; }
    done
fi

load_python() {
    module purge
    [ -n "$PYTHON_MODULE" ] && module load $PYTHON_MODULE
    PY="$PIPE_HOME/venv/bin/python"
    # only our code: the module's PYTHONPATH (py-pip and others) would shadow
    # the venv's packages
    export PYTHONPATH="$PIPE_HOME/code"
    export PYTHONNOUSERSITE=1
    [ -x "$PY" ] || { echo "ERROR: $PY missing, run setup.sh first" >&2; return 1; }
}

load_openfoam() {
    module purge
    if [ -n "$FOAM_BASHRC" ]; then
        # OpenFOAM's bashrc is not safe under 'set -e', and its failing tests
        # would fire the job's ERR trap (set -E) and mark the sample FAILED
        local saved_trap; saved_trap="$(trap -p ERR)"
        trap - ERR; set +e
        source "$FOAM_BASHRC"
        set -e; eval "${saved_trap:-trap - ERR}"
    else
        local m
        for m in $OPENFOAM_MODULES; do
            [ "$m" = "autoload" ] && continue      # not a module on Leonardo
            if ! module load "$m"; then
                echo "ERROR: 'module load $m' failed. OpenFOAM modules visible now:" >&2
                module -t avail 2>&1 | grep -i foam >&2 || echo "  (none)" >&2
                echo "Set OPENFOAM_MODULES in config.sh; 'modmap -m openfoam' lists the" \
                     "profile each version lives in." >&2
                return 1
            fi
        done
    fi
    if [ -z "$WM_PROJECT_DIR" ] || ! command -v blockMesh >/dev/null; then
        echo "ERROR: OpenFOAM environment not found (WM_PROJECT_DIR='$WM_PROJECT_DIR')" >&2
        echo "       try 'module help openfoam+' or set FOAM_BASHRC in config.sh" >&2
        return 1
    fi
    echo "OpenFOAM: $WM_PROJECT_DIR"
}
