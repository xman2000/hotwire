@echo off
REM ==[ H O T W I R E ]===================================================
REM  Hotwire launcher for Windows. Everything it does is in hotwire.ps1,
REM  beside this file; this file only starts it. Built by Searle Street
REM  Technologies and Claude. MIT License. https://github.com/xman2000/hotwire
REM
REM  Usage:
REM    hotwire.bat          start the server, and restart it when it exits
REM    hotwire.bat check    check the settings and report; start nothing
REM
REM  hotwire.ps1 can be replaced while the launcher runs: it takes over at
REM  the next restart. This file rarely changes, because cmd reads it
REM  while it runs: replace it only with the launcher's window closed.
REM  When an update of Hotwire replaced hotwire.ps1 and the new one stops
REM  with an error before it proved itself (hotwire\self-update\applied is
REM  still there), this puts back the copy it replaced and runs that one.
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
if errorlevel 3 if not errorlevel 4 exit /b 3
if not errorlevel 1 exit /b 0
if exist "%~dp0hotwire\self-update\applied" if exist "%~dp0hotwire\previous\hotwire.ps1" goto rollback
if errorlevel 2 if not errorlevel 3 exit /b 2
REM PowerShell itself failed: hotwire.ps1 would not load, or could not run here. Keep the window open.
echo.
echo The launcher could not run. The lines above say why. The server is not running.
pause
exit /b 1
:rollback
copy /y "%~dp0hotwire\previous\hotwire.ps1" "%~dp0hotwire.ps1" >nul || exit /b 1
(echo launcher_failed & type "%~dp0hotwire\self-update\applied") > "%~dp0hotwire\self-update\rolled-back"
del "%~dp0hotwire\self-update\applied"
echo The updated launcher stopped with an error before it proved itself. The previous launcher is back; starting it.
goto run
REM HOTWIRE-PART hotwire.ps1
