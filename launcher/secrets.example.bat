@echo off
REM Copy this file to secrets.bat and edit it. secrets.bat is gitignored.
REM RCON is remote code execution on this machine -- treat this like a
REM root password. Long, unique, and never committed.
REM
REM At least 8 characters (RCON_PASSWORD_MIN in hotwire.bat), and not the
REM example value below. Do not put a double quote in it, and do not start
REM it with a semicolon; the launcher will refuse to start and say so rather
REM than run on a password that is not the one written here. Write a
REM percent sign as %% -- this is a batch file, and a single % is not kept.
REM Everything else, including ! and ^, is read as written.
REM
REM Do not wrap the value in extra quotes. The two below are the syntax.
set "RCON_PASSWORD=change_me"
