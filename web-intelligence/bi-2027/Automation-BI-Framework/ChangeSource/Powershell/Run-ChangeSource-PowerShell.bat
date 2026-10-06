@echo off
REM ==========================================================================
REM  Run-ChangeSource-PowerShell.bat - launcher for the PowerShell version.
REM ..........................................................................
REM  Runs change_source.ps1 (the PowerShell implementation). Use this if you
REM  prefer PowerShell over the Java/jar version.
REM
REM  It locates powershell.exe explicitly (Windows PowerShell 5.1) and falls
REM  back to pwsh.exe (PowerShell 7), so it works even when PowerShell is not
REM  on the PATH.
REM
REM  IMPORTANT: this reads environments\my-env.bru - the SAME file Bruno uses.
REM  Keep this .bat (and change_source.ps1) INSIDE the extracted Bruno
REM  collection folder (the folder that contains environments\my-env.bru).
REM
REM  Any arguments are forwarded to the script, e.g.:
REM     Run-ChangeSource-PowerShell.bat -Test
REM     Run-ChangeSource-PowerShell.bat -DocIds "5418,5403" -StrategyMode custom -Test
REM ==========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

REM ---- locate a PowerShell executable ---------------------------------------
set "PS_EXE="

REM 1) Windows PowerShell 5.1 at its fixed system location
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM 2) powershell.exe on PATH
if not defined PS_EXE for %%P in (powershell.exe) do if not defined PS_EXE if not "%%~$PATH:P"=="" set "PS_EXE=%%~$PATH:P"

REM 3) PowerShell 7 (pwsh) on PATH
if not defined PS_EXE for %%P in (pwsh.exe) do if not defined PS_EXE if not "%%~$PATH:P"=="" set "PS_EXE=%%~$PATH:P"

REM 4) PowerShell 7 default install location
if not defined PS_EXE if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PS_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"

if not defined PS_EXE (
  echo [ERROR] Could not find PowerShell ^(powershell.exe or pwsh.exe^).
  echo         Use Run-ChangeSource.bat ^(Java version^) instead.
  goto :end
)

echo [INFO] Using PowerShell: %PS_EXE%
echo.
REM Pass -EnvFile explicitly (from this .bat's folder) so the script always
REM finds environments\my-env.bru regardless of how it was launched.
REM -NoPause: the .bat does the final "Press Enter" so we don't pause twice.
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0change_source.ps1" -EnvFile "%~dp0environments\my-env.bru" -NoPause %*

:end
echo.
echo ==========================================================================
set /p "_dummy=Press Enter to close . . . "
endlocal
