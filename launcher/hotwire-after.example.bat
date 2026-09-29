@echo off
REM ==[ H O T W I R E ]===================================================
REM  hotwire-after.bat -- your own commands, run after an update.
REM
REM  To use it, copy this file to hotwire-after.bat beside hotwire.bat.
REM  It runs from the server's folder after Rust and Oxide are updated and
REM  before the server starts. If it fails, the launcher logs that and
REM  starts the server anyway; "hotwire.bat check" never runs it.
REM
REM  Hotwire never creates or changes this file. What is in it is yours.
REM ======================================================================

REM Examples. Remove the REM to use one.

REM Keep a note of when each update happened:
REM echo %date% %time% >> updates.txt

REM Put back a file an update replaces, from a copy of your own:
REM copy /Y D:\my-files\some-file.cfg server\my_server\cfg\ >nul
