@echo off
setlocal EnableDelayedExpansion

REM =====================================================================
REM  HOTWIRE LAUNCHER
REM
REM  Start script for a Rust dedicated server. Relaunches the server when
REM  it exits, and updates it either on every start or on demand.
REM
REM  Built by xman2000 and Claude.  MIT licence.
REM  https://github.com/xman2000/hotwire
REM =====================================================================
REM
REM  SETUP
REM    1. Section 1: set ROOT and STEAMCMD.
REM    2. Copy secrets.example.bat to secrets.bat and set RCON_PASSWORD.
REM    3. Section 4: enable the options you need. Anything left disabled
REM       uses the game's default.
REM    4. Run this file. Leave the window open.
REM
REM  RUN LOOP
REM    The script does not exit after starting the server. It waits for the
REM    server process to end, then starts it again after RESTART_DELAY
REM    seconds. Close the window to stop the server permanently.
REM
REM  UPDATE MODES            set with UPDATE_MODE in section 1
REM    always     steamcmd and the mod framework run on every start.
REM               This is the default and matches most Rust launchers.
REM    hotwire    steamcmd and the mod framework run only when UPDATE.flag
REM               or VALIDATE.flag is present in ROOT. The flag is deleted
REM               once acted on: one flag, one update. All other restarts
REM               relaunch and nothing more.
REM
REM    Use hotwire when restarts are automated. In always mode an
REM    unattended restart installs whatever build is current at the time,
REM    with no operator present.
REM
REM    Create a flag by hand:
REM      New-Item -ItemType File C:\rustserver\UPDATE.flag
REM
REM    In hotwire mode, if MAX_DAYS_WITHOUT_UPDATE days pass without an
REM    update, one runs regardless. Rust clients update themselves; a
REM    server that does not eventually refuses every connection.
REM
REM  PLUGIN                  optional, see src\Hotwire.cs
REM    Schedules restarts, announces them to players, counts down, and
REM    writes the flag when a scheduled restart is an update. The flag file
REM    is the only interface between plugin and launcher. Neither half
REM    requires the other.
REM
REM  EDITING OPTIONS
REM    One option per line. REM disables it, removing REM enables it:
REM
REM      REM  server.maxplayers -- Slots.
REM      REM  [int, default 500]
REM      set "ARGS=!ARGS! +server.maxplayers 50"
REM
REM    Lines are independent. Disabling one cannot affect any other.
REM
REM  VALUES
REM    Quote values containing spaces. Write a literal percent sign as %%.
REM    !ARGS! is required and is not a typo for %ARGS%: delayed expansion
REM    substitutes after cmd parses the line, which keeps | & > < ^ safe
REM    inside a value.
REM
REM  DEFAULTS
REM    The defaults shown in section 4 were read out of a Rust build, not
REM    copied from documentation. Report any that disagree with the game.
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

REM  HOW UPDATES HAPPEN. Two modes, and the right one depends on who is
REM  deciding when your server restarts.
REM
REM    always   Update every time the server starts. This is how nearly
REM             every Rust launcher behaves. Restarts take longer, and you
REM             are never behind. Right if you restart by hand.
REM
REM    hotwire  Update only when a flag file says to, so restarts are quick
REM             and updates happen when you choose. Right if something is
REM             restarting the server for you -- the Hotwire plugin, a
REM             scheduled task -- because otherwise a 5am restart can
REM             install a new build over a working server unattended.
set "UPDATE_MODE=always"

REM  Only used in hotwire mode. Rust clients update themselves, so a server
REM  that never updates eventually cannot be joined at all -- it is not
REM  stale, it is unreachable, and it usually happens on force wipe day.
REM  If this many days pass with no update, one is done anyway and said
REM  loudly in the console. 0 turns the backstop off.
set "MAX_DAYS_WITHOUT_UPDATE=14"

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
set "STAMP=%ROOT%\logs\last_update.txt"


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



REM =====================================================================
:start
REM =====================================================================
REM  3. UPDATE OR RESTART?
REM
REM  The two flag files, and what each one costs:
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

if /i "%UPDATE_MODE%"=="always" (
    set "DO_UPDATE=1"
    echo [%date% %time%] UPDATE_MODE is always -- updating before launch.
)

if exist "%ROOT%\UPDATE.flag" (
    set "DO_UPDATE=1"
    echo [%date% %time%] UPDATE.flag found -- this pass will update.
)
if exist "%ROOT%\VALIDATE.flag" (
    set "DO_UPDATE=1"
    set "DO_VALIDATE=1"
    echo [%date% %time%] VALIDATE.flag found -- update and validate.
)

REM  The backstop. Only in hotwire mode, only when nothing has already
REM  asked for an update, and skipped entirely when set to 0. A missing
REM  stamp counts as forever, so a fresh install updates once on its first
REM  start rather than waiting a fortnight to find out it is out of date.
if /i "%UPDATE_MODE%"=="always" goto :updatedecided
if "%DO_UPDATE%"=="1" goto :updatedecided
if "%MAX_DAYS_WITHOUT_UPDATE%"=="0" goto :updatedecided

set "DAYS_SINCE_UPDATE=9999"
if exist "%STAMP%" for /f %%d in ('powershell -NoProfile -Command "[int]((Get-Date) - (Get-Item '%STAMP%').LastWriteTime).TotalDays"') do set "DAYS_SINCE_UPDATE=%%d"

if !DAYS_SINCE_UPDATE! GEQ %MAX_DAYS_WITHOUT_UPDATE% (
    set "DO_UPDATE=1"
    echo [%date% %time%] ================================================
    echo [%date% %time%] No update in !DAYS_SINCE_UPDATE! days. Updating anyway.
    echo [%date% %time%] A server that never updates stops being joinable
    echo [%date% %time%] once the clients move on. Set UPDATE_MODE=always,
    echo [%date% %time%] or schedule updates, to stop seeing this.
    echo [%date% %time%] ================================================
)

:updatedecided

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

REM  What the backstop reads. Its timestamp is the whole point; the text
REM  inside is only there so a person can read it too.
echo Last update: %date% %time%> "%STAMP%"

if defined HOOK_AFTER call %HOOK_AFTER%


REM =====================================================================
:buildargs
REM =====================================================================
REM  4. SERVER OPTIONS
REM
REM  One option per line. REM a line to switch it off; an option you do not
REM  set simply uses the game's default, printed beside every one of them.
REM
REM  This is a curated list, not every convar Rust has. The game holds about
REM  sixteen hundred, and the great majority are diagnostics and internal
REM  tuning that nobody sets when starting a server. The ones here are the
REM  ones people actually change.
REM =====================================================================

set "ARGS="

REM ---------------------------------------------------------------------
REM  4.0  PROCESS
REM ---------------------------------------------------------------------

REM  Run headless, with no window and no renderer. Required on a server.
set "ARGS=!ARGS! -batchmode -nographics"

REM ---------------------------------------------------------------------
REM  4.1  IDENTITY AND THE MAP
REM
REM  Get these right before the first boot. server.identity names the folder under
REM  server\ that holds the map, blueprints, bans and every player's progress:
REM  change it later and you have a brand new server with the old one orphaned on
REM  disk. Changing level, seed or worldsize regenerates the map, which wipes
REM  everything built on it.
REM ---------------------------------------------------------------------

REM  server.identity -- Save folder name. Short, lower case, no spaces.
REM  [string, default "my_server_identity"]
set "ARGS=!ARGS! +server.identity my_server"

REM  server.level -- Leave as-is for a generated map. For a custom map use server.levelurl instead.
REM  [string, default "Procedural Map"]
set "ARGS=!ARGS! +server.level "Procedural Map""

REM  server.seed -- Any integer. The same seed and worldsize always give the same map.
REM  [int, default 1337]
set "ARGS=!ARGS! +server.seed 1234567"

REM  server.worldsize -- Metres across, 1000-6000. Memory and boot time climb faster than the number does.
REM  [int, default 4500]
set "ARGS=!ARGS! +server.worldsize 4000"

REM  server.levelurl -- Custom map URL. Replaces level, seed and worldsize -- do not set both.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.levelurl VALUE"

REM ---------------------------------------------------------------------
REM  4.2  NETWORK
REM
REM  All three ports need forwarding at the router, and it is worth reserving this
REM  machine's address in DHCP while you are in there: if the lease moves, every
REM  forward breaks at once.
REM ---------------------------------------------------------------------

REM  server.port -- Game traffic, UDP.
REM  [int, default 28015]
set "ARGS=!ARGS! +server.port 28015"

REM  server.queryport -- Server browser, UDP. Getting this wrong is the classic Rust fault: the
REM  server runs perfectly and is simply invisible.
REM
REM  Do not use 27015, and avoid 27000-27030 generally. That is Steam's own
REM  client port range, so on a machine that also runs Steam the client can
REM  take the port and the server stops answering browser queries until
REM  something releases it. Guides recommending 27015 are copying Source
REM  engine convention; Rust is not Source. Left at 0 the game derives
REM  1 + the higher of server.port and rcon.port, which is 28017 here.
REM  [int, default 0]
set "ARGS=!ARGS! +server.queryport 28017"

REM  rcon.port -- Remote console, TCP.
REM  [int, default 0]
set "ARGS=!ARGS! +rcon.port 28016"

REM  server.maxplayers -- Slots.
REM  [int, default 500]
set "ARGS=!ARGS! +server.maxplayers 50"

REM  server.ip -- Bind address. Leave alone unless the machine is multi-homed.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.ip VALUE"

REM  server.playertimeout -- Seconds of silence before a client is dropped.
REM  [int, default 60]
REM set "ARGS=!ARGS! +server.playertimeout VALUE"

REM  server.rejoin_delay -- Seconds a kicked player waits before rejoining.
REM  [int, default 300]
REM set "ARGS=!ARGS! +server.rejoin_delay VALUE"

REM ---------------------------------------------------------------------
REM  4.3  BROWSER LISTING
REM
REM  What people see before they join.
REM ---------------------------------------------------------------------

REM  server.hostname -- Your advert. Pipes and spaces are safe here.
REM  [string, default "My Untitled Rust Server"]
set "ARGS=!ARGS! +server.hostname "My Rust Server | Monthly | NA""

REM  server.description -- Join-screen text. Backslash-n makes a line break.
REM  [string, default "No server description has been provided."]
set "ARGS=!ARGS! +server.description "What makes this server different.""

REM  server.tags -- Browser filter tags, comma separated, no spaces. The client knows:
REM    monthly biweekly weekly    wipe schedule
REM    vanilla softcore hardcore primitive pve    ruleset
REM    roleplay creative minigame training battlefield builds    style
REM  Add a region tag too, such as NA or EU. Only tags the browser filters
REM  on do anything; inventing your own just makes a longer string.
REM  [property, default UNKNOWN]
set "ARGS=!ARGS! +server.tags "monthly,pve,NA""

REM  server.headerimage -- 512x256 banner. Direct image URL, not a page containing one.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.headerimage VALUE"

REM  server.logoimage -- Server logo. Direct image URL.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.logoimage VALUE"

REM  server.url -- Website link on the join screen.
REM  [string, default ""]
REM set "ARGS=!ARGS! +server.url VALUE"

REM ---------------------------------------------------------------------
REM  4.4  ADMIN AND RCON
REM
REM  RCON is remote code execution on this machine. The password belongs in
REM  secrets.bat and nowhere else.
REM ---------------------------------------------------------------------

REM  rcon.password -- Read from secrets.bat. Never write a literal here.
REM  [?, default UNKNOWN]
set "ARGS=!ARGS! +rcon.password !RCON_PASSWORD!"

REM  rcon.web -- 1 for WebSocket RCON, which is what current tools expect.
REM  [bool, default true]
set "ARGS=!ARGS! +rcon.web 1"

REM  rcon.ip -- Bind address for RCON. Leave alone unless multi-homed.
REM  [string, default ""]
REM set "ARGS=!ARGS! +rcon.ip VALUE"

REM  server.printReportsToConsole -- Player reports appear in the console.
REM  [bool, default false]
set "ARGS=!ARGS! +server.printReportsToConsole true"

REM ---------------------------------------------------------------------
REM  4.5  SAVES AND LOGS
REM
REM  The save interval is how much progress a crash costs everybody, which is why
REM  a scheduled restart should quit cleanly rather than kill the process.
REM ---------------------------------------------------------------------

REM  server.saveinterval -- Seconds between world saves. Lower costs a brief hitch more often.
REM  [int, default 600]
set "ARGS=!ARGS! +server.saveinterval 300"

REM  server.saveBackupCount -- Rolling save backups kept on disk.
REM  [int, default 2]
REM set "ARGS=!ARGS! +server.saveBackupCount VALUE"

REM  chat.serverlog -- Print chat to the console and log.
REM  [bool, default true]
REM set "ARGS=!ARGS! +chat.serverlog VALUE"

REM ---------------------------------------------------------------------
REM  4.6  PVE, PVP AND DAMAGE
REM
REM  server.pve is a blunt server-wide switch and turns off far more than most
REM  people expect. Almost every PVE server uses a plugin instead, which can make
REM  zones, times or teams behave differently.
REM ---------------------------------------------------------------------

REM  server.pve -- Server-wide PVE.
REM  [bool, default false]
REM set "ARGS=!ARGS! +server.pve VALUE"

REM  server.pvp_ttk_global -- Time-to-kill multiplier. Above 1 means players take longer to die.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.pvp_ttk_global VALUE"

REM  server.bulletdamage -- Bullet damage multiplier.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.bulletdamage VALUE"

REM  server.arrowdamage -- Arrow damage multiplier.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +server.arrowdamage VALUE"

REM  server.radiation -- Radiation zones on or off.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.radiation VALUE"

REM  server.stability -- Building stability. Off lets people build things that could not stand up.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.stability VALUE"

REM ---------------------------------------------------------------------
REM  4.7  DEATH AND RESPAWN
REM ---------------------------------------------------------------------

REM  server.woundingenabled -- Players go down wounded instead of dying outright.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.woundingenabled VALUE"

REM  server.crawlingenabled -- Wounded players can crawl.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.crawlingenabled VALUE"

REM  server.woundedrecoverchance -- Chance of getting back up without help.
REM  [float, default 0.2]
REM set "ARGS=!ARGS! +server.woundedrecoverchance VALUE"

REM  server.dropitems -- Drop your inventory on death.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.dropitems VALUE"

REM  server.corpses -- Leave a lootable corpse.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.corpses VALUE"

REM  server.respawnAtDeathPosition -- Respawn where you died.
REM  [bool, default false]
REM set "ARGS=!ARGS! +server.respawnAtDeathPosition VALUE"

REM  server.respawnWithLoadout -- Respawn holding a kit.
REM  [bool, default false]
REM set "ARGS=!ARGS! +server.respawnWithLoadout VALUE"

REM ---------------------------------------------------------------------
REM  4.8  DESPAWN TIMES
REM
REM  Seconds. Raising these leaves more on the ground, which players like and the
REM  entity count does not.
REM ---------------------------------------------------------------------

REM  server.itemdespawn -- Dropped items.
REM  [float, default 300.0]
REM set "ARGS=!ARGS! +server.itemdespawn VALUE"

REM  server.itemdespawn_quick -- Low-value items, which go sooner.
REM  [float, default 30.0]
REM set "ARGS=!ARGS! +server.itemdespawn_quick VALUE"

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

REM  decay.scale -- Decay rate multiplier. 0 turns decay off entirely, which many modded servers do.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +decay.scale VALUE"

REM  decay.upkeep -- Whether tool cupboards consume upkeep at all.
REM  [bool, default true]
REM set "ARGS=!ARGS! +decay.upkeep VALUE"

REM  decay.upkeep_grief_protection -- Minutes of grace after a cupboard runs dry.
REM  [float, default 1440.0]
REM set "ARGS=!ARGS! +decay.upkeep_grief_protection VALUE"

REM ---------------------------------------------------------------------
REM  4.10  CHAT
REM ---------------------------------------------------------------------

REM  chat.enabled -- Chat on or off.
REM  [bool, default true]
REM set "ARGS=!ARGS! +chat.enabled VALUE"

REM  chat.globalchat -- Everyone hears everyone, anywhere on the map. Off leaves only local chat.
REM  [bool, default true]
REM set "ARGS=!ARGS! +chat.globalchat VALUE"

REM  chat.localchat -- Proximity chat.
REM  [bool, default false]
REM set "ARGS=!ARGS! +chat.localchat VALUE"

REM  chat.localChatRange -- Metres that proximity chat carries.
REM  [float, default 100.0]
REM set "ARGS=!ARGS! +chat.localChatRange VALUE"

REM ---------------------------------------------------------------------
REM  4.11  EVENTS
REM
REM  server.events is the master switch; the rest tune individual events.
REM ---------------------------------------------------------------------

REM  server.events -- Timed world events on or off.
REM  [bool, default true]
REM set "ARGS=!ARGS! +server.events VALUE"

REM  patrolhelicopter.lifetimeMinutes -- How long the patrol helicopter stays before leaving.
REM  [float, default 30.0]
REM set "ARGS=!ARGS! +patrolhelicopter.lifetimeMinutes VALUE"

REM  patrolhelicopter.guns -- How many guns it fires with.
REM  [int, default 1]
REM set "ARGS=!ARGS! +patrolhelicopter.guns VALUE"

REM  patrolhelicopter.bulletDamageScale -- Its damage multiplier.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +patrolhelicopter.bulletDamageScale VALUE"

REM  cargoship.event_enabled -- Cargo ship on or off.
REM  [bool, default true]
REM set "ARGS=!ARGS! +cargoship.event_enabled VALUE"

REM  cargoship.event_duration_minutes -- How long it stays.
REM  [float, default 50.0]
REM set "ARGS=!ARGS! +cargoship.event_duration_minutes VALUE"

REM  halloween.enabled -- Halloween event.
REM  [bool, default false]
REM set "ARGS=!ARGS! +halloween.enabled VALUE"

REM  xmas.enabled -- Christmas event.
REM  [bool, default false]
REM set "ARGS=!ARGS! +xmas.enabled VALUE"

REM ---------------------------------------------------------------------
REM  4.12  SPAWNS AND POPULATIONS
REM
REM  Populations are per square kilometre, so a bigger map means more animals at
REM  the same number. The spawn rates and densities scale the whole system at once
REM  and go a long way; change them in small steps.
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

REM  spawn.player_scale -- How strongly nearby players suppress spawns.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +spawn.player_scale VALUE"

REM  bear.Population -- Bears.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +bear.Population VALUE"

REM  polarbear.Population -- Polar bears.
REM  [float, default 1.0]
REM set "ARGS=!ARGS! +polarbear.Population VALUE"

REM  boar.Population -- Boar.
REM  [float, default 5.0]
REM set "ARGS=!ARGS! +boar.Population VALUE"

REM  stag.Population -- Stags.
REM  [float, default 3.0]
REM set "ARGS=!ARGS! +stag.Population VALUE"

REM  chicken.Population -- Chickens.
REM  [float, default 3.0]
REM set "ARGS=!ARGS! +chicken.Population VALUE"

REM  wolf2.Population -- Wolves. The class really is Wolf2; Rust replaced the original.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +wolf2.Population VALUE"

REM  ridablehorse.Population -- Horses. Note the spelling: ridable, one e.
REM  [float, default 2.0]
REM set "ARGS=!ARGS! +ridablehorse.Population VALUE"

REM ---------------------------------------------------------------------
REM  4.13  IDLE KICK
REM ---------------------------------------------------------------------

REM  server.idlekick -- Minutes of idling before a kick.
REM  [int, default 30]
REM set "ARGS=!ARGS! +server.idlekick VALUE"

REM  server.idlekickmode -- 0 never, 1 only when the server is full, 2 always.
REM  [int, default 1]
REM set "ARGS=!ARGS! +server.idlekickmode VALUE"

REM ---------------------------------------------------------------------
REM  4.14  RUST+ COMPANION APP
REM
REM  Rust+ needs its own port forward, which is almost always why it does not
REM  work.
REM ---------------------------------------------------------------------

REM  app.port -- Rust+ port, TCP. 0 derives server.port + 68, so 28083 here.
REM  [int, default UNKNOWN]
REM set "ARGS=!ARGS! +app.port VALUE"

REM  app.listenip -- Bind address for Rust+.
REM  [string, default ""]
REM set "ARGS=!ARGS! +app.listenip VALUE"

REM ---------------------------------------------------------------------
REM  4.15  PERFORMANCE
REM
REM  Leave this alone unless you are chasing a problem you have actually measured.
REM  Raising the tick rate is the most common thing people try and the least likely
REM  to help: it multiplies CPU cost and does nothing for a server that was not
REM  CPU-bound to begin with.
REM ---------------------------------------------------------------------

REM  server.tickrate -- Server ticks per second.
REM  [int, default 10]
REM set "ARGS=!ARGS! +server.tickrate VALUE"

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
