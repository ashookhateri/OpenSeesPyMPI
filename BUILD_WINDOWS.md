# Windows Build Configuration — OpenSeesPyMPI

Target environment: **Windows 10/11 x64 · Visual Studio 2022 (v143) · CMake ≥ 3.25 · CPython 3.10-3.12 x64 · Microsoft MPI 10.1**

> **Reality check.** No Windows machine, MSVC toolchain or MS-MPI installation was
> available while this package was prepared. Everything below is derived from
> the actual `CMakeLists.txt` / `cmake/cmake/OpenSeesDependenciesWin.cmake` in the
> repository and from the verified Linux-side configuration, but **no Windows
> build was executed and no Windows build log exists.** Do not read this file as
> evidence that a Windows build succeeds.

---

## 1. Required libraries (complete list, read from `CMakeLists.txt`)

| Dependency | Used by | Where it comes from | Windows notes |
|---|---|---|---|
| **CMake** ≥ 3.16 (`cmake_minimum_required`) | build | installer | 3.25+ recommended for MS-MPI discovery |
| **MSVC v143 / C++17** | all | Visual Studio 2022 "Desktop development with C++" | project sets `CMAKE_CXX_STANDARD 17` |
| **Fortran compiler** | `project(... LANGUAGES C CXX Fortran)` | Intel `ifx`, or none | if absent, pass `-DCMAKE_Fortran_COMPILER=` and expect Fortran element sources to be skipped/fail |
| **TCL 8.6** (`tcl::tcl`, `TCL_INCLUDE_PATH`) | `OpenSees`, `OpenSeesSP/MP` | `cmake/OpenSeesDependenciesWin.cmake` | not needed by `OpenSeesPyMPI` sources, but the top-level build still resolves it |
| **Python 3 development** (`Python.h`, `python3x.lib`) | `OpenSeesPy` / `OpenSeesPyMPI` | python.org installer | must be x64 and the same minor version you will import from |
| **Microsoft MPI 10.1** (`msmpi.lib`, `mpi.h`, `msmpi.dll`) | `OpenSeesSP`, `OpenSeesMP`, `OpenSeesPyMPI` | `msmpisdk.msi` (SDK) + `msmpisetup.exe` (runtime) | the only supported MPI on Windows for this project |
| **METIS** | `OPS_partition()`, partitioners | `OTHER/METIS` (built when `MPI_FOUND`) or `find_package(METIS)` | needs `metis.lib`; the vendored payload is C and MSVC-compatible but usually needs `/D_SCL_SECURE_NO_DEPRECATE` or a standalone build. **Headers need no extra flag**: `CMakeLists.txt` globs `OTHER/**/*.h` into the global include path, so `metis.h` is found from `OTHER/METIS/metis.h`. Do not pass `METIS_INCLUDE_DIRS` — that is not a variable the project reads (it reads `METIS_INCLUDES`/`METIS_LIBRARIES`, see `cmake/cmake/FindMETIS.cmake`). |
| **SuperLU_DIST 4.3** | `OpenSeesSP/MP` (`DistributedSuperLU`) | `OTHER/SuperLU_DIST_4.3` | not required by the Python MPI target's source list, but the top-level `if(MPI_FOUND)` block adds it |
| **MUMPS** | `OpenSeesSP/MP` | `MUMPS_DIR` (external) | absent ⇒ `-D_NOMUMPS`; effectively unavailable on Windows |
| **Eigen3** (`Eigen3::Eigen`) | matrix/utilities | `OTHER/eigenAPI` or `find_package` | header-only |
| **HDF5** (`HDF5::HDF5`) | data recorders | `find_package(HDF5)` | must match the module's architecture |
| **ZLIB** (`ZLIB::ZLIB`) | compression | `find_package` | — |
| **BLAS / LAPACK** | `OPS_SysOfEqn` | `OTHER/BLAS`, `OTHER/LAPACK`, or `find_package(LAPACK)` | vendored Fortran BLAS needs a Fortran compiler |
| **MKL / ScaLAPACK** | `OpenSeesSP/MP` only | optional `find_package(MKL)` | not needed for the Python MPI target |

---

## 2. Install MS-MPI (one-time)

```powershell
# 1. download both installers from https://aka.ms/msmpi
#    msmpisdk.msi   (SDK: headers + msmpi.lib)
#    msmpisetup.exe (runtime: mpiexec.exe + msmpi.dll)
msiexec /i msmpisdk.msi /qn
.\msmpisetup.exe /unattend

# 2. verify
mpiexec -help | Select-Object -First 5
Test-Path "${env:ProgramFiles(x86)}\Microsoft SDKs\MPI\Include\mpi.h"
Test-Path "${env:ProgramFiles(x86)}\Microsoft SDKs\MPI\Lib\x64\msmpi.lib"
```

Add `%ProgramFiles%\Microsoft MPI\Bin` to `PATH` (the runtime installer normally
does this; a reboot may be required).

---

## 3. Configure CMake and generate the Visual Studio solution

Two trees, always. `_PARALLEL_INTERPRETERS` must be defined while
`OPS_INTERPRETER` (an OBJECT library inside `OpenSeesLIB`) is compiled, so the
serial and MPI modules cannot share a build directory.

```powershell
# from an "x64 Native Tools Command Prompt for VS 2022", at the repo root
$py      = (Get-Command python).Source
$pyroot  = & $py -c "import sys;print(sys.prefix)"
$msmpi   = "${env:ProgramFiles(x86)}\Microsoft SDKs\MPI"

# --- A. OpenSeesPyMPI tree -------------------------------------------------
cmake -S . -B build-mpi -G "Visual Studio 17 2022" -A x64 `
      -DCMAKE_BUILD_TYPE=Release `
      -DPython_ROOT_DIR=$pyroot -DPython_EXECUTABLE=$py `
      -DOPS_BUILD_PYMPI=ON `
      -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL `
      -DMPI_C_INCLUDE_PATH="$msmpi\Include" `
      -DMPI_CXX_INCLUDE_PATH="$msmpi\Include" `
      -DMPI_C_LIBRARIES="$msmpi\Lib\x64\msmpi.lib" `
      -DMPI_CXX_LIBRARIES="$msmpi\Lib\x64\msmpi.lib"

# --- B. standard OpenSeesPy tree (unchanged behaviour) ---------------------
cmake -S . -B build-serial -G "Visual Studio 17 2022" -A x64 `
      -DCMAKE_BUILD_TYPE=Release `
      -DPython_ROOT_DIR=$pyroot -DPython_EXECUTABLE=$py `
      -DOPS_BUILD_PYMPI=OFF -DOPS_FINAL_TARGET=OpenSeesPy
```

`build-windows.ps1` runs exactly these two configurations (paths fixed at
`build-mpi\` and `build-serial\`), builds the targets, collects
`opensees_mpi.pyd` / `opensees.pyd`, and performs a **single-process** import smoke
test. `build.ps1` is a thin forwarder to it.

### 3.1 What the CMake configuration must guarantee

| Requirement | Where it is enforced |
|---|---|
| MPI is found or the build stops | `OPS_BUILD_PYMPI=ON` block: `FATAL_ERROR` if `NOT MPI_FOUND` |
| Python development files present | same block: `FATAL_ERROR` if `NOT Python_FOUND` |
| `_PARALLEL_INTERPRETERS` reaches `OpenSeesCommands.cpp` and `OPS_partition()` | `target_compile_definitions(OPS_INTERPRETER PUBLIC ...)` |
| METIS/MPI symbols resolvable for the whole tree | `target_link_libraries(OpenSeesLIB PUBLIC ${MPI_CXX_LIBRARIES} METIS)` |
| Correct module identity (`opensees_mpi`, `PyInit_opensees_mpi`) | `OPS_PY_MODULE_NAME` / `OPS_PY_INIT_SYMBOL` |
| `.pyd` suffix, no `lib` prefix | `PREFIX ""`, `OUTPUT_NAME "opensees_mpi"`, `SUFFIX` from `cmake/cmake/OpenSeesPyMPISuffix.cmake` |
| Why not `CMAKE_SHARED_MODULE_SUFFIX` | on Windows it resolves to `.dll` (`Platform/Windows.cmake` + `CMakeSystemSpecificInformation.cmake:60`), so it cannot name a CPython extension; the helper returns `.pyd` |
| `/MD` runtime for the extension | `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL` (overrides the project's `/MT` default) |

---

## 4. Build

```powershell
cmake --build build-mpi    --config Release --target OpenSeesPyMPI --parallel
cmake --build build-serial --config Release --target OpenSeesPy       --parallel
```

Expected artefacts:

```
build-mpi\Release\opensees_mpi.pyd
build-serial\Release\opensees.pyd
```

---

## 5. Installation

```powershell
$dst = "C:\OpenSeesPyMPI"
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item build-mpi\Release\opensees_mpi.pyd    $dst
Copy-Item build-serial\Release\opensees.pyd     $dst
Copy-Item "$env:ProgramFiles\Microsoft MPI\Bin\msmpi.dll" $dst -ErrorAction SilentlyContinue
$env:PYTHONPATH = $dst
python -c "import opensees_mpi as ops; print(ops.__name__, ops.getMPIRank(), ops.getMPISize())"
mpiexec -n 2 python tests\test_3_frame_static.py
```

Always invoke the **same** `python.exe` on every MPI process; mixing a conda
interpreter with a system interpreter produces `ImportError: DLL load failed`
on ranks 1..N-1 only, which is easy to misdiagnose.

---

## 6. Troubleshooting the errors this build is likely to produce

| Symptom | Cause | Fix |
|---|---|---|
| `LNK2019: unresolved external symbol MPI_Init` (and friends) | `OPS_INTERPRETER` compiled with `_PARALLEL_INTERPRETERS` but MPI libs not on the link line of a consumer | keep `OPS_BUILD_PYMPI=ON` and build only `OpenSeesPyMPI`; the option already adds `${MPI_CXX_LIBRARIES}` to `OpenSeesLIB` |
| `LNK2019: unresolved external symbol MPI_Channel::…` | an older patch level that did not list `SRC/actor/channel/MPI_Channel.cpp` in the module target (audit D1) | re-apply the current patch; the file must appear in the `add_library(OpenSeesPyMPI …)` block |
| Module built as `opensees_mpi.dll`, `import` fails | older CMake block that relied on `CMAKE_SHARED_MODULE_SUFFIX` (audit D2) | current block sets `SUFFIX=".pyd"` via the helper; verify with `dir build-mpi\Release\opensees_mpi.pyd` |
| `LNK2038: mismatch detected for 'RuntimeLibrary'` | `/MT` objects linked into a `/MD` CPython extension | configure with `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL` (already in `build.ps1`) |
| `ImportError: DLL load failed while importing opensees_mpi` | `msmpi.dll` not found, or Python minor version mismatch | copy `msmpi.dll` next to the `.pyd`, rebuild against the exact interpreter |
| `Could NOT find MPI` | MS-MPI SDK not installed, or 32-bit SDK on a 64-bit build | install `msmpisdk.msi`, pass `-DMPI_C_LIBRARIES=...\Lib\x64\msmpi.lib` |
| `Could NOT find METIS` / `metis.lib` missing | vendored METIS not built with MSVC | build `OTHER/METIS` standalone and pass `-DMETIS_LIBRARY=` / `-DMETIS_INCLUDE_DIRS=` |
| CMake errors on `Fortran` | no Fortran compiler | `-DCMAKE_Fortran_COMPILER=` (and expect Fortran-only elements to be unavailable) |
| `opserr` output missing on ranks > 0 | MS-MPI buffers per process | redirect each rank: `mpiexec -n 2 -redirect` or `-output` files |
| `mpiexec` refuses to start 4 ranks | not enough cores / policy | `mpiexec -n 4` oversubscribes on MS-MPI only with `-cores`/`-affinity` options; use `-n 2` on a 2-core machine |

### 6.1 The one line to test first on Windows

`OpenSeesCommands` calls `new MPI_MachineBroker(&theBroker, 0, 0)`, i.e.
`MPI_Init(&argc, &argv)` with `argc = 0` and `argv = nullptr`. MPICH and Open MPI
accept this; **MS-MPI has not been checked**. If the very first import aborts
inside `MPI_Init`, that is the cause — the fix is to construct the broker with a
synthetic `argv` (one dummy program name) in `PythonModule`, not to patch MS-MPI.

---

## 7. Build logs

| Log | Status |
|---|---|
| `build-mpi\configure.log`, `build-mpi\build.log`, `build-serial\*.log` | **do not exist** — no Windows run was performed. The scripts write them at first run (the earlier draft wrote `build\mpi\…`, which was audit D9). |
| Linux per-file type-check of the modified C++ (`g++ -fsyntax-only`, 3 configurations) | **exists**, summarized in `TEST_REPORT.md §2` |
| Linux CMake configure of the new block (`ON`/`OFF`, CMake 3.28.3, stubbed sibling targets) | **exists**, summarized in `TEST_REPORT.md §3` |
| Full library build/link, any `mpiexec` run | **not performed**, reason documented in `TEST_REPORT.md §5` |

The scripts write their logs to `build\<tree>\configure.log` and
`build\<tree>\build.log` on first run, which is the evidence a maintainer needs
to complete this table.
