<#
    OpenSeesPyMPI - independent Windows build script
    ================================================
    Target: Windows 10/11 x64, Visual Studio 2022 (v143), CMake >= 3.25,
            CPython 3.10-3.12 x64, Microsoft MPI 10.1.

    Compatibility: Windows PowerShell 5.1 and PowerShell 7+.
    Written without PS7-only syntax (no '?.', no '??', no ternary, no
    -AdditionalChildPath) so it parses and runs on the 5.1 that ships with
    Windows 10/11.

    STATUS OF THIS SCRIPT
    ---------------------
    It has NOT been executed on Windows (no Windows/MS-MPI was available where
    it was written).  On Linux it was executed with -CheckOnly to prove that it
    parses and that its dependency checks fail gracefully.  A real run is
    required before any build claim can be made.

    What it does
    ------------
    1.  detects VS 2022 / MS-MPI / Python / CMake
    2.  configures TWO trees (both required):
          build-serial  -> standard OpenSeesPy   (OPS_BUILD_PYMPI=OFF)
          build-mpi     -> OpenSeesPyMPI         (OPS_BUILD_PYMPI=ON)
    3.  builds the requested targets
    4.  copies opensees_mpi.pyd / opensees.pyd into -InstallDir
    5.  import smoke check (single process only; NOT an MPI test)
#>

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')] [string] $Config = 'Release',
    [string] $Python = '',
    [string] $MpiRoot = '',
    [string] $MetisRoot = '',
    [string] $MumpsDir = '',
    [string] $InstallDir = '',
    [int]    $Jobs = 0,
    [switch] $SerialOnly,
    [switch] $SkipSerial,
    [switch] $CheckOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0          # 2.0 works on 5.1 and 7+

function Write-Step([string] $Message) {
    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

$script:Status = New-Object System.Collections.ArrayList

function Add-Status([string] $Item, [string] $State, [string] $Detail) {
    [void]$script:Status.Add([pscustomobject]@{
        Item   = $Item
        State  = $State
        Detail = $Detail
    })
    $colour = 'Gray'
    if ($State -eq 'OK')        { $colour = 'Green' }
    if ($State -eq 'MISSING')   { $colour = 'Red' }
    if ($State -eq 'NOT RUN')   { $colour = 'Yellow' }
    Write-Host ("  {0,-22} {1,-9} {2}" -f $Item, $State, $Detail) -ForegroundColor $colour
}

function Join-IfSet([string] $Base, [string] $Child) {
    # Join-Path throws when $Base is empty (e.g. %ProgramFiles% unset, or the
    # script is run on a non-Windows host for -CheckOnly).
    if (-not $Base) { return '' }
    return (Join-Path $Base $Child)
}

function Stop-Build([string] $Message) {
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    if (-not $CheckOnly) { exit 1 }
}

Write-Step 'Script environment'
Write-Host ("PowerShell         : {0}" -f $PSVersionTable.PSVersion.ToString())
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Stop-Build 'PowerShell 5.1 or later is required.'
}

$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
if (-not (Test-Path (Join-Path $Root 'CMakeLists.txt'))) {
    Stop-Build "CMakeLists.txt not found in $Root. Place this script at the root of the OpenSees clone."
}
Write-Host ("Repository         : {0}" -f $Root)

# ------------------------------------------------------------------ toolchain
Write-Step 'Dependency check'

$cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
$cmake = ''
if ($cmakeCmd) { $cmake = $cmakeCmd.Source }
if (-not $cmake) {
    $guess = Join-IfSet $env:ProgramFiles 'CMake\bin\cmake.exe'
    if ($guess -and (Test-Path $guess)) { $cmake = $guess }
}
if ($cmake) {
    $cmakeVersion = (& $cmake --version | Select-Object -First 1)
    Add-Status 'cmake' 'OK' "$cmake  ($cmakeVersion)"
} else {
    Add-Status 'cmake' 'MISSING' 'install CMake >= 3.25 and add it to PATH'
}

if (-not $Python) {
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd) { $Python = $pyCmd.Source }
}
$pyPrefix = ''
if ($Python -and (Test-Path $Python)) {
    $pyVersion = & $Python -c "import sys;print('.'.join(map(str,sys.version_info[:3])))"
    $pyArch    = & $Python -c "import platform;print(platform.architecture()[0])"
    $pyPrefix  = & $Python -c "import sys;print(sys.prefix)"
    $pyHeader  = Join-Path $pyPrefix 'include\Python.h'
    if ($pyArch -eq '64bit' -and (Test-Path $pyHeader)) {
        Add-Status 'python' 'OK' "$Python  ($pyVersion, $pyArch)"
    } else {
        Add-Status 'python' 'MISSING' "need 64-bit CPython with headers; looked for $pyHeader"
    }
} else {
    Add-Status 'python' 'MISSING' 'pass -Python C:\path\to\python.exe'
}

$vswhere = Join-IfSet ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if ($vswhere -and (Test-Path $vswhere)) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vsPath) { Add-Status 'visual studio 2022' 'OK' $vsPath }
    else         { Add-Status 'visual studio 2022' 'MISSING' 'install the C++ desktop workload' }
} else {
    Add-Status 'visual studio 2022' 'NOT RUN' 'vswhere not found; assuming a Developer PowerShell'
}

if (-not $MpiRoot) {
    $mpiCandidates = @(
        (Join-IfSet ${env:ProgramFiles(x86)} 'Microsoft SDKs\MPI'),
        (Join-IfSet $env:ProgramFiles 'Microsoft SDKs\MPI'),
        (Join-IfSet $env:ProgramFiles 'Microsoft MPI')
    )
    foreach ($candidate in $mpiCandidates) {
        if ((-not $MpiRoot) -and $candidate -and (Test-Path $candidate)) { $MpiRoot = $candidate }
    }
}
$mpiInclude = ''
$mpiLib = ''
$mpiInclude = Join-IfSet $MpiRoot 'Include'
$mpiLib = Join-IfSet $MpiRoot 'Lib\x64\msmpi.lib'

if ($mpiInclude -and (Test-Path (Join-Path $mpiInclude 'mpi.h')) -and (Test-Path $mpiLib)) {
    Add-Status 'Microsoft MPI' 'OK' $MpiRoot
} else {
    Add-Status 'Microsoft MPI' 'MISSING' 'install msmpisdk.msi (SDK) and msmpisetup.exe (runtime) from https://aka.ms/msmpi'
}

$mpiexec = Get-Command mpiexec.exe -ErrorAction SilentlyContinue
if ($mpiexec) { Add-Status 'mpiexec' 'OK' $mpiexec.Source }
else          { Add-Status 'mpiexec' 'MISSING' 'add "%ProgramFiles%\Microsoft MPI\Bin" to PATH (tests only)' }

# METIS headers are picked up by the global OTHER/**/*.h include glob, so the
# in-tree target needs no extra include path.  -MetisRoot is only for a
# prebuilt metis.lib.
if ($MetisRoot) {
    $metisHeader = Join-Path $MetisRoot 'metis.h'
    if (Test-Path $metisHeader) { Add-Status 'METIS (external)' 'OK' $MetisRoot }
    else                        { Add-Status 'METIS (external)' 'MISSING' "metis.h not found in $MetisRoot" }
} else {
    $bundled = Join-Path $Root 'OTHER\METIS\metis.h'
    if (Test-Path $bundled) { Add-Status 'METIS (bundled)' 'OK' $bundled }
    else                    { Add-Status 'METIS (bundled)' 'MISSING' 'OTHER\METIS\metis.h not found in this clone' }
}

$fortran = Get-Command ifx -ErrorAction SilentlyContinue
if (-not $fortran) { $fortran = Get-Command ifort -ErrorAction SilentlyContinue }
if (-not $fortran) { $fortran = Get-Command gfortran -ErrorAction SilentlyContinue }
if ($fortran) { Add-Status 'Fortran' 'OK' $fortran.Source }
else          { Add-Status 'Fortran' 'NOT RUN' 'none found; configure with -DCMAKE_Fortran_COMPILER= if the build stops on Fortran' }

$testsDir = Join-Path $Root 'tests'
if (Test-Path (Join-Path $testsDir 'test_3_frame_static.py')) {
    Add-Status 'test suite' 'OK' $testsDir
} else {
    Add-Status 'test suite' 'NOT RUN' 'copy the delivered tests\ folder into the clone to run the benchmarks'
}

$blocking = @($script:Status | Where-Object { $_.State -eq 'MISSING' -and $_.Item -ne 'mpiexec' })
if ($CheckOnly) {
    Write-Step 'Summary'
    Write-Host ("blocking issues: {0}" -f $blocking.Count)
    if ($blocking.Count -gt 0) { exit 2 }
    exit 0
}
if ($blocking.Count -gt 0) {
    Stop-Build (($blocking | ForEach-Object { $_.Item }) -join ', ')
}

# ------------------------------------------------------------------ configure
$buildMpi    = Join-Path $Root 'build-mpi'
$buildSerial = Join-Path $Root 'build-serial'
if (-not $InstallDir) { $InstallDir = Join-Path $Root 'install' }
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$commonArgs = @(
    '-S', $Root,
    '-G', 'Visual Studio 17 2022',
    '-A', 'x64',
    ("-DPython_ROOT_DIR=" + $pyPrefix),
    ("-DPython_EXECUTABLE=" + $Python),
    ("-DCMAKE_BUILD_TYPE=" + $Config),
    # CPython is built with /MD; the project defaults to the static /MT CRT and
    # mixing them breaks the extension link (audit R6).
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'
)
if ($MumpsDir) { $commonArgs += ("-DMUMPS_DIR=" + $MumpsDir) }
if ($MetisRoot) {
    $commonArgs += ("-DMETIS_INCLUDES=" + $MetisRoot)
    $metisLib = Join-Path $MetisRoot 'metis.lib'
    if (Test-Path $metisLib) { $commonArgs += ("-DMETIS_LIBRARIES=" + $metisLib) }
}

function Invoke-Configure([string] $Directory, [string[]] $ExtraArgs) {
    Write-Step ("Configure " + $Directory)
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $log = Join-Path $Directory 'configure.log'
    $cmakeArgs = @()
    $cmakeArgs += $commonArgs
    $cmakeArgs += @('-B', $Directory)
    $cmakeArgs += $ExtraArgs
    & $cmake @cmakeArgs 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) {
        Write-Host '--- last 40 log lines ---' -ForegroundColor Yellow
        Get-Content $log -Tail 40
        Stop-Build ("CMake configure failed for " + $Directory + " (see " + $log + ")")
    }
}

function Invoke-Build([string] $Directory, [string[]] $Targets) {
    Write-Step ("Build " + ($Targets -join ', ') + " in " + $Directory)
    $log = Join-Path $Directory 'build.log'
    $buildArgs = @('--build', $Directory, '--config', $Config, '--target')
    foreach ($t in $Targets) { $buildArgs += $t }
    if ($Jobs -gt 0) { $buildArgs += @('--parallel', $Jobs.ToString()) } else { $buildArgs += '--parallel' }
    & $cmake @buildArgs 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) {
        Write-Host '--- last 60 log lines ---' -ForegroundColor Yellow
        Get-Content $log -Tail 60
        Stop-Build ("Build failed in " + $Directory + " (see " + $log + ")")
    }
}

function Find-Artifact([string] $Directory, [string] $Pattern) {
    $found = Get-ChildItem -Path $Directory -Recurse -Filter $Pattern -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending
    if ($found -and $found.Count -gt 0) { return $found[0].FullName }
    return ''
}

# ------------------------------------------------------------------ MPI tree
if (-not $SerialOnly) {
    $mpiArgs = @(
        '-DOPS_BUILD_PYMPI=ON',
        ("-DMPI_C_INCLUDE_PATH=" + $mpiInclude),
        ("-DMPI_C_HEADER_DIR=" + $mpiInclude),
        ("-DMPI_CXX_INCLUDE_PATH=" + $mpiInclude),
        ("-DMPI_C_LIBRARIES=" + $mpiLib),
        ("-DMPI_CXX_LIBRARIES=" + $mpiLib)
    )
    Invoke-Configure $buildMpi $mpiArgs
    Invoke-Build $buildMpi @('OpenSeesPyMPI')

    $artifact = Find-Artifact $buildMpi 'opensees_mpi*.pyd'
    if (-not $artifact) { Stop-Build 'opensees_mpi.pyd was not produced - see build-mpi\build.log' }
    Copy-Item $artifact (Join-Path $InstallDir 'opensees_mpi.pyd') -Force
    Write-Host ("produced: " + (Join-Path $InstallDir 'opensees_mpi.pyd'))
}

# --------------------------------------------------------------- serial tree
if (-not $SkipSerial) {
    Invoke-Configure $buildSerial @('-DOPS_BUILD_PYMPI=OFF', '-DOPS_FINAL_TARGET=OpenSeesPy')
    Invoke-Build $buildSerial @('OpenSeesPy')

    $artifact = Find-Artifact $buildSerial 'opensees*.pyd'
    if (-not $artifact) { Stop-Build 'opensees.pyd was not produced - see build-serial\build.log' }
    Copy-Item $artifact (Join-Path $InstallDir 'opensees.pyd') -Force
    Write-Host ("produced: " + (Join-Path $InstallDir 'opensees.pyd'))
}

# ------------------------------------------------------------- smoke checks
Write-Step 'Single-process import smoke check (not an MPI test)'
$env:PYTHONPATH = $InstallDir
& $Python -c "import opensees_mpi as ops; print('module:', ops.__name__); print('mpi initialized:', ops.isMPIInitialized()); print('rank/size:', ops.getMPIRank(), ops.getMPISize())"
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Import failed. Usual causes: msmpi.dll not on PATH, /MT vs /MD mismatch,' -ForegroundColor Yellow
    Write-Host 'or the module was built for a different CPython minor version.' -ForegroundColor Yellow
    Stop-Build 'import smoke check failed'
}
Add-Status 'import (n=1)' 'OK' 'module imported; MPI test still NOT RUN'

Write-Step 'Summary'
$script:Status | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("Module directory: " + $InstallDir)
Write-Host 'Multi-process tests (NOT executed by this script):'
Write-Host ("  `$env:PYTHONPATH='" + $InstallDir + "'")
Write-Host '  mpiexec -n 2 python tests\test_1_lifecycle.py'
Write-Host '  mpiexec -n 2 python tests\test_3_frame_static.py'
Write-Host '  mpiexec -n 4 python tests\test_3_frame_static.py'
Write-Host '  python tests\compare_results.py'
