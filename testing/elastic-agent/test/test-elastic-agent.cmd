@echo off
setlocal EnableDelayedExpansion

REM =====================================================
REM Usage:
REM   test-elastic-agent.cmd [--inspect | --run] [--debug="selectors"]
REM
REM Modes:
REM   (default / --inspect)  Validate and print resolved config — no network needed.
REM   --run                  Run the agent against %LOGSTASH_HOST%:%LOGSTASH_PORT%.
REM                          Start the monitor stack (monitor.sh) before using this mode.
REM
REM Examples:
REM   test-elastic-agent.cmd
REM   test-elastic-agent.cmd --inspect
REM   test-elastic-agent.cmd --run
REM   test-elastic-agent.cmd --run --debug="input"
REM   test-elastic-agent.cmd --run --debug="input,harvester"
REM
REM NOTE: --run may require running this script as Administrator on Windows.
REM =====================================================

set SCRIPT_DIR=%~dp0
set AGENT_HOME=%SCRIPT_DIR%..\elastic-agent-9.4.1-windows-x86_64\
set CONFIG=%SCRIPT_DIR%elastic-agent-test.yml
REM Agent state is written into the agent home's data\ dir. The elastic-agent-* subdir
REM contains the unpacked binaries and must NOT be deleted — only runtime state is cleared.
set DATA_DIR=%AGENT_HOME%data

REM === DEFAULTS ===
set MODE=inspect
set DEBUG_SELECTORS=

REM Set connection defaults — override by setting env vars before running this script.
if not defined LOGSTASH_HOST set LOGSTASH_HOST=localhost
if not defined LOGSTASH_PORT set LOGSTASH_PORT=5050

REM === PARSE ARGS ===
:parse
if "%~1"=="" goto execute

if /I "%~1"=="--inspect" (
    set MODE=inspect
)

if /I "%~1"=="--run" (
    set MODE=run
)

echo %~1 | findstr /B /I "--debug=" >nul
if not errorlevel 1 (
    set DEBUG_SELECTORS=%~1
    set DEBUG_SELECTORS=!DEBUG_SELECTORS:--debug==!
    set DEBUG_SELECTORS=!DEBUG_SELECTORS:"=!
)

shift
goto parse

:execute

cd /d "%AGENT_HOME%"

echo.
echo ==========================================
echo  Elastic Agent Test Runner
echo ==========================================
echo  Home    : %AGENT_HOME%
echo  Config  : %CONFIG%
echo  Mode    : %MODE%
if defined DEBUG_SELECTORS echo  Debug   : %DEBUG_SELECTORS%
echo ==========================================
echo.

REM ── INSPECT MODE ────────────────────────────────────────────────────────────
if /I "%MODE%"=="inspect" (
    echo [INFO] Validating config. No network connection required.
    echo.
    "elastic-agent.exe" inspect -c "%CONFIG%"
    echo.
    echo ==========================================
    if %ERRORLEVEL%==0 (
        echo [OK] Config inspection passed.
    ) else (
        echo [WARN] Inspect exited with code %ERRORLEVEL% — review output above.
    )
    echo ==========================================
    pause
    exit /b %ERRORLEVEL%
)

REM ── RUN MODE ────────────────────────────────────────────────────────────────

REM Clear agent runtime state so every run re-reads all inputs from scratch.
REM Deletes all subdirs inside data\ EXCEPT the elastic-agent-* binary package dir.
set FOUND_STATE=0
for /D %%D in ("%DATA_DIR%\*") do (
    echo %%~nxD | findstr /B /I "elastic-agent-" >nul
    if errorlevel 1 (
        rd /s /q "%%D"
        echo [INFO] Cleared state dir: %%D
        set FOUND_STATE=1
    )
)
if "!FOUND_STATE!"=="0" echo [INFO] No previous state found, starting fresh.

echo.
echo [INFO] Starting Elastic Agent (standalone mode).
echo [INFO] Output target: %LOGSTASH_HOST%:%LOGSTASH_PORT%  ^(ensure monitor.sh is running^)
echo [INFO] Stop the agent with Ctrl+C when done.
echo.

if defined DEBUG_SELECTORS (
    "elastic-agent.exe" run -c "%CONFIG%" -d "%DEBUG_SELECTORS%"
) else (
    "elastic-agent.exe" run -c "%CONFIG%"
)

echo.
echo ==========================================
echo  Elastic Agent stopped.
echo ==========================================
pause
