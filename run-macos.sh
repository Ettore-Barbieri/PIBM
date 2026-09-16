#!/bin/bash
#==============================================================================
# Run a PIBM configuration on macOS.  Replaces IBM.sh (SLURM/ARCHIE-WeSt).
#
# Usage:  ./run-macos.sh Run_simple [nranks]     # default nranks = 4
#         ./run-macos.sh Run_BATS
#
# Progress goes to <rundir>/out ; follow it with:  tail -f <rundir>/out
#==============================================================================
set -euo pipefail

RUNDIR="${1:?usage: ./run-macos.sh <rundir> [nranks]}"
# Default to the number of performance cores: only the random walk is
# MPI-parallel, OpenMPI busy-waits, and the efficiency cores on Apple Silicon
# would just hold the others up at each barrier.
if [ -n "${2:-}" ]; then
  NP="$2"
else
  NP="$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || true)"
  [ -z "$NP" ] && NP="$(sysctl -n hw.physicalcpu 2>/dev/null || true)"
  [ -z "$NP" ] && NP=4
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT/$RUNDIR"

[ -x ./IBM ] || { echo "ERROR: no ./IBM in $RUNDIR -- run ./build-macos.sh $RUNDIR first" >&2; exit 1; }

# Refuse to clobber the authors' published results in Run/.
if [ "$RUNDIR" = "Run" ]; then
  echo "ERROR: Run/ holds the published Euler.nc and other result files that a" >&2
  echo "       run would overwrite. Use Run_BATS (a clean copy of Run/'s inputs)." >&2
  exit 1
fi

rm -f Euler.nc ParY*.nc PassY*.nc restart.nc
echo "started $(date)  |  ${NP} ranks  |  $(grep -E 'NDay_Run' time.nml | tr -d ' ')"

# Keep the machine awake for the whole run. Display sleep is harmless, but an
# idle system sleep suspends the MPI ranks and the run simply stops advancing
# until someone wakes the machine. caffeinate -i blocks idle sleep, -s blocks
# system sleep while on mains power; both end when the run does.
CAFF=""
command -v caffeinate >/dev/null && CAFF="caffeinate -is"
# Only the vertical random walk is MPI-parallel; biology, Eulerian physics and
# all netCDF I/O run on the master rank. -np 4 saturates the M2 performance
# cores -- more ranks do not help, and OpenMPI busy-waits, so do not run two
# configurations at the same time.
time $CAFF mpirun -np "$NP" ./IBM > out 2>&1
echo "finished $(date)"
