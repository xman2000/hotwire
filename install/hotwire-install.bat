@echo off
REM  hotwire-install -- double-click this to install a Rust server with Oxide.
REM
REM  All it does is start hotwire-install.ps1, which sits beside it and does the work,
REM  asking before every step.
REM
REM  Why a .bat at all: Windows will not run a PowerShell script (.ps1) when you
REM  double-click it, and by default refuses to run one even when typed. The line below
REM  lets that one script run for this one window. No Windows setting is changed, and
REM  nothing else is allowed to run. Read hotwire-install.ps1 first if you like -- it is
REM  plain text.
REM
REM  No labels or goto in this file on purpose: those are what break when a .bat loses
REM  its Windows line endings on the way to you.

setlocal

if not exist "%~dp0hotwire-install.ps1" (
    echo.
    echo   hotwire-install.ps1 is missing. Put it in the same folder as this file:
    echo   %~dp0
    echo.
    pause
    exit /b 1
)

REM  "Run as administrator" starts a .bat in C:\Windows\System32, not where the file is.
REM  Installing a server there would be a disaster, so start from this file's folder.
if /i "%CD%"=="%SystemRoot%\System32" cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hotwire-install.ps1" %*
set "HW_EXIT=%ERRORLEVEL%"

REM  A double-clicked window closes the moment the script ends. Keep it open to be read.
echo.
pause
exit /b %HW_EXIT%
