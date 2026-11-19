#!/usr/bin/env bash
#
# OpenSeesPyMPI - independent Linux/macOS build script
# ===================================================
#
# Builds two separate trees, because _PARALLEL_INTERPRETERS must be defined
# while OPS_INTERPRETER is compiled (that object library is shared by every
# target in a tree):
#
#   build-serial  -> opensees.<soabi>.so        standard OpenSeesPy
#   build-mpi     -> opensees_mpi.<soabi>.so    OpenSeesPyMPI
#
# STATUS: type-checked and configure-checked only.  This script has never been
# run to completion, because the machine it was written on has no MPI and no
# root access to install it.  Anything it does not execute stays "NOT RUN".
#
# Usage:
#   ./build-linux.sh                 # check, configure, build both modules
#   ./build-linux.sh --check-only    # dependency report only, exit 2 if blocked
#   ./build-linux.sh --mpi-only -j 2
#   ./build-linux.sh --debug
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-Release}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
PYTHON="${PYTHON:-python3}"
DO_SERIAL=1
DO_MPI=1
CHECK_ONLY=0
BUILD_MPI="$ROOT/build-mpi"
BUILD_SERIAL="$ROOT/build-serial"
INSTALL_DIR="${INSTALL_DIR:-$ROOT/install}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)  CHECK_ONLY=1; shift ;;
    --mpi-only)    DO_SERIAL=0; shift ;;
    --serial-only) DO_MPI=0; shift ;;
    --debug)       CONFIG=Debug; shift ;;
    -j|--jobs)     JOBS="$2"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

CM="${CMAKE:-cmake}"
BLOCKING=0

status() {  # item state detail
  printf '  %-22s %-9s %s\n' "$1" "$2" "$3"
  if [[ "$2" == "MISSING" ]]; then BLOCKING=$((BLOCKING+1)); fi
}
step() { printf '\n=== %s ===\n' "$1"; }
fail() { printf '\nERROR: %s\n' "$1" >&2; [[ $CHECK_ONLY -eq 1 ]] || exit 1; }

step "Script environment"
[[ -f "$ROOT/CMakeLists.txt" ]] || { echo "CMakeLists.txt not found in $ROOT" >&2; exit 2; }
echo "repository : $ROOT"
echo "config     : $CONFIG"
echo "jobs       : $JOBS"

step "Dependency check"
if command -v "$CM" >/dev/null 2>&1; then
  status cmake OK "$("$CM" --version | head -1)"
else
  status cmake MISSING "install CMake >= 3.16 and put it on PATH"
fi

PY_PREFIX=""
if command -v "$PYTHON" >/dev/null 2>&1; then
  PY_PREFIX="$("$PYTHON" -c 'import sys;print(sys.prefix)')"
  if "$PYTHON" - <<'PY' >/dev/null 2>&1
import sysconfig, os, sys
sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_paths()['include'], 'Python.h')) else 1)
PY
  then
    status python OK "$("$PYTHON" -c 'import sys;print(sys.version.split()[0])') ($PY_PREFIX)"
  else
    status python MISSING "python development headers (python3-dev)"
  fi
else
  status python MISSING "$PYTHON not found; pass PYTHON=/path/to/python3"
fi

if command -v mpicxx >/dev/null 2>&1; then
  status mpi OK "$(mpicxx --version 2>/dev/null | head -1)"
  MPI_CXX="$(command -v mpicxx)"
elif [[ -n "${MPI_CXX_COMPILER:-}" ]]; then
  status mpi OK "$MPI_CXX_COMPILER (from MPI_CXX_COMPILER)"
  MPI_CXX="$MPI_CXX_COMPILER"
else
  status mpi MISSING "install MPICH or Open MPI with development headers (libmpich-dev / libopenmpi-dev)"
  MPI_CXX=""
fi

command -v mpiexec >/dev/null 2>&1 && status mpiexec OK "$(command -v mpiexec)" \
                                     || status mpiexec MISSING "MPI runtime; needed only for the tests"

if command -v gfortran >/dev/null 2>&1; then
  status fortran OK "$(gfortran --version | head -1)"
else
  status fortran "NOT RUN" "no gfortran; project declares LANGUAGES C CXX Fortran"
fi

if [[ -f "$ROOT/OTHER/METIS/metis.h" ]]; then
  status "METIS (bundled)" OK "$ROOT/OTHER/METIS/metis.h (headers via global OTHER/**/*.h glob)"
else
  status "METIS (bundled)" MISSING "OTHER/METIS/metis.h not present in this clone"
fi

if [[ -f "$ROOT/tests/test_3_frame_static.py" ]]; then
  status "test suite" OK "$ROOT/tests"
else
  status "test suite" "NOT RUN" "copy the delivered tests/ into the clone to run the benchmarks"
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  step "Summary"
  echo "blocking issues: $BLOCKING"
  [[ $BLOCKING -eq 0 ]] && exit 0 || exit 2
fi

[[ $BLOCKING -eq 0 ]] || fail "missing dependencies (see above)"

mkdir -p "$INSTALL_DIR"

configure() {  # dir extra...
  local dir="$1"; shift
  step "Configure $dir"
  mkdir -p "$dir"
  "$CM" -S "$ROOT" -B "$dir" \
        "-DCMAKE_BUILD_TYPE=$CONFIG" \
        "-DPython_EXECUTABLE=$(command -v "$PYTHON")" \
        "$@" 2>&1 | tee "$dir/configure.log"
  local st=${PIPESTATUS[0]}
  [[ $st -eq 0 ]] || { tail -40 "$dir/configure.log"; fail "configure failed for $dir (see $dir/configure.log)"; }
}

build() {  # dir target...
  local dir="$1"; shift
  step "Build $* in $dir"
  "$CM" --build "$dir" --target "$@" -j "$JOBS" 2>&1 | tee "$dir/build.log"
  local st=${PIPESTATUS[0]}
  [[ $st -eq 0 ]] || { tail -60 "$dir/build.log"; fail "build failed in $dir (see $dir/build.log)"; }
}

if [[ $DO_MPI -eq 1 ]]; then
  configure "$BUILD_MPI" -DOPS_BUILD_PYMPI=ON "-DMPI_CXX_COMPILER=$MPI_CXX"
  build "$BUILD_MPI" OpenSeesPyMPI
  artifact="$(find "$BUILD_MPI" -name 'opensees_mpi*.so' -o -name 'opensees_mpi*.dylib' | head -1)"
  [[ -n "$artifact" ]] || fail "opensees_mpi extension was not produced (see $BUILD_MPI/build.log)"
  cp "$artifact" "$INSTALL_DIR/"
  echo "produced: $INSTALL_DIR/$(basename "$artifact")"
fi

if [[ $DO_SERIAL -eq 1 ]]; then
  configure "$BUILD_SERIAL" -DOPS_BUILD_PYMPI=OFF -DOPS_FINAL_TARGET=OpenSeesPy
  build "$BUILD_SERIAL" OpenSeesPy
  artifact="$(find "$BUILD_SERIAL" -name 'opensees*.so' -o -name 'opensees*.dylib' | head -1)"
  [[ -n "$artifact" ]] || fail "opensees extension was not produced (see $BUILD_SERIAL/build.log)"
  cp "$artifact" "$INSTALL_DIR/"
  echo "produced: $INSTALL_DIR/$(basename "$artifact")"
fi

step "Single-process import smoke check (not an MPI test)"
PYTHONPATH="$INSTALL_DIR" "$PYTHON" - <<'PY'
import opensees_mpi as ops
print("module         :", ops.__name__)
print("mpi initialized:", ops.isMPIInitialized())
print("rank/size      :", ops.getMPIRank(), ops.getMPISize())
PY
[[ $? -eq 0 ]] || fail "import smoke check failed"

step "Done"
cat <<EOF
Modules: $INSTALL_DIR
Multi-process tests (NOT executed here):
  PYTHONPATH=$INSTALL_DIR mpiexec -n 1 $PYTHON $ROOT/tests/test_1_lifecycle.py
  PYTHONPATH=$INSTALL_DIR mpiexec -n 2 $PYTHON $ROOT/tests/test_1_lifecycle.py
  PYTHONPATH=$INSTALL_DIR mpiexec -n 2 $PYTHON $ROOT/tests/test_3_frame_static.py
  PYTHONPATH=$INSTALL_DIR mpiexec -n 4 $PYTHON $ROOT/tests/test_3_frame_static.py
  $PYTHON $ROOT/tests/compare_results.py
EOF
