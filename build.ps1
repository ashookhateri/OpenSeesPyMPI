# Backwards-compatible entry point.
#
# The real, independent Windows build script is build-windows.ps1.  This file
# only forwards its arguments so that older instructions keep working.
#
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -Config Release
#
$forward = Join-Path $PSScriptRoot 'build-windows.ps1'
& $forward @args
exit $LASTEXITCODE
