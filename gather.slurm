#!/bin/bash
# Runs after the sample array (any outcome) and collects results.
# Can also be run by hand on a login node:  PIPE_HOME=$PWD bash gather.slurm
set -eo pipefail
: "${PIPE_HOME:?PIPE_HOME not set}"
source "$PIPE_HOME/config.sh"
source "$PIPE_HOME/env.sh"
load_python
"$PY" "$PIPE_HOME/code/gather.py" "$RUN_ROOT" "$FIRST_SAMPLE" "$N_SAMPLES" "$N_AVG"
