#!/usr/bin/env sh
# occt-builder - Linux/macOS entry point (needs PowerShell 7: "pwsh").
#   ./build_occt.sh [config.yaml] [-DryRun] [-Clean]
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v pwsh >/dev/null 2>&1; then
    echo "pwsh (PowerShell 7) is required: https://learn.microsoft.com/powershell/scripting/install/installing-powershell" >&2
    exit 1
fi
exec pwsh -NoProfile -File "$HERE/scripts/Build-Occt.ps1" "$@"
