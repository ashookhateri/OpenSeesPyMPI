# CHANGELOG — OpenSeesPyMPI

All changes are relative to upstream `OpenSees/OpenSees` commit
`5b9b70511e04e8f1b65710edb98fdffd8ef3add0` (2026-11-13) on branch
`feature/openseespy-mpi`.

Legend: **[TC]** = parsed/type-checked only (`-fsyntax-only`, no object file),
**[CFG]** = CMake configure verified against stubbed targets, **[UT]** = logic
executed and asserted in isolation, **[RUN]** = process actually executed,
**[NU]** = NOT RUN here (blocked by missing MPI/Windows/toolchain).
Type-checking is never counted as compilation.

---

## 2026-11-19 — Phase 2b: P0/P1 remediation after the technical audit

Source of the work items: `TECHNICAL_AUDIT.md` (findings D1-D9).

### 1. `CMakeLists.txt` — link fix, duplicate removal, correct artefact name

- **D1 (P0):** `\${OPS_SRC_DIR}/actor/channel/MPI_Channel.cpp` added to the target.
  It was previously compiled only into `OpenSeesMP`/`OpenSeesSP`, so the module
  referenced `MPI_Channel` symbols it never defined.
- **D6 (P1):** `ActorSubdomain.cpp` and `ShadowSubdomain.cpp` removed; they are
  already compiled inside `OPS_Domain` (in `OpenSeesLIB`).
  `PartitionedDomain*.cpp` stay, because upstream comments them out of `OPS_Domain`.
- **D2 (P0, Windows):** `OUTPUT_NAME "opensees_mpi"` + `SUFFIX` from the new helper;
  the install rule copies the target verbatim instead of renaming with
  `${CMAKE_SHARED_MODULE_SUFFIX}` (which is `.dll` on Windows).
- Added a fail-fast check that `TARGET METIS` exists.
- All link libraries are now `PRIVATE` (no interface leakage into other targets).

### 2. `cmake/cmake/OpenSeesPyMPISuffix.cmake` (new file)

`ops_py_module_suffix(<outvar>)` returns `.pyd` on Windows,
`.${Python_SOABI}${CMAKE_SHARED_MODULE_SUFFIX}` when a SOABI is known, else
`${CMAKE_SHARED_MODULE_SUFFIX}`. It is a separate file so that all three branches
can be unit-tested with `cmake -P` on any host. **[UT] verified for all 3 branches.**

### 3. `SRC/actor/machineBroker/MPI_MachineBroker.cpp` / `.h`

- `ownsMPI` (from Phase 2) unchanged.
- **D8 (P1):** the destructor now also checks `MPI_Finalized()` before calling
  `MPI_Finalize()`, so a host that finalized MPI itself cannot be finalized twice.

### 4. `SRC/interpreter/OpenSeesCommands.cpp`

- **D8 (P1):** `~OpenSeesCommands()` checks `MPI_Finalized()` before
  `theMachineBroker->shutdown()`. That call is collective; issuing it after
  finalization aborted the process during interpreter teardown.

### 5. `SRC/interpreter/PythonModule.cpp`

Two more wrappers, still read-only w.r.t. the communicator:

- `isMPIFinalized()` → `MPI_Finalized`
- `mpiAbort(errorcode=1)` → `MPI_Abort(MPI_COMM_WORLD, errorcode)`, so a failing
  rank can tear the job down instead of leaving the others blocked.

### 6. Build scripts (rewritten, PS 5.1 + 7 compatible)

- New independent scripts: **`build-linux.sh`** and **`build-windows.ps1`**;
  `build.sh` / `build.ps1` are now 3-line forwarders.
- **D3/D4:** no `?.`, no `??`, no ternary, no `-AdditionalChildPath`, and no
  assignment to `$args`. Verified: `bash -n` ×2, PowerShell 7.4.6 parser ×3. **[RUN]**
- **D5:** METIS guessing removed. Headers are visible through the global
  `OTHER/**/*.h` include glob; `-MetisRoot` (Windows) passes the variables
  `FindMETIS.cmake` actually reads (`METIS_INCLUDES`, `METIS_LIBRARIES`).
- **D9:** both scripts now build `build-mpi/` and `build-serial/` at the repo root,
  matching the documentation, and write `configure.log` / `build.log` there.
- Added `--check-only` / `-CheckOnly` dependency report (exit 2 when blocked) and
  a check that the test suite is present before printing test commands. **[RUN]**

### 7. Documentation

- New `TECHNICAL_AUDIT.md` (findings, evidence, fix status, risk register).
- `TEST_REPORT.md`, `README.md`, `BUILD_WINDOWS.md`, `ARCHITECTURE.md`,
  `tests/README.md` updated for the new names, suffix handling, METIS behaviour and
  the two-round verification status.
- New `tests/test_6_lifecycle_safety.py` for the `MPI_Finalized`/abort surface.

### Not changed on purpose

No solver work, no new OpenSees classes, no visibility/export hardening (D7 stays
open and documented), no rewrite of `OPS_partition()`. The goal of this round was a
correct, buildable extension, not new capability.

### Status after Phase 2b

Type-checked: 7/7 invocations. Configure-verified: ON/OFF. Unit-verified: suffix
helper. **Compiled: 0. Linked: 0. MPI runs: 0.** No functional claim is made.

---

## 2026-11-19 — Phase 2: minimal implementation

### 1. `CMakeLists.txt` — new `OPS_BUILD_PYMPI` option and `OpenSeesPyMPI` target

**Why:** `SRC/interpreter/OpenSeesMiscCommands.cpp` implements `OPS_partition()`
entirely inside `#ifdef _PARALLEL_INTERPRETERS` (line 1965 onward), and
`OpenSeesCommands::OpenSeesCommands()` creates the MPI broker inside the same
guard. The stock `OpenSeesPy` target never defines it, so the Python MPI path
exists but is dead code in every shipped wheel. `_PARALLEL_INTERPRETERS` is a
**PUBLIC** definition of the `OpenSeesMP` *executable*, so it never reaches the
`OPS_INTERPRETER` objects that are baked into `OpenSeesLIB` — a per-executable
definition cannot switch this path on.

**Change:**
- `option(OPS_BUILD_PYMPI "Build the OpenSeesPyMPI module (Python + MPI)" OFF)`
- fatal errors if MPI or Python development files are missing
- `target_compile_definitions(OPS_INTERPRETER PUBLIC _PARALLEL_INTERPRETERS ${MUMPS_FLAG})`
  so `OPS_partition()` and the broker path are compiled into `OpenSeesLIB`
- `target_link_libraries(OpenSeesLIB PUBLIC ${MPI_CXX_LIBRARIES} METIS)` so the
  newly reachable symbols resolve for every consumer in the tree
- new target `OpenSeesPyMPI` (SHARED, `PREFIX ""`) with exactly the sources the
  existing `OpenSeesSP`/`OpenSeesMP` targets already use for partitioning
  (`PartitionedDomain*`, `ActorSubdomain`, `ShadowSubdomain`,
  `MPI_MachineBroker`, `MPIDiagonalSOE/Solver`) plus `PythonModule.cpp`
- module identity defines: `OPS_PY_MODULE_NAME="opensees_mpi"`,
  `OPS_PY_INIT_SYMBOL=opensees_mpi`
- install rule producing `opensees_mpi${CMAKE_SHARED_MODULE_SUFFIX}`

**Consequence (documented, not a bug):** with `OPS_BUILD_PYMPI=ON` the whole
build tree becomes MPI-capable, so a dedicated build directory is required to
preserve the serial `opensees` module.

**Verification:** CMake 3.28.3 configured the new block against stubbed sibling
targets — `ON`: target created, 10 sources, defines
`_PARALLEL_INTERPRETERS;_NOMUMPS;OPS_PY_MODULE_NAME="opensees_mpi";OPS_PY_INIT_SYMBOL=opensees_mpi`;
`OFF`: no target created, configure exit 0. **[T]**

### 2. `SRC/interpreter/PythonModule.cpp` — module identity + MPI introspection

**Why:** the module name was the literal `"opensees"` in `PyModuleDef` and the
entry point was the literal `PyInit_opensees`. Without a rename, the MPI build
would shadow or clash with an installed serial OpenSeesPy. Separately, Phase 4
requires rank / size / communication checks that no existing command exposes.

**Change:**
- `OPS_PY_MODULE_NAME` / `OPS_PY_INIT_SYMBOL` macros default to `"opensees"` /
  `opensees` (serial behaviour byte-for-byte unchanged) and are overridden by the
  MPI target; `PyMODINIT_FUNC OPS_PY_CONCAT(PyInit_, OPS_PY_INIT_SYMBOL)(void)`
- under `#ifdef _PARALLEL_INTERPRETERS`, five read-only wrappers:
  `isMPIInitialized()`, `getMPIRank()`, `getMPISize()`, `mpiBarrier()`,
  `mpiSum(x)` — each calls only `MPI_Initialized`, `MPI_Comm_rank`,
  `MPI_Comm_size`, `MPI_Barrier`, `MPI_Allreduce`; none initializes, finalizes
  or creates a communicator
- registered with `PyModule_AddFunctions()` inside `PyInit_*`

**Verification:** `g++ -std=c++17 -fsyntax-only` with the project's include
directories, in three configurations (serial, `_PARALLEL_INTERPRETERS`,
`_PARALLEL_INTERPRETERS` + renamed module) — exit 0 in all three. The MPI
configurations were checked against a **stub `mpi.h`** (real MPI headers are not
installable here), so MPI *APIs* are not verified, only the C++/Python C-API
code. **[C]**

### 3. `SRC/actor/machineBroker/MPI_MachineBroker.{h,cpp}` — MPI ownership

**Why:** the constructor already guards initialization
(`MPI_Initialized(&flag); if (!flag) MPI_Init(...)`), but the destructor called
`MPI_Finalize()` unconditionally. In the Python path the broker is destroyed from
`Py_AtExit → cleanupFunc → ~OpenSeesCommands`, so a host application (mpi4py,
a test harness, a driver that called `MPI_Init`) would have its communicator
finalized out from under it.

**Change:** `bool ownsMPI;` set from `MPI_Initialized`; `MPI_Finalize()` only
when `ownsMPI`. `MPI_Init` behaviour is unchanged for `OpenSeesMP`/`OpenSeesSP`,
where the broker is always the initializer, so both executables still finalize
exactly as before.

**Verification:** `g++ -std=c++17 -fsyntax-only`, exit 0. **[C]**

---

## Not changed (deliberately)

| Candidate | Reason |
|---|---|
| `SRC/interpreter/OpenSeesCommands.cpp` | the broker path and `MPIDiagonal`/`ParallelProfileSPD` wiring already exist; no edit needed |
| `SRC/interpreter/OpenSeesMiscCommands.cpp` | `OPS_partition()` already implements the METIS decomposition; editing it would be an unnecessary rewrite |
| `PythonWrapper.cpp` | no new command strings needed — the MPI helpers are module-level functions |
| `SRC/domain/domain/partitioned/*` | reused as-is by the new target |
| `Conf.cmake` | the new switch lives next to the target it controls, not in the user config file |

---

## Known limitations carried into Phase 3/4

1. Python's `system` command can only build genuinely parallel SOEs for
   `"MPIDiagonal"` and `"ParallelProfileSPD"`. `"Mumps"` is the **serial** MUMPS
   wrapper; there is no `MumpsParallel` branch; the `"Petsc"` branch is empty.
2. `ops.partition()` requires a **byte-identical mesh** on every rank
   (`MPI_Reduce` + `MPI_MAX` check) and prunes the local `Domain`; it does not
   create `PartitionedDomain` actors.
3. Nothing in this changelog has been compiled into a shared library, linked, or
   executed with `mpiexec` — that environment does not exist here.
