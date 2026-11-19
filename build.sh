#!/usr/bin/env bash
# Backwards-compatible entry point.
#
# The real, independent Linux build script is build-linux.sh.  This file only
# forwards its arguments so that older instructions keep working.
#
#   ./build.sh --check-only
#
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-linux.sh" "$@"
