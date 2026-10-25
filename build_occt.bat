@echo off
rem ===========================================================================
rem  occt-builder - double-click to build OCCT with occt-build.yaml
rem
rem  Usage:
rem    build_occt.bat                      build with occt-build.yaml
rem    build_occt.bat my-config.yaml       build with another config
rem    build_occt.bat -DryRun              show what would be done
rem    build_occt.bat -Clean               rebuild from scratch
rem
rem  Set OCCT_BUILDER_NOPAUSE=1 to skip the final pause (CI, scripts).
rem ===========================================================================
setlocal
set "HERE=%~dp0"

set "PS=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%scripts\Build-Occt.ps1" %*
set "RC=%ERRORLEVEL%"

if not defined OCCT_BUILDER_NOPAUSE pause
exit /b %RC%
