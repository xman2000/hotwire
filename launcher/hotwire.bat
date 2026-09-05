@echo off
setlocal EnableDelayedExpansion

REM =====================================================================
REM  HOTWIRE LAUNCHER  --  a Rust server start script you can edit
REM  without fear.  MIT.  https://github.com/xman2000/hotwire
REM =====================================================================
REM
REM  START HERE
REM    1. Set ROOT and STEAMCMD below, in section 1.
REM    2. Copy secrets.example.bat to secrets.bat and put your RCON
REM       password in it.
REM    3. Work down section 4 and switch on the options you want.
REM    4. Run this file. It relaunches the server whenever it exits.
REM
REM  SWITCHING AN OPTION ON OR OFF
REM    Every option is one independent line. REM in front turns it off:
REM
REM      REM  server.maxplayers -- slots.  [default: unknown]
REM      set "ARGS=!ARGS! +server.maxplayers 50"
REM
REM    An option you do not set uses the game's default, and no line
REM    depends on the one above it -- so you cannot break this file by
REM    switching something off. That is not true of the one-long-command
REM    launchers this replaces, and it is the whole point.
REM
REM  WRITING A VALUE
REM    Quote anything containing a space. Double a literal percent sign:
REM    20%% not 20%. And !ARGS! is deliberate, not a typo for %ARGS%: it
REM    keeps | & > < ^ safe inside a value, so a hostname like
REM    My Server | Monthly | NA works here and breaks elsewhere.
REM
REM  AFTER A RUST UPDATE
REM    Defaults move more often than names do, so regenerate the option
REM    reference from YOUR build rather than trusting these comments:
REM
REM      python tools\convars.py "<server>\RustDedicated_Data\Managed\Assembly-CSharp.dll" --bat
REM
REM    Where a comment says [default: unknown] it has not been verified.
REM    That is honest; a wrong default is a trap.
REM =====================================================================


REM =====================================================================
REM  1. PATHS  --  edit these, then the options below
REM =====================================================================

REM Where the server is installed. steamcmd writes here.
set "ROOT=C:\rustserver"

REM Where steamcmd itself lives.
set "STEAMCMD=C:\steamcmd\steamcmd.exe"

REM Rust's Steam app id. Do not change this.
set "APPID=258550"

REM Update once when this launcher starts, on the assumption that we do
REM not know what state the install was left in. 0 = every update must
REM be asked for explicitly with a flag file (see section 3).
set "UPDATE_ON_LAUNCH=1"

REM Give up on steamcmd after this many tries and launch the install we
REM already have. A stale build is a server; an infinite retry is not.
set "MAX_STEAM_TRIES=5"

REM Rotated server logs to keep.
set "LOG_KEEP=14"

REM Seconds to wait before relaunching after the server exits.
set "RESTART_DELAY=15"

REM Optional: a command run before and after an update, for backups or
REM notifications. Leave empty to do nothing.
set "HOOK_BEFORE="
set "HOOK_AFTER="

set "LOGFILE=%ROOT%\logs\server_log.txt"


REM =====================================================================
REM  2. SECRETS  --  never put a password in this file
REM =====================================================================
REM  Copy secrets.example.bat to secrets.bat and set RCON_PASSWORD there.
REM  secrets.bat is gitignored. This launcher will not start without it --
REM  but it does not check the value, so change the example password.

set "SECRETS=%~dp0secrets.bat"

if not exist "%SECRETS%" (
    echo [%date% %time%] MISSING %SECRETS%
    echo Copy secrets.example.bat to secrets.bat and set RCON_PASSWORD.
    pause & exit /b 1
)
call "%SECRETS%"
if not defined RCON_PASSWORD (
    echo [%date% %time%] secrets.bat did not set RCON_PASSWORD.
    pause & exit /b 1
)

cd /d "%ROOT%" || (echo Cannot cd to %ROOT% & pause & exit /b 1)
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

set "FIRST_PASS=1"


REM =====================================================================
:start
REM =====================================================================
REM  3. UPDATE OR RESTART?
REM
REM  A restart relaunches and nothing else. An update happens only when a
REM  flag file says so, and the flag is deleted once acted on -- so one
REM  flag buys exactly one update.
REM
REM    UPDATE.flag     app_update, then the mod framework, then launch
REM    VALIDATE.flag   the same plus "validate", which re-checksums the
REM                    whole install. Slow. Weekly, or after a crash.
REM
REM  Anything can create one -- you, a scheduled task, or the Hotwire
REM  plugin when a scheduled update comes due:
REM
REM    New-Item -ItemType File C:\rustserver\UPDATE.flag
REM =====================================================================

set "DO_UPDATE=0"
set "DO_VALIDATE=0"

if exist "%ROOT%\UPDATE.flag" (
    set "DO_UPDATE=1"
    echo [%date% %time%] UPDATE.flag found -- this pass will update.
)
if exist "%ROOT%\VALIDATE.flag" (
    set "DO_UPDATE=1"
    set "DO_VALIDATE=1"
    echo [%date% %time%] VALIDATE.flag found -- update and validate.
)
if "%FIRST_PASS%"=="1" if "%UPDATE_ON_LAUNCH%"=="1" (
    set "DO_UPDATE=1"
    echo [%date% %time%] First pass since launch -- updating.
)
set "FIRST_PASS=0"

if defined HOOK_BEFORE call %HOOK_BEFORE%

if "%DO_UPDATE%"=="0" (
    echo [%date% %time%] Plain restart -- skipping steamcmd and framework.
    goto buildargs
)

set /a STEAM_TRIES=0

:steamupdate
set /a STEAM_TRIES+=1
if "%DO_VALIDATE%"=="1" (
    "%STEAMCMD%" +force_install_dir "%ROOT%" +login anonymous +app_update %APPID% validate +quit
) else (
    "%STEAMCMD%" +force_install_dir "%ROOT%" +login anonymous +app_update %APPID% +quit
)
if not errorlevel 1 goto framework

echo [%date% %time%] steamcmd error (attempt !STEAM_TRIES! of %MAX_STEAM_TRIES%).
if !STEAM_TRIES! GEQ %MAX_STEAM_TRIES% (
    echo [%date% %time%] Giving up on steamcmd. Launching what we have.
    goto framework
)
timeout /t 60 /nobreak >nul
goto steamupdate

:framework
REM  Oxide/uMod. Comment this whole block out for a vanilla server.
REM  -f makes curl fail on an HTTP error instead of saving the error page,
REM  which would otherwise be force-extracted over a working install.
curl -fSL -A "Mozilla/5.0" "https://umod.org/games/rust/download" --output "%ROOT%\OxideMod.zip"
if errorlevel 1 (
    echo [%date% %time%] Framework download failed. Keeping the install.
) else (
    powershell -NoProfile -Command "Expand-Archive -Force '%ROOT%\OxideMod.zip' '%ROOT%'"
    if errorlevel 1 echo [%date% %time%] Framework extract failed.
)
if exist "%ROOT%\OxideMod.zip" del "%ROOT%\OxideMod.zip"

if exist "%ROOT%\UPDATE.flag"   del "%ROOT%\UPDATE.flag"
if exist "%ROOT%\VALIDATE.flag" del "%ROOT%\VALIDATE.flag"

if defined HOOK_AFTER call %HOOK_AFTER%


REM =====================================================================
:buildargs
REM =====================================================================
REM  4. SERVER OPTIONS
REM
REM  One option per line. REM a line to disable it.
REM  A starting set. Run tools\convars.py for the complete list.
REM =====================================================================

set "ARGS="

REM ---------------------------------------------------------------------
REM  4.1 PROCESS
REM ---------------------------------------------------------------------

REM Run headless with no window and no renderer. Required on a server.
set "ARGS=!ARGS! -batchmode -nographics"

REM ---------------------------------------------------------------------
REM  4.2 IDENTITY AND WORLD
REM
REM  WARNING: server.identity names the folder under server\ holding the
REM  map save, blueprints, bans and player data. Changing it creates a
REM  brand new server and orphans the old one. Never edit it mid-wipe.
REM  Changing level, seed or worldsize also generates a new map.
REM ---------------------------------------------------------------------

REM server.identity -- save folder name. Keep it short, no spaces.  [default: unknown]
set "ARGS=!ARGS! +server.identity "my_server""

REM server.level -- map type. "Procedural Map", "Barren", "HapisIsland",
REM "CraggyIsland", "SavasIsland_koth".  [default: "Procedural Map"]
set "ARGS=!ARGS! +server.level "Procedural Map""

REM server.seed -- procedural map seed. Any integer. Same seed + same
REM worldsize = same map.  [default: random]
set "ARGS=!ARGS! +server.seed 1234567"

REM server.worldsize -- map size in metres. 1000-6000. Bigger costs RAM
REM and startup time superlinearly.  [default: 4000]
set "ARGS=!ARGS! +server.worldsize 4000"

REM server.levelurl -- custom map URL. Set this INSTEAD of level/seed/
REM worldsize, not as well as.  [default: empty]
REM set "ARGS=!ARGS! +server.levelurl "https://example.com/map.map""

REM ---------------------------------------------------------------------
REM  4.3 NETWORK
REM
REM  All three need forwarding at the router. queryport is what the
REM  server browser uses -- get it wrong and the server runs fine and is
REM  invisible, which is a miserable thing to debug.
REM ---------------------------------------------------------------------

REM server.port -- game traffic, UDP.  [default: 28015]
set "ARGS=!ARGS! +server.port 28015"

REM server.queryport -- Steam server browser, UDP. Not a fixed default:
REM Rust derives it as 1 + the greater of server.port and rcon.port when it
REM is not set, so the layout above gives 28017.
REM
REM AVOID 27015 AND THE 27000-27030 RANGE. That is the Steam CLIENT port
REM range. If the machine running the server also runs Steam, the client
REM can take the port, the server stops answering browser queries, and it
REM goes invisible until something releases it. Guides that tell you to use
REM 27015 are copying Source-engine convention; Rust is not Source.
set "ARGS=!ARGS! +server.queryport 28017"

REM rcon.port -- remote console, TCP.  [default: 28016]
set "ARGS=!ARGS! +rcon.port 28016"

REM app.port -- Rust+ companion app, TCP. Rust derives it as
REM server.port + 68 when unset, so 28015 gives 28083. Needs its own
REM port forward, which is the usual reason Rust+ "does not work".
REM set "ARGS=!ARGS! +app.port 28083"

REM server.ip -- bind address. Leave unset unless multi-homed.
REM set "ARGS=!ARGS! +server.ip 0.0.0.0"

REM ---------------------------------------------------------------------
REM  4.4 BROWSER LISTING
REM
REM  What players see before they join. \n makes a line break in the
REM  description. A literal percent must be doubled: 20%% not 20%.
REM ---------------------------------------------------------------------

REM server.hostname -- name in the browser. This is your advert.
set "ARGS=!ARGS! +server.hostname "My Rust Server | Monthly | NA""

REM server.description -- long text on the join screen.
set "ARGS=!ARGS! +server.description "What makes this server different.\nSecond line.""

REM server.tags -- browser filter tags, comma separated, no spaces.
set "ARGS=!ARGS! +server.tags "monthly,modded,NA""

REM server.headerimage -- 512x256 banner. Direct image URL.
REM set "ARGS=!ARGS! +server.headerimage "https://example.com/banner.png""

REM server.url -- website shown on the join screen.
REM set "ARGS=!ARGS! +server.url "https://example.com""

REM server.maxplayers -- slots.  [default: unknown]
set "ARGS=!ARGS! +server.maxplayers 50"

REM ---------------------------------------------------------------------
REM  4.5 ADMIN AND RCON
REM
REM  RCON is remote code execution on this machine. Treat the password
REM  like a root password: long, unique, and never in this file.
REM ---------------------------------------------------------------------

REM rcon.password -- from secrets.bat. Never a literal here.
set "ARGS=!ARGS! +rcon.password "!RCON_PASSWORD!""

REM rcon.web -- 1 = WebSocket RCON (what modern tools expect).
set "ARGS=!ARGS! +rcon.web 1"

REM ---------------------------------------------------------------------
REM  4.6 SAVES AND LOGGING
REM ---------------------------------------------------------------------

REM server.saveinterval -- seconds between world saves. This is how much
REM progress a hard kill throws away, so shut down cleanly.  [default: 600 -- VERIFY]
set "ARGS=!ARGS! +server.saveinterval 300"

REM server.combatlog / chatlog -- keep the logs admins need.
set "ARGS=!ARGS! +server.combatlog true"
set "ARGS=!ARGS! +server.chatlog true"

REM server.printReportsToConsole -- player reports in the console.
set "ARGS=!ARGS! +server.printReportsToConsole"

REM ---------------------------------------------------------------------
REM  4.7 GAMEPLAY  --  a sample. Regenerate for the full list.
REM ---------------------------------------------------------------------

REM server.globalchat -- 1 = everyone hears everyone.  [default: true]
set "ARGS=!ARGS! +server.globalchat 1"

REM server.itemdespawn -- seconds before dropped items vanish.  [default: unknown]
REM set "ARGS=!ARGS! +server.itemdespawn 1200"

REM decay.scale -- decay rate multiplier. 0 disables decay entirely.  [default: 1]
REM set "ARGS=!ARGS! +decay.scale 0.2"

REM hackablelockedcrate.requiredhackseconds -- codelock crate timer.  [default: 900]
REM set "ARGS=!ARGS! +hackablelockedcrate.requiredhackseconds 300"

REM rideablehorse.population -- horses per square km.  [default: unknown]
REM set "ARGS=!ARGS! +rideablehorse.population 3"


REM =====================================================================
REM  5. LAUNCH
REM =====================================================================

REM Rotate the log. -logfile TRUNCATES on every start, so without this a
REM restart destroys the log of whatever went wrong before it.
if exist "%LOGFILE%" (
    for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%i"
    move /y "%LOGFILE%" "%ROOT%\logs\server_log_!STAMP!.txt" >nul
    powershell -NoProfile -Command "Get-ChildItem '%ROOT%\logs\server_log_*.txt' | Sort-Object LastWriteTime -Descending | Select-Object -Skip %LOG_KEEP% | Remove-Item -Force" 2>nul
)

echo [%date% %time%] Starting server...
RustDedicated.exe !ARGS! -logfile "!LOGFILE!"

echo [%date% %time%] Server exited. Restarting in %RESTART_DELAY%s. Ctrl+C to stop.
timeout /t %RESTART_DELAY% /nobreak
goto start
