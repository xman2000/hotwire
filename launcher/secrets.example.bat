@echo off
REM Copy this file to secrets.bat and edit it. secrets.bat is gitignored.
REM RCON is remote code execution on this machine -- treat this like a
REM root password. Long, unique, and never committed.
REM
REM Avoid ! and ^ in the password. The launcher runs with delayed
REM expansion on, which eats both, and the server would then be listening
REM on a password that is not the one written here. Every other printable
REM character is fine.
set "RCON_PASSWORD=change_me"
