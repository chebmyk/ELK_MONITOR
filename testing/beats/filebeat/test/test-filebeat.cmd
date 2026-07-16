@echo off
setlocal EnableDelayedExpansion

REM =====================================================
REM Usage:
REM   test-filebeat.cmd [--once] [--debug="selectors"]
REM
REM Examples:
REM   test-filebeat.cmd
REM   test-filebeat.cmd --once
REM   test-filebeat.cmd --debug="input"
REM   test-filebeat.cmd --once --debug="input,harvester"
REM =====================================================

REM === CURRENT DIRECTORY ===
set SCRIPT_DIR=%~dp0
set FILEBEAT_HOME=..\filebeat-9.4.1-windows-x86_64\
set CONFIG=%SCRIPT_DIR%filebeat_test.yml

REM === DEFAULTS ===
set ONCE_FLAG=
set DEBUG_SELECTORS=input,harvester,publish

REM === PARSE ARGS ===
:parse
if "%~1"=="" goto run

if /I "%~1"=="--once" (
    set ONCE_FLAG=--once
)

echo %~1 | findstr /B /I "--debug=" >nul
if not errorlevel 1 (
    set DEBUG_SELECTORS=%~1
    set DEBUG_SELECTORS=!DEBUG_SELECTORS:--debug==!
    set DEBUG_SELECTORS=!DEBUG_SELECTORS:"=!
)

shift
goto parse

:run

cd /d "%FILEBEAT_HOME%"

REM === CLEAR REGISTRY so every run re-reads all inputs from scratch ===
if exist "%FILEBEAT_HOME%data\registry\filebeat" (
    rd /s /q "%FILEBEAT_HOME%data\registry\filebeat"
    echo [INFO] Registry cleared.
) else (
    echo [INFO] No registry found, starting fresh.
)

echo.
echo ==========================================
echo Filebeat Test Runner
echo ==========================================
echo Home: %FILEBEAT_HOME%
echo Config: %CONFIG%
echo Once: %ONCE_FLAG%
echo Debug: %DEBUG_SELECTORS%
echo ==========================================
echo.

"%FILEBEAT_HOME%filebeat.exe" ^
  -c "%CONFIG%" ^
  -e ^
  %ONCE_FLAG% ^
  -d "%DEBUG_SELECTORS%"

echo.
echo ==========================================
echo Filebeat finished
echo ==========================================
pause