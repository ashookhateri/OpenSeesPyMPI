# TECHNICAL AUDIT — OpenSeesPyMPI

**Subject:** independent audit of the OpenSeesPyMPI implementation, followed by the
P0/P1 remediation round.
**Base commit:** upstream `OpenSees/OpenSees` @ `5b9b70511e04e8f1b65710edb98fdffd8ef3add0`
**Branch:** `feature/openseespy-mpi`
**Audit method:** read-only inspection of the source tree, the CMake graph and the
delivered scripts; every claim below is tied to a file path or a command that was
actually executed. No source file was modified during the audit itself.

---

## 0. Claim discipline (read this before the tables)

| Term used in this document | Meaning |
|---|---|
| **Implemented** | code exists in the working tree / commit |
| **Type-checked** | `g++ -std=c++17 -fsyntax-only` produced no diagnostics. **No object file is produced by `-fsyntax-only`; this is not compilation.** |
| **Configure-verified** | CMake parsed the block and created/omitted the target as expected, against **stubbed** sibling targets |
| **Unit-verified** | a piece of logic was executed in isolation and its output asserted |
| **Compiled / linked / runtime-tested** | **not achieved anywhere in this project yet** |

Three things this project has **never** done: produced an object file for its own
sources, linked `opensees_mpi`, or started a single MPI process.

---

## 1. Findings from the audit

Severity: **P0** = blocks the build; **P1** = blocks a supported workflow;
**P2/P3** = correctness/robustness debt.

| ID | Sev | Finding | Evidence (audit time) | Status now |
|---|---|---|---|---|
| **D1** | P0 | `OpenSeesPyMPI` never compiled or linked `SRC/actor/channel/MPI_Channel.cpp`. That file is added **only** to targets `OpenSeesMP` and `OpenSeesSP`, while the module's broker constructor calls `new MPI_Channel(i)` and the subdomains call `sendID/sendObj/...` ⇒ undefined references at link on every platform. | `SRC/actor/channel/CMakeLists.txt:21-35`; project-wide grep found no other CMakeLists listing it | **FIXED** — added to the target |
| **D2** | P0 (Win) | Extension suffix was wrong: the install rule used `CMAKE_SHARED_MODULE_SUFFIX`, which is `.dll` on Windows (`Platform/Windows.cmake` sets `CMAKE_SHARED_LIBRARY_SUFFIX ".dll"`; `CMakeSystemSpecificInformation.cmake:60` copies it). A CPython extension must be `.pyd`, and `build.ps1` searched for `*.pyd` ⇒ "was not produced". | CMake 3.28.3 module sources, quoted in §3 | **FIXED** — `SUFFIX`/`OUTPUT_NAME` set from a tested helper |
| **D3** | P1 | `build.ps1` used the PS7-only null-conditional operator `?.` (lines 53, 62) while the README told users to run it with Windows PowerShell 5.1 ⇒ parse error before any work. | language-version fact; no `pwsh` on the audit host to execute | **FIXED** — rewritten, no PS7-only syntax |
| **D4** | P1 | `build.ps1` assigned to the automatic variable `$args` (line 132) ⇒ failure under `[CmdletBinding()]` / strict mode. | same | **FIXED** — renamed `$cmakeArgs` |
| **D5** | P1 | METIS wiring in the scripts was wrong twice: the variable passed (`METIS_INCLUDE_DIRS`) is not the one `FindMETIS.cmake` reads (`METIS_INCLUDES`/`METIS_LIBRARIES`), and the path `OTHER/METIS/include` does not exist (`metis.h` is at `OTHER/METIS/metis.h`). | `cmake/cmake/FindMETIS.cmake`, `ls OTHER/METIS` | **FIXED** — scripts no longer guess; headers are already global via the `OTHER/**/*.h` glob, and `-MetisRoot` passes the correct variable names only for a prebuilt lib |
| **D6** | P1 | `ActorSubdomain.cpp` and `ShadowSubdomain.cpp` are compiled inside `OPS_Domain` (in `OpenSeesLIB`) and were listed **again** in the module target ⇒ duplicate compilation; a hard duplicate-symbol error if `BUILD_SHARED_LIBS` ever becomes `ON`. | `SRC/domain/subdomain/CMakeLists.txt` | **FIXED** — removed; `PartitionedDomain*.cpp` stay because upstream comments them out of `OPS_Domain` |
| **D7** | P2 | No symbol-visibility control (`-fvisibility=hidden`, version script, `WINDOWS_EXPORT_ALL_SYMBOLS`) anywhere; both modules statically embed the same non-static globals (`opserrPtr`, …) ⇒ ELF interposition risk when both are loaded. | project-wide grep: no hits | **OPEN** — documented as a known risk, not silently ignored |
| **D8** | P1 | Lifecycle gaps: no `MPI_Finalized` guard (a driver that finalizes MPI first causes a double `MPI_Finalize`, fatal in MPI), and no abort path (a failing rank leaves the others blocked in a collective). | `MPI_MachineBroker.cpp` dtor, `OpenSeesCommands.cpp` dtor | **FIXED** — see §4 |
| **D9** | P3 | Docs/script path mismatches: docs said `build-mpi\…`, the script wrote `build\mpi\…`; documented test command `tests\test_3_frame_static.py` does not exist in the upstream repo (the suite ships inside the ZIP and upstream already owns a `tests/` folder). | `BUILD_WINDOWS.md` vs `build.ps1`; `[ -e work/OpenSees/tests/test_3_frame_static.py ]` → missing | **FIXED** — scripts now create `build-mpi/`, `build-serial/` at the repo root and check whether the suite is present before printing test commands |

### Findings that were checked and **rejected** (no change needed)

| Suspicion | Result |
|---|---|
| `metis.h` not visible when `OPS_partition()` is compiled into `OPS_INTERPRETER` | **Not a problem.** `CMakeLists.txt` globs `${OPS_BUNDLED_DIR}/*.h` (i.e. `OTHER/**/*.h`) into the global include path, which is how `SRC/graph/partitioner/MetisWrapper.h` already compiles. |
| `METIS`/`SUPERLU_DIST` targets missing when the option is on | They are created in the `if(MPI_FOUND)` block, and the option now fails fast if `TARGET METIS` is absent. |
| Any module source duplicated inside an object/static library | **No.** A comment-aware scan of every `CMakeLists.txt` shows the 9 module sources are referenced only by executable target blocks (`OpenSees`, `OpenSeesMP`, `OpenSeesSP`, `OpenSeesPy`) — never by an `OPS_*`/`OpenSeesLIB`/`graph` target. |

---

## 2. Link-dependency review (after the fixes)

Target `OpenSeesPyMPI` (SHARED, `EXCLUDE_FROM_ALL`) now compiles exactly 9 files:

```
interpreter/PythonModule.cpp
actor/objectBroker/FEM_ObjectBrokerAllClasses.cpp
actor/machineBroker/MPI_MachineBroker.cpp      -> needs MPI_Channel
actor/channel/MPI_Channel.cpp                  -> FIX D1
domain/domain/partitioned/PartitionedDomain.cpp
domain/domain/partitioned/PartitionedDomainEleIter.cpp
domain/domain/partitioned/PartitionedDomainSubIter.cpp
system_of_eqn/linearSOE/diagonal/MPIDiagonalSOE.cpp
system_of_eqn/linearSOE/diagonal/MPIDiagonalSolver.cpp
```

and links `OpenSeesLIB` (which contains `OPS_INTERPRETER` with `OPS_partition()`),
`OPS_Reliability`, `OPS_Recorder`, `OPS_Numerics`, `METIS`, `SUPERLU_DIST`,
`HDF5::HDF5`, `ZLIB::ZLIB`, `Eigen3::Eigen`, `${MPI_CXX_LIBRARIES}`,
`${Python_LIBRARIES}` — all `PRIVATE`.

`OpenSeesLIB` itself gets `PUBLIC ${MPI_CXX_LIBRARIES} METIS` when the option is
on, because `OPS_partition()` (METIS) and the broker path (MPI) are now reachable
from that archive for every consumer in the tree.

Residual link risk that **cannot** be validated without a real toolchain:
unresolved symbols from classes referenced by the interpreter but living in other
optional libraries (e.g. PFEM / UMFPACK paths). This is exactly what a first real
link will reveal.

---

## 3. Windows suffix evidence (D2)

```
CMake 3.28.3, share/cmake-3.28/Modules/Platform/Windows.cmake
   set(CMAKE_SHARED_LIBRARY_SUFFIX ".dll")

CMake 3.28.3, share/cmake-3.28/Modules/CMakeSystemSpecificInformation.cmake:60
   set(CMAKE_SHARED_MODULE_SUFFIX "${CMAKE_SHARED_LIBRARY_SUFFIX}")

=> on MSVC, ${CMAKE_SHARED_MODULE_SUFFIX} == ".dll"   (a CPython extension needs ".pyd")
```

Fixed by a new, unit-tested helper `cmake/cmake/OpenSeesPyMPISuffix.cmake`:

| Input | Output (asserted) |
|---|---|
| `WIN32=TRUE`, `CMAKE_SHARED_MODULE_SUFFIX=.dll` | `.pyd` |
| `Python_SOABI=cpython-312-x86_64-linux-gnu`, `.so` | `.cpython-312-x86_64-linux-gnu.so` |
| no SOABI, `.so` | `.so` |

The target now carries `OUTPUT_NAME "opensees_mpi"` + `SUFFIX <helper result>` and
the install rule copies it verbatim, so Windows produces `opensees_mpi.pyd`.

---

## 4. MPI lifecycle (audit + redesign)

**Single initialization site** (verified by grep): `OpenSeesCommands::OpenSeesCommands()`
→ `new MPI_MachineBroker(&theBroker, 0, 0)` → `MPI_Initialized` → `ownsMPI = (flag == 0)`
→ `MPI_Init` only when owned. No other translation unit in `SRC/interpreter` or
`SRC/actor` calls `MPI_Init`.

**Finalization** now reads:

```
Py_AtExit(cleanupFunc)
  module->getCmds().wipe();  delete module
  ~OpenSeesCommands:
      delete[] theChannels
      MPI_Finalized(&finalized)             <-- added
      if (!finalized) broker->shutdown()    <-- guard added (collective!)
      delete broker
  ~MPI_MachineBroker:
      if (ownsMPI) { MPI_Finalized(&f); if (!f) MPI_Finalize(); }   <-- guard added
```

Guarantees established by construction:

1. never initialize twice (host may own MPI);
2. never finalize twice (host may have finalized first);
3. never enter a collective after finalization;
4. exactly one broker per process.

New Python surface for diagnostics and failure handling: `isMPIFinalized()`,
`mpiAbort(errorcode)` (default `1`), alongside `isMPIInitialized()`,
`getMPIRank()`, `getMPISize()`, `mpiBarrier()`, `mpiSum(x)`.

Still unverified and honestly listed as risk: `MPI_Init(&argc,&argv)` with
`argc = 0, argv = nullptr` on MS-MPI; whether `shutdown()` (collective) can block
if ranks exit at different times; `Py_AtExit` ordering versus MPI teardown.

---

## 5. Solver surface (unchanged by this round, deliberately)

The user asked to reach a correct, buildable extension — **not** new solvers. The
audited limitation stands: from Python only `MPIDiagonal` and
`ParallelProfileSPD` are genuinely parallel; `Mumps` is the serial wrapper, the
`Petsc` branch is empty, and `SuperLU_DIST`/`MumpsParallelSOE` are unreachable
from the Python command string.

---

## 6. Verification performed for this round

| Check | Command | Exit / result |
|---|---|---|
| `PythonModule.cpp` serial | `g++ -std=c++17 -fsyntax-only …` | 0 |
| `PythonModule.cpp` MPI | + `_PARALLEL_INTERPRETERS` + stub `mpi.h` | 0 |
| `PythonModule.cpp` MPI+renamed | + `OPS_PY_MODULE_NAME`/`OPS_PY_INIT_SYMBOL` | 0 |
| `MPI_MachineBroker.cpp` MPI | same include set | 0 |
| `MPI_Channel.cpp` MPI | after extending the stub with `MPI_Status`, `MPI_CHAR`, `MPI_Send`, `MPI_Recv` | 0 (stub-based) |
| `OpenSeesCommands.cpp` serial **and** MPI | + `-IOTHER/CSPARSE -IOTHER/UMFPACK` | 0 / 0 |
| suffix helper, 3 branches | `cmake -P` with assertions | `.pyd`, `.cpython-312-…so`, `.so` |
| CMake block ON | harness configure | target created, 9 sources, `SUFFIX='.cpython-312-x86_64-linux-gnu.so'`, `OUTPUT_NAME='opensees_mpi'`, `MPI_Channel.cpp` present, duplicates absent |
| CMake block OFF | harness configure | no target, exit 0 |
| duplicate-source scan | comment-aware scan of every CMakeLists | no module source compiled by any library |
| `build-linux.sh` / `build.sh` | `bash -n` | syntax OK |
| `build-linux.sh --check-only` | executed on this host | correct status table, exit **2** (MPI missing) |
| `build-windows.ps1`, `build.ps1`, `tests/run_all.ps1` | PowerShell 7.4.6 `Parser::ParseFile` | PARSE OK ×3 |
| `build-windows.ps1 -CheckOnly` | executed under PowerShell 7.4.6 | correct status table, exit **2** |
| Bash scripts run end-to-end | — | **NOT RUN** (no MPI) |
| Full compile / link / `mpiexec` | — | **NOT RUN** |
| PowerShell 5.1 execution | — | **NOT RUN** (no Windows); script avoids PS7-only syntax and is parsed clean |

---

## 7. Remaining risk register (post-fix)

| ID | Risk | Severity | Note |
|---|---|---|---|
| R1 | First real link may still fail on symbols from optional libraries (PFEM/UMFPACK paths pulled in by `OpenSeesCommands.cpp`) | High | only a real toolchain answers this |
| R2 | `MPI_Init(&argc,&argv)` with `argc=0, argv=nullptr` on MS-MPI | High | first thing to test on Windows |
| R3 | Python-side parallel static analysis is limited to `MPIDiagonal`/`ParallelProfileSPD` | High | unchanged by design |
| R4 | `_PARALLEL_INTERPRETERS` makes the whole tree MPI-capable ⇒ dedicated build dir mandatory | Medium | option defaults `OFF`; scripts enforce separate dirs |
| R5 | Symbol interposition when both modules load (D7) | Medium | open |
| R6 | `/MT` vs `/MD` CRT mismatch on Windows | Medium | scripts pass `MultiThreadedDLL` |
| R7 | METIS/MSVC build of `OTHER/METIS` | Medium | unverified |
| R8 | `shutdown()` collective during interpreter teardown | Medium | guarded against post-finalize, not against rank skew |

---

## 8. What is still missing before any functional claim

1. a real `cmake --build … --target OpenSeesPyMPI` on Linux with MPICH/Open MPI;
2. `import opensees_mpi` and `getMPIRank()` at `-n 1`, then `-n 2`/`-n 4`;
3. `ops.partition()` on a real mesh, with per-rank element counts summing to the model;
4. the frame benchmark against serial, with recorded `worst|Δ|`;
5. the same on Windows with MS-MPI.

Until those exist, the accurate statement remains: **source-justified design,
type-checked code, configure-verified build graph, unit-verified suffix logic —
never compiled, never linked, never run under MPI.**
