@echo off
REM  hotwire-setup -- double-click this to install a Rust server, or to connect one to
REM  Hotwire Panel. It shows a menu and asks before it does anything.
REM
REM  All it does is start hotwire-setup.ps1, which sits beside it and does the work.
REM
REM  Why a .bat at all: Windows will not run a PowerShell script (.ps1) when you
REM  double-click it, and by default refuses to run one even when typed. The line below
REM  lets that one script run for this one window. No Windows setting is changed, and
REM  nothing else is allowed to run. Read hotwire-setup.ps1 first if you like -- it is
REM  plain text.
REM
REM  From a console, name the command:  hotwire-setup.bat connect
REM
REM  Written with no labels, no goto and no bracketed blocks, on purpose. Labels break
REM  when a .bat loses its Windows line endings on the way to you, and a block breaks
REM  when the folder it runs from has a bracket in its name -- "New folder (2)",
REM  "Program Files (x86)" -- because the folder name closes the block early.

setlocal

set "HW_PS1=%~dp0hotwire-setup.ps1"
set "HW_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%HW_POWERSHELL%" set "HW_POWERSHELL=powershell.exe"

if not exist "%HW_PS1%" echo.
if not exist "%HW_PS1%" echo   hotwire-setup.ps1 is missing. It has to be in the same folder as this file.
if not exist "%HW_PS1%" echo.
if not exist "%HW_PS1%" echo   If you opened this from inside a .zip file, close this window, right-click the
if not exist "%HW_PS1%" echo   .zip, choose Extract All, and double-click hotwire-setup.bat in the new folder.
if not exist "%HW_PS1%" echo.
if not exist "%HW_PS1%" pause
if not exist "%HW_PS1%" exit /b 1

REM  "Run as administrator" starts a .bat in C:\Windows\System32, not where the file is.
REM  Installing a server there would be a disaster, so start from this file's folder.
if /i "%CD%"=="%SystemRoot%\System32" cd /d "%~dp0"

"%HW_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%HW_PS1%" %*
set "HW_EXIT=%ERRORLEVEL%"

REM  A double-clicked window closes the moment the script ends, so keep it open to be
REM  read. Given a command, it was typed into a console that stays open anyway.
if "%~1"=="" echo.
if "%~1"=="" pause
exit /b %HW_EXIT%
