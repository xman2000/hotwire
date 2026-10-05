@echo off
REM ==[ H O T W I R E ]===================================================
REM  Hotwire launcher for Windows. Everything it does is in hotwire.ps1,
REM  beside this file; this file only starts it. Built by xman2000 and
REM  Claude. MIT License. https://github.com/xman2000/hotwire
REM
REM  Usage:
REM    hotwire.bat          start the server, and restart it when it exits
REM    hotwire.bat check    check the settings and report; start nothing
REM
REM  hotwire.ps1 can be replaced while the launcher runs: it takes over at
REM  the next restart. This file does not change between releases, because
REM  cmd reads it while it runs. The HOTWIRE-PART line names the file the
REM  launcher's code hash covers besides this one.
REM ======================================================================
if not exist "%~dp0hotwire.ps1" (
    echo hotwire.ps1 is missing. Put it beside hotwire.bat, then run hotwire.bat again.
    pause
    exit /b 1
)
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hotwire.ps1" %*
if errorlevel 75 if not errorlevel 76 goto run
exit /b %errorlevel%
REM HOTWIRE-PART hotwire.ps1
