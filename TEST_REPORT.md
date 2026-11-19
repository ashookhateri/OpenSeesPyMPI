# TEST REPORT — OpenSeesPyMPI

**Round 2** (post-audit remediation) · 2026-11-19
**Host:** Linux sandbox, Ubuntu 24.04.5, x86_64, 2 vCPU, 3.8 GiB RAM
**Windows host:** none · **MPI runtime:** none, and not installable (no root: `sudo` refused by `no_new_privs`)
**PowerShell:** 7.4.6 (portable, downloaded for this round) · **PowerShell 5.1:** unavailable
**Rule:** a check is `PASS` only if a command ran and its exit status was read. Everything else is `NOT RUN`, with the blocker named.

> **The three claims this report does not make:** it does not claim a successful
> build, a successful link, or a successful MPI run. `-fsyntax-only` produces no
> object file, and a CMake configure against stubbed targets is not a build.

---

## 1. Precisely separated stages

| Stage | Status | Evidence |
|---|---|---|
| Implemented (source in tree) | ✅ | 5 files changed + 1 new file, branch `feature/openseespy-mpi` |
| Type-checked (`g++ -fsyntax-only`) | ✅ | §2, 7 invocations, exit 0 |
| Configure-verified (CMake, stubbed siblings) | ✅ | §3, `ON` and `OFF`, exit 0 |
| Unit-verified logic (`cmake -P`, suffix helper) | ✅ | §4, 4 assertions |
| Scripts syntax-verified | ✅ | §5, `bash -n` ×2, PS parser ×3 |
| Scripts executed | ⚠️ partially | §5, only `--check-only` / `-CheckOnly` paths |
| **Compiled** (object files) | ❌ NOT RUN | no MPI/TCL/Eigen/HDF5 dev packages, no `gfortran`, no root |
| **Linked** (`.so`/`.pyd`) | ❌ NOT RUN | same |
| **Runtime-tested** (`mpiexec`, structural analysis) | ❌ NOT RUN | same |
| Windows build (`build-windows.ps1` full run) | ❌ NOT RUN | no Windows, no MSVC, no MS-MPI |

---

## 2. Type-checks (real commands, re-run this round)

Include set used by all invocations:

```bash
INCS="$(find SRC -type d -printf ' -I%p ') -I/tmp/tcl-core-8-6-13/generic \
      -IOTHER/CSPARSE -IOTHER/UMFPACK"
PYINC="$(python3-config --includes)"
```

| # | Command | Exit |
|---|---|---|
| A1 | `g++ -std=c++17 -fsyntax-only $INCS $PYINC SRC/interpreter/PythonModule.cpp` | **0** |
| A2 | `… -I/tmp/fake_mpi $INCS $PYINC -D_PARALLEL_INTERPRETERS SRC/interpreter/PythonModule.cpp` | **0** |
| A3 | `… -I/tmp/fake_mpi … -D_PARALLEL_INTERPRETERS '-DOPS_PY_MODULE_NAME="opensees_mpi"' -DOPS_PY_INIT_SYMBOL=opensees_mpi SRC/interpreter/PythonModule.cpp` | **0** |
| B | `… -D_PARALLEL_INTERPRETERS SRC/actor/machineBroker/MPI_MachineBroker.cpp` | **0** |
| C | `… -D_PARALLEL_INTERPRETERS SRC/interpreter/OpenSeesCommands.cpp` | **0** |
| D | `… SRC/interpreter/OpenSeesCommands.cpp` (serial) | **0** |
| E | `… -D_PARALLEL_INTERPRETERS SRC/actor/channel/MPI_Channel.cpp` | **0** |

C and D failed on the first attempt because `cs.h` / `umfpack.h` were not on the
include path; after adding `-IOTHER/CSPARSE -IOTHER/UMFPACK` they pass. E failed
until the **stub** `mpi.h` gained `MPI_Status`, `MPI_CHAR`, `MPI_Send`, `MPI_Recv`,
`MPI_Get_count` and an include guard.

**Header provenance — no real MPI headers were used.** `/usr/include/mpi.h` and
`/usr/include/*/mpich/mpi.h` do not exist on this host. Every MPI-configured check
used a hand-written `/tmp/fake_mpi/mpi.h` (now ~45 lines: macros, opaque `MPI_Comm`,
`MPI_Status` struct, and `extern "C"` prototypes). Therefore **MPI signatures,
constants and ABI remain unverified**; only C++/CPython-C-API well-formedness is
established.

What a type-check does **not** prove: that the symbols link, that the module
imports, that the MPI calls are balanced, or that any structural result is right.

---

## 3. CMake configure (harness, stubbed sibling targets)

CMake 3.28.3, the new block extracted verbatim from `CMakeLists.txt` by script,
`OPS_INTERPRETER`/`OpenSeesLIB`/`OPS_Reliability`/`OPS_Recorder`/`OPS_Numerics`/
`METIS`/`SUPERLU_DIST` stubbed, `HDF5::HDF5`/`ZLIB::ZLIB`/`Eigen3::Eigen` imported,
`Python_SOABI` emulated as `cpython-312-x86_64-linux-gnu`.

```
=== OPS_BUILD_PYMPI=ON ===
-- HARNESS_SUFFIX='.cpython-312-x86_64-linux-gnu.so' OUTPUT_NAME='opensees_mpi' PREFIX=''
-- HARNESS_SOURCES_OK mpi_channel=yes duplicates=no
-- HARNESS_OK target=OpenSeesPyMPI sources=9
-- HARNESS_DEFS=_PARALLEL_INTERPRETERS;_NOMUMPS;OPS_PY_MODULE_NAME="opensees_mpi";OPS_PY_INIT_SYMBOL=opensees_mpi
-- HARNESS_INCLUDES=/usr/include/python3.12
-- Configuring done (0.2s)
-- Generating done (0.0s)
EXIT=0

=== OPS_BUILD_PYMPI=OFF ===
-- HARNESS_OK option_off_no_target
-- Configuring done (0.2s)
-- Generating done (0.0s)
EXIT=0
```

Assertions inside the harness: `MPI_Channel.cpp` present in `SOURCES`;
`ActorSubdomain.cpp`/`ShadowSubdomain.cpp` absent (no duplicates); `SUFFIX`,
`OUTPUT_NAME`, `PREFIX` correct. This validates the **build graph description**,
not dependency resolution and not a build.

---

## 4. Unit test of the suffix helper (both-platform logic)

`cmake/cmake/OpenSeesPyMPISuffix.cmake`, executed with `cmake -P`:

```
-- linux+soabi    -> '.cpython-312-x86_64-linux-gnu.so'
-- linux-no-soabi -> '.so'
-- win32          -> '.pyd'
-- win32 assertion: OK        (FATAL_ERROR branch never triggered)
```

This is the only piece of platform logic that could be executed on a single host,
and it is executed and asserted, not assumed.

---

## 5. Script verification

| Check | Command | Result |
|---|---|---|
| shell syntax | `bash -n build-linux.sh` / `bash -n build.sh` | OK / OK |
| Linux dependency logic | `CMAKE=<cmake3.28> bash build-linux.sh --check-only` (fake tree in `/tmp`) | correct table, **exit 2** (blocking: `mpi`, `mpiexec`) |
| script refuses wrong cwd | same with `CMakeLists.txt` absent | `CMakeLists.txt not found …`, exit 2 |
| PowerShell syntax | PowerShell 7.4.6 `Parser::ParseFile` on `build-windows.ps1`, `build.ps1`, `tests/run_all.ps1` | `PARSE OK` ×3 |
| Windows dependency logic | `pwsh -File build-windows.ps1 -CheckOnly` | correct table (MSVC/MS-MPI MISSING, Fortran NOT RUN), **exit 2** |
| PowerShell 5.1 | — | **NOT RUN**; the scripts avoid `?.`, `??`, ternaries and `-AdditionalChildPath`, and are parsed clean under 7.4.6 |
| Full script run (either OS) | — | **NOT RUN** (no MPI, no MSVC) |

---

## 6. Phase 4 suite — status (unchanged: written, not executed)

| Required test | Script | Status | Blocker |
|---|---|---|---|
| MPI initialization | `test_1_lifecycle.py` | **NOT RUN** | no MPI; module cannot be built |
| Rank / process identification | `test_1_lifecycle.py` | **NOT RUN** | same |
| MPI communication | `test_2_communication.py` | **NOT RUN** | same |
| Parallel domain partitioning | `test_5_partition.py` | **NOT RUN** | METIS + MPI + a built module |
| Distributed analysis | `test_3` / `test_4` | **NOT RUN** | same |
| Python script execution | `test_3` / `test_4` | **NOT RUN** | same |
| MPI shutdown / lifecycle safety | `test_1`, `test_6_lifecycle_safety.py` | **NOT RUN** | same |
| Comparison with standard OpenSeesPy | `compare_results.py` | tool **verified** (agreement + mismatch cases), **numbers NOT RUN** | serial/MPI modules not built |

Pass criteria the suite enforces when it becomes runnable: `isMPIInitialized() is True`
and `isMPIFinalized() is False` after import; `0 <= rank < size`;
`Allreduce(1) == size`; `sum(rank+1) == n(n+1)/2`; five barriers complete and one
barrier measurably waits for a slow rank (≥ 0.15 s); `ops.partition()` returns 0 with
disjoint parts whose union equals the model and no empty rank; frame displacements,
reactions and element forces match serial within `rtol=1e-6, atol=1e-9`;
`compare_results.py` exits 1 on divergence.

---

## 7. What closes this report

1. Linux with `libmpich-dev tcl-dev libeigen3-dev libhdf5-dev gfortran`:
   `./build-linux.sh` → first real compile + link of `opensees_mpi.*.so`.
2. `mpiexec -n 1/2/4 python tests/test_1_lifecycle.py` and `test_6_lifecycle_safety.py`.
3. `mpiexec -n 2/4 python tests/test_3_frame_static.py` + `test_4_frame_nonlinear.py`,
   then `python tests/compare_results.py`; record the numbers here.
4. Windows with VS2022 + MS-MPI: `.\build-windows.ps1`, then `tests\run_all.ps1`;
   paste `build-mpi\build.log`, `build-mpi\configure.log` and `results\summary.csv`.

Until then: **type-checked, configure-verified, unit-verified — never compiled,
never linked, never run under MPI.**
