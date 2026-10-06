@echo off
REM ==========================================================================
REM  Run-ChangeSource-JavaNoJar.bat - run the Java WITHOUT building a jar.
REM ..........................................................................
REM  Yes - you can run a .java program from a .bat without making a jar.
REM  This compiles java\ChangeSource.java into .\out and runs it with
REM     java -cp out ChangeSource
REM
REM  JVM SELECTION:
REM    1. JAVA_HOME (if declared and valid)  <-- primary
REM    2. javac/java already on PATH
REM    3. (OPTIONAL, currently commented out) auto-detect the SAP JVM / SapMachine
REM       from the installation - see the block below to re-enable it.
REM  A JDK (javac) is required to compile.
REM
REM  IMPORTANT: reads environments\my-env.bru - the SAME file Bruno uses. Keep
REM  this .bat INSIDE the extracted Bruno collection folder (the folder that
REM  contains environments\my-env.bru).
REM
REM  Arguments are forwarded, e.g.:
REM     Run-ChangeSource-JavaNoJar.bat --test
REM     Run-ChangeSource-JavaNoJar.bat --docIds 5418,5403 --strategyMode custom --test
REM
REM  NOTE (JDK 11+ single-file mode): you can also skip compilation entirely:
REM     java java\ChangeSource.java --test
REM  but that recompiles every run, so we compile once into .\out.
REM ==========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

call :find_java
if not defined JAVAC_EXE (
  echo [ERROR] Could not find javac ^(a JDK is required to compile^).
  echo         Set JAVA_HOME to a JDK, or add javac to your PATH.
  echo         ^(You can also enable SAP-JVM auto-detect: see the commented
  echo          block in this .bat's :find_java section.^)
  goto :end
)
echo [INFO] Java home : %JAVA_HOME_DETECTED%
echo [INFO] Using javac: %JAVAC_EXE%
echo [INFO] Using java : %JAVA_EXE%
"%JAVA_EXE%" -version

if not exist "out" mkdir "out"
echo [INFO] Compiling java\ChangeSource.java into .\out ...
"%JAVAC_EXE%" -d out "java\ChangeSource.java"
if errorlevel 1 ( echo [ERROR] Compilation failed. & goto :end )

echo.
"%JAVA_EXE%" -cp out ChangeSource %*

:end
echo.
echo ==========================================================================
set /p "_dummy=Press Enter to close . . . "
endlocal
exit /b

REM ==========================================================================
REM  :find_java  -> sets JAVA_EXE, JAVAC_EXE, JAR_EXE, JAVA_HOME_DETECTED
REM  Prefers the SAP JVM / SapMachine. Supports any version (11/17/21+).
REM ==========================================================================
:find_java
set "JAVA_EXE="
set "JAVAC_EXE="
set "JAR_EXE="
set "JAVA_HOME_DETECTED="

REM (1) JAVA_HOME - primary. If declared and valid (has javac), use it.
if not defined JAVAC_EXE call :try_home "%JAVA_HOME%"

REM (2) javac/java already on PATH
if not defined JAVAC_EXE call :try_path

REM --------------------------------------------------------------------------
REM (OPTIONAL) Auto-detect the SAP JVM / SapMachine from the installation.
REM Kept for reference but COMMENTED OUT. To enable it (e.g. when JAVA_HOME is
REM not set), remove the "REM " at the start of the lines below.
REM Supports SapMachine 11/17/21+ and BusinessObjects-bundled sapjvm_*.
REM
REM  (a) SAP-specific environment variables
REM  if not defined JAVAC_EXE call :try_home "%SAPMACHINE_JDK_HOME%"
REM  if not defined JAVAC_EXE call :try_home "%SAPMACHINE_HOME%"
REM  if not defined JAVAC_EXE call :try_home "%SAPJVM_HOME%"
REM
REM  (b) SAP install roots - newest folder first (/o-n). SapMachine == SAP's JDK.
REM  if not defined JAVAC_EXE call :scan_root "C:\Program Files\Java"
REM  if not defined JAVAC_EXE call :scan_root "C:\Program Files\SapMachine"
REM  if not defined JAVAC_EXE call :scan_root "C:\Program Files\SAP\SapMachine"
REM
REM  (c) SAP BusinessObjects bundled sapjvm
REM  if not defined JAVAC_EXE call :scan_sapjvm "C:\Program Files\SAP BusinessObjects"
REM  if not defined JAVAC_EXE call :scan_sapjvm "C:\Program Files (x86)\SAP BusinessObjects"
REM  if not defined JAVAC_EXE call :scan_sapjvm "C:\Program Files\SAP\FrontEnd"
REM
REM  (d) generic Java install folders (last resort)
REM  if not defined JAVAC_EXE call :scan_root "C:\Program Files (x86)\Java"
REM --------------------------------------------------------------------------
goto :eof

REM ---- :scan_root <folder>  try each subfolder (newest first) as a JDK home
:scan_root
if not exist "%~1" goto :eof
for /f "delims=" %%D in ('dir /b /ad /o-n "%~1" 2^>nul') do if not defined JAVAC_EXE call :try_home "%~1\%%D"
goto :eof

REM ---- :scan_sapjvm <folder>  find bundled sapjvm* dirs (recursive)
:scan_sapjvm
if not exist "%~1" goto :eof
for /f "delims=" %%J in ('dir /b /s /ad "%~1\sapjvm*" 2^>nul') do if not defined JAVAC_EXE call :try_home "%%J"
goto :eof

REM ---- :try_path  use javac/java already on PATH
:try_path
where javac >nul 2>&1
if errorlevel 1 goto :eof
set "JAVAC_EXE=javac"
set "JAVA_EXE=java"
set "JAR_EXE=jar"
set "JAVA_HOME_DETECTED=(from PATH)"
goto :eof

REM ---- :try_home <folder>  require javac (this launcher needs a JDK) --------
:try_home
set "_H=%~1"
if "%_H%"=="" goto :eof
if not exist "%_H%\bin\javac.exe" goto :eof
set "JAVAC_EXE=%_H%\bin\javac.exe"
set "JAVA_EXE=%_H%\bin\java.exe"
set "JAVA_HOME_DETECTED=%_H%"
if exist "%_H%\bin\jar.exe" set "JAR_EXE=%_H%\bin\jar.exe"
goto :eof
