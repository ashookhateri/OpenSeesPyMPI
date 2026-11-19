# OpenSeesPyMPI

An MPI-enabled build of **OpenSeesPy**, built from the official
[OpenSees](https://github.com/OpenSees/OpenSees) source on branch
`feature/openseespy-mpi` (base: `5b9b70511e04e8f1b65710edb98fdffd8ef3add0`).

The module keeps the standard OpenSeesPy API and adds Python access to the
parallel machinery that already exists in OpenSees but was compiled out of every
shipped OpenSeesPy build:

- `ops.partition(...)` — METIS domain decomposition (upstream code, previously unreachable)
- `ops.getMPIRank()`, `ops.getMPISize()`, `ops.isMPIInitialized()`,
  `ops.isMPIFinalized()`, `ops.mpiBarrier()`, `ops.mpiSum(x)`, `ops.mpiAbort(code)`
- `ops.system('MPIDiagonal')`, `ops.system('ParallelProfileSPD')` — the two
  genuinely distributed linear solvers the Python command layer exposes

---

## Status — read before using

| Stage | State |
|---|---|
| Source changes | ✅ complete (5 files modified, 1 new CMake helper) |
| Type-checked (`g++ -fsyntax-only`, 7 invocations) | ✅ passes |
| CMake configure verified (`ON` / `OFF`, stubbed siblings) | ✅ passes |
| Suffix logic unit-tested for Linux **and** Windows | ✅ passes |
| Build scripts syntax-verified (bash + PowerShell parser) | ✅ passes |
| **Compiled** | ❌ **NOT RUN** |
| **Linked** | ❌ **NOT RUN** |
| **MPI runtime / structural analysis** | ❌ **NOT RUN** |
| **Windows build** | ❌ **NOT RUN** |

The machine used for development is Linux-only and has no MPI, no MSVC, no
system-package access (`sudo` refused) and no way to obtain Microsoft MPI.
See `TECHNICAL_AUDIT.md` and `TEST_REPORT.md` for the evidence behind every line
above. **Nothing here is a claim that the module works.**

---

## 1. Package contents

| Path | Purpose |
|---|---|
| `patches/openseespy-mpi.patch` | complete diff vs upstream `5b9b7051` |
| `patched-src/` | the modified files in full (`CMakeLists.txt`, `cmake/cmake/OpenSeesPyMPISuffix.cmake`, `PythonModule.cpp`, `OpenSeesCommands.cpp`, `MPI_MachineBroker.{h,cpp}`) |
| `build-linux.sh` | independent Linux/macOS build (`--check-only` available) |
| `build-windows.ps1` | independent Windows build, PowerShell 5.1 **and** 7 (`-CheckOnly` available) |
| `build.sh`, `build.ps1` | 3-line forwarders kept for old instructions |
| `TECHNICAL_AUDIT.md` | audit findings D1–D9, fix status, risk register |
| `TEST_REPORT.md` | exactly what ran, what did not, and why |
| `ARCHITECTURE.md` | source-derived architecture report + design |
| `BUILD_WINDOWS.md` | dependency list, MS-MPI setup, troubleshooting |
| `CHANGELOG.md` | every modification with its source justification |
| `ENVIRONMENT_REPORT.md` | diagnostic table of the build machine |
| `tests/` | lifecycle, communication, partition and 2D steel-frame benchmarks |

---

## 2. Apply the patch

```bash
git clone https://github.com/OpenSees/OpenSees.git
cd OpenSees
git checkout 5b9b70511e04e8f1b65710edb98fdffd8ef3add0
git checkout -b feature/openseespy-mpi
git apply /path/to/openseespy-mpi.patch
cp -r /path/to/OpenSeesPyMPI/tests/. ./tests/        # the delivered files do not
                                                      # collide with upstream test names
```

Prerequisites, dependency list and Windows/MS-MPI details: `BUILD_WINDOWS.md`.
Short version — Linux: `cmake ≥ 3.16`, `g++ ≥ 11`, `python3-dev`, MPICH/Open MPI
+ dev headers, `tcl-dev`, Eigen3, HDF5, zlib, BLAS/LAPACK, `gfortran`.
Windows: VS 2022 (v143), CMake ≥ 3.25, CPython 3.10–3.12 x64, MS-MPI 10.1.

---

## 3. Build

```bash
# Linux / macOS
./build-linux.sh                 # dependency report, then build both modules
./build-linux.sh --check-only    # report only; exit 2 if something is missing
```

```powershell
# Windows - works in Windows PowerShell 5.1 and in PowerShell 7
powershell -ExecutionPolicy Bypass -File .\build-windows.ps1 -Config Release
.\build-windows.ps1 -CheckOnly
```

Both produce two trees on purpose:

```
build-serial/  -> opensees.<soabi>.so        (standard OpenSeesPy, unchanged)
build-mpi/     -> opensees_mpi.<soabi>.so    (OpenSeesPyMPI)
                  opensees_mpi.pyd on Windows
```

`_PARALLEL_INTERPRETERS` has to be defined while `OPS_INTERPRETER` is compiled,
and that object library is shared by every target in a tree, so the serial and
MPI modules cannot come from one build directory.

---

## 4. Run

```bash
export PYTHONPATH=/path/to/install
python -c "import opensees_mpi as ops; print(ops.getMPIRank(), ops.getMPISize())"

mpiexec -n 1 python tests/test_1_lifecycle.py
mpiexec -n 2 python tests/test_1_lifecycle.py
mpiexec -n 2 python tests/test_5_partition.py
mpiexec -n 2 python tests/test_3_frame_static.py
mpiexec -n 4 python tests/test_3_frame_static.py
python tests/compare_results.py
```

Windows: `mpiexec.exe` from MS-MPI, and the **same** `python.exe` on every rank
(mixing a conda interpreter with a system one makes only ranks 1..N-1 fail to
import).

### Rules the upstream code enforces

1. **Every rank builds the identical model.** `ops.partition()` verifies this with
   `MPI_Reduce`/`MPI_MAX` and refuses mismatched meshes.
2. **`ops.partition()` is collective** — call it once, on all ranks, after the model
   is complete and before `ops.analysis(...)`.
3. **Do not call `MPI_Init`/`MPI_Finalize` yourself.** The module initializes only
   if MPI is not already initialized, and finalizes only if it did the init and
   nobody finalized first.
4. **Query results only on ranks that own the node.** After partitioning each rank
   holds a subset; the tests write one JSON per rank and merge them.
5. **Pick the solver deliberately.** `MPIDiagonal` only for diagonal/lumped
   systems, `ParallelProfileSPD` for SPD profile systems. Serial solvers on a
   pruned domain solve the wrong system and raise no error.

---

## 5. Limitations (source-verified, not guesses)

| # | Limitation |
|---|---|
| L1 | From Python only `MPIDiagonal` and `ParallelProfileSPD` are truly parallel. `'Mumps'` builds the **serial** `MumpsSOE`; there is no `MumpsParallel` branch; the `'Petsc'` branch is empty. `SuperLU_DIST`/`MumpsParallelSOE` are unreachable from the Python command string. |
| L2 | Python never builds a `PartitionedDomain`: `OpenSeesCommands` always allocates a plain `Domain`, and `ops.partition()` prunes it. The actor/shadow decomposition of OpenSeesSP is not available from Python. |
| L3 | No parallel speedup is claimed for any model. On a 12-element frame, 2 ranks are expected to be *slower* than serial. |
| L4 | `MPI_Init(&argc, &argv)` is called with `argc = 0, argv = nullptr` (upstream `OpenSeesCommands`). MPICH/Open MPI accept it; **unverified on MS-MPI** — it is the first thing to test on Windows. |
| L5 | `OPS_BUILD_PYMPI=ON` makes the whole tree MPI-capable; a dedicated build directory is mandatory. |
| L6 | Both modules statically embed `OpenSeesLIB`, so loading `opensees` and `opensees_mpi` in one process still risks symbol interposition (open item D7). |
| L7 | No Windows build has been performed. |

---

## 6. Reverting

```bash
git checkout -- CMakeLists.txt SRC/interpreter/PythonModule.cpp \
               SRC/interpreter/OpenSeesCommands.cpp \
               SRC/actor/machineBroker/MPI_MachineBroker.h \
               SRC/actor/machineBroker/MPI_MachineBroker.cpp
rm -f cmake/cmake/OpenSeesPyMPISuffix.cmake
```
