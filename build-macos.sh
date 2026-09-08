#!/bin/bash
#==============================================================================
# PIBM build script for macOS (Homebrew gfortran + open-mpi + netCDF).
#
# Drop-in replacement for "job-Archie", which is hard-wired to the Intel
# toolchain and module system of the ARCHIE-WeSt cluster at Strathclyde.
#
# Usage:   ./build-macos.sh [rundir]        # default rundir = Run_simple
#          Test=1 ./build-macos.sh Run      # debug build (bounds + FPE traps)
#
# Produces the executable ./<rundir>/IBM
#==============================================================================
set -euo pipefail

RUNDIR="${1:-Run_simple}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$ROOT/src"
SCRDIR="$ROOT/$RUNDIR/Compile"
Test="${Test:-0}"

[ -d "$ROOT/$RUNDIR" ] || { echo "ERROR: run directory '$RUNDIR' not found" >&2; exit 1; }

#--- Toolchain -----------------------------------------------------------------
# mpif90 already injects the MPI include/lib flags, so no MPIDIR is needed.
CFT="${CFT:-mpif90}"
command -v "$CFT"      >/dev/null || { echo "ERROR: $CFT not found (brew install open-mpi)" >&2; exit 1; }
command -v nf-config   >/dev/null || { echo "ERROR: nf-config not found (brew install netcdf-fortran)" >&2; exit 1; }
command -v nc-config   >/dev/null || { echo "ERROR: nc-config not found (brew install netcdf)" >&2; exit 1; }

NFDIR="$(nf-config --prefix)"
NCDIR="$(nc-config --prefix)"
NETCDFINC="-I$NFDIR/include"
NETCDFLIB="-L$NFDIR/lib -lnetcdff -L$NCDIR/lib -lnetcdf"

#--- Compiler flags ------------------------------------------------------------
# -fdefault-real-8 -fdefault-double-8 are the gfortran equivalents of Intel's
# -r8: the model declares everything as plain "real" and relies on 8-byte reals.
REAL8="-fdefault-real-8 -fdefault-double-8"

if [ "$Test" = 1 ]; then
  echo "Building with DEBUG options (slow: bounds checking + FPE traps)..."
  FFLAGS="-O0 -g $REAL8 -fbacktrace -fcheck=all -ffpe-trap=invalid,zero,overflow \
          -Wall -Wno-unused-dummy-argument -Wno-unused-variable -Wno-compare-reals"
else
  echo "Building with OPTIMISED options..."
  FFLAGS="-O3 -mcpu=native $REAL8"
fi
# Some routines exceed the free-form 132-column default.
FFLAGS="$FFLAGS -ffree-line-length-none"

LFLAGS="$NETCDFLIB"
FFLAGS="$FFLAGS $NETCDFINC"

#--- Assemble the compile directory --------------------------------------------
# Sources from src/, then the run directory's own params.f90 / variables.f90
# overwrite their src/ counterparts -- this is how a run is configured.
rm -rf "$SCRDIR"
mkdir -p "$SCRDIR"
cp -f "$SOURCE"/*.f90  "$SCRDIR"/
cp -f "$SOURCE"/Make*  "$SCRDIR"/
cp -f "$ROOT/$RUNDIR"/*.f90 "$SCRDIR"/ 2>/dev/null || true

cd "$SCRDIR"

#--- Substitute flags into the Makefile (same approach as job-Archie) -----------
sed -e "s?\$(FFLAGS)?$FFLAGS?g" \
    -e "s?\$(CFT)?$CFT?g" \
    -e "s?\$(LFLAGS)?$LFLAGS?g" Makefile > Makefile.build
mv -f Makefile.build Makefile

make
mv -f IBM "$ROOT/$RUNDIR/"
echo "OK -> $RUNDIR/IBM"
