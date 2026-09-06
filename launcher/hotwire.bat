@echo off
setlocal EnableDelayedExpansion

REM  "hotwire.bat check" validates the settings and the option list,
REM  says what is wrong, and exits without updating or starting
REM  anything. Run it after editing section 4.
set "CHECK_ONLY="
if /i "%~1"=="check" set "CHECK_ONLY=1"

REM ==[ H O T W I R E ]===================================================
REM  Version 1.1.6   2026-09-05
REM  Built by xman2000 and Claude.  MIT License.
REM
REM  The launcher. Starts a Rust dedicated server, relaunches it when it
REM  exits, and updates it either on every start or on demand.
REM
REM  https://github.com/xman2000/hotwire
REM ======================================================================
REM
REM  REQUIREMENTS
REM     Windows, steamcmd, and a Rust dedicated server. PowerShell and
REM     curl are used for log rotation, date maths and downloads; both
REM     ship with Windows 10 and later.
REM
REM     Nothing else. The plugin described below is optional and this file
REM     works perfectly well without it.
REM
REM  SETUP
REM     1.  Section 1: set ROOT and STEAMCMD.
REM     2.  Copy secrets.example.bat to secrets.bat and set RCON_PASSWORD.
REM     3.  Section 4: enable the options you need. Anything left disabled
REM         uses the game's default.
REM     4.  Run "hotwire.bat check" to have it read back what you set
REM         and say what is wrong. It does not update or start anything.
REM     5.  Run this file. Leave the window open.
REM
REM  RUN LOOP
REM     The script does not exit after starting the server. It waits for
REM     the server process to end, then starts it again after
REM     RESTART_DELAY seconds. Close the window to stop the server
REM     permanently.
REM
REM  UPDATE MODES
REM     Set UPDATE_MODE in section 1.
REM
REM     always     steamcmd and the mod framework run on every start. This
REM                is the default and matches most Rust launchers.
REM
REM     hotwire    steamcmd and the mod framework run only when
REM                UPDATE.flag or VALIDATE.flag is present in ROOT. The
REM                flag is deleted once acted on: one flag, one update.
REM                All other restarts relaunch and nothing more.
REM
REM     Use hotwire when restarts are automated. In always mode an
REM     unattended restart installs whatever build is current at the time,
REM     with no operator present.
REM
REM     Create a flag by hand:
REM       New-Item -ItemType File C:\rustserver\UPDATE.flag
REM
REM     In hotwire mode, if MAX_DAYS_WITHOUT_UPDATE days pass without an
REM     update, one runs regardless. Rust clients update themselves; a
REM     server that does not eventually refuses every connection.
REM
REM  PLUGIN
REM     Optional. See src\Hotwire.cs at the address above. It schedules
REM     restarts, announces them to players, counts down, and writes the
REM     flag when a scheduled restart is an update. The flag file is the
REM     only interface between plugin and launcher, and neither half
REM     requires the other.
REM
REM     The plugin needs Oxide/uMod. Its countdown bar is drawn through
REM     AdvancedStatus, a paid plugin most servers will not have --
REM     without it the countdown still runs and is announced in chat,
REM     which is the normal case rather than a degraded one.
REM
REM  EDITING OPTIONS
REM     One option per line. REM disables it, removing REM enables it:
REM
REM       REM   server.maxplayers -- Slots.
REM       REM   [int, default 500]
REM       set "ARGS=!ARGS! +server.maxplayers 50"
REM
REM     Lines are independent. Disabling one cannot affect any other.
REM
REM  VALUES
REM     Quote any value that contains a space.
REM
REM     Double a literal percent sign: write 20%% rather than 20%.
REM
REM     !ARGS! is required and is not a typo for %ARGS%. Delayed expansion
REM     substitutes after cmd has parsed the line, so pipes, ampersands,
REM     redirection arrows and carets already inside ARGS are never seen
REM     by the parser.
REM
REM  DEFAULTS
REM     The defaults shown in section 4 were read out of a Rust build, not
REM     copied from documentation. Report any that disagree with the game.
REM ======================================================================


REM ======================================================================
REM  1. PATHS AND BEHAVIOR
REM ======================================================================

REM   Where the server is installed. steamcmd writes here.
set "ROOT=C:\rustserver"

REM   Where steamcmd itself lives.
set "STEAMCMD=C:\steamcmd\steamcmd.exe"

REM   Rust's Steam app id. Do not change this.
set "APPID=258550"

REM   When updates happen. Pick the mode that matches who decides when the
REM     server restarts.
REM
REM     always     Every start. Restarts take longer and the server is
REM                never behind. Use this if you restart by hand.
REM
REM     hotwire    Only when a flag file says so. Restarts are quick and
REM                updates happen when you choose. Use this if anything
REM                else restarts the server for you.
set "UPDATE_MODE=always"

REM   hotwire mode only. If this many days pass with no update, one runs
REM     anyway and says so in the console. Rust clients update themselves,
REM     so a server that never does eventually refuses every connection. 0
REM     disables the backstop.
set "MAX_DAYS_WITHOUT_UPDATE=14"

REM   Give up on steamcmd after this many tries and launch the install
REM     already on disk. A stale build is a server; an infinite retry is
REM     not.
set "MAX_STEAM_TRIES=5"

REM   Rotated server logs to keep.
set "LOG_KEEP=14"

REM   Seconds to wait before relaunching after the server exits. A run
REM     that crashed backs off from here; see CRASH_SECONDS below.
set "RESTART_DELAY=15"

REM   A run shorter than this counts as a crash rather than a restart.
REM     A Rust server takes minutes to boot, so anything under a minute
REM     did not start -- bad convar, port already bound, corrupt save.
set "CRASH_SECONDS=60"

REM   Consecutive crashes before the launcher stops instead of looping
REM     forever. Set to 0 to never stop.
set "MAX_CRASH_STREAK=10"

REM   Optional commands run before and after an update, for backups or
REM     notifications. Leave empty to do nothing.
set "HOOK_BEFORE="
set "HOOK_AFTER="

set "LOGFILE=%ROOT%\logs\server_log.txt"
set "UPDATE_STAMP=%ROOT%\logs\last_update.txt"

REM  Consecutive crashes. Set here rather than at :start so it survives
REM  the loop, which is the whole point of counting it.
set /a CRASH_STREAK=0


REM ======================================================================
REM  1b. CHECKING THE SETTINGS ABOVE
REM
REM     Section 1 is numbers and paths, and a wrong one there fails a long
REM     way from where it was typed. LOG_KEEP=0 makes the log cull delete
REM     every rotated log rather than none. A trailing backslash on ROOT
REM     turns +force_install_dir "C:\rustserver\" into a quoted string
REM     steamcmd never closes. A misspelled UPDATE_MODE silently selects
REM     the mode you did not want, because anything that is not "always"
REM     is treated as "hotwire".
REM ======================================================================

set "CFGBAD="

REM  A trailing backslash escapes the closing quote of every path we
REM  hand to another program. Take it off rather than complain about it.
if "!ROOT:~-1!"=="\" set "ROOT=!ROOT:~0,-1!"
if "!STEAMCMD:~-1!"=="\" set "STEAMCMD=!STEAMCMD:~0,-1!"

if not defined ROOT (
    echo [%date% %time%] ROOT is empty. Set it in section 1.
    set "CFGBAD=1"
)

if /i not "%UPDATE_MODE%"=="always" if /i not "%UPDATE_MODE%"=="hotwire" (
    echo [%date% %time%] UPDATE_MODE is [%UPDATE_MODE%]. It must be
    echo [%date% %time%] exactly "always" or "hotwire" -- anything else is
    echo [%date% %time%] treated as hotwire, which is probably not what
    echo [%date% %time%] you meant.
    set "CFGBAD=1"
)

REM  Numeric test with no echo and no pipe. Digits are the delimiters,
REM  so an all-digit value produces no tokens and the inner loop never
REM  runs; one non-digit produces a token and clears the flag. An empty
REM  value produces no tokens either, so it is ruled out first.
for %%V in (MAX_DAYS_WITHOUT_UPDATE MAX_STEAM_TRIES LOG_KEEP RESTART_DELAY CRASH_SECONDS MAX_CRASH_STREAK) do (
    set "CFGVAL=!%%V!"
    set "CFGNUM=1"
    if not defined CFGVAL set "CFGNUM="
    for /f "delims=0123456789" %%X in ("!CFGVAL!") do set "CFGNUM="
    if not defined CFGNUM (
        echo [%date% %time%] %%V must be a whole number. It is [!CFGVAL!].
        set "CFGBAD=1"
    )
)

REM  Skip 0 keeps nothing back, so the cull would remove every rotated
REM  log including the one just written.
if "%LOG_KEEP%"=="0" (
    echo [%date% %time%] LOG_KEEP is 0, which would delete every rotated
    echo [%date% %time%] log rather than keep none. Use 1 or more.
    set "CFGBAD=1"
)

if "%MAX_STEAM_TRIES%"=="0" (
    echo [%date% %time%] MAX_STEAM_TRIES is 0, so steamcmd would never run.
    set "CFGBAD=1"
)

if defined CFGBAD (
    echo [%date% %time%] ================================================
    echo [%date% %time%] Section 1 has a setting that cannot work.
    echo [%date% %time%] Not starting. Fix the lines named above.
    echo [%date% %time%] ================================================
    pause & exit /b 1
)


REM ======================================================================
REM  2. SECRETS
REM
REM     Copy secrets.example.bat to secrets.bat and set RCON_PASSWORD
REM     there. secrets.bat is gitignored. This launcher will not start
REM     without it, but it does not check the value, so change the example
REM     password.
REM ======================================================================

set "SECRETS=%~dp0secrets.bat"

if not exist "%SECRETS%" (
    echo [%date% %time%] MISSING %SECRETS%
    echo Copy secrets.example.bat to secrets.bat and set RCON_PASSWORD.
    pause & exit /b 1
)
REM  Read with delayed expansion OFF. A password containing ! is eaten
REM  at the moment secrets.bat SETS it, not where it is used, because
REM  the called file is parsed by this same cmd. Turning expansion off
REM  around the call is the only place that can be fixed; the for loop
REM  then carries the value back across the scope boundary intact,
REM  because the block was parsed while expansion was still off.
setlocal DisableDelayedExpansion
call "%SECRETS%"
if not defined RCON_PASSWORD (
    endlocal
    echo [%date% %time%] secrets.bat did not set RCON_PASSWORD.
    pause & exit /b 1
)
for /f "delims=" %%P in ("%RCON_PASSWORD%") do (
    endlocal
    set "RCON_PASSWORD=%%P"
)
if not defined RCON_PASSWORD (
    echo [%date% %time%] The RCON password did not survive being read.
    echo [%date% %time%] A leading semicolon or a double quote in it will
    echo [%date% %time%] do that. Change the password; do not quote it.
    pause & exit /b 1
)

REM  Everything above proves the password exists. This proves it is
REM  plausible, which is a different question and the one that bites.
REM
REM  A two-character leftover in a secrets file went through as
REM  +rcon.password "xx" and the server died in Bootstrap.Init_Tier0 with
REM  "String cannot be of zero length", naming nothing and pointing
REM  nowhere. Rust redacts the password out of its own logged command
REM  line, so an empty or absurd value makes that redaction throw before
REM  anything else runs. Hours went into that. The launcher knows which
REM  file the value came from and the engine never will, so the check
REM  belongs here.
REM
REM  Asked in PowerShell rather than with batch string slicing, because
REM  the value is untrusted text: a quote or a caret in it would break
REM  the very comparison meant to catch a bad password.
set "PWCHECK="
for /f %%R in ('powershell -NoProfile -Command "$p=$env:RCON_PASSWORD; if (-not $p) {'EMPTY'} elseif ($p.Length -lt 8) {'SHORT'} elseif ($p -eq 'change_me') {'EXAMPLE'} elseif ($p.Contains([char]34)) {'QUOTE'} else {'OK'}"') do set "PWCHECK=%%R"
if not defined PWCHECK set "PWCHECK=OK"

if not "!PWCHECK!"=="OK" (
    echo [%date% %time%] ================================================
    if "!PWCHECK!"=="EMPTY"   echo [%date% %time%] The RCON password is empty.
    if "!PWCHECK!"=="SHORT"   echo [%date% %time%] The RCON password is under 8 characters.
    if "!PWCHECK!"=="EXAMPLE" echo [%date% %time%] The RCON password is still the example value.
    if "!PWCHECK!"=="QUOTE"   echo [%date% %time%] The RCON password contains a double quote.
    echo [%date% %time%] Fix it in:
    echo [%date% %time%]   %SECRETS%
    echo [%date% %time%] The line should read, with one pair of quotes
    echo [%date% %time%] around the whole assignment:
    echo [%date% %time%]   set "RCON_PASSWORD=your password here"
    echo [%date% %time%] RCON is remote code execution on this machine.
    echo [%date% %time%] Not starting -- the server would have crashed in
    echo [%date% %time%] Bootstrap.Init_Tier0 without telling you why.
    echo [%date% %time%] ================================================
    pause & exit /b 1
)

REM  The other opaque failure: a wrong ROOT. Every convar would be fine
REM  and the server simply would not be there.
if not exist "%ROOT%\RustDedicated.exe" (
    echo [%date% %time%] ================================================
    echo [%date% %time%] No RustDedicated.exe in:
    echo [%date% %time%]   %ROOT%
    echo [%date% %time%] ROOT is set at the top of this file and is wrong,
    echo [%date% %time%] or the install is incomplete.
    echo [%date% %time%] ================================================
    pause & exit /b 1
)

cd /d "%ROOT%" || (echo Cannot cd to %ROOT% & pause & exit /b 1)
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs" >nul 2>&1
if not exist "%ROOT%\logs" (
    echo [%date% %time%] ================================================
    echo [%date% %time%] Cannot create %ROOT%\logs
    echo [%date% %time%] The rotated logs and the update backstop stamp
    echo [%date% %time%] both live there. Without it a crash leaves no
    echo [%date% %time%] log to read and the backstop never fires.
    echo [%date% %time%] Check permissions on ROOT.
    echo [%date% %time%] ================================================
    pause & exit /b 1
)



:start

REM ======================================================================
REM  3. UPDATE OR RESTART
REM
REM     The two flag files, and what each one costs:
REM
REM     UPDATE.flag     app_update, then the mod framework, then launch.
REM     VALIDATE.flag   The same, plus validate, which re-checksums the
REM                     whole install. Slow. Weekly at most, or after a
REM                     crash.
REM
REM     Anything can create one: you, a scheduled task, or the plugin when
REM     a scheduled update comes due.
REM
REM       New-Item -ItemType File C:\rustserver\UPDATE.flag
REM ======================================================================

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
REM  Floor, not [int]: [int] rounds, so 13.6 days would trip a 14-day
REM  backstop half a day early.
if exist "%UPDATE_STAMP%" for /f %%d in ('powershell -NoProfile -Command "[math]::Floor(((Get-Date) - (Get-Item '%UPDATE_STAMP%').LastWriteTime).TotalDays)"') do set "DAYS_SINCE_UPDATE=%%d"

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

REM  check mode inspects; it never installs.
if defined CHECK_ONLY set "DO_UPDATE=0"

if defined HOOK_BEFORE call %HOOK_BEFORE%

if "%DO_UPDATE%"=="0" (
    echo [%date% %time%] Plain restart -- skipping steamcmd and framework.
    goto buildargs
)

set /a STEAM_TRIES=0
set "STEAM_OK=0"

:steamupdate
set /a STEAM_TRIES+=1
if "%DO_VALIDATE%"=="1" (
    "%STEAMCMD%" +force_install_dir "%ROOT%" +login anonymous +app_update %APPID% validate +quit
) else (
    "%STEAMCMD%" +force_install_dir "%ROOT%" +login anonymous +app_update %APPID% +quit
)
if errorlevel 1 goto steamfailed
set "STEAM_OK=1"
goto framework

:steamfailed
echo [%date% %time%] steamcmd error (attempt !STEAM_TRIES! of %MAX_STEAM_TRIES%).
if !STEAM_TRIES! GEQ %MAX_STEAM_TRIES% goto steamgaveup
REM  timeout refuses to run when stdin is redirected, which is how this
REM  launcher behaves under a scheduler. Without the fallback the retry
REM  would return instantly and hammer steamcmd.
timeout /t 60 /nobreak >nul 2>&1
if errorlevel 1 ping -n 61 127.0.0.1 >nul 2>&1
goto steamupdate

:steamgaveup
echo [%date% %time%] Giving up on steamcmd. Launching what we have.

:framework
REM  Oxide/uMod. Comment this whole block out for a vanilla server.
REM  -f makes curl fail on an HTTP error instead of saving the error page,
REM  which would otherwise be force-extracted over a working install.
set "FRAMEWORK_OK=0"
curl -fSL -A "Mozilla/5.0" "https://umod.org/games/rust/download" --output "%ROOT%\OxideMod.zip"
if errorlevel 1 (
    echo [%date% %time%] Framework download failed. Keeping the install.
) else (
    powershell -NoProfile -Command "Expand-Archive -Force '%ROOT%\OxideMod.zip' '%ROOT%'"
    if errorlevel 1 (
        echo [%date% %time%] Framework extract failed.
    ) else (
        set "FRAMEWORK_OK=1"
    )
)
if exist "%ROOT%\OxideMod.zip" del "%ROOT%\OxideMod.zip"

REM  The flag is consumed and the backstop clock reset ONLY when the
REM  update actually happened.
REM
REM  Both used to run unconditionally, and both are reachable after
REM  steamcmd has given up. That turned "one flag, one update" into "one
REM  flag, one attempt": a failed update ate the flag and said nothing,
REM  and the next restart was a plain restart. Worse, a server that could
REM  not reach Steam reset its own backstop clock on every failed try, so
REM  the one thing written to catch a server drifting out of date was the
REM  one thing that could never fire.
set "UPDATE_OK=0"
if "!STEAM_OK!"=="1" if "!FRAMEWORK_OK!"=="1" set "UPDATE_OK=1"

REM  UPDATE_STAMP is what the backstop reads. Its timestamp is the whole
REM  point; the text inside is only there so a person can read it too.
REM  No REM inside the block below -- a stray parenthesis in a comment
REM  closes the block early, and a stray redirect writes a file.
REM  The stamp line writes its redirect FIRST. Written the other way
REM  round, the character sitting just before the redirect arrow is
REM  whatever digit the clock happens to end on, and cmd reads a digit
REM  in that position as a file handle number rather than as text.
REM  Handle 1 is stdout and works by luck; handles 3 to 9 create the
REM  file and write nothing into it; handle 2 sends the line to stderr.
REM  The backstop reads the file timestamp rather than its contents, so
REM  this was surviving on the file being created at all.
REM
REM  This comment sits outside the block below on purpose. REM does not
REM  neutralize a redirect, so an arrow inside a comment inside a block
REM  creates a file.
if "!UPDATE_OK!"=="1" (
    if exist "%ROOT%\UPDATE.flag"   del "%ROOT%\UPDATE.flag"
    if exist "%ROOT%\VALIDATE.flag" del "%ROOT%\VALIDATE.flag"
    >"%UPDATE_STAMP%" echo Last update: %date% %time%
) else (
    echo [%date% %time%] ================================================
    echo [%date% %time%] The update did NOT complete.
    echo [%date% %time%] Any UPDATE.flag or VALIDATE.flag is being KEPT,
    echo [%date% %time%] and the backstop clock has NOT been reset, so
    echo [%date% %time%] the next start will try again.
    echo [%date% %time%] ================================================
)

REM  Deleting a flag and writing the stamp can both fail on a
REM  permission problem, and neither failure shows up in the outcome:
REM  the update worked. A flag that will not delete means every
REM  restart from now updates, forever, in silence. A stamp that will
REM  not write means the backstop believes no update has ever
REM  happened and fires on every start. Warnings, not failures --
REM  the update itself succeeded.
if "!UPDATE_OK!"=="1" if exist "%ROOT%\UPDATE.flag" (
    echo [%date% %time%] WARNING: UPDATE.flag is still present after a
    echo [%date% %time%] successful update. It could not be deleted, so
    echo [%date% %time%] every restart from now will update. Check the
    echo [%date% %time%] permissions on ROOT.
)
if "!UPDATE_OK!"=="1" if exist "%ROOT%\VALIDATE.flag" (
    echo [%date% %time%] WARNING: VALIDATE.flag is still present after a
    echo [%date% %time%] successful update, so every restart will
    echo [%date% %time%] validate. That is slow, and unintended.
)
if "!UPDATE_OK!"=="1" if not exist "%UPDATE_STAMP%" (
    echo [%date% %time%] WARNING: could not write the update stamp at
    echo [%date% %time%]   %UPDATE_STAMP%
    echo [%date% %time%] The backstop reads it, so it will act as though
    echo [%date% %time%] no update has ever happened.
)

if defined HOOK_AFTER call %HOOK_AFTER%


REM ======================================================================
:buildargs
REM ======================================================================
REM  4. SERVER OPTIONS
REM
REM     One option per line. REM a line to switch it off; an option you do
REM     not set uses the game's default, printed beside every one of them.
REM
REM     This is a curated list, not every convar Rust has. Most of them are
REM     diagnostics and internal tuning that nobody sets when starting a
REM     server, and listing those here would only bury these.
REM ======================================================================

set "ARGS="

REM ----------------------------------------------------------------------
REM  4.0  PROCESS
REM ----------------------------------------------------------------------

REM   Run headless, with no window and no renderer. Required on a server.
set "ARGS=!ARGS! -batchmode -nographics"

REM ----------------------------------------------------------------------
REM  4.1  IDENTITY AND THE MAP
REM
REM     Get these right before the first boot. server.identity names the
REM     folder under server\ that holds the map, blueprints, bans and
REM     every player's progress: change it later and you have a brand new
REM     server with the old one orphaned on disk. Changing level, seed or
REM     worldsize regenerates the map, which wipes everything built on it.
REM ----------------------------------------------------------------------

REM   server.identity -- Save folder name. Short, lower case, no spaces.
REM   [string, default "my_server_identity"]
set "ARGS=!ARGS! +server.identity my_server"

REM   server.level -- Leave as-is for a generated map. For a custom map
REM     use server.levelurl instead.
REM   [string, default "Procedural Map"]
set "ARGS=!ARGS! +server.level "Procedural Map""

REM   server.seed -- Any integer. The same seed and worldsize always give
REM     the same map.
REM   [int, default 1337]
set "ARGS=!ARGS! +server.seed 1234567"

REM   server.worldsize -- Metres across, 1000-6000. Memory and boot time
REM     climb faster than the number does.
REM   [int, default 4500]
set "ARGS=!ARGS! +server.worldsize 4000"

REM   server.levelurl -- Custom map URL. Replaces level, seed and
REM     worldsize -- do not set both.
REM   [string, default ""]
REM set "ARGS=!ARGS! +server.levelurl VALUE"

REM ----------------------------------------------------------------------
REM  4.2  NETWORK
REM
REM     All three ports need forwarding at the router, and it is worth
REM     reserving this machine's address in DHCP while you are in there:
REM     if the lease moves, every forward breaks at once.
REM ----------------------------------------------------------------------

REM   server.port -- Game traffic, UDP.
REM   [int, default 28015]
set "ARGS=!ARGS! +server.port 28015"

REM   server.queryport -- Server browser, UDP. Getting this wrong is the
REM     classic Rust fault: the server runs perfectly and is simply
REM     invisible.
REM
REM     Do not use 27015, and avoid 27000-27030 generally. That is Steam's
REM     own client port range, so on a machine that also runs Steam the
REM     client can take the port and the server stops answering browser
REM     queries until something releases it. Guides recommending 27015
REM     copy Source engine convention; Rust is not Source.
REM
REM     Left at 0 the game derives 1 + the higher of server.port and
REM     rcon.port, which is 28017 for the layout above.
REM   [int, default 0]
set "ARGS=!ARGS! +server.queryport 28017"

REM   rcon.port -- Remote console, TCP.
REM   [int, default 0]
set "ARGS=!ARGS! +rcon.port 28016"

REM   server.maxplayers -- Slots.
REM   [int, default 500]
set "ARGS=!ARGS! +server.maxplayers 50"

REM   server.ip -- Bind address. Leave alone unless the machine is multi-
REM     homed.
REM   [string, default ""]
REM set "ARGS=!ARGS! +server.ip VALUE"

REM   server.playertimeout -- Seconds of silence before a client is
REM     dropped.
REM   [int, default 60]
REM set "ARGS=!ARGS! +server.playertimeout VALUE"

REM   server.rejoin_delay -- Seconds a kicked player waits before
REM     rejoining.
REM   [int, default 300]
REM set "ARGS=!ARGS! +server.rejoin_delay VALUE"

REM ----------------------------------------------------------------------
REM  4.3  BROWSER LISTING
REM
REM     What people see before they join.
REM ----------------------------------------------------------------------

REM   server.hostname -- Your advert. Pipes and spaces are safe here.
REM   [string, default "My Untitled Rust Server"]
set "ARGS=!ARGS! +server.hostname "My Rust Server | Monthly | NA""

REM   server.description -- Join-screen text. Backslash-n makes a line
REM     break.
REM   [string, default "No server description has been provided."]
set "ARGS=!ARGS! +server.description "What makes this server different.""

REM   server.tags -- Browser filter tags, comma separated, no spaces. The
REM     tags the client recognizes are:
REM
REM     wipe schedule   monthly biweekly weekly
REM     ruleset         vanilla softcore hardcore primitive pve
REM     style           roleplay creative minigame training
REM                     battlefield builds
REM
REM     Add a region tag such as NA or EU. Only tags the browser filters
REM     on have any effect; inventing your own only makes the string
REM     longer.
REM   [property, default UNKNOWN]
set "ARGS=!ARGS! +server.tags "monthly,pve,NA""

REM   server.headerimage -- 512x256 banner. Direct image URL, not a page
REM     containing one.
REM   [string, default ""]
REM set "ARGS=!ARGS! +server.headerimage VALUE"

REM   server.logoimage -- Server logo. Direct image URL.
REM   [string, default ""]
REM set "ARGS=!ARGS! +server.logoimage VALUE"

REM   server.url -- Website link on the join screen.
REM   [string, default ""]
REM set "ARGS=!ARGS! +server.url VALUE"

REM ----------------------------------------------------------------------
REM  4.4  ADMIN AND RCON
REM
REM     RCON is remote code execution on this machine. The password
REM     belongs in secrets.bat and nowhere else.
REM ----------------------------------------------------------------------

REM   rcon.password -- Read from secrets.bat. Never write a literal here.
REM
REM   Four quotes, not three. set "VAR=..." takes first quote to last, so
REM   dropping one leaves ARGS holding an unterminated quote that
REM   swallows every option appended after it. And !VAR! rather than
REM   %VAR%: under delayed expansion a percent-expanded value is rescanned
REM   for !, an exclamation-expanded one is not.
REM   [?, default UNKNOWN]
set "ARGS=!ARGS! +rcon.password "!RCON_PASSWORD!""

REM   rcon.web -- 1 for WebSocket RCON, which is what current tools
REM     expect.
REM   [bool, default true]
set "ARGS=!ARGS! +rcon.web 1"

REM   rcon.ip -- Bind address for RCON. Leave alone unless multi-homed.
REM   [string, default ""]
REM set "ARGS=!ARGS! +rcon.ip VALUE"

REM   server.printReportsToConsole -- Player reports appear in the
REM     console.
REM   [bool, default false]
set "ARGS=!ARGS! +server.printReportsToConsole true"

REM ----------------------------------------------------------------------
REM  4.5  SAVES AND LOGS
REM
REM     The save interval is how much progress a crash costs everybody,
REM     which is why a scheduled restart should quit cleanly rather than
REM     kill the process.
REM ----------------------------------------------------------------------

REM   server.saveinterval -- Seconds between world saves. Lower costs a
REM     brief hitch more often.
REM   [int, default 600]
set "ARGS=!ARGS! +server.saveinterval 300"

REM   server.saveBackupCount -- Rolling save backups kept on disk.
REM   [int, default 2]
REM set "ARGS=!ARGS! +server.saveBackupCount VALUE"

REM   chat.serverlog -- Print chat to the console and log.
REM   [bool, default true]
REM set "ARGS=!ARGS! +chat.serverlog VALUE"

REM ----------------------------------------------------------------------
REM  4.6  PVE, PVP AND DAMAGE
REM
REM     server.pve is a blunt server-wide switch and turns off far more
REM     than most people expect. Almost every PVE server uses a plugin
REM     instead, which can make zones, times or teams behave differently.
REM ----------------------------------------------------------------------

REM   server.pve -- Server-wide PVE.
REM   [bool, default false]
REM set "ARGS=!ARGS! +server.pve VALUE"

REM   server.pvp_ttk_global -- Time-to-kill multiplier. Above 1 means
REM     players take longer to die.
REM   [float, default 1.0]
REM set "ARGS=!ARGS! +server.pvp_ttk_global VALUE"

REM   server.bulletdamage -- Bullet damage multiplier.
REM   [float, default 1.0]
REM set "ARGS=!ARGS! +server.bulletdamage VALUE"

REM   server.arrowdamage -- Arrow damage multiplier.
REM   [float, default 1.0]
REM set "ARGS=!ARGS! +server.arrowdamage VALUE"

REM   server.radiation -- Radiation zones on or off.
REM   [bool, default true]
REM set "ARGS=!ARGS! +server.radiation VALUE"

REM   server.stability -- Building stability. Off lets people build things
REM     that could not stand up.
REM   [bool, default true]
REM set "ARGS=!ARGS! +server.stability VALUE"

REM ----------------------------------------------------------------------
REM  4.7  DEATH AND RESPAWN
REM ----------------------------------------------------------------------

REM   server.woundingenabled -- Players go down wounded instead of dying
REM     outright.
REM   [bool, default true]
REM set "ARGS=!ARGS! +server.woundingenabled VALUE"

REM   server.crawlingenabled -- Wounded players can crawl.
REM   [bool, default true]
REM set "ARGS=!ARGS! +server.crawlingenabled VALUE"

REM   server.woundedrecoverchance -- Chance of getting back up without
REM     help.
REM   [float, default 0.2]
REM set "ARGS=!ARGS! +server.woundedrecoverchance VALUE"

REM   server.dropitems -- Drop your inventory on death.
REM   [bool, default true]
REM set "ARGS=!ARGS! +server.dropitems VALUE"

REM   server.corpses -- Leave a lootable corpse.
REM   [bool, default true]
REM set "ARGS=!ARGS! +server.corpses VALUE"

REM   server.respawnAtDeathPosition -- Respawn where you died.
REM   [bool, default false]
REM set "ARGS=!ARGS! +server.respawnAtDeathPosition VALUE"

REM   server.respawnWithLoadout -- Respawn holding a kit.
REM   [bool, default false]
REM set "ARGS=!ARGS! +server.respawnWithLoadout VALUE"

REM ----------------------------------------------------------------------
REM  4.8  DESPAWN TIMES
REM
REM     Seconds. Raising these leaves more on the ground, which players
REM     like and the entity count does not.
REM ----------------------------------------------------------------------

REM   server.itemdespawn -- Dropped items.
REM   [float, default 300.0]
REM set "ARGS=!ARGS! +server.itemdespawn VALUE"

REM   server.itemdespawn_quick -- Low-value items, which go sooner.
REM   [float, default 30.0]
REM set "ARGS=!ARGS! +server.itemdespawn_quick VALUE"

REM   server.corpsedespawn -- Player corpses.
REM   [float, default 300.0]
REM set "ARGS=!ARGS! +server.corpsedespawn VALUE"

REM   server.npccorpsedespawn -- NPC corpses.
REM   [float, default 600.0]
REM set "ARGS=!ARGS! +server.npccorpsedespawn VALUE"

REM   server.debrisdespawn -- Building debris after a raid.
REM   [float, default 30.0]
REM set "ARGS=!ARGS! +server.debrisdespawn VALUE"

REM ----------------------------------------------------------------------
REM  4.9  DECAY AND UPKEEP
REM ----------------------------------------------------------------------

REM   decay.scale -- Decay rate multiplier. 0 turns decay off entirely,
REM     which many modded servers do.
REM   [float, default 1.0]
REM set "ARGS=!ARGS! +decay.scale VALUE"

REM   decay.upkeep -- Whether tool cupboards consume upkeep at all.
REM   [bool, default true]
REM set "ARGS=!ARGS! +decay.upkeep VALUE"

REM   decay.upkeep_grief_protection -- Minutes of grace after a cupboard
REM     runs dry.
REM   [float, default 1440.0]
REM set "ARGS=!ARGS! +decay.upkeep_grief_protection VALUE"

REM ----------------------------------------------------------------------
REM  4.10  CHAT
REM ----------------------------------------------------------------------

REM   chat.enabled -- Chat on or off.
REM   [bool, default true]
REM set "ARGS=!ARGS! +chat.enabled VALUE"

REM   chat.globalchat -- Everyone hears everyone, anywhere on the map. Off
REM     leaves only local chat.
REM   [bool, default true]
REM set "ARGS=!ARGS! +chat.globalchat VALUE"

REM   chat.localchat -- Proximity chat.
REM   [bool, default false]
REM set "ARGS=!ARGS! +chat.localchat VALUE"

REM   chat.localChatRange -- Metres that proximity chat carries.
REM   [float, default 100.0]
REM set "ARGS=!ARGS! +chat.localChatRange VALUE"

REM ----------------------------------------------------------------------
REM  4.11  EVENTS
REM
REM     server.events is the master switch; the rest tune individual
REM     events.
REM ----------------------------------------------------------------------

REM   server.events -- Timed world events on or off.
REM   [bool, default true]
REM set "ARGS=!ARGS! +server.events VALUE"

REM   patrolhelicopter.lifetimeMinutes -- How long the patrol helicopter
REM     stays before leaving.
REM   [float, default 30.0]
REM set "ARGS=!ARGS! +patrolhelicopter.lifetimeMinutes VALUE"

REM   patrolhelicopter.guns -- How many guns it fires with.
REM   [int, default 1]
REM set "ARGS=!ARGS! +patrolhelicopter.guns VALUE"

REM   patrolhelicopter.bulletDamageScale -- Its damage multiplier.
REM   [float, default 1.0]
REM set "ARGS=!ARGS! +patrolhelicopter.bulletDamageScale VALUE"

REM   cargoship.event_enabled -- Cargo ship on or off.
REM   [bool, default true]
REM set "ARGS=!ARGS! +cargoship.event_enabled VALUE"

REM   cargoship.event_duration_minutes -- How long it stays.
REM   [float, default 50.0]
REM set "ARGS=!ARGS! +cargoship.event_duration_minutes VALUE"

REM   halloween.enabled -- Halloween event.
REM   [bool, default false]
REM set "ARGS=!ARGS! +halloween.enabled VALUE"

REM   xmas.enabled -- Christmas event.
REM   [bool, default false]
REM set "ARGS=!ARGS! +xmas.enabled VALUE"

REM ----------------------------------------------------------------------
REM  4.12  SPAWNS AND POPULATIONS
REM
REM     Populations are per square kilometre, so a bigger map means more
REM     animals at the same number. The spawn rates and densities scale
REM     the whole system at once and go a long way; change them in small
REM     steps.
REM ----------------------------------------------------------------------

REM   spawn.max_rate -- Upper bound on spawn rate.
REM   [float, default 1.0]
REM set "ARGS=!ARGS! +spawn.max_rate VALUE"

REM   spawn.min_rate -- Lower bound on spawn rate.
REM   [float, default 0.5]
REM set "ARGS=!ARGS! +spawn.min_rate VALUE"

REM   spawn.max_density -- Upper bound on spawn density.
REM   [float, default 1.0]
REM set "ARGS=!ARGS! +spawn.max_density VALUE"

REM   spawn.min_density -- Lower bound on spawn density.
REM   [float, default 0.5]
REM set "ARGS=!ARGS! +spawn.min_density VALUE"

REM   spawn.player_scale -- How strongly nearby players suppress spawns.
REM   [float, default 2.0]
REM set "ARGS=!ARGS! +spawn.player_scale VALUE"

REM   bear.Population -- Bears.
REM   [float, default 2.0]
REM set "ARGS=!ARGS! +bear.Population VALUE"

REM   polarbear.Population -- Polar bears.
REM   [float, default 1.0]
REM set "ARGS=!ARGS! +polarbear.Population VALUE"

REM   boar.Population -- Boar.
REM   [float, default 5.0]
REM set "ARGS=!ARGS! +boar.Population VALUE"

REM   stag.Population -- Stags.
REM   [float, default 3.0]
REM set "ARGS=!ARGS! +stag.Population VALUE"

REM   chicken.Population -- Chickens.
REM   [float, default 3.0]
REM set "ARGS=!ARGS! +chicken.Population VALUE"

REM   wolf2.Population -- Wolves. The class really is Wolf2; Rust replaced
REM     the original.
REM   [float, default 2.0]
REM set "ARGS=!ARGS! +wolf2.Population VALUE"

REM   ridablehorse.Population -- Horses. Note the spelling: ridable, one
REM     e.
REM   [float, default 2.0]
REM set "ARGS=!ARGS! +ridablehorse.Population VALUE"

REM ----------------------------------------------------------------------
REM  4.13  IDLE KICK
REM ----------------------------------------------------------------------

REM   server.idlekick -- Minutes of idling before a kick.
REM   [int, default 30]
REM set "ARGS=!ARGS! +server.idlekick VALUE"

REM   server.idlekickmode -- 0 never, 1 only when the server is full, 2
REM     always.
REM   [int, default 1]
REM set "ARGS=!ARGS! +server.idlekickmode VALUE"

REM ----------------------------------------------------------------------
REM  4.14  RUST+ COMPANION APP
REM
REM     Rust+ needs its own port forward, which is almost always why it
REM     does not work.
REM ----------------------------------------------------------------------

REM   app.port -- Rust+ port, TCP. 0 derives server.port + 68, so 28083
REM     here.
REM   [int, default UNKNOWN]
REM set "ARGS=!ARGS! +app.port VALUE"

REM   app.listenip -- Bind address for Rust+.
REM   [string, default ""]
REM set "ARGS=!ARGS! +app.listenip VALUE"

REM ----------------------------------------------------------------------
REM  4.15  PERFORMANCE
REM
REM     Leave this alone unless you are chasing a problem you have
REM     actually measured. Raising the tick rate is the most common thing
REM     people try and the least likely to help: it multiplies CPU cost
REM     and does nothing for a server that was not CPU-bound to begin
REM     with.
REM ----------------------------------------------------------------------

REM   server.tickrate -- Server ticks per second.
REM   [int, default 10]
REM set "ARGS=!ARGS! +server.tickrate VALUE"

REM ======================================================================
REM  4b. CHECKING THE OPTION LIST
REM
REM     Machinery. Nothing in this section is a setting.
REM
REM     Rust ignores a convar it does not recognize, and accepts an empty
REM     value for one it does. Both fail in silence. The second took a
REM     server down for an afternoon: an empty rcon.password reached
REM     Bootstrap.Init_Tier0, which redacts the password out of its own
REM     logged command line and threw "String cannot be of zero length",
REM     naming no file, no convar and no cause. The launcher is the last
REM     place that still knows which line the value came from, so the
REM     check belongs here.
REM
REM     What it catches: a convar with no value, an empty value, a value
REM     that is still an unexpanded variable, the same convar set twice,
REM     a name with no dot in it, an unbalanced quote, a port that is not
REM     a number or is out of range or collides with another port, and a
REM     server.identity that cannot be a folder name.
REM
REM     Written in PowerShell because the checks need a real tokenizer,
REM     and assembled one line at a time so it stays readable. The script
REM     contains no double quote, percent sign or exclamation mark, so
REM     nothing in it can be mangled on the way through cmd; where those
REM     three characters are needed they are built with [char].
REM
REM     ARGS reaches it through the environment rather than the command
REM     line, because it is full of quotes and pipes by design. Not
REM     through a file: ARGS carries the RCON password, and a file would
REM     put it on disk where a backup running at the same moment could
REM     pick it up. RCON_PASSWORD is already in this process environment,
REM     so this adds no exposure that was not there.
REM ======================================================================

set "HOTWIRE_ARGS=!ARGS!"

set "PSCHK="
set "PSCHK=!PSCHK!$Q=[char]34; $PC=[char]37; $EX=[char]33; "
set "PSCHK=!PSCHK!$p=@(); $s=[string]$env:HOTWIRE_ARGS; "
set "PSCHK=!PSCHK!$t=@(); $c=[Text.StringBuilder]::new(); $q=$false; $st=$false; "
set "PSCHK=!PSCHK!foreach($ch in $s.ToCharArray()){ if($ch -eq $Q){ $q=-not $q; $st=$true } elseif((($ch -eq [char]32) -or ($ch -eq [char]9) -or ($ch -eq [char]13) -or ($ch -eq [char]10)) -and (-not $q)){ if($st -or ($c.Length -gt 0)){ $t+=$c.ToString(); $c.Clear() | Out-Null; $st=$false } } else { $c.Append($ch) | Out-Null; $st=$true } } "
set "PSCHK=!PSCHK!if($st -or ($c.Length -gt 0)){ $t+=$c.ToString() } "
set "PSCHK=!PSCHK!if($q){ $p+=[string]('unbalanced quote in the option list') } "
set "PSCHK=!PSCHK!$seen=@{}; $val=@{}; $i=0; "
set "PSCHK=!PSCHK!while($i -lt $t.Count){ $x=[string]$t[$i]; "
set "PSCHK=!PSCHK! if($x.StartsWith([string][char]43)){ $n=$x.Substring(1); "
set "PSCHK=!PSCHK!  if($n.Length -eq 0){ $p+=[string]('a bare plus with no convar after it'); $i++; continue } "
set "PSCHK=!PSCHK!  if(-not $n.Contains([string][char]46)){ $p+=[string]::Concat($n,[string](' is not a convar name; it needs a dot, and Rust ignores unknown convars in silence')) } "
set "PSCHK=!PSCHK!  if(($i+1) -ge $t.Count){ $p+=[string]::Concat($n,[string](' has no value; it is the last thing on the line')); $i++; continue } "
set "PSCHK=!PSCHK!  $v=[string]$t[$i+1]; "
set "PSCHK=!PSCHK!  if($v.StartsWith([string][char]43) -or ($v.StartsWith([string][char]45) -and ($v -notmatch [string]('^-?\d+(\.\d+)?$')))){ $p+=[string]::Concat($n,[string](' has no value; the next thing is '),$v); $i++; continue } "
set "PSCHK=!PSCHK!  if($v.Length -eq 0){ $p+=[string]::Concat($n,[string](' is set to an empty value')) } "
set "PSCHK=!PSCHK!  if(($n -ne [string]('rcon.password')) -and (($v -match [string]::Concat($PC,'[A-Za-z_][A-Za-z0-9_]*',$PC)) -or ($v -match [string]::Concat($EX,'[A-Za-z_][A-Za-z0-9_]*',$EX)))){ $p+=[string]::Concat($n,[string](' still contains an unexpanded variable: '),$v) } "
set "PSCHK=!PSCHK!  if($seen.ContainsKey($n)){ $p+=[string]::Concat($n,[string](' is set twice; whichever line is last wins, silently')) } "
set "PSCHK=!PSCHK!  $seen[$n]=1; $val[$n]=$v; $i+=2; continue } "
set "PSCHK=!PSCHK! $i++ } "
set "PSCHK=!PSCHK!$ports=@([string]('server.port'),[string]('server.queryport'),[string]('rcon.port'),[string]('app.port')); "
set "PSCHK=!PSCHK!$pn=@{}; "
set "PSCHK=!PSCHK!foreach($k in $ports){ if($val.ContainsKey($k)){ $v=[string]$val[$k]; "
set "PSCHK=!PSCHK!  if($v -notmatch [string]('^\d+$')){ $p+=[string]::Concat($k,[string](' is '),$v,[string](', which is not a number')) } "
set "PSCHK=!PSCHK!  elseif(([int]$v -lt 1) -or ([int]$v -gt 65535)){ $p+=[string]::Concat($k,[string](' is '),$v,[string]('; a port must be 1-65535')) } "
set "PSCHK=!PSCHK!  else { $pn[$k]=[int]$v } } } "
set "PSCHK=!PSCHK!foreach($a in $pn.Keys){ foreach($b in $pn.Keys){ if(([string]::CompareOrdinal($a,$b) -lt 0) -and ($pn[$a] -eq $pn[$b])){ $p+=[string]::Concat($a,[string](' and '),$b,[string](' are both '),[string]$pn[$a],[string]('; they must differ')) } } } "
set "PSCHK=!PSCHK!if($val.ContainsKey([string]('server.identity'))){ $v=[string]$val[[string]('server.identity')]; "
set "PSCHK=!PSCHK! $bad=[char[]]@([char]92,[char]47,[char]58,[char]42,[char]63,[char]34,[char]60,[char]62,[char]124); "
set "PSCHK=!PSCHK! if($v.Length -eq 0){ $p+=[string]('server.identity is empty; it names the save folder') } "
set "PSCHK=!PSCHK! elseif($v.IndexOfAny($bad) -ge 0){ $p+=[string]::Concat([string]('server.identity is '),$v,[string]('; it names a folder, so no path characters')) } } "
set "PSCHK=!PSCHK!foreach($m in $p){ Write-Output ([string]::Concat([string]('  '),$m)) } "
set "PSCHK=!PSCHK!if($p.Count -gt 0){ exit 2 } else { exit 0 } "

powershell -NoProfile -NonInteractive -Command "!PSCHK!"
set "ARGCHECK=!errorlevel!"
set "HOTWIRE_ARGS="

REM  Exactly 2 means the check ran and found problems. 0 means it ran
REM  and found none. ANYTHING ELSE means the check itself did not run --
REM  9009 for no PowerShell, 1 for an error inside the script.
REM
REM  Those are separated on purpose. If this script is ever wrong, it
REM  exits 1, and treating that as "problems found" would refuse to start
REM  a server whose settings are perfectly fine. A diagnostic that breaks
REM  must cost the diagnostic and nothing else.
if "!ARGCHECK!"=="2" (
    echo [%date% %time%] ================================================
    echo [%date% %time%] The option list has problems, listed above.
    echo [%date% %time%] Not starting. They are set in section 4.
    echo [%date% %time%] ================================================
    pause & exit /b 1
)

if not "!ARGCHECK!"=="0" (
    echo [%date% %time%] Option check did not run ^(exit !ARGCHECK!^).
    echo [%date% %time%] Continuing without it.
)

if defined CHECK_ONLY (
    echo [%date% %time%] Settings and option list checked. No problems.
    echo [%date% %time%] check mode -- not starting the server.
    exit /b 0
)


REM ======================================================================
REM  5. LAUNCH
REM ======================================================================

REM  Rotate the log. -logfile TRUNCATES on every start, so without this a
REM  restart destroys the log of whatever went wrong before it.
REM
REM  That was true of a crash loop too, which is the case it most needed
REM  to be false for. Rotation culled to LOG_KEEP every pass, and a server
REM  dying on boot loops every 15 seconds, so about three and a half
REM  minutes later the log holding the actual failure had been culled away
REM  and fourteen identical near-empty ones were left in its place.
REM
REM  So the first log of a crash streak goes to server_crash_*, which the
REM  cull never matches. Later crashes in the same streak rotate normally:
REM  they say the same thing as the first, and keeping every one of them
REM  is how a crash loop fills a disk.
if exist "%LOGFILE%" (
    set "LOGSTAMP="
    for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "LOGSTAMP=%%i"
    if not defined LOGSTAMP set "LOGSTAMP=unstamped-!RANDOM!"
    set "ROTATED=%ROOT%\logs\server_log_!LOGSTAMP!.txt"
    if "!CRASH_STREAK!"=="1" set "ROTATED=%ROOT%\logs\server_crash_!LOGSTAMP!.txt"
    move /y "%LOGFILE%" "!ROTATED!" >nul
    powershell -NoProfile -Command "Get-ChildItem '%ROOT%\logs\server_log_*.txt' | Sort-Object LastWriteTime -Descending | Select-Object -Skip %LOG_KEEP% | Remove-Item -Force" 2>nul
)

echo [%date% %time%] Starting server...

REM  Timed so a crash loop can be told from a working restart. If either
REM  call fails the run is treated as a long one: erring that way keeps
REM  the server running, and the other way would stop it over a failed
REM  timestamp.
set "RUN_START=0"
for /f %%t in ('powershell -NoProfile -Command "[int]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalSeconds"') do set "RUN_START=%%t"

"%ROOT%\RustDedicated.exe" !ARGS! -logfile "!LOGFILE!"

set "RUN_END=0"
for /f %%t in ('powershell -NoProfile -Command "[int]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalSeconds"') do set "RUN_END=%%t"
set "RUN_SECONDS=99999"
if not "!RUN_START!"=="0" if not "!RUN_END!"=="0" set /a RUN_SECONDS=RUN_END-RUN_START

if !RUN_SECONDS! LSS %CRASH_SECONDS% (
    set /a CRASH_STREAK+=1
) else (
    set /a CRASH_STREAK=0
)

if not "%MAX_CRASH_STREAK%"=="0" if !CRASH_STREAK! GEQ %MAX_CRASH_STREAK% goto crashstop

REM  Back off, so a permanently broken config does not relaunch four
REM  times a minute forever -- and does not run HOOK_BEFORE that often
REM  either, which for anyone hooking a backup in is the expensive part.
set "DELAY=%RESTART_DELAY%"
if !CRASH_STREAK! GEQ 2 set "DELAY=30"
if !CRASH_STREAK! GEQ 3 set "DELAY=60"
if !CRASH_STREAK! GEQ 4 set "DELAY=120"
if !CRASH_STREAK! GEQ 5 set "DELAY=300"

if !CRASH_STREAK! GTR 0 (
    echo [%date% %time%] Server exited after !RUN_SECONDS!s -- that is a crash, not a restart.
    echo [%date% %time%] Crash !CRASH_STREAK! of %MAX_CRASH_STREAK%. Retrying in !DELAY!s.
) else (
    echo [%date% %time%] Server exited. Restarting in !DELAY!s. Ctrl+C to stop.
)
REM  Same fallback as the steamcmd retry: no stdin, no timeout, and
REM  without this the relaunch loop would spin with no delay at all.
timeout /t !DELAY! /nobreak
if errorlevel 1 (
    set /a PINGWAIT=!DELAY!+1
    ping -n !PINGWAIT! 127.0.0.1 >nul 2>&1
)
goto start

:crashstop
echo [%date% %time%] ====================================================
echo [%date% %time%] STOPPED. %MAX_CRASH_STREAK% consecutive crashes, each
echo [%date% %time%] under %CRASH_SECONDS%s. The server is not starting, and
echo [%date% %time%] relaunching it again will not change that.
echo [%date% %time%]
echo [%date% %time%] The log from the first crash is kept as
echo [%date% %time%]   %ROOT%\logs\server_crash_*.txt
echo [%date% %time%] and is the one worth reading. Usual causes: a bad
echo [%date% %time%] convar in section 4, a port already in use, or a
echo [%date% %time%] corrupt save. Another copy of this launcher
echo [%date% %time%] already running would do it too -- the second one
echo [%date% %time%] cannot bind the port.
echo [%date% %time%]
echo [%date% %time%] Set MAX_CRASH_STREAK=0 to loop forever instead.
echo [%date% %time%] ====================================================
pause
exit /b 1
