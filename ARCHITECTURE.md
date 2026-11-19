# OpenSeesPyMPI — Source-Code Architecture Report and Design

**Upstream repository:** https://github.com/OpenSees/OpenSees
**Commit analysed:** `5b9b70511e04e8f1b65710edb98fdffd8ef3add0` (2026-11-13, shallow clone, `--depth 1`)
**Branch created for the work:** `feature/openseespy-mpi`
**Analysis rule followed:** every statement below was read from the actual source tree. Nothing is inferred from names alone. No source file was modified during this analysis phase.

---

## Part 1 — What the source tree actually contains

### 1.1 Repository layout (relevant part)

```
OpenSees/
├── CMakeLists.txt              # single top-level build script (all targets)
├── Conf.cmake                  # user switches (OPS_FINAL_TARGET, options)
├── cmake/cmake/                # Find*.cmake, OpenSeesFunctions.cmake, deps per-OS
│   ├── OpenSeesDependenciesWin.cmake      <-- Windows dependency resolution
│   └── OpenSeesDependenciesUnix.cmake
├── OTHER/                      # vendored third-party: BLAS, LAPACK, METIS,
│                               # SuperLU_DIST_4.3, SuperLU_5.1.1, MUMPS, AMD,
│                               # ARPACK, UMFPACK, ITPACK, CSPARSE, Tetgen, ...
├── SRC/
│   ├── actor/                  # actor / channel / machine broker subsystem
│   ├── interpreter/            # Tcl + Python command layers  <-- OpenSeesPy
│   ├── tcl/                    # tclMain, mpiMain, mpiParameterMain  <-- SP/MP mains
│   ├── domain/domain/partitioned/  # PartitionedDomain
│   ├── domain/subdomain/       # ActorSubdomain, ShadowSubdomain
│   ├── analysis/analysis/      # DomainDecompositionAnalysis, StaticAnalysis, ...
│   ├── system_of_eqn/linearSOE/diagonal/  # MPIDiagonalSOE / MPIDiagonalSolver
│   └── ...
└── tests/                      # CTest + python/tcl regression files
```

### 1.2 Build architecture (verified in `CMakeLists.txt`)

The build is a set of **OBJECT libraries** merged into one static `OpenSeesLIB`, plus a few static/shared libraries, plus four executable/module targets:

```cmake
add_library(OPS_INTERPRETER   OBJECT)   # all OpenSeesCommands*.cpp + PythonModule.cpp?  (see note)
add_library(OPS_SysOfEqnPython OBJECT)
...
add_library(OPS_InterpTcl STATIC)       # Tcl command wrappers (TclWrapper.cpp, Tcl*Command.cpp)
add_library(OpenSeesLIB)                # links OPS_INTERPRETER and ~25 other OBJECT libs
set(CMAKE_CXX_STANDARD 17)
```

Targets:

| Target | Type | Entry point | Parallel define | Present in stock tree |
|---|---|---|---|---|
| `OpenSees` | executable | `SRC/tcl/tclAppInit.cpp`, `tclMain.cpp`, `commands.cpp` | — | yes |
| `OpenSeesSP` | executable | `SRC/tcl/mpiMain.cpp` | `_PARALLEL_PROCESSING` | only if `MPI_FOUND` |
| `OpenSeesMP` | executable | `SRC/tcl/mpiParameterMain.cpp` | `_PARALLEL_INTERPRETERS` | only if `MPI_FOUND` |
| `OpenSeesPy` | SHARED module | `SRC/interpreter/PythonModule.cpp` (`PyInit_opensees`) | **none** | yes |

`install(PROGRAMS $<TARGET_FILE:OpenSeesPy> DESTINATION bin RENAME opensees.so)` — the shipped Python extension name is `opensees`.

**Note on `OPS_INTERPRETER` vs `PythonModule.cpp`:** `SRC/interpreter/CMakeLists.txt` adds the whole `OpenSeesCommands*.cpp` family to the `OPS_INTERPRETER` OBJECT library, but adds `PythonModule.cpp`, `PythonWrapper.cpp`, `PythonStream.cpp` directly to the `OpenSeesPy` target. This asymmetry is the single most important build fact for this project (see Finding F1).

---

## 2. Component-by-component investigation

### 2.1 OpenSeesMP

| Item | Value |
|---|---|
| Exact file path | `SRC/tcl/mpiParameterMain.cpp` (entry point), plus `SRC/tcl/tclMain.cpp`, `SRC/tcl/commands.cpp` |
| Class names | No dedicated class. It uses `MPI_MachineBroker` (instance, stack-allocated as `theMachine`), `FEM_ObjectBrokerAllClasses`, and the global Tcl command state in `commands.cpp` |
| Important functions | `main()`; `g3TclMain(argc, argv, appInitProc, rank, np)`; `OpenSeesParseArgv()`; `MPI_MachineBroker::getPID()/getNP()/getMyChannel()/getRemoteProcess()` |
| Dependencies | MPI, Tcl, METIS, SuperLU_DIST, MUMPS (optional via `_MUMPS`), `PartitionedDomain`, `DistributedSparseGenColLinSOE`, `MPIDiagonalSOE`, `ActorSubdomain`/`ShadowSubdomain`, `ParallelNumberer` |
| Relationships | `CMakeLists.txt` builds it **only if** `MPI_FOUND`; compile definition `_PARALLEL_INTERPRETERS` is applied to the **executable target only**; it starts `MPI_MachineBroker` before any interpreter exists; rank 0 serialises `argv` into an `ID` + `Message` and pushes it to every other rank through `MPI_Channel::sendID/sendMsg`; then **every rank** calls `g3TclMain(...)`, i.e. every rank runs the same Tcl script |

**Functionally:** OpenSeesMP = *"same script on every rank, each rank keeps one partition"*. Process ownership stays inside one `MPI_MachineBroker` per rank; rank 0 additionally owns an array of `Channel*` of length `np-1`.

### 2.2 OpenSeesSP

| Item | Value |
|---|---|
| Exact file path | `SRC/tcl/mpiMain.cpp` |
| Class names | `MPI_MachineBroker`, `ShadowSubdomain`, `ActorSubdomain`, `FEM_ObjectBrokerAllClasses`, `PartitionedDomain` |
| Important functions | `main()`; `theMachineBroker->runActors()` (secondary ranks); `g3TclMain(argc, argv, TCL_LOCAL_APPINIT, 1, 0)` (rank 0 only); `theDomain.clearAll()`; `theMachineBroker->shutdown()` |
| Dependencies | MPI, Tcl, METIS, SuperLU_DIST, MUMPS, `PartitionedDomain`, `DistributedSuperLU`, `MumpsParallelSOE`, `ActorSubdomain`, `ShadowSubdomain` |
| Relationships | Built **only if** `MPI_FOUND`; compile definition `_PARALLEL_PROCESSING`; global `PartitionedDomain theDomain` is declared in `SRC/tcl/commands.cpp` under `_PARALLEL_PROCESSING` |

**Functionally:** OpenSeesSP = *"master/slave actor model"*. Rank 0 runs the interpreter and owns `ShadowSubdomain` proxies; ranks 1..n-1 never interpret anything — they spin in `MachineBroker::runActors()`, which loops: `recvID` → `theObjectBroker->getNewActor(actorType, theChannel)` → `theActor->run()` → `delete theActor`, until a `0` ID arrives.

> **Explicit warning (requested): OpenSeesMP and OpenSeesSP are not two names for the same thing.**
> OpenSeesSP = partitioned object model (actor/shadow, one interpreter, `_PARALLEL_PROCESSING`).
> OpenSeesMP = replicated interpreter model (every rank interprets, `_PARALLEL_INTERPRETERS`).
> They share `MPI_MachineBroker`, `MPI_Channel`, METIS and SuperLU_DIST, and nothing else about their control flow.

### 2.3 OpenSeesPy

| Item | Value |
|---|---|
| Exact file path | `CMakeLists.txt` → target `OpenSeesPy`; sources `SRC/interpreter/PythonModule.cpp`, `SRC/actor/objectBroker/FEM_ObjectBrokerAllClasses.cpp`; also `SRC/interpreter/pythonMain.cpp` (82 lines, standalone embedding host) |
| Class names | `PythonModule` (subclass of `DL_Interpreter`), `PythonWrapper`, `PythonStream`, `OpenSeesCommands`, `OpenSeesCommandsPython` |
| Important functions | `PyInit_opensees()` (module entry), `getmethodsFunc()`, `cleanupFunc()` (registered with `Py_AtExit`), `PythonModule::run()`, `PythonModule::runCommand()` (`PyRun_SimpleString`), `PythonModule::evalDoubleStringExpression()`, the whole `OPS_*` C API surface in `OpenSeesCommands*.cpp`, `PythonWrapper::addOpenSeesCommands()` |
| Dependencies | `OpenSeesLIB`, `OPS_SysOfEqnPython`, `OPS_Reliability`, `OPS_Recorder`, `OPS_Numerics`, HDF5, ZLIB, Eigen3, `${Python_LIBRARIES}` — **no MPI, no METIS, no SuperLU_DIST** |
| Relationships | Shares `OpenSeesLIB` (and therefore the same `OPS_INTERPRETER` objects) with the `OpenSees` executable; module name is hard-coded `"opensees"` in `PyModuleDef`; exports `OpenSeesError` exception + `OpenSeesParameter` dict |

### 2.4 `SRC/interpreter/PythonModule.cpp` (577 lines)

| Item | Value |
|---|---|
| Class names | `PythonModule : public DL_Interpreter`; file-local `struct module_state` |
| Important functions | constructor `PythonModule()` (creates `PythonWrapper wrapper` and `OpenSeesCommands cmds`), `run()`, `addCommand()`/`removeCommand()` (both return `-1` — commands live in the wrapper), `getInt/getDouble/getDoubleList/getString/getStringFromAll/getVoidPtr`, `setInt/setDouble/setString/setGenericDict`, `trimSpaces`, `resetInput`, `runCommand`, `evalDoubleStringExpression`; statics `getmethodsFunc()`, `cleanupFunc()`, `PyInit_opensees()`, `opensees_traverse/clear` |
| Dependencies | `Python.h`, `PythonWrapper`, `OpenSeesCommands`, `OPS_Globals.h` |
| Relationships | Defines the **global** `opserrPtr` (`static PythonStream sserr`) used by the entire OpenSees source in the Python build; owns the single `PythonModule* module`, deleted at `Py_AtExit` |

### 2.5 `SRC/interpreter/OpenSeesCommands.cpp` (3609 lines)

| Item | Value |
|---|---|
| Class names | `OpenSeesCommands` (declared in `OpenSeesCommands.h`) |
| Important functions | 22 member definitions, of which the structural ones are `setSOE`, `setNumberer`, `setHandler`, `setCTest`, `setStaticIntegrator`, `setTransientIntegrator`, `setAlgorithm`, `setStaticAnalysis`, `setVariableAnalysis`, `setTransientAnalysis`, `setPFEMAnalysis`, `wipeAnalysis`, `wipe`, `setFileDatabase`, `eigen`; free functions `OPS_*` implement the command surface; a static `OpenSeesCommands* cmds` is the active object |
| Dependencies | ~200 OpenSees headers; conditionally `<mpi.h>`, `MPI_MachineBroker`, `MPIDiagonalSOE`, `Distributed*SOE`, `ParallelNumberer`, `PartitionedDomain`, `MumpsParallelSOE` |
| Relationships | Instantiated inside `PythonModule`; supplies the `theDomain`, analysis aggregates and (under `_PARALLEL_INTERPRETERS`) the MPI broker + channel arrays |

**Verified behaviours that matter for the design:**

1. Under `_PARALLEL_INTERPRETERS` the constructor does:
   ```cpp
   theMachineBroker = new MPI_MachineBroker(&theBroker, 0, 0);   // argc=0, argv=nullptr
   rank==0 → theChannels = new Channel*[np-1]; fill via getRemoteProcess()
   rank>0  → theChannels[0] = getMyChannel()
   ```
   and the destructor calls `theMachineBroker->shutdown()` then `delete theMachineBroker`.
2. `theDomain = new Domain;` **always** — even in the parallel build the Python layer never instantiates `PartitionedDomain`.
3. `setSOE` accepts the string `"MPIDiagonal"` **only** under `_PARALLEL_INTERPRETERS` (otherwise it silently falls back to the serial `Diagonal` solver), and `"ParallelProfileSPD"` builds a `DistributedProfileSPDLinSOE` wired to the broker's rank/channels. `"Petsc"` matches but has an **empty body** (no SOE is created). `"Mumps"` → `OPS_MumpsSolver()` under `#ifdef _MUMPS`, and there is **no** `MumpsParallel` string branch.

### 2.6 MPI communication classes

| Item | Value |
|---|---|
| Exact file paths | `SRC/actor/channel/MPI_Channel.h/.cpp` (495 lines cpp), `SRC/actor/address/MPI_ChannelAddress.h/.cpp`, base `SRC/actor/channel/Channel.h` |
| Class names | `MPI_Channel : public Channel`, `MPI_ChannelAddress : public ChannelAddress` |
| Important functions | `MPI_Channel(int otherProcess)`, `setUpConnection`, `sendObj`/`recvObj`, `sendMsg`/`recvMsg`/`recvMsgUnknownSize`, `sendMatrix`/`recvMatrix`, `sendVector`/`recvVector`, `sendID`/`recvID`, `setNextAddress`, `getLastSendersAddress`; private `int otherTag; MPI_Comm otherComm;` |
| Dependencies | `<mpi.h>`, `Channel`, `MovableObject`, `FEM_ObjectBroker`, `Matrix`, `Vector`, `ID`, `Message` |
| Relationships | Created in arrays by `MPI_MachineBroker` (one per peer); used by `mpiParameterMain.cpp` to broadcast `argv`, by `MachineBroker::runActors()` to receive actor-type IDs, by `ShadowSubdomain`/`ActorSubdomain` for object shipping, and by `Distributed*SOE`/`ParallelNumberer` for system assembly |

### 2.7 MachineBroker classes

| Item | Value |
|---|---|
| Exact file paths | `SRC/actor/machineBroker/MachineBroker.h/.cpp` (abstract), `MPI_MachineBroker.h/.cpp` (127 lines cpp), plus `AlphaMachineBroker`, `DecMachineBroker`, `MillMachineBroker` |
| Class names | `MachineBroker`, `MPI_MachineBroker : public MachineBroker` |
| Important functions | `MachineBroker::runActors()` (slave loop: `recvID` → `getNewActor` → `sendID` status → `theActor->run()` → `delete`), `startActor(int actorType, int compDemand)`, `finishedWithActor`, `shutdown`; `MPI_MachineBroker::getPID/getNP/getMyChannel/getRemoteProcess/freeProcess` |
| Dependencies | `<mpi.h>`, `ID`, `FEM_ObjectBroker`, `Channel`, `MPI_Channel` |
| Relationships | Owns `MPI_Channel** theChannels` of length `size` and `ID* usedChannels`; `getMyChannel()` returns `theChannels[0]`; `getRemoteProcess()` is rank-0-only and errors on other ranks. Constructor contains the **only** `MPI_Init` in the Python path; destructor contained an unconditional `MPI_Finalize()` (patched — see Part 3) |

### 2.8 Domain decomposition

| Item | Value |
|---|---|
| Exact file paths | `SRC/domain/domain/partitioned/PartitionedDomain.h/.cpp` (+`PartitionedDomainEleIter.cpp`, `PartitionedDomainSubIter.cpp`), `SRC/domain/subdomain/{Subdomain,ActorSubdomain,ShadowSubdomain}.h/.cpp`, `SRC/analysis/analysis/DomainDecompositionAnalysis.h`, `SRC/analysis/analysis/StaticAnalysis.*`, `SRC/graph/partitioner/{GraphPartitioner,MetisWrapper}.h`, `SRC/graph/numberer/MetisNumberer.h`, `SRC/system_of_eqn/linearSOE/diagonal/MPIDiagonalSOE.*` |
| Class names | `PartitionedDomain : public Domain`, `Subdomain`, `ActorSubdomain : public Subdomain, public Actor`, `ShadowSubdomain : public Shadow, public Subdomain`, `DomainDecompositionAnalysis : public Analysis, public MovableObject`, `Metis : public GraphPartitioner` |
| Important functions | `PartitionedDomain::partition(...)`, `addElement/addNode/addSP_Constraint/addMP_Constraint`, `hasDomainChanged`, `update/commit/revertToLastCommit`, `eigenAnalysis`; `DomainDecompositionAnalysis::analyze(double)`, `newStep`, `analysisStep`, `formTangent`, `formResidual`, `getNumExternalEqn`, `sendSelf/recvSelf`; `ActorSubdomain::run()`; `MachineBroker::runActors()` |
| Dependencies | METIS (`METIS_PartMeshNodal`), `MPI_Channel`, `FEM_ObjectBroker`, `ID`, `Matrix`, `Vector`, `Message`, SuperLU_DIST/MUMPS for the distributed SOEs |
| Relationships | Used **only** by OpenSeesSP/MP and by `SRC/tcl/commands.cpp` under `_PARALLEL_PROCESSING`; **not reachable from Python** |

**Crucial distinction found in the Python path:** the Python command `ops.partition()` in `SRC/interpreter/OpenSeesMiscCommands.cpp` (lines 1965-2283, guarded by `#ifdef _PARALLEL_INTERPRETERS`) does **not** build a `PartitionedDomain` and does **not** create `ShadowSubdomain` actors. It:

1. reads rank/np from `MPI_COMM_WORLD`;
2. collects the node and element connectivity of the **local full model**;
3. checks via `MPI_Reduce(MPI_MAX)` that all ranks hold the *same* mesh;
4. runs `METIS_PartMeshNodal` **on rank 0 only**;
5. `MPI_Bcast`s the element and node partitions;
6. **deletes** every non-local element, node, `SP_Constraint`, `MP_Constraint`, nodal load and elemental load from each rank's own `Domain`.

So the "distributed domain" in OpenSeesPyMPI is *N pruned replicas of one full non-partitioned `Domain`*, one per rank — architecturally different from OpenSeesSP's object-decomposed `PartitionedDomain`.

### 2.9 CMake configuration (facts that constrain the design)

| Fact | Evidence | Consequence |
|---|---|---|
| `find_package(MPI)` is called at top level; METIS + SuperLU_DIST are only added `if(MPI_FOUND)` | `CMakeLists.txt` (MPI block, ~line 435) | No MPI ⇒ no METIS ⇒ `OPS_partition()` has no symbol to call |
| `_PARALLEL_INTERPRETERS` is a **PUBLIC** definition of the `OpenSeesMP` **executable** | `CMakeLists.txt` OpenSeesMP block | It does **not** reach `OPS_INTERPRETER` objects, which are compiled on their own |
| `OPS_INTERPRETER` is an OBJECT library embedded in `OpenSeesLIB`; `OpenSeesPy` links `OpenSeesLIB` | `SRC/CMakeLists.txt`, `CMakeLists.txt` | A single `.cpp` cannot be compiled twice with different defines in one build tree |
| Windows: `MSVC` branch sets `CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded"` (static CRT) and `BUILD_SHARED_LIBS OFF` | `CMakeLists.txt` ~line 92 | Mixing with a DLL Python/MS-MPI is a known link hazard; the Python module must be `SHARED` and consistent |
| Windows dependency resolution exists | `cmake/cmake/OpenSeesDependenciesWin.cmake` | There is a supported Windows dependency path to extend, not invent |
| `MUMPS_DIR` unset ⇒ `-D_NOMUMPS` and empty MUMPS libs | `CMakeLists.txt` MPI block | On Windows without MUMPS, no MUMPS SOE at all |

### 2.10 Python module initialization (exact chain)

```
import opensees_mpi
└── PyInit_opensees (or the renamed symbol)
    ├── getmethodsFunc()
    │   ├── new PythonModule                (PythonModule.cpp)
    │   │   └── OpenSeesCommands(this)      (OpenSeesCommands.cpp)
    │   │       ├── #ifdef _PARALLEL_INTERPRETERS: new MPI_MachineBroker(&theBroker, 0, 0)
    │   │       │       ├── MPI_Initialized?  → no: MPI_Init(&argc,&argv)
    │   │       │       ├── MPI_Comm_rank / MPI_Comm_size
    │   │       │       └── new MPI_Channel[i] for i in 0..np-1
    │   │       ├── theDomain = new Domain
    │   │       └── reliability = new OpenSeesReliabilityCommands(theDomain)
    │   └── PythonWrapper::addOpenSeesCommands()  → PyMethodDef table
    ├── PyModule_Create(&moduledef)         (name = OPS_PY_MODULE_NAME)
    ├── PyModule_AddObject "OpenSeesError", "OpenSeesParameter"
    ├── [patched] PyModule_AddFunctions(MPI introspection)
    └── Py_AtExit(cleanupFunc)
        └── module->getCmds().wipe(); delete module
            └── ~OpenSeesCommands: theMachineBroker->shutdown(); delete theMachineBroker
                └── ~MPI_MachineBroker: [patched] MPI_Finalize() only if it owned MPI
```

---

## 3. Findings that shape the design (numbered, all source-verified)

- **F1 — The Python MPI path already exists but is compiled out.** `OPS_partition()` and the broker construction both sit behind `_PARALLEL_INTERPRETERS`, which the stock `OpenSeesPy` target never defines. OpenSeesPyMPI is therefore primarily a *build-variant + lifecycle* problem, not a rewrite.
- **F2 — The define cannot be scoped to one target.** `OPS_INTERPRETER` (an OBJECT library inside `OpenSeesLIB`) contains `OpenSeesCommands.cpp` and `OpenSeesMiscCommands.cpp`. Enabling the define there affects every consumer of `OpenSeesLIB` in the same build tree ⇒ **a dedicated build directory is mandatory** to "preserve the original OpenSeesPy build".
- **F3 — Duplicate initialization is already guarded.** `MPI_MachineBroker` calls `MPI_Initialized` before `MPI_Init`. No second `MPI_Init` will occur even if a host (mpi4py, pytest-mpi) initialized first.
- **F4 — Finalization was *not* guarded.** The old destructor called `MPI_Finalize()` unconditionally, which is a defect when MPI was initialized outside OpenSees. Patched (see Part 3).
- **F5 — Module name is hard-coded.** `PyModuleDef` name and `PyInit_opensees` are string/identifier literals; without a rename the MPI build would collide with an installed serial `opensees`. Patched via two macros.
- **F6 — Python never gets a `PartitionedDomain`.** `OpenSeesCommands` always creates a plain `Domain`. Distributed analysis from Python can only mean "pruned replicas + distributed SOE", never the actor/shadow decomposition.
- **F7 — Python's distributed solver surface is narrow.** Only `"MPIDiagonal"` and `"ParallelProfileSPD"` produce genuinely parallel SOEs; `"Mumps"` is the serial MUMPS wrapper; `"Petsc"` is an empty branch. General unsymmetric distributed solving (SuperLU_DIST, `MumpsParallelSOE`) is wired for OpenSeesSP/MP only.
- **F8 — `MPI_Init(&argc, &argv)` receives `argc = 0, argv = nullptr`** from `OpenSeesCommands`. Accepted by MPICH/Open MPI; on MS-MPI this is the highest-risk single line in the whole design (see Risk R3).

---

## Part 2 — Architecture for OpenSeesPyMPI

### 2.1 Design principles (in priority order)

1. **Reuse, don't replace.** `MPI_MachineBroker`, `MPI_Channel`, `OPS_partition()` (METIS), `MPIDiagonalSOE`, `DistributedProfileSPDLinSOE` are used as-is.
2. **Never break the serial module.** The serial `opensees` module keeps its target, its sources and its name. MPI work happens through a new option + new target in a separate build tree.
3. **One owner for MPI.** The `MPI_MachineBroker` owns `MPI_Init` only if MPI was not already initialized, and finalizes only in that case.
4. **No invented APIs.** The only Python additions are thin read-only wrappers over MPI calls that already exist in the codebase (`MPI_Comm_rank`, `MPI_Comm_size`, `MPI_Barrier`, `MPI_Allreduce`).
5. **Honest capability boundary.** Where the existing architecture does not permit something (general distributed implicit solve from Python), we document the gap instead of faking it.

### 2.2 Architecture diagram

```
                       ┌──────────────────────────────────────────────┐
                       │  mpiexec -n N python driver.py               │
                       │  (MS-MPI: mpiexec.exe, Linux: mpiexec)       │
                       └───────────────┬──────────────────────────────┘
                                       │ N independent processes
        ┌──────────────────────────────┼──────────────────────────────┐
        │ rank 0                       │ rank 1..N-1                  │
        ▼                              ▼                              ▼
┌────────────────────┐        ┌────────────────────┐        ┌────────────────────┐
│ python interpreter │        │ python interpreter │        │ python interpreter │
│  import            │        │  import            │        │  import            │
│  opensees_mpi      │        │  opensees_mpi      │        │  opensees_mpi      │
├────────────────────┤        ├────────────────────┤        ├────────────────────┤
│ PyInit_opensees_mpi│        │ PyInit_opensees_mpi│        │ PyInit_opensees_mpi│
│  └ PythonModule    │        │  └ PythonModule    │        │  └ PythonModule    │
│     └ OpenSeesCmds │        │     └ OpenSeesCmds │        │     └ OpenSeesCmds │
│        └ MPI_MachineBroker ─┼── MPI_Channel ─────┼─ MPI_Channel ──────────────┤
│           (MPI_Initialized │ │   (point-to-point,│ │  all MPI_COMM_WORLD ops)│
│            guard; owns MPI)│ │    tags per pair) │ │                         │
├────────────────────┤        ├────────────────────┤        ├────────────────────┤
│ Domain (full model)│        │ Domain (full model)│        │ Domain (full model)│
│  ↓ ops.partition() │        │  ↓ ops.partition() │        │  ↓ ops.partition() │
│ Domain (pruned to  │        │ Domain (pruned to  │        │ Domain (pruned to  │
│  METIS part 0)     │        │  METIS part 1)     │        │  METIS part N-1)   │
├────────────────────┤        ├────────────────────┤        ├────────────────────┤
│ analysis + SOE     │        │ analysis + SOE     │        │ analysis + SOE     │
│ MPIDiagonal /      │        │ MPIDiagonal /      │        │ MPIDiagonal /      │
│ ParallelProfileSPD │        │ ParallelProfileSPD │        │ ParallelProfileSPD │
└─────────┬──────────┘        └─────────┬──────────┘        └─────────┬──────────┘
          │  METIS on rank 0 only: METIS_PartMeshNodal               │
          │  MPI_Reduce (mesh equality) / MPI_Bcast (epart, npart)   │
          └──────────────────────────────────────────────────────────┘
                       Py_AtExit → cleanupFunc → ~OpenSeesCommands
                                 → broker->shutdown() (barrier/collectives)
                                 → ~MPI_MachineBroker → MPI_Finalize()
                                   (only if this process owned MPI)
```

### 2.3 Component dependency graph

```
OpenSeesPyMPI (new SHARED target)
├── PythonModule.cpp ─────────────► Python.h
│   ├── PythonWrapper.cpp ────────► all OPS_* commands
│   └── PythonStream.cpp ─────────► OPS_Stream
├── FEM_ObjectBrokerAllClasses.cpp ─► every OpenSees class tag
├── MPI_MachineBroker.cpp ────────► MachineBroker, MPI_Channel, mpi.h
│   └── MPI_Channel.cpp ──────────► Channel, MovableObject, Matrix, Vector, ID, Message, mpi.h
├── PartitionedDomain*.cpp ───────► Domain, METIS (via GraphPartitioner), Subdomain
│   └─ (ActorSubdomain.cpp / ShadowSubdomain.cpp are NOT compiled here:
│       they already live in OPS_Domain inside OpenSeesLIB — audit D6)
├── MPIDiagonalSOE.cpp ───────────► LinearSOE, MPIDiagonalSolver, mpi.h
│   └── MPIDiagonalSolver.cpp
└── OpenSeesLIB (OBJECT-lib aggregate, compiled with _PARALLEL_INTERPRETERS)
    ├── OPS_INTERPRETER  ──► OpenSeesCommands.cpp, OpenSeesMiscCommands.cpp (OPS_partition)
    ├── OPS_Domain, OPS_Analysis, OPS_Element, OPS_Material, OPS_SysOfEqn, ...
    └── links: METIS, SUPERLU_DIST, HDF5::HDF5, ZLIB::ZLIB, Eigen3::Eigen,
               ${MPI_CXX_LIBRARIES}, ${Python_LIBRARIES}
```

Direction of dependency is strictly downward; no new edge is introduced between `OPS_INTERPRETER` and the Python target (that edge already exists through `OpenSeesLIB`).

### 2.4 Process ownership and communication lifecycle

| Phase | Rank 0 | Rank > 0 | MPI calls |
|---|---|---|---|
| import | creates broker → `MPI_Init` if needed → owns channels 0..np-2 | same, but keeps only `theChannels[0]` | `MPI_Initialized`, `MPI_Init`, `MPI_Comm_rank/size` |
| model build | identical script ⇒ identical model | identical script ⇒ identical model | none (deterministic, no communication) |
| `ops.partition()` | `MPI_Reduce` mesh check, `METIS_PartMeshNodal`, `MPI_Bcast` | `MPI_Reduce`, wait for bcast | `MPI_Reduce`, `MPI_Bcast` |
| analysis | local assembly + distributed SOE exchanges | same | `MPI_Channel` point-to-point (tags per peer) |
| barrier/debug | `ops.mpiBarrier()` | same | `MPI_Barrier` |
| exit | `Py_AtExit` → `shutdown()` → `MPI_Finalize` | same | collectives, then finalize |

**Ownership rule:** exactly one `MPI_MachineBroker` per process, created lazily inside `OpenSeesCommands`, destroyed with the module. No script, driver, or test may call `MPI_Init`/`MPI_Finalize` directly against this module.

### 2.5 Required source-file modifications (implemented, see Part 3)

| File | Change | Why (source-justified) |
|---|---|---|
| `CMakeLists.txt` | `option(OPS_BUILD_PYMPI)`, `OpenSeesPyMPI` target (9 sources incl. `MPI_Channel.cpp`), `_PARALLEL_INTERPRETERS` on `OPS_INTERPRETER`, METIS/MPI on `OpenSeesLIB`, `OUTPUT_NAME`+`SUFFIX`, install rule | F1, F2, D1, D2, D6 |
| `SRC/interpreter/PythonModule.cpp` | `OPS_PY_MODULE_NAME` / `OPS_PY_INIT_SYMBOL` macros; MPI introspection functions (`isMPIInitialized`, `getMPIRank`, `getMPISize`, `isMPIFinalized`, `mpiBarrier`, `mpiAbort`, `mpiSum`) under `_PARALLEL_INTERPRETERS` | F5 + testability + D8 |
| `SRC/interpreter/OpenSeesCommands.cpp` | `MPI_Finalized()` guard before the collective `shutdown()` in the destructor | D8 |
| `SRC/actor/machineBroker/MPI_MachineBroker.h/.cpp` | `bool ownsMPI`; finalize only when owned; `MPI_Finalized()` guard in the destructor | F4, D8 |

### 2.6 New source files

**One CMake helper module** (no C++ file): `cmake/cmake/OpenSeesPyMPISuffix.cmake` defines
`ops_py_module_suffix(<outvar>)`. It exists as a separate file precisely so all
three platform branches can be executed and asserted with `cmake -P` on any host
(a `CMakeLists.txt`-embedded `if(WIN32)` cannot be tested from one operating
system). Nothing else was added: every capability is reached through existing
classes, and the MPI introspection helpers live in `PythonModule.cpp`, the file
that already owns module-level init.

### 2.7 Build sequence

```
# serial module (unchanged behaviour)
cmake -S . -B build-serial -DOPS_FINAL_TARGET=OpenSeesPy
cmake --build build-serial --target OpenSeesPy -j

# MPI module (separate tree, mandatory)
cmake -S . -B build-mpi -DOPS_BUILD_PYMPI=ON \
      -DCMAKE_PREFIX_PATH=<tcl;eigen;hdf5;mpi> \
      -DMPI_CXX_COMPILER=<mpicxx or MS-MPI wrapper>
cmake --build build-mpi --target OpenSeesPyMPI -j
# artefact: opensees_mpi.so / opensees_mpi.pyd
```

### 2.8 Windows compatibility requirements

| Requirement | Detail |
|---|---|
| Toolchain | Visual Studio 2022 (v143), x64, C++17 (project already sets `CMAKE_CXX_STANDARD 17`) |
| MPI | Microsoft MPI v10.1 (MS-MPI) via `msmpisdk.msi` + `msmpisetup.exe`; CMake finds `msmpi.lib` / `mpi.h` |
| Python | CPython 3.10-3.12 x64 with `Python.h`; must match the MPI process bitness |
| CRT | Project defaults to `/MT` (`CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded"`); the Python module must not mix `/MT` objects with a `/MD` CPython runtime — the script forces `/MD` for the module and its dependencies |
| Extension suffix | `.pyd`. **Not** from `CMAKE_SHARED_MODULE_SUFFIX` — on Windows that variable is `.dll` (`Platform/Windows.cmake` ⇒ `CMakeSystemSpecificInformation.cmake:60`), which cannot name a CPython extension. The target sets `SUFFIX` from `ops_py_module_suffix()` in `cmake/cmake/OpenSeesPyMPISuffix.cmake` (`.pyd` on `WIN32`, `.${Python_SOABI}${suffix}` on Linux/macOS). Export of `PyInit_opensees_mpi` is handled by `PyMODINIT_FUNC`, so no `WINDOWS_EXPORT_ALL_SYMBOLS` is needed |
| Fortran | The project declares `LANGUAGES C CXX Fortran`; without a Fortran compiler CMake must be told (`-DCMAKE_Fortran_COMPILER=`) or gfortran/ifx installed |
| Missing on Windows | METIS payload for MSVC (present under `OTHER/METIS`), SuperLU_DIST, MUMPS — MUMPS is effectively unavailable, so `-D_NOMUMPS` |
| Runtime | `msmpi.dll`; run with `mpiexec -n N python driver.py` |

### 2.9 Risk assessment

| ID | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | `_PARALLEL_INTERPRETERS` leaks into the whole tree when `OPS_BUILD_PYMPI=ON` | High | Dedicated build directory; option defaults `OFF`; documented in README |
| R2 | Python cannot select a general distributed sparse solver (F7) ⇒ a steel-frame implicit static analysis may not run in parallel at all | **High** | Explicitly documented; benchmark must report what actually ran; no claim of parallel speedup |
| R3 | `MPI_Init(&argc,&argv)` with `argc=0, argv=nullptr` on MS-MPI | Medium-High | First thing to test on Windows; fallback = synthesise `argv` in `PythonModule` before broker creation |
| R4 | `Py_AtExit` cleanup runs collectives (`shutdown()`) after the interpreter may already be partly torn down | Medium | Test `MPI_Abort`-free exit paths; keep `opserr` usage out of the destructor (already commented as such upstream) |
| R5 | METIS on MSVC may not build from `OTHER/METIS` | Medium | Build METIS separately (CMake `FindMETIS.cmake` exists) or supply prebuilt `metis.lib` |
| R6 | Static CRT (`/MT`) vs CPython (`/MD`) | Medium | Force `/MD` for the module target in `build.ps1` |
| R7 | Two modules (`opensees`, `opensees_mpi`) loaded in one process | Low | Distinct module names + distinct init symbols (F5 patch) |
| R8 | Numerical divergence: pruned domains drop cut-node coupling that only the distributed SOE can recover | High | Compare against serial results; report per-DOF differences |

### 2.10 Testing strategy

1. **Lifecycle (single and multi rank):** import, `isMPIInitialized`, `getMPIRank`, `getMPISize`, barrier, clean exit code 0 — no structural analysis involved.
2. **Partition:** identical mesh on all ranks ⇒ `ops.partition()` returns 0; per-rank element/node counts sum to the global counts; METIS parts are disjoint and cover.
3. **Communication:** `ops.mpiSum()` equals `N × value`; a barrier separates phases.
4. **Analysis:** linear static and nonlinear static (Newton) 2D steel frame on `MPIDiagonal` / `ParallelProfileSPD`, compared against the **serial** `opensees` module running the same script.
5. **Negative tests:** mismatched mesh (must print the "same mesh" warning and fail partition), unknown SOE type, `-n 1` degenerate case.
6. **Reporting:** displacements, reactions, element forces, wall-clock time, absolute/relative differences; every unexecuted test is marked *not run* with the reason.

---

## Part 3 — Implemented changes (see `CHANGELOG.md` for the full log)

| File | Diff size | Purpose |
|---|---|---|
| `CMakeLists.txt` | +32 / −10 | `OPS_BUILD_PYMPI` option, `OpenSeesPyMPI` target (9 sources), define propagation, `OUTPUT_NAME`/`SUFFIX`, `PRIVATE` links, install rule, METIS target check |
| `cmake/cmake/OpenSeesPyMPISuffix.cmake` | new file, 27 lines | `ops_py_module_suffix()` — testable platform suffix logic |
| `SRC/interpreter/PythonModule.cpp` | +25 / −0 | module-name macros + 7 MPI helpers (`isMPIFinalized`, `mpiAbort` added in Phase 2b) |
| `SRC/interpreter/OpenSeesCommands.cpp` | +8 / −1 | `MPI_Finalized()` guard before `shutdown()` |
| `SRC/actor/machineBroker/MPI_MachineBroker.h` | +5 / −0 | `ownsMPI` member |
| `SRC/actor/machineBroker/MPI_MachineBroker.cpp` | +8 / −3 | ownership-aware init/finalize + `MPI_Finalized()` guard |

Verification performed in this environment (full detail in `TEST_REPORT.md`; findings
and remaining risk in `TECHNICAL_AUDIT.md`):

- `g++ -std=c++17 -fsyntax-only` on `PythonModule.cpp` — **passes** in three configurations (serial, `_PARALLEL_INTERPRETERS`, `_PARALLEL_INTERPRETERS` + renamed module).  
  *`-fsyntax-only` emits no object file: this is a parse/type check, not a compilation.*
- `g++ -std=c++17 -fsyntax-only` on `MPI_MachineBroker.cpp`, `MPI_Channel.cpp` (the file D1 added), and `OpenSeesCommands.cpp` (serial **and** MPI) — **passes** against a stub `mpi.h`; no real MPI headers exist on the audit host.
- CMake 3.28.3 configure of the block against stubbed sibling targets — **passes** for `ON` (target created, **9** sources, `MPI_Channel.cpp` present, no duplicates, `SUFFIX='.cpython-312-x86_64-linux-gnu.so'`, `OUTPUT_NAME='opensees_mpi'`) and `OFF` (no target).
- Suffix helper, all three branches, executed with `cmake -P` and asserted — **passes** (`.pyd`, `.cpython-312-…so`, `.so`).
- Build scripts: `bash -n` (2 scripts), PowerShell 7.4.6 parser (3 scripts), and both `--check-only` paths executed for real — **passes** (exit 2 while MPI is absent, as designed).
- Full compile/link and any MPI execution — **NOT RUN** (no MPI, no MSVC, no root, no dependency libraries in this environment).

---

## Part 4 — MPI lifecycle safety (design, after audit D8)

The module never owns the process' MPI session unconditionally; it owns it only if
it created it, and it never issues a collective after finalization.

```
import ──► OpenSeesCommands ctor ──► MPI_MachineBroker ctor
             MPI_Initialized(&f)
             ownsMPI = (f == 0)      # false when a driver (mpiexec host, pytest-mpi,
             if (ownsMPI) MPI_Init(&argc,&argv)   # another extension) already did it

exit ────► Py_AtExit(cleanup) ──► ~OpenSeesCommands
             delete[] theChannels
             MPI_Finalized(&f)                # collective safety gate (D8)
             if (!f) broker->shutdown()
             delete broker ──► ~MPI_MachineBroker
                                 MPI_Finalized(&f)         # D8
                                 if (ownsMPI && !f) MPI_Finalize()
```

Properties established **by construction** (each is a code path, not a hope):

| # | Property | How |
|---|---|---|
| P1 | never initialises twice | `MPI_Initialized` + `ownsMPI` |
| P2 | never finalises twice | `MPI_Finalized` in both destructors |
| P3 | never enters a collective after finalisation | the guard sits **before** `shutdown()`, which is collective |
| P4 | exactly one broker per process | created in `OpenSeesCommands`, one module instance |
| P5 | a failing rank can tear the job down | `ops.mpiAbort(code)`, default `1` |
| P6 | lifecycle state is observable from Python | `isMPIInitialized()`, `isMPIFinalized()` |

Residual, unverified: `MPI_Init(&argc,&argv)` with `argc=0, argv=nullptr` on
MS-MPI; whether `shutdown()` can block if ranks reach teardown at different times;
`Py_AtExit` ordering versus MPI teardown in CPython 3.12. These are listed as R2/R4
in `TECHNICAL_AUDIT.md` §7 and cannot be settled without a real MPI runtime.

---

## Part 5 — Build matrix and verification status

| | Linux | Windows |
|---|---|---|
| Script | `build-linux.sh` (`--check-only`) | `build-windows.ps1` (`-CheckOnly`), PS 5.1 & 7 |
| Trees | `build-mpi/`, `build-serial/` | `build-mpi\`, `build-serial\` |
| Artefact | `opensees_mpi.cpython-3xx-<arch>-linux-gnu.so` | `opensees_mpi.pyd` |
| MPI | MPICH / Open MPI (dev headers) | MS-MPI 10.1 (SDK + runtime) |
| CRT / runtime | system | `/MD` forced for the module |
| Configure-verified here | ✅ (stubbed siblings) | ❌ logic executed under pwsh-on-Linux, real MSVC never used |
| Built here | ❌ | ❌ |
