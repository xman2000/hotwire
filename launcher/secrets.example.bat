@echo off
REM Copy this file to secrets.bat and edit it. secrets.bat is gitignored.
REM RCON is remote code execution on this machine -- treat this like a
REM root password. Long, unique, and never committed.
REM
REM Do not put a double quote in it, and do not start it with a
REM semicolon; the launcher will refuse to start and say so rather than
REM run on a password that is not the one written here. Everything else,
REM including ! % and ^, is read exactly as written.
REM
REM Do not wrap the value in extra quotes. The two below are the syntax.
set "RCON_PASSWORD=change_me"
