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
REM  the next restart. This file rarely changes, because cmd reads it
REM  while it runs: replace it only with the launcher's window closed.
REM  The HOTWIRE-PART line names the file the
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
if errorlevel 2 if not errorlevel 3 exit /b 2
if not errorlevel 1 exit /b 0
REM PowerShell itself failed: hotwire.ps1 would not load, or could not run here. Keep the window open.
echo.
echo The launcher could not run. The lines above say why. The server is not running.
pause
exit /b 1
REM HOTWIRE-PART hotwire.ps1
