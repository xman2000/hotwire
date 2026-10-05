@echo off
REM ==[ H O T W I R E ]===================================================
REM  hotwire-before.bat -- your own commands, run before every start.
REM
REM  To use it, copy this file to hotwire-before.bat beside hotwire.bat.
REM  It runs from the server's folder, before any update. If it fails, the
REM  launcher logs that and starts the server anyway; "hotwire.bat check"
REM  never runs it. Keep it quick: the server waits for it.
REM
REM  Hotwire never creates or changes this file. What is in it is yours.
REM ======================================================================

REM Examples. Remove the REM to use one.

REM Copy the plugin configs somewhere safe:
REM xcopy oxide\config D:\rust-config-copy\ /E /I /Y >nul

REM Tell a Discord channel the server is starting (a webhook URL of your own):
REM curl -s -H "Content-Type: application/json" -d "{\"content\":\"Server starting\"}" https://discord.com/api/webhooks/...
