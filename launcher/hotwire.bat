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
REM  One option per line. REM a line to disable it; an option you do not set
REM  uses the game's default, which is printed beside every one below.
REM
REM  Every name and every default here was read out of a real
REM  Assembly-CSharp.dll, not from documentation and not from memory. Run
REM  tools/convars.py --check on this file after a Rust update and it will
REM  tell you which of them have moved.
REM
REM  This is a curated list, not the whole console surface. The assembly holds
REM  about 1600 convars; most are diagnostic and runtime tuning that nobody
REM  sets at launch, and burying these hundred among them would make the file
REM  unreadable. tools/convars.py --all prints the rest when you need it.
REM =====================================================================

set "ARGS="

REM ---------------------------------------------------------------------
REM  4.0  PROCESS
REM ---------------------------------------------------------------------

REM  Run headless with no window and no renderer. Required on a server.
set "ARGS=!ARGS! -batchmode -nographics"

REM ---------------------------------------------------------------------
REM  4.1  IDENTITY AND THE MAP
REM
REM  WARNING: identity names the folder under server\ holding the map, blueprints,
REM  bans and player data. Changing it creates a brand new server and orphans the
REM  old one. Changing level, seed or worldsize generates a new map.
REM ---------------------------------------------------------------------

REM  server.identity -- Save folder name. Short, no spaces.
REM  [string, default "my_server_identity"]
set "ARGS=!ARGS! +server.identity my_server"

REM  server.level -- Procedural Map, Barren, HapisIsland, CraggyIsland, SavasIsland_koth.
REM  [string, default "Procedural Map"]
set "ARGS=!ARGS! +server.level "Procedural Map""

REM  server.seed -- Procedural seed. Same seed and worldsize give the same map.
REM  [int, default 1337]
set "ARGS=!ARGS! +server.seed 1234567"

REM  server.worldsize -- Map size in metres, 1000-6000. Costs RAM and boot time superlinearly.
REM  [int, default 4500]
set "ARGS=!ARGS! +server.worldsize 4000"

REM  server.levelurl -- Custom map URL. Set INSTEAD of level, seed and worldsize.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.levelurl VALUE"

REM ---------------------------------------------------------------------
REM  4.2  NETWORK
REM
REM  All of these need forwarding at the router. Get queryport wrong and the server
REM  runs perfectly while being invisible in the browser, which is miserable to
REM  debug.
REM ---------------------------------------------------------------------

REM  server.port -- Game traffic, UDP.
REM  [int, default 28015]
set "ARGS=!ARGS! +server.port 28015"

REM  server.queryport -- Server browser, UDP. 0 derives it as 1 + max(server.port, rcon.port).
REM  AVOID 27015 and the 27000-27030 range: that is the Steam CLIENT range,
REM  and if this machine also runs Steam the client can take the port and the
REM  server goes invisible until something releases it.
REM  [int, default 0]
set "ARGS=!ARGS! +server.queryport 28017"

REM  rcon.port -- Remote console, TCP.
REM  [int, default 0]
set "ARGS=!ARGS! +rcon.port 28016"

REM  server.ip -- Bind address. Leave unset unless multi-homed.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.ip VALUE"

REM  server.maxplayers -- Slots.
REM  [int, default 500]
set "ARGS=!ARGS! +server.maxplayers 50"

REM  server.playertimeout -- Seconds before a silent client is dropped.
REM  [int, default 60]
REM set "ARGS=!ARGS! +server.playertimeout VALUE"

REM  server.rejoin_delay -- Seconds a kicked player must wait before rejoining.
REM  [int, default 300]
REM set "ARGS=!ARGS! +server.rejoin_delay VALUE"

REM ---------------------------------------------------------------------
REM  4.3  BROWSER LISTING
REM
REM  What players see before they join. A literal percent must be doubled.
REM ---------------------------------------------------------------------

REM  server.hostname -- Name in the browser. This is your advert.
REM  [string, default "My Untitled Rust Server"]
set "ARGS=!ARGS! +server.hostname "My Rust Server | Monthly | NA""

REM  server.description -- Long text on the join screen. Use backslash-n for a line break.
REM  [string, default "No server description has been provided."]
set "ARGS=!ARGS! +server.description "What makes this server different.""

REM  server.tags -- Browser filter tags, comma separated, no spaces.
REM  [property, default UNKNOWN]
set "ARGS=!ARGS! +server.tags "monthly,modded,NA""

REM  server.headerimage -- 512x256 banner. Direct image URL.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.headerimage VALUE"

REM  server.logoimage -- Server logo. Direct image URL.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.logoimage VALUE"

REM  server.url -- Website shown on the join screen.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.url VALUE"

REM  server.censorplayerlist -- Hide the player list from the browser.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.censorplayerlist VALUE"

REM ---------------------------------------------------------------------
REM  4.4  ADMIN AND RCON
REM
REM  RCON is remote code execution on this machine. Treat the password like a root
REM  password: long, unique, and never in this file.
REM ---------------------------------------------------------------------

REM  rcon.password -- From secrets.bat. Never a literal here. Command-line only:
REM  it is not a convar, so tools that audit convars will not see it.
REM  [?, default UNKNOWN]
set "ARGS=!ARGS! +rcon.password !RCON_PASSWORD!"

REM  rcon.web -- 1 = WebSocket RCON, which is what modern tools expect.
REM  [bool, default true]
set "ARGS=!ARGS! +rcon.web 1"

REM  rcon.ip -- Bind address for RCON.
REM  [string, default ""]
REM set "ARGS=!ARGS! +rcon.ip VALUE"

REM  rcon.maxconnections -- Simultaneous RCON connections allowed.
REM  [int, default 500]
REM set "ARGS=!ARGS! +rcon.maxconnections VALUE"

REM  server.printReportsToConsole -- Player reports appear in the console.
REM  [bool, default false]
set "ARGS=!ARGS! +server.printReportsToConsole true"

REM ---------------------------------------------------------------------
REM  4.5  SAVES AND LOGS
REM
REM  saveinterval is how much progress a hard kill throws away, which is why the
REM  plugin shuts down with quit rather than being killed.
REM ---------------------------------------------------------------------

REM  server.saveinterval -- Seconds between world saves.
REM  [int, default 600]
set "ARGS=!ARGS! +server.saveinterval 300"

REM  server.saveBackupCount -- Rolling save backups kept.
REM  [int, default 2]
REM set "ARGS=!ARGS! +server.saveBackupCount VALUE"

REM  server.saveframebudget -- Milliseconds per frame spent saving. Higher is faster, hitchier.
REM  [int, default 5]
REM set "ARGS=!ARGS! +server.saveframebudget VALUE"

REM  chat.serverlog -- Print chat to the server console and log.
REM  [bool, default true]
REM set "ARGS=!ARGS! +chat.serverlog VALUE"

REM  server.combatlogdelay -- Seconds of delay before combat log entries are readable.
REM  [int, default 10]
REM set "ARGS=!ARGS! +server.combatlogdelay VALUE"

REM  server.combatlogsize -- Combat log entries kept per player.
REM  [int, default 30]
REM set "ARGS=!ARGS! +server.combatlogsize VALUE"

REM  server.netlog -- Log network traffic.
REM  [property, default UNKNOWN]
REM set "ARGS=!ARGS! +server.netlog VALUE"

REM ---------------------------------------------------------------------
REM  4.6  PVE, PVP AND DAMAGE
REM ---------------------------------------------------------------------

REM  server.pve -- Server-wide PVE. Blunt: most modded servers use a plugin instead.
REM  [bool, default false]
REM set "ARGS=!ARGS! +server.pve VALUE"

REM  server.pvp_ttk_global -- Global time-to-kill multiplier. Higher means players die slower.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.pvp_ttk_global VALUE"

REM  server.pvp_ttk_bullet -- Time-to-kill multiplier for bullets only.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.pvp_ttk_bullet VALUE"

REM  server.pvp_ttk_melee -- Time-to-kill multiplier for melee only.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.pvp_ttk_melee VALUE"

REM  server.bulletdamage -- Bullet damage multiplier.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.bulletdamage VALUE"

REM  server.bulletarmor -- Bullet armour multiplier.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.bulletarmor VALUE"

REM  server.arrowdamage -- Arrow damage multiplier.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.arrowdamage VALUE"

REM  server.bleedingdamage -- Bleed damage multiplier.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.bleedingdamage VALUE"

REM  server.radiation -- Radiation on or off.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.radiation VALUE"

REM  server.stability -- Building stability. Off lets people build physically impossible bases.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.stability VALUE"

REM ---------------------------------------------------------------------
REM  4.7  DEATH, RESPAWN AND WOUNDING
REM ---------------------------------------------------------------------

REM  server.woundingenabled -- Players go down wounded rather than dying outright.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.woundingenabled VALUE"

REM  server.crawlingenabled -- Wounded players can crawl.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.crawlingenabled VALUE"

REM  server.woundedrecoverchance -- Chance of getting back up unaided.
REM  [float, default 0.2]
REM set "ARGS=!ARGS! +server.woundedrecoverchance VALUE"

REM  server.respawnAtDeathPosition -- Respawn where you died. Very not-vanilla.
REM  [bool, default false]
REM set "ARGS=!ARGS! +server.respawnAtDeathPosition VALUE"

REM  server.respawnWithLoadout -- Respawn with a kit.
REM  [bool, default false]
REM set "ARGS=!ARGS! +server.respawnWithLoadout VALUE"

REM  server.respawnresetrange -- Metres within which a respawn point is reused.
REM  [float, default 50.0]
REM set "ARGS=!ARGS! +server.respawnresetrange VALUE"

REM  server.respawnTimeAdditionBed -- Extra seconds on a bed respawn.
REM  [float, default 0.0]
REM set "ARGS=!ARGS! +server.respawnTimeAdditionBed VALUE"

REM  server.respawnTimeAdditionBag -- Extra seconds on a sleeping bag respawn.
REM  [float, default 0.0]
REM set "ARGS=!ARGS! +server.respawnTimeAdditionBag VALUE"

REM  server.dropitems -- Drop your inventory on death.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.dropitems VALUE"

REM  server.corpses -- Leave a lootable corpse.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.corpses VALUE"

REM ---------------------------------------------------------------------
REM  4.8  DESPAWN TIMES
REM
REM  The most-tuned group on a modded server after rates. All in seconds.
REM ---------------------------------------------------------------------

REM  server.itemdespawn -- Dropped items.
REM  [float, default 300.0]
REM set "ARGS=!ARGS! +server.itemdespawn VALUE"

REM  server.itemdespawn_quick -- Low-value items, which go sooner.
REM  [float, default 30.0]
REM set "ARGS=!ARGS! +server.itemdespawn_quick VALUE"

REM  server.itemdespawn_container_scale -- Multiplier for items inside a dropped container.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +server.itemdespawn_container_scale VALUE"

REM  server.corpsedespawn -- Player corpses.
REM  [float, default 300.0]
REM set "ARGS=!ARGS! +server.corpsedespawn VALUE"

REM  server.npccorpsedespawn -- NPC corpses.
REM  [float, default 600.0]
REM set "ARGS=!ARGS! +server.npccorpsedespawn VALUE"

REM  server.debrisdespawn -- Building debris after a raid.
REM  [float, default 30.0]
REM set "ARGS=!ARGS! +server.debrisdespawn VALUE"

REM ---------------------------------------------------------------------
REM  4.9  DECAY AND UPKEEP
REM ---------------------------------------------------------------------

REM  decay.scale -- Decay rate multiplier. 0 disables decay entirely.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +decay.scale VALUE"

REM  decay.upkeep -- Upkeep on or off.
REM  [bool, default true]
REM set "ARGS=!ARGS! +decay.upkeep VALUE"

REM  decay.upkeep_grief_protection -- Minutes of upkeep grace after a tool cupboard runs dry.
REM  [float, default 1440.0]
REM set "ARGS=!ARGS! +decay.upkeep_grief_protection VALUE"

REM  decay.high_wall_upkeep -- Upkeep multiplier for external walls.
REM  [float, default 0.2]
REM set "ARGS=!ARGS! +decay.high_wall_upkeep VALUE"

REM ---------------------------------------------------------------------
REM  4.10  CHAT
REM ---------------------------------------------------------------------

REM  chat.enabled -- Chat on or off.
REM  [bool, default true]
REM set "ARGS=!ARGS! +chat.enabled VALUE"

REM  chat.globalchat -- Everyone hears everyone. This is NOT server.globalchat.
REM  [bool, default true]
REM set "ARGS=!ARGS! +chat.globalchat VALUE"

REM  chat.localchat -- Proximity chat.
REM  [bool, default false]
REM set "ARGS=!ARGS! +chat.localchat VALUE"

REM  chat.localChatRange -- Metres that proximity chat carries.
REM  [float, default 100.0]
REM set "ARGS=!ARGS! +chat.localChatRange VALUE"

REM  chat.historysize -- Messages kept in history.
REM  [int, default 1000]
REM set "ARGS=!ARGS! +chat.historysize VALUE"

REM ---------------------------------------------------------------------
REM  4.11  EVENTS
REM
REM  server.events is the master switch. The rest tune individual events.
REM ---------------------------------------------------------------------

REM  server.events -- Master switch for timed world events.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.events VALUE"

REM  patrolhelicopter.lifetimeMinutes -- How long the patrol helicopter stays before leaving.
REM  [float, default 30.0]
REM set "ARGS=!ARGS! +patrolhelicopter.lifetimeMinutes VALUE"

REM  patrolhelicopter.guns -- Number of guns it fires with.
REM  [int, default 1]
REM set "ARGS=!ARGS! +patrolhelicopter.guns VALUE"

REM  patrolhelicopter.bulletDamageScale -- Its bullet damage multiplier.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +patrolhelicopter.bulletDamageScale VALUE"

REM  patrolhelicopter.bulletAccuracy -- Its accuracy. Lower is more accurate.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +patrolhelicopter.bulletAccuracy VALUE"

REM  cargoship.event_enabled -- Cargo ship on or off.
REM  [bool, default true]
REM set "ARGS=!ARGS! +cargoship.event_enabled VALUE"

REM  cargoship.event_duration_minutes -- How long it stays.
REM  [float, default 50.0]
REM set "ARGS=!ARGS! +cargoship.event_duration_minutes VALUE"

REM  cargoship.loot_rounds -- Crate refresh rounds during a visit.
REM  [int, default 3]
REM set "ARGS=!ARGS! +cargoship.loot_rounds VALUE"

REM  bradleyapc.KillScientistsOnBradleyDeath -- Scientists die with the tank.
REM  [bool, default false]
REM set "ARGS=!ARGS! +bradleyapc.KillScientistsOnBradleyDeath VALUE"

REM  halloween.enabled -- Halloween event.
REM  [bool, default false]
REM set "ARGS=!ARGS! +halloween.enabled VALUE"

REM  xmas.enabled -- Christmas event.
REM  [bool, default false]
REM set "ARGS=!ARGS! +xmas.enabled VALUE"

REM ---------------------------------------------------------------------
REM  4.12  SPAWNS AND POPULATIONS
REM
REM  Populations are per square kilometre. Rates and densities scale the whole
REM  spawn system, so small changes go a long way.
REM ---------------------------------------------------------------------

REM  spawn.max_rate -- Upper bound on spawn rate.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +spawn.max_rate VALUE"

REM  spawn.min_rate -- Lower bound on spawn rate.
REM  [float, default 0.5]
REM set "ARGS=!ARGS! +spawn.min_rate VALUE"

REM  spawn.max_density -- Upper bound on spawn density.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +spawn.max_density VALUE"

REM  spawn.min_density -- Lower bound on spawn density.
REM  [float, default 0.5]
REM set "ARGS=!ARGS! +spawn.min_density VALUE"

REM  spawn.player_scale -- How much nearby players suppress spawns.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +spawn.player_scale VALUE"

REM  bear.Population -- Bears per square kilometre.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +bear.Population VALUE"

REM  boar.Population -- Boar per square kilometre.
REM  [float, default 5.0]
REM set "ARGS=!ARGS! +boar.Population VALUE"

REM  chicken.Population -- Chickens per square kilometre.
REM  [float, default 3.0]
REM set "ARGS=!ARGS! +chicken.Population VALUE"

REM  wolf2.Population -- Wolves. The class is Wolf2: Rust replaced the old one.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +wolf2.Population VALUE"

REM  stag.Population -- Stags per square kilometre.
REM  [float, default 3.0]
REM set "ARGS=!ARGS! +stag.Population VALUE"

REM  polarbear.Population -- Polar bears per square kilometre.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +polarbear.Population VALUE"

REM  ridablehorse.Population -- Horses. Note the spelling: ridable, one e.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +ridablehorse.Population VALUE"

REM ---------------------------------------------------------------------
REM  4.13  IDLE, AUTH AND ANTI-CHEAT
REM ---------------------------------------------------------------------

REM  server.idlekick -- Minutes of idling before a kick. 0 disables.
REM  [int, default 30]
REM set "ARGS=!ARGS! +server.idlekick VALUE"

REM  server.idlekickmode -- 0 off, 1 when the server is full, 2 always.
REM  [int, default 1]
REM set "ARGS=!ARGS! +server.idlekickmode VALUE"

REM  server.idlekickadmins -- 1 also kicks idle admins.
REM  [int, default 0]
REM set "ARGS=!ARGS! +server.idlekickadmins VALUE"

REM  server.authtimeout -- Seconds allowed for a client to authenticate.
REM  [int, default 60]
REM set "ARGS=!ARGS! +server.authtimeout VALUE"

REM  server.strictauth_steam -- Reject clients Steam will not vouch for.
REM  [bool, default false]
REM set "ARGS=!ARGS! +server.strictauth_steam VALUE"

REM  server.anticheattoken -- EAC anti-cheat token checks.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.anticheattoken VALUE"

REM ---------------------------------------------------------------------
REM  4.14  RUST+ COMPANION APP
REM
REM  Needs its own port forward, which is the usual reason Rust+ does not work.
REM ---------------------------------------------------------------------

REM  app.port -- Rust+ companion port, TCP. 0 derives it as server.port + 68.
REM  [int, default UNKNOWN]
REM set "ARGS=!ARGS! +app.port VALUE"

REM  app.listenip -- Bind address for Rust+.
REM  [string, default ""]
REM set "ARGS=!ARGS! +app.listenip VALUE"

REM  app.maxconnections -- Simultaneous Rust+ connections.
REM  [int, default 500]
REM set "ARGS=!ARGS! +app.maxconnections VALUE"

REM ---------------------------------------------------------------------
REM  4.15  PERFORMANCE
REM
REM  Leave these alone unless you are chasing a specific measured problem.
REM ---------------------------------------------------------------------

REM  server.tickrate -- Server tick rate. Raising it costs CPU and rarely helps.
REM  [int, default 10]
REM set "ARGS=!ARGS! +server.tickrate VALUE"

REM  server.entityrate -- Entity updates sent per tick.
REM  [int, default 16]
REM set "ARGS=!ARGS! +server.entityrate VALUE"

REM  global.maxthreads -- Worker threads Rust may use.
REM  [int, default 8]
REM set "ARGS=!ARGS! +global.maxthreads VALUE"

REM  server.netcache -- Cache network payloads. Costs memory, saves CPU.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.netcache VALUE"

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
