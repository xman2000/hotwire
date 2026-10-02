@echo off
setlocal EnableDelayedExpansion

REM ==[ H O T W I R E ]===================================================
REM  Hotwire launcher for Windows, version 1.1.19 (2026-10-02)
REM  Built by xman2000 and Claude.  MIT License.
REM  https://github.com/xman2000/hotwire
REM
REM  Your settings are in hotwire.cfg, beside this file, and the RCON
REM  password is in hotwire-secrets.cfg. This file holds no settings:
REM  replace it with a newer release and nothing of yours changes.
REM
REM  Usage:
REM    hotwire.bat          start (or resume) the supervised server
REM    hotwire.bat check    check everything and report, but do not start
REM ======================================================================

REM  "hotwire.bat check" reads hotwire.cfg, says what is wrong, and exits
REM  without updating or starting the server. It does ask Steam for the
REM  current build. Run it after editing a setting.
set "CHECK_ONLY="
if /i "%~1"=="check" set "CHECK_ONLY=1"

REM  Who this launcher is, for the plugin and the panel: written to
REM  oxide\data\Hotwire\launcher.json before every start, with this file's
REM  code hash (the HOTWIRE_LAUNCHER_HASH line near the end). The plugin
REM  works the hash out again from this file's bytes, so the panel offers a
REM  wipe or a permanent setting only through a launcher that is unmodified
REM  and says it can carry them out. settings_file says the settings are
REM  read from hotwire.cfg. Not settings; do not edit.
set "HOTWIRE_LAUNCHER_VERSION=1.1.19"
set "HOTWIRE_LAUNCHER_CAPABILITIES=supervise,update,framework_verify,crash_backstop,log_rotate,convar_persist,wipe,settings_file"

REM ======================================================================
REM  HOW THIS LAUNCHER WORKS
REM ======================================================================
REM
REM  REQUIREMENTS
REM     Windows, steamcmd, and a Rust dedicated server. PowerShell and
REM     curl are used for reading the settings, date maths and downloads;
REM     both ship with Windows 10 and later.
REM
REM     Nothing else. The plugin described below is optional and this file
REM     works perfectly well without it.
REM
REM  SETUP
REM     1.  Copy hotwire.example.cfg to hotwire.cfg and fill in sections 1
REM         and 2.
REM     2.  Copy hotwire-secrets.example.cfg to hotwire-secrets.cfg and set
REM         the RCON password.
REM     3.  Keep hotwire.bat beside RustDedicated.exe: its own folder is the
REM         server's.
REM     4.  Run "hotwire.bat check", then run this file. Leave the window
REM         open.
REM
REM  YOUR SETTINGS ARE DATA
REM     hotwire.cfg and hotwire-secrets.cfg are read, one "name value" line
REM     at a time, and never run: a line that is not a setting is ignored
REM     and named by "hotwire.bat check". Values reach Rust as separate
REM     arguments and cmd never sees them, so no character in a server name
REM     can break anything. hotwire.cfg is read again before every start,
REM     so an edit takes effect at the next restart. The start-script
REM     converter on afkpanel.com makes a hotwire.cfg from an old start
REM     script; it can never make code.
REM
REM  YOUR OWN COMMANDS
REM     go in hotwire-before.bat (run before every start) and
REM     hotwire-after.bat (run after an update), beside this file. Copy the
REM     .example files to begin. A hook that fails is logged and the server
REM     starts anyway; check mode runs no hook.
REM
REM  RUN LOOP
REM     The script does not exit after starting the server. It waits for
REM     the server process to end, then starts it again after
REM     hotwire.restart_delay seconds. Close the window to stop the server
REM     permanently.
REM
REM  UPDATE MODES
REM     Set hotwire.update_mode in hotwire.cfg.
REM
REM     auto       The default. hotwire while the plugin has an update
REM                scheduled (it keeps UPDATE.schedule fresh in the
REM                server's folder), otherwise always. Turning on an
REM                update schedule in the plugin is all it takes.
REM
REM     always     steamcmd and the mod framework run on every start, as
REM                in most Rust launchers.
REM
REM     hotwire    steamcmd and the mod framework run when UPDATE.flag or
REM                VALIDATE.flag is in the server's folder, when Steam has
REM                a newer build (hotwire.update_on_new_build), when the
REM                launcher cannot find out whether it has one, or when
REM                the backstop below fires. A flag is deleted only once
REM                its update completes: one flag, one update. Other
REM                restarts just relaunch.
REM
REM     off        Never. A flag file is left in place and reported.
REM
REM     Create a flag by hand, in the server's folder:
REM       New-Item -ItemType File UPDATE.flag
REM
REM     In hotwire mode, if hotwire.max_days_without_update days pass
REM     without an update, one runs regardless. Rust clients update
REM     themselves; a server that does not eventually refuses every
REM     connection.
REM
REM  SEVERAL SERVERS ON ONE MACHINE
REM     Give each its own folder, its own copy of this file and hotwire.cfg,
REM     and its own ports. They may share one SteamCMD: only one of them
REM     runs it at a time, and the others wait. Copying a whole server
REM     folder is safe -- the launcher's folder is the server's -- but give
REM     the copy different ports before starting it.
REM
REM  PLUGIN
REM     Optional. See src\Hotwire.cs at the address above. It schedules
REM     restarts, announces them to players, counts down, and writes the
REM     flag when a scheduled restart is an update. Files in the server's
REM     folder are the only interface between plugin and launcher: the
REM     update flags, WIPE.flag and CONVAR.request from the plugin, and
REM     oxide\data\Hotwire\launcher.json from here. Neither half requires
REM     the other.
REM
REM  DEFAULTS
REM     The defaults in hotwire.example.cfg were read out of a Rust build,
REM     not copied from documentation. Out of the box this launcher sets
REM     only what a server cannot run without, or what has to agree with
REM     something outside the game -- the ports, which match the firewall.
REM     Everything else is the game's own default until you choose
REM     otherwise.
REM ======================================================================

REM ------------------------------------------------ fixed, not settings ----
REM  Where code comes from is never a setting: hotwire.cfg is data that
REM  other tools may write, and data must never be able to say what gets
REM  downloaded or run. The server's folder is this file's own folder, so a
REM  copied server folder brings its launcher with it.
set "ROOT=%~dp0"
if "!ROOT:~-1!"=="\" set "ROOT=!ROOT:~0,-1!"
set "APPID=258550"
set "UPDATE_FLAG=UPDATE.flag"
set "VALIDATE_FLAG=VALIDATE.flag"
set "WIPE_FLAG=WIPE.flag"
set "FRAMEWORK_VERSION_FILE=%ROOT%\RustDedicated_Data\Managed\Oxide.Rust.dll"
set "FRAMEWORK_FEED=https://assets.umod.org/games/rust.json"
set "FRAMEWORK_URL=https://umod.org/games/rust/download"
set "FRAMEWORK_RELEASES=https://api.github.com/repos/OxideMod/Oxide.Rust/releases/latest"
set "FRAMEWORK_ASSET=Oxide.Rust.zip"
set "LOGFILE=%ROOT%\logs\server_log.txt"
set "UPDATE_STAMP=%ROOT%\logs\last_update.txt"
set "HOOK_BEFORE=%ROOT%\hotwire-before.bat"
set "HOOK_AFTER=%ROOT%\hotwire-after.bat"
set "HOTWIRE_SELF=%~f0"

REM  The PowerShell at the end of this file reads the settings, writes a
REM  wipe or a permanent convar into hotwire.cfg, and starts the server.
REM  This line hands it everything from its #HOTWIRE-PS line down, with
REM  HOTWIRE_MODE saying which part to run. It holds no double quote,
REM  percent sign or exclamation mark, so cmd passes it through unchanged.
set "HW_PS=$t=[IO.File]::ReadAllText($env:HOTWIRE_SELF,[Text.Encoding]::GetEncoding(28591)); $i=$t.LastIndexOf('#'+'HOTWIRE-PS'); if($i -ge 0){ Invoke-Expression $t.Substring($i) } else { exit 9 }"

REM  Consecutive crashes. Set here rather than at :start so it survives
REM  the loop, which is the whole point of counting it.
set /a CRASH_STREAK=0

REM  The other opaque failure: a server that is not here. Every setting
REM  would be fine and the server simply would not start.
if not exist "%ROOT%\RustDedicated.exe" (
    echo [%date% %time%] ================================================
    echo [%date% %time%] No RustDedicated.exe in:
    echo [%date% %time%]   %ROOT%
    echo [%date% %time%] Keep hotwire.bat beside RustDedicated.exe, or the
    echo [%date% %time%] install is incomplete.
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
    echo [%date% %time%] Check permissions on the server's folder.
    echo [%date% %time%] ================================================
    pause & exit /b 1
)

REM  The first read of hotwire.cfg decides whether this launcher starts at
REM  all: a missing file, or a bad save folder, map or port, stops here
REM  with the reason. Later reads keep the last good settings instead.
set "HOTWIRE_FIRST=1"


:start

REM ======================================================================
REM  5. READING hotwire.cfg AND hotwire-secrets.cfg
REM
REM     Machinery. PowerShell reads both files as data and checks every
REM     line. cmd is handed only the launcher's own settings, each checked
REM     to be a number, a word or a path with nothing cmd reads as syntax.
REM     The server's settings and the RCON password never pass through
REM     cmd: PowerShell keeps them for the start, in section 8.
REM ======================================================================
call :hotwire_load
if defined HOTWIRE_FIRST if not "!HW_LOAD!"=="ok" (
    if not defined HW_LOAD echo [%date% %time%] The settings could not be read: PowerShell did not answer.
    echo [%date% %time%] Not starting.
    pause & exit /b 1
)
set "HOTWIRE_FIRST="

REM  The branch named in messages. Empty means Steam chooses, which for a
REM  fresh install is public.
set "BRANCH_NAME=%STEAM_BRANCH%"
if not defined BRANCH_NAME set "BRANCH_NAME=public"


REM  Who decides updates on this pass. auto follows the Hotwire plugin: while
REM  it has an update scheduled it keeps UPDATE.schedule in the server's
REM  folder, rewritten every 15 minutes. A marker that is missing, over two
REM  hours old, or cannot be read means nobody is scheduling updates, so this
REM  pass updates as always does: the direction that keeps a server joinable.
set "UPDATE_EFFECTIVE=%UPDATE_MODE%"
if /i not "%UPDATE_MODE%"=="auto" goto :updatemodeknown
set "UPDATE_EFFECTIVE=always"
set "HOTWIRE_MARKER=%ROOT%\UPDATE.schedule"
for /f %%m in ('powershell -NoProfile -NonInteractive -Command "$f=$env:HOTWIRE_MARKER; if((Test-Path -LiteralPath $f) -and (((Get-Date)-(Get-Item -LiteralPath $f).LastWriteTime).TotalHours -lt 2)){'fresh'}else{'none'}"') do if "%%m"=="fresh" set "UPDATE_EFFECTIVE=hotwire"
set "HOTWIRE_MARKER="
if /i "!UPDATE_EFFECTIVE!"=="hotwire" echo [%date% %time%] hotwire.update_mode is auto: the Hotwire plugin schedules updates.
if /i "!UPDATE_EFFECTIVE!"=="always" echo [%date% %time%] hotwire.update_mode is auto: no update schedule from the Hotwire plugin.
:updatemodeknown

REM ======================================================================
REM  6a. WHAT BUILD IS OUT THERE
REM
REM     Machinery. Nothing here is a setting -- those are in hotwire.cfg.
REM
REM     Steam knows the current Rust build, and steamapps\appmanifest tells
REM     us which one is installed. Comparing the two answers the question
REM     that actually matters on patch day -- am I behind, and is it worth
REM     the downtime -- without installing anything.
REM
REM     One steamcmd launch, so the answer is cached for
REM     hotwire.build_check_hours.
REM     A daily restart pays for it once a day; a crash loop, which relaunches
REM     every few seconds, never pays at all.
REM
REM     Note the walk in the script: buildid appears under every depot as
REM     well, so it looks for branches, then the branch inside it, then buildid
REM     inside that. Taking the first buildid in the file reads a depot's
REM     and silently compares the wrong numbers.
REM
REM     If another server is using SteamCMD right now, this does not wait
REM     for it: the question is skipped for this start, and the update, if
REM     one is due, waits its turn below.
REM
REM     If anything here fails -- no steamcmd, Steam unreachable, a hang --
REM     both numbers come back as ? and the launcher carries on under the
REM     ordinary rules. This decides nothing on its own.
REM ======================================================================

set "INSTALLED_BUILD="
set "PUBLIC_BUILD="
if "%BUILD_CHECK_HOURS%"=="0" goto :buildcheckdone

set "HOTWIRE_ACF=%ROOT%\steamapps\appmanifest_%APPID%.acf"
set "HOTWIRE_BUILDCACHE=%ROOT%\logs\build_check.txt"
set "HOTWIRE_APPINFO=%ROOT%\logs\.appinfo.tmp"
set "HOTWIRE_STEAMCMD=%STEAMCMD%"
set "HOTWIRE_APPID=%APPID%"
set "HOTWIRE_BUILDHOURS=%BUILD_CHECK_HOURS%"
REM  When flags decide updates, the answer must be today's: a cached
REM  "current" from before a Rust release would start the old build. So the
REM  cache is used only during a crash streak, which is what it is for.
if /i not "!UPDATE_EFFECTIVE!"=="always" if /i not "!UPDATE_EFFECTIVE!"=="off" if !CRASH_STREAK! EQU 0 set "HOTWIRE_BUILDHOURS=0"
set "HOTWIRE_BRANCH=%BRANCH_NAME%"

set "PSBUILD="
set "PSBUILD=!PSBUILD!$ErrorActionPreference='SilentlyContinue'; $q=[char]34; "
set "PSBUILD=!PSBUILD!$acf=$env:HOTWIRE_ACF; $cache=$env:HOTWIRE_BUILDCACHE; $out=$env:HOTWIRE_APPINFO; "
set "PSBUILD=!PSBUILD!$sc=$env:HOTWIRE_STEAMCMD; $app=$env:HOTWIRE_APPID; $hours=0; "
set "PSBUILD=!PSBUILD![void][int]::TryParse([string]$env:HOTWIRE_BUILDHOURS, [ref]$hours); "
set "PSBUILD=!PSBUILD!$inst='?'; "
set "PSBUILD=!PSBUILD!if(Test-Path -LiteralPath $acf){ $t=[IO.File]::ReadAllText($acf); "
set "PSBUILD=!PSBUILD!  $m=[regex]::Match($t, $q+'buildid'+$q+'\s+'+$q+'(\d+)'+$q); if($m.Success){ $inst=$m.Groups[1].Value } } "
set "PSBUILD=!PSBUILD!$pub='?'; "
set "PSBUILD=!PSBUILD!$fresh=$false; "
set "PSBUILD=!PSBUILD!if(Test-Path -LiteralPath $cache){ $age=((Get-Date)-(Get-Item -LiteralPath $cache).LastWriteTime).TotalHours; "
set "PSBUILD=!PSBUILD!  if($age -lt $hours){ $fresh=$true; $pub=([IO.File]::ReadAllText($cache)).Trim() } } "
set "PSBUILD=!PSBUILD!if(-not $fresh){ "
set "PSBUILD=!PSBUILD!  $lk=$null; if(Test-Path -LiteralPath $sc){ try{ $lk=[IO.File]::Open((Join-Path (Split-Path -Parent $sc) 'hotwire-steamcmd.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch {} } "
set "PSBUILD=!PSBUILD!  if($lk){ "
set "PSBUILD=!PSBUILD!    $p=Start-Process -FilePath $sc -ArgumentList @('+login','anonymous','+app_info_update','1','+app_info_print',$app,'+quit') -RedirectStandardOutput $out -NoNewWindow -PassThru; "
set "PSBUILD=!PSBUILD!    if($p.WaitForExit(180000)){ "
set "PSBUILD=!PSBUILD!      if(Test-Path -LiteralPath $out){ $t=[IO.File]::ReadAllText($out); "
set "PSBUILD=!PSBUILD!        $i=$t.IndexOf($q+'branches'+$q); "
set "PSBUILD=!PSBUILD!        if($i -ge 0){ $j=$t.IndexOf($q+[string]$env:HOTWIRE_BRANCH+$q,$i); "
set "PSBUILD=!PSBUILD!          if($j -ge 0){ $m=[regex]::Match($t.Substring($j), $q+'buildid'+$q+'\s+'+$q+'(\d+)'+$q); "
set "PSBUILD=!PSBUILD!            if($m.Success){ $pub=$m.Groups[1].Value; [IO.File]::WriteAllText($cache,$pub) } } } } "
set "PSBUILD=!PSBUILD!    } else { try{ $p.Kill() } catch {} } "
set "PSBUILD=!PSBUILD!    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue "
set "PSBUILD=!PSBUILD!    $lk.Dispose() "
set "PSBUILD=!PSBUILD!  } "
set "PSBUILD=!PSBUILD!} "
set "PSBUILD=!PSBUILD!Write-Output ($inst+' '+$pub) "

for /f "usebackq tokens=1,2" %%A in (`powershell -NoProfile -NonInteractive -Command "!PSBUILD!"`) do (
    set "INSTALLED_BUILD=%%A"
    set "PUBLIC_BUILD=%%B"
)

set "HOTWIRE_ACF="
set "HOTWIRE_BUILDCACHE="
set "HOTWIRE_APPINFO="
set "HOTWIRE_STEAMCMD="
set "HOTWIRE_APPID="
set "HOTWIRE_BUILDHOURS="
set "HOTWIRE_BRANCH="

if "!INSTALLED_BUILD!"=="?" set "INSTALLED_BUILD="
if "!PUBLIC_BUILD!"=="?" set "PUBLIC_BUILD="

if not defined INSTALLED_BUILD (
    echo [%date% %time%] Rust build: cannot read the installed build from
    echo [%date% %time%]   %ROOT%\steamapps\appmanifest_%APPID%.acf
) else if not defined PUBLIC_BUILD (
    echo [%date% %time%] Rust build: installed !INSTALLED_BUILD!, and Steam did
    echo [%date% %time%] not answer. Carrying on under the usual rules.
) else if "!INSTALLED_BUILD!"=="!PUBLIC_BUILD!" (
    echo [%date% %time%] Rust build: installed !INSTALLED_BUILD!, !BRANCH_NAME! !PUBLIC_BUILD! -- current.
) else if !INSTALLED_BUILD! GTR !PUBLIC_BUILD! (
    echo [%date% %time%] Rust build: installed !INSTALLED_BUILD!, !BRANCH_NAME! !PUBLIC_BUILD! -- this
    echo [%date% %time%] server is on a newer build than Steam's !BRANCH_NAME! branch, so it
    echo [%date% %time%] is on another branch, such as staging. The next update
    echo [%date% %time%] moves it to !BRANCH_NAME!, as hotwire.steam_branch says.
) else (
    echo [%date% %time%] ================================================
    echo [%date% %time%] Rust build: installed !INSTALLED_BUILD!
    echo [%date% %time%]             !BRANCH_NAME!    !PUBLIC_BUILD!
    echo [%date% %time%] A NEWER BUILD IS AVAILABLE.
    echo [%date% %time%] Clients update themselves, so once the protocol
    echo [%date% %time%] moves this server stops accepting connections.
    REM  What happens next depends on the update mode, so say that, not what
    REM  an admin in another mode would do (the owner's test, 2026-09-28).
    set "HW_NEWER=updates"
    if /i "!UPDATE_EFFECTIVE!"=="off" set "HW_NEWER=off"
    if /i "!UPDATE_EFFECTIVE!"=="hotwire" if not "%UPDATE_ON_NEW_BUILD%"=="1" set "HW_NEWER=flag"
    if "!HW_NEWER!"=="updates" echo [%date% %time%] A normal start updates it before launching.
    if "!HW_NEWER!"=="off" echo [%date% %time%] hotwire.update_mode is off, so this launcher does not update it.
    if "!HW_NEWER!"=="flag" echo [%date% %time%] Create %UPDATE_FLAG% in %ROOT% to update on the next start.
    set "HW_NEWER="
    echo [%date% %time%] ================================================
)

:buildcheckdone


REM ======================================================================
REM  6. UPDATE OR RESTART
REM
REM     The two flag files, and what each one costs:
REM
REM     UPDATE.flag     app_update, then the mod framework, then launch.
REM     VALIDATE.flag   The same, plus validate, which re-checksums the
REM                     whole install. Slow. Weekly at most, or after a
REM                     crash.
REM
REM     Anything can create one: you, a scheduled task, or the plugin when
REM     a scheduled update comes due. hotwire.update_mode off leaves them
REM     unread.
REM
REM       New-Item -ItemType File UPDATE.flag     (in the server's folder)
REM ======================================================================

set "DO_UPDATE=0"
set "DO_VALIDATE=0"

if /i "!UPDATE_EFFECTIVE!"=="off" (
    echo [%date% %time%] hotwire.update_mode is off -- not updating.
    if exist "%ROOT%\%UPDATE_FLAG%" echo [%date% %time%] %UPDATE_FLAG% is being left in place, not acted on.
    if exist "%ROOT%\%VALIDATE_FLAG%" echo [%date% %time%] %VALIDATE_FLAG% is being left in place, not acted on.
    goto :updatedecided
)

if /i "!UPDATE_EFFECTIVE!"=="always" (
    set "DO_UPDATE=1"
    echo [%date% %time%] hotwire.update_mode is %UPDATE_MODE% -- updating before launch.
)

if exist "%ROOT%\%UPDATE_FLAG%" (
    set "DO_UPDATE=1"
    echo [%date% %time%] %UPDATE_FLAG% found -- this pass will update.
)
if exist "%ROOT%\%VALIDATE_FLAG%" (
    set "DO_UPDATE=1"
    set "DO_VALIDATE=1"
    echo [%date% %time%] %VALIDATE_FLAG% found -- update and validate.
)

REM  The backstop. Only in hotwire mode, only when nothing has already
REM  asked for an update, and skipped entirely when set to 0. A missing
REM  stamp counts as forever, so a fresh install updates once on its first
REM  start rather than waiting a fortnight to find out it is out of date.
if /i "!UPDATE_EFFECTIVE!"=="always" goto :updatedecided
if "%DO_UPDATE%"=="1" goto :updatedecided
REM  A build that has actually changed beats a calendar. This runs before
REM  the day count, so a server that is behind updates today rather than
REM  on day fourteen -- and one that is current is left alone no matter
REM  how long it has been.
if not "%UPDATE_ON_NEW_BUILD%"=="1" goto :nobuildtrigger
if not defined INSTALLED_BUILD goto :buildunknown
if not defined PUBLIC_BUILD goto :buildunknown
if "!INSTALLED_BUILD!"=="!PUBLIC_BUILD!" goto :nobuildtrigger
REM  Behind means public is higher. A server on a newer build than public,
REM  as a test branch is, is not behind, and updating it every start would
REM  achieve nothing but a steamcmd run.
if !INSTALLED_BUILD! GTR !PUBLIC_BUILD! goto :nobuildtrigger
set "DO_UPDATE=1"
echo [%date% %time%] Updating: installed build !INSTALLED_BUILD! is behind
echo [%date% %time%] Steam's !PUBLIC_BUILD!.
goto :updatedecided
:buildunknown
REM  Not knowing is not the same as current. A server left on an old build
REM  turns every player away after a Rust release, so an unanswered question
REM  costs an update, never the server.
set "DO_UPDATE=1"
echo [%date% %time%] Updating: the launcher could not tell whether this
echo [%date% %time%] install is on Steam's current build.
goto :updatedecided
:nobuildtrigger

if "%MAX_DAYS_WITHOUT_UPDATE%"=="0" goto :updatedecided

set "DAYS_SINCE_UPDATE=9999"
REM  Floor, not [int]: [int] rounds, so 13.6 days would trip a 14-day
REM  backstop half a day early.
REM  HW-10: pass the path through an environment variable, never inside a
REM  PowerShell single-quoted literal, so an apostrophe in the path (a folder
REM  like C:\Rob's server) cannot close the literal and break or inject.
set "HOTWIRE_STAMP=%UPDATE_STAMP%"
if exist "%UPDATE_STAMP%" for /f %%d in ('powershell -NoProfile -Command "[math]::Floor(((Get-Date) - (Get-Item -LiteralPath $env:HOTWIRE_STAMP).LastWriteTime).TotalDays)"') do set "DAYS_SINCE_UPDATE=%%d"
set "HOTWIRE_STAMP="

if !DAYS_SINCE_UPDATE! GEQ %MAX_DAYS_WITHOUT_UPDATE% (
    set "DO_UPDATE=1"
    echo [%date% %time%] ================================================
    echo [%date% %time%] No update in !DAYS_SINCE_UPDATE! days. Updating anyway.
    echo [%date% %time%] A server that never updates stops being joinable
    echo [%date% %time%] once the clients move on. Set hotwire.update_mode
    echo [%date% %time%] always in hotwire.cfg, or schedule updates, to stop
    echo [%date% %time%] seeing this.
    echo [%date% %time%] ================================================
)

:updatedecided

REM  check mode inspects; it never installs. It says what a normal start would
REM  do instead of "Plain restart", which read as the opposite of the line above.
if defined CHECK_ONLY if "%DO_UPDATE%"=="1" echo [%date% %time%] check mode -- a normal start would update here. Nothing is installed.
if defined CHECK_ONLY if "%DO_UPDATE%"=="0" echo [%date% %time%] check mode -- a normal start would launch without updating.
if defined CHECK_ONLY set "DO_UPDATE=0"

REM  hotwire-before.bat runs on every real start, before any update, in a
REM  cmd of its own: whatever it does to its variables, or an exit in it,
REM  stays there. A failure is said and the start carries on. check mode
REM  runs nothing on your behalf, hooks included.
if defined CHECK_ONLY goto :hookbeforedone
if not exist "%HOOK_BEFORE%" goto :hookbeforedone
echo [%date% %time%] Running the before-start hook (hotwire-before.bat)...
cmd /d /c call "%HOOK_BEFORE%"
if errorlevel 1 echo [%date% %time%] hotwire-before.bat exited non-zero; carrying on.
:hookbeforedone

if "%DO_UPDATE%"=="0" (
    if not defined CHECK_ONLY echo [%date% %time%] Plain restart -- skipping steamcmd and framework.
    goto buildargs
)

REM  Fast Rust updates. Steam updates a game by patching the files on disk,
REM  and Oxide has replaced some of them, so on a modded server Steam's first
REM  try at a new build stops with "Corrupt game files" (state 0x486). Steam
REM  then marks the install Files Corrupt in steamapps\appmanifest (StateFlags,
REM  bit 128), and its next run checks every file first and succeeds. Marking
REM  it before the first run saves the failed try. The record is Steam's own
REM  and undocumented: one exact line is changed, the change is checked
REM  before it is written, a copy is kept in hotwire\, and if Steam ever
REM  ignores the mark the update takes its usual second try (see steamfailed).
set "PSMARK="
set "PSMARK=!PSMARK!$f=$env:HOTWIRE_ACFPATH; $q=[char]34; $nl=[char]10; if(-not (Test-Path -LiteralPath $f)){ exit 0 }; "
set "PSMARK=!PSMARK!$re='\A\s*'+$q+'StateFlags'+$q+'\s+'+$q+'4'+$q+'\s*\z'; $lines=[IO.File]::ReadAllText($f).Split($nl); $hit=@(); "
set "PSMARK=!PSMARK!for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].TrimEnd([char]13) -match $re){ $hit+=$i } }; "
set "PSMARK=!PSMARK!if($hit.Count -ne 1){ Write-Output 'Fast Rust updates: Steam''s install record is not in the expected form; leaving it to Steam.'; exit 0 }; "
set "PSMARK=!PSMARK!$new=[string[]]$lines.Clone(); $new[$hit[0]]=$lines[$hit[0]].Replace($q+'4'+$q, $q+'132'+$q); $tmp=$f+'.hotwire-tmp'; "
set "PSMARK=!PSMARK!try{ [IO.File]::WriteAllText($tmp, [string]::Join($nl, $new)); "
set "PSMARK=!PSMARK!  $back=[IO.File]::ReadAllText($tmp).Split($nl); $diff=0; for($i=0; $i -lt $lines.Length; $i++){ if($back[$i] -ne $lines[$i]){ $diff++ } }; "
set "PSMARK=!PSMARK!  if($back.Length -ne $lines.Length -or $diff -ne 1){ throw 'unexpected' }; "
set "PSMARK=!PSMARK!  $dir=Join-Path $env:HOTWIRE_ROOT 'hotwire'; if(-not (Test-Path -LiteralPath $dir)){ [void](New-Item -ItemType Directory -Path $dir) }; "
set "PSMARK=!PSMARK!  Copy-Item -LiteralPath $f -Destination (Join-Path $dir 'appmanifest-before-update.acf') -Force; [IO.File]::Replace($tmp, $f, [NullString]::Value); "
set "PSMARK=!PSMARK!  Write-Output 'Fast Rust updates: Steam will check every game file before this update, so it finishes in one try.' "
set "PSMARK=!PSMARK!} catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; Write-Output 'Fast Rust updates: Steam''s install record could not be changed; leaving it to Steam.' } "
set "PSCORRUPT=$m=[regex]::Match([IO.File]::ReadAllText($env:HOTWIRE_ACFPATH), 'StateFlags'+[char]34+'\s+'+[char]34+'([0-9]+)'); if($m.Success -and ([int64]$m.Groups[1].Value -band 128)){ exit 0 }; exit 1"
set "QUICK_RETRY_USED=0"
set "RECOVERY_USED=0"
REM  A refused update. To patch, SteamCMD needs the file lists of the build
REM  installed. It reads them from its cache and asks Steam only on a miss,
REM  and Steam refuses an old Rust build's lists to an anonymous login. The
REM  cache is shared by every server using this SteamCMD, so one server's
REM  update can leave another, still on the old build, unable to update. The
REM  locked run above reads what SteamCMD's log gained during it and answers
REM  96 when a list of the installed build was refused. Without Steam's
REM  install record SteamCMD checks the files on disk against the new build
REM  and downloads what differs, so the record is set aside in hotwire\ and
REM  the update runs again, once. If it still fails and Steam left no record
REM  it can use, the old one is put back.
set "PSASIDE=$f=$env:HOTWIRE_ACFPATH; if(-not (Test-Path -LiteralPath $f)){ exit 1 }; $dir=Join-Path $env:HOTWIRE_ROOT 'hotwire'; try{ if(-not (Test-Path -LiteralPath $dir)){ [void](New-Item -ItemType Directory -Path $dir) }; Move-Item -LiteralPath $f -Destination (Join-Path $dir 'appmanifest-refused.acf') -Force; Write-Output 'Steam no longer serves the installed Rust build''s file list, so this update cannot patch it.'; Write-Output 'Setting Steam''s install record aside and updating again: Steam checks the files on disk and downloads what changed.'; exit 0 } catch { exit 1 }"
set "PSSETTLE=$q=[char]34; $saved=Join-Path $env:HOTWIRE_ROOT 'hotwire\appmanifest-refused.acf'; $f=$env:HOTWIRE_ACFPATH; if(-not (Test-Path -LiteralPath $saved)){ exit 0 }; $b=''; if(Test-Path -LiteralPath $f){ $m=[regex]::Match([IO.File]::ReadAllText($f), $q+'buildid'+$q+'\s+'+$q+'([0-9]+)'); if($m.Success){ $b=$m.Groups[1].Value } }; if($b -eq '' -or $b -eq '0'){ Copy-Item -LiteralPath $saved -Destination $f -Force; Write-Output 'The update did not finish. Steam''s install record is put back as it was.' }"
REM  Its own path: the build check above clears HOTWIRE_ACF once it is done.
set "HOTWIRE_ACFPATH=%ROOT%\steamapps\appmanifest_%APPID%.acf"
set "HOTWIRE_ROOT=%ROOT%"
if "%FAST_RUST_UPDATES%"=="1" if not "%INSTALL_FRAMEWORK%"=="0" if defined INSTALLED_BUILD if defined PUBLIC_BUILD if !INSTALLED_BUILD! LSS !PUBLIC_BUILD! (
    powershell -NoProfile -NonInteractive -Command "!PSMARK!"
)
set "HOTWIRE_ROOT="

set /a STEAM_TRIES=0
set "STEAM_OK=0"

REM  One SteamCMD run at a time on this machine. Several servers can share one
REM  SteamCMD, and nothing says two runs of it at once are safe, so the run
REM  first holds hotwire-steamcmd.lock beside steamcmd.exe, opened unshared.
REM  Windows lets go of an open file when its process ends, however it ends,
REM  so a crash can never leave the lock stuck. hotwire-setup takes the same
REM  lock. Waiting longer than hotwire.steamcmd_wait_minutes counts as a
REM  failed try.
REM  The arguments are assembled in PowerShell from the environment, so a
REM  folder name never passes through cmd's parser on the way.
set "PSSTEAM="
set "PSSTEAM=!PSSTEAM!$sc=$env:HOTWIRE_STEAMCMD; $q=[char]34; "
set "PSSTEAM=!PSSTEAM!$a='+force_install_dir '+$q+$env:HOTWIRE_ROOT+$q+' +login anonymous +app_update '+$env:HOTWIRE_APPID; "
set "PSSTEAM=!PSSTEAM!if(-not [string]::IsNullOrWhiteSpace($env:HOTWIRE_STEAMBRANCH)){ $a=$a+' -beta '+$env:HOTWIRE_STEAMBRANCH }; "
set "PSSTEAM=!PSSTEAM!if($env:HOTWIRE_VALIDATE -eq '1'){ $a=$a+' validate' }; $a=$a+' +quit'; "
set "PSSTEAM=!PSSTEAM!$wait=0; [void][int]::TryParse([string]$env:HOTWIRE_STEAMWAIT, [ref]$wait); $deadline=(Get-Date).AddMinutes($wait); "
set "PSSTEAM=!PSSTEAM!$lock=Join-Path (Split-Path -Parent $sc) 'hotwire-steamcmd.lock'; $h=$null; $said=$false; "
set "PSSTEAM=!PSSTEAM!while($null -eq $h){ try{ $h=[IO.File]::Open($lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { "
set "PSSTEAM=!PSSTEAM!  if((Get-Date) -gt $deadline){ Write-Output ('Another server has been using SteamCMD for over '+$wait+' minutes. Not waiting any longer.'); exit 97 }; "
set "PSSTEAM=!PSSTEAM!  if(-not $said){ Write-Output 'Another server is using SteamCMD right now. Waiting for it to finish...'; $said=$true }; Start-Sleep -Seconds 5 } } "
set "PSSTEAM=!PSSTEAM!try{ $lg=Join-Path (Split-Path -Parent $sc) 'logs\content_log.txt'; $before=0; if(Test-Path -LiteralPath $lg){ $before=(Get-Item -LiteralPath $lg).Length }; "
set "PSSTEAM=!PSSTEAM!  $inst=@(); if($env:HOTWIRE_ACFPATH -and (Test-Path -LiteralPath $env:HOTWIRE_ACFPATH)){ foreach($x in [regex]::Matches([IO.File]::ReadAllText($env:HOTWIRE_ACFPATH), $q+'manifest'+$q+'\s+'+$q+'([0-9]+)'+$q)){ $inst+=$x.Groups[1].Value } }; "
set "PSSTEAM=!PSSTEAM!  $p=Start-Process -FilePath $sc -ArgumentList $a -NoNewWindow -Wait -PassThru; $code=$p.ExitCode; "
set "PSSTEAM=!PSSTEAM!  if($code -ne 0 -and $env:HOTWIRE_RECOVER -eq '1' -and $inst.Count -gt 0 -and (Test-Path -LiteralPath $lg)){ $len=(Get-Item -LiteralPath $lg).Length; if($len -lt $before){ $before=0 }; "
set "PSSTEAM=!PSSTEAM!    if($len -gt $before){ $fs=[IO.File]::Open($lg, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite); try{ [void]$fs.Seek($before, [IO.SeekOrigin]::Begin); $n=[int][Math]::Min($len-$before, 4194304); $buf=New-Object byte[] $n; [void]$fs.Read($buf, 0, $n) } finally { $fs.Dispose() }; "
set "PSSTEAM=!PSSTEAM!      foreach($line in [Text.Encoding]::UTF8.GetString($buf).Split([char]10)){ if($line.Contains('Failed to get manifest request code') -and $line.Contains('Access Denied')){ $mm=[regex]::Match($line, 'Manifest: ([0-9]+)'); if($mm.Success -and ($inst -contains $mm.Groups[1].Value)){ $code=96 } } } } }; "
set "PSSTEAM=!PSSTEAM!  exit $code } finally { $h.Dispose() } "

:steamupdate
set /a STEAM_TRIES+=1
set "HOTWIRE_STEAMCMD=%STEAMCMD%"
set "HOTWIRE_ROOT=%ROOT%"
set "HOTWIRE_APPID=%APPID%"
set "HOTWIRE_STEAMBRANCH=%STEAM_BRANCH%"
set "HOTWIRE_VALIDATE=%DO_VALIDATE%"
set "HOTWIRE_STEAMWAIT=%STEAMCMD_WAIT_MINUTES%"
set "HOTWIRE_RECOVER=%RECOVER_REFUSED_UPDATE%"
powershell -NoProfile -NonInteractive -Command "!PSSTEAM!"
set "STEAMEXIT=!errorlevel!"
set "HOTWIRE_STEAMCMD="
set "HOTWIRE_ROOT="
set "HOTWIRE_APPID="
set "HOTWIRE_STEAMBRANCH="
set "HOTWIRE_VALIDATE="
set "HOTWIRE_STEAMWAIT="
set "HOTWIRE_RECOVER="
if not "!STEAMEXIT!"=="0" goto steamfailed
set "STEAM_OK=1"
if "!RECOVERY_USED!"=="1" echo [%date% %time%] The update finished without the old file list. The old install record is kept in hotwire\appmanifest-refused.acf.
goto framework

:steamfailed
echo [%date% %time%] steamcmd error (attempt !STEAM_TRIES! of %MAX_STEAM_TRIES%).
if not "!STEAMEXIT!"=="96" goto steamnotrefused
if "!RECOVERY_USED!"=="1" goto steamnotrefused
set "HOTWIRE_ROOT=%ROOT%"
powershell -NoProfile -NonInteractive -Command "!PSASIDE!"
set "ASIDEEXIT=!errorlevel!"
set "HOTWIRE_ROOT="
if not "!ASIDEEXIT!"=="0" goto steamnotrefused
set "RECOVERY_USED=1"
goto steamupdate
:steamnotrefused
if !STEAM_TRIES! GEQ %MAX_STEAM_TRIES% goto steamgaveup
REM  Once per update, a try that left the install marked Files Corrupt is
REM  retried at once: Steam checks every file on that next run, so waiting
REM  changes nothing.
if "!QUICK_RETRY_USED!"=="1" goto steamwait
if not exist "!HOTWIRE_ACFPATH!" goto steamwait
powershell -NoProfile -NonInteractive -Command "!PSCORRUPT!" >nul 2>&1
if errorlevel 1 goto steamwait
set "QUICK_RETRY_USED=1"
echo [%date% %time%] Steam marked the game files for a full check; trying again now.
goto steamupdate
:steamwait
REM  timeout refuses to run when stdin is redirected, which is how this
REM  launcher behaves under a scheduler. Without the fallback the retry
REM  would return instantly and hammer steamcmd.
set /a PINGWAIT=%STEAM_RETRY_SECONDS%+1
timeout /t %STEAM_RETRY_SECONDS% /nobreak >nul 2>&1
if errorlevel 1 ping -n !PINGWAIT! 127.0.0.1 >nul 2>&1
goto steamupdate

:steamgaveup
echo [%date% %time%] Giving up on steamcmd. Launching what we have.
if not "!RECOVERY_USED!"=="1" goto steamsettled
set "HOTWIRE_ROOT=%ROOT%"
powershell -NoProfile -NonInteractive -Command "!PSSETTLE!"
set "HOTWIRE_ROOT="
:steamsettled

:framework
REM  Oxide/uMod. hotwire.install_framework 0 skips it for a vanilla server.
REM  -f makes curl fail on an HTTP error instead of saving the error page,
REM  which would otherwise be force-extracted over a working install.
set "FRAMEWORK_OK=0"
if "%INSTALL_FRAMEWORK%"=="0" (
    echo [%date% %time%] Vanilla server: hotwire.install_framework is 0, so no framework.
    set "FRAMEWORK_OK=1"
    goto :frameworkdone
)

REM  Re-read the installed build. If steamcmd changed it, the game's own
REM  managed assemblies were just rewritten and the framework has to go
REM  back over the top of them whatever its version says. Only when the
REM  game did NOT move is skipping the extract safe.
REM  Read with the same [char]-built regex as section 6a rather than with
REM  findstr and escaped quotes. cmd has no backslash escape, and quoting a
REM  quote inside a for/f is how this file has gone wrong before.
set "BUILD_AFTER="
set "HOTWIRE_ACF2=%ROOT%\steamapps\appmanifest_%APPID%.acf"
for /f %%B in ('powershell -NoProfile -NonInteractive -Command "$q=[char]34; $t=[IO.File]::ReadAllText($env:HOTWIRE_ACF2); $m=[regex]::Match($t, $q+'buildid'+$q+'\s+'+$q+'(\d+)'+$q); if($m.Success){ $m.Groups[1].Value }"') do set "BUILD_AFTER=%%B"
set "HOTWIRE_ACF2="

set "FWSKIP=0"
if not "%SKIP_UNCHANGED_FRAMEWORK%"=="1" goto :frameworkextract
if not defined INSTALLED_BUILD goto :frameworkextract
if not defined BUILD_AFTER goto :frameworkextract
if not "!INSTALLED_BUILD!"=="!BUILD_AFTER!" (
    echo [%date% %time%] The game moved from !INSTALLED_BUILD! to !BUILD_AFTER!,
    echo [%date% %time%] so the framework is going back over it.
    goto :frameworkextract
)

set "HOTWIRE_FWFILE=%FRAMEWORK_VERSION_FILE%"
set "HOTWIRE_FWFEED=%FRAMEWORK_FEED%"
set "PSFW="
set "PSFW=!PSFW!$ErrorActionPreference='SilentlyContinue'; "
set "PSFW=!PSFW!$f=$env:HOTWIRE_FWFILE; $u=$env:HOTWIRE_FWFEED; "
set "PSFW=!PSFW!if([string]::IsNullOrWhiteSpace($f)){ exit 2 } "
set "PSFW=!PSFW!if(-not (Test-Path -LiteralPath $f)){ exit 2 } "
set "PSFW=!PSFW!$v=[string](Get-Item -LiteralPath $f).VersionInfo.FileVersion; "
set "PSFW=!PSFW!if([string]::IsNullOrWhiteSpace($v)){ exit 2 } "
set "PSFW=!PSFW!$vn=(($v.Trim() -split '\.') + @('0','0','0'))[0..2] -join '.'; "
set "PSFW=!PSFW!try{ [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 } catch {} "
set "PSFW=!PSFW!$r=Invoke-RestMethod -Uri $u -TimeoutSec 25; "
set "PSFW=!PSFW!$l=[string]$r.latest_release_version; "
set "PSFW=!PSFW!if([string]::IsNullOrWhiteSpace($l)){ exit 2 } "
set "PSFW=!PSFW!$ln=(($l.Trim() -split '\.') + @('0','0','0'))[0..2] -join '.'; "
set "PSFW=!PSFW!Write-Output ('Framework: installed '+$vn+', latest '+$ln); "
set "PSFW=!PSFW!if($vn -eq $ln){ exit 0 } else { exit 1 } "
powershell -NoProfile -NonInteractive -Command "!PSFW!"
set "FWSAME=!errorlevel!"
set "HOTWIRE_FWFILE="
set "HOTWIRE_FWFEED="

REM  0 means the versions matched. 1 means they did not. Anything else
REM  means the comparison could not be made -- no version file, no feed,
REM  no network -- and the extract happens, which is what used to happen
REM  every time anyway.
if "!FWSAME!"=="0" (
    echo [%date% %time%] Game and framework both unchanged. Skipping the
    echo [%date% %time%] extract rather than writing over a working install.
    set "FWSKIP=1"
) else if not "!FWSAME!"=="1" (
    echo [%date% %time%] Could not compare framework versions ^(exit !FWSAME!^).
    echo [%date% %time%] Extracting, as before.
)

if "!FWSKIP!"=="1" (
    set "FRAMEWORK_OK=1"
    goto :frameworkdone
)

:frameworkextract
REM  HW-9: the framework (uMod / Oxide) is third-party and its version changes
REM  with every Rust release, so there is no hash of ours to pin it against.
REM  GitHub publishes a SHA-256 for every release file, and uMod's download
REM  link redirects to that same file, so the launcher checks the download
REM  against it (hotwire.verify_framework). That proves the file is the one GitHub
REM  holds for the release, not who built it: both come from GitHub. When the
REM  check cannot be made, the download is unverified, as it always was, and
REM  the log says so rather than staying silent. setup pins the first-party
REM  launcher and plugin separately (see $PinnedHashes in hotwire-setup.ps1).
REM  HW-10: the destination path goes through an environment variable, never a
REM  PowerShell single-quoted literal, so an apostrophe in the path is safe.
REM  The PowerShell below avoids the characters delayed expansion eats.
set "FW_FROM=%FRAMEWORK_URL%"
set "FW_SHA="
set "FW_TAG="
set "FW_CHECK=0"
if "%VERIFY_FRAMEWORK%"=="0" goto :fwfetch
set "FW_CHECK=1"
set "HOTWIRE_FWREL=%FRAMEWORK_RELEASES%"
set "HOTWIRE_FWASSET=%FRAMEWORK_ASSET%"
set "HOTWIRE_FWOUT=%ROOT%\logs\.framework-release.tmp"
if exist "!HOTWIRE_FWOUT!" del "!HOTWIRE_FWOUT!"
set "PSREL="
set "PSREL=!PSREL!try{ [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 } catch {} "
set "PSREL=!PSREL!try{ $r=Invoke-RestMethod -Uri $env:HOTWIRE_FWREL -TimeoutSec 25 -Headers @{ Accept='application/vnd.github+json' }; "
set "PSREL=!PSREL!$a=@($r.assets | Where-Object { $_.name -eq $env:HOTWIRE_FWASSET })[0]; $d=[string]$a.digest; $u=[string]$a.browser_download_url; "
set "PSREL=!PSREL!if($d.Length -eq 71 -and $d -like 'sha256:*' -and $u -like 'https://github.com/*'){ "
set "PSREL=!PSREL!Set-Content -LiteralPath $env:HOTWIRE_FWOUT -Value ($u+' '+$d.Substring(7).ToLower()+' '+[string]$r.tag_name) -Encoding ASCII } } catch {} "
powershell -NoProfile -NonInteractive -Command "!PSREL!"
if exist "!HOTWIRE_FWOUT!" (
    for /f "usebackq tokens=1-3" %%A in ("!HOTWIRE_FWOUT!") do (
        set "FW_FROM=%%A"
        set "FW_SHA=%%B"
        set "FW_TAG=%%C"
    )
    del "!HOTWIRE_FWOUT!"
)
set "HOTWIRE_FWREL="
set "HOTWIRE_FWASSET="
set "HOTWIRE_FWOUT="
set "PSREL="
if not defined FW_SHA (
    set "FW_FROM=%FRAMEWORK_URL%"
    echo [%date% %time%] GitHub did not say what Oxide's latest release is, so this
    echo [%date% %time%] download cannot be checked. Downloading from uMod as before.
)

:fwfetch
if defined FW_SHA (
    echo [%date% %time%] Downloading Oxide !FW_TAG! from GitHub, to check against its SHA-256.
) else (
    echo [%date% %time%] Downloading the framework from uMod ^(third-party, not hash-verified^).
)
set "HOTWIRE_ZIPROOT=%ROOT%"
curl -fSL -A "Mozilla/5.0" "!FW_FROM!" --output "%ROOT%\OxideMod.zip"
if errorlevel 1 (
    echo [%date% %time%] Framework download failed. Keeping the install.
    goto :fwcleanup
)
if defined FW_SHA (
    set "HOTWIRE_FWZIP=%ROOT%\OxideMod.zip"
    set "HOTWIRE_FWSHA=!FW_SHA!"
    powershell -NoProfile -NonInteractive -Command "$h=(Get-FileHash -Algorithm SHA256 -LiteralPath $env:HOTWIRE_FWZIP).Hash.ToLower(); if($h -eq $env:HOTWIRE_FWSHA){ exit 0 } else { Write-Output ('Downloaded SHA-256: '+$h); exit 1 }"
    if errorlevel 1 (
        echo [%date% %time%] The download does not match the SHA-256 GitHub lists for
        echo [%date% %time%] Oxide !FW_TAG! ^(!FW_SHA!^). Not extracting it: the server
        echo [%date% %time%] starts on the framework it already has, and the update
        echo [%date% %time%] is tried again at the next restart.
        set "HOTWIRE_FWZIP="
        set "HOTWIRE_FWSHA="
        goto :fwcleanup
    )
    set "HOTWIRE_FWZIP="
    set "HOTWIRE_FWSHA="
    echo [%date% %time%] SHA-256 matches GitHub's for Oxide !FW_TAG!.
)
(
    powershell -NoProfile -Command "Expand-Archive -Force -LiteralPath (Join-Path $env:HOTWIRE_ZIPROOT 'OxideMod.zip') -DestinationPath $env:HOTWIRE_ZIPROOT"
    if errorlevel 1 (
        echo [%date% %time%] Framework extract failed.
    ) else (
        set "FRAMEWORK_OK=1"
    )
)
:fwcleanup
set "HOTWIRE_ZIPROOT="
if exist "%ROOT%\OxideMod.zip" del "%ROOT%\OxideMod.zip"

:frameworkdone

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
    if exist "%ROOT%\%UPDATE_FLAG%"   del "%ROOT%\%UPDATE_FLAG%"
    if exist "%ROOT%\%VALIDATE_FLAG%" del "%ROOT%\%VALIDATE_FLAG%"
    >"%UPDATE_STAMP%" echo Last update: %date% %time%
) else (
    echo [%date% %time%] ================================================
    echo [%date% %time%] The update did NOT complete.
    echo [%date% %time%] Any %UPDATE_FLAG% or %VALIDATE_FLAG% is being KEPT,
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
if "!UPDATE_OK!"=="1" if exist "%ROOT%\%UPDATE_FLAG%" (
    echo [%date% %time%] WARNING: %UPDATE_FLAG% is still present after a
    echo [%date% %time%] successful update. It could not be deleted, so
    echo [%date% %time%] every restart from now will update. Check the
    echo [%date% %time%] permissions on the server's folder.
)
if "!UPDATE_OK!"=="1" if exist "%ROOT%\%VALIDATE_FLAG%" (
    echo [%date% %time%] WARNING: %VALIDATE_FLAG% is still present after a
    echo [%date% %time%] successful update, so every restart will
    echo [%date% %time%] validate. That is slow, and unintended.
)
if "!UPDATE_OK!"=="1" if not exist "%UPDATE_STAMP%" (
    echo [%date% %time%] WARNING: could not write the update stamp at
    echo [%date% %time%]   %UPDATE_STAMP%
    echo [%date% %time%] The backstop reads it, so it will act as though
    echo [%date% %time%] no update has ever happened.
)

REM  hotwire-after.bat runs after an update attempt, whether or not it
REM  worked, in a cmd of its own like the before-start hook.
if not exist "%HOOK_AFTER%" goto :hookafterdone
echo [%date% %time%] Running the after-update hook (hotwire-after.bat)...
cmd /d /c call "%HOOK_AFTER%"
if errorlevel 1 echo [%date% %time%] hotwire-after.bat exited non-zero; carrying on.
:hookafterdone



REM ======================================================================
:buildargs
REM ======================================================================
REM  6b. WIPES AND PERMANENT SETTINGS
REM
REM     Machinery. The plugin leaves WIPE.flag or CONVAR.request here when
REM     the panel asks for a wipe or a permanent convar. Between runs is the
REM     safe moment: the PowerShell at the end of this file checks every
REM     value and writes it into hotwire.cfg, which is then read again so
REM     this start uses it. Check mode changes nothing.
REM ======================================================================
if defined CHECK_ONLY goto :editsdone
set "HOTWIRE_EDITS="
if exist "%ROOT%\%WIPE_FLAG%" set "HOTWIRE_EDITS=1"
if exist "%ROOT%\CONVAR.request" set "HOTWIRE_EDITS=1"
if not defined HOTWIRE_EDITS goto :editsdone
set "HOTWIRE_EDITS="
call :hotwire_ps edits
set "HOTWIRE_QUIET=1"
call :hotwire_load
set "HOTWIRE_QUIET="
:editsdone

if defined CHECK_ONLY (
    echo [%date% %time%] check mode -- not starting the server.
    exit /b 0
)


REM ======================================================================
REM  8. LAUNCH
REM ======================================================================

REM  Rotate the log. -logfile TRUNCATES on every start, so without this a
REM  restart destroys the log of whatever went wrong before it.
REM
REM  That was true of a crash loop too, which is the case it most needed
REM  to be false for. Rotation culled to hotwire.log_keep every pass, and a
REM  server dying on boot loops every 15 seconds, so about three and a half
REM  minutes later the log holding the actual failure had been culled away
REM  and fourteen identical near-empty ones were left in its place.
REM
REM  So the first log of a crash streak goes to server_crash_*, which the
REM  cull never matches. Later crashes in the same streak rotate normally:
REM  they say the same thing as the first, and keeping every one of them
REM  is how a crash loop fills a disk.
if not "%ROTATE_LOGS%"=="0" if exist "%LOGFILE%" (
    REM  HW-10: log root via an environment variable, not a PS single-quoted
    REM  literal, so an apostrophe in the path is safe.
    set "HOTWIRE_LOGROOT=%ROOT%"
    set "LOGSTAMP="
    for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "LOGSTAMP=%%i"
    if not defined LOGSTAMP set "LOGSTAMP=unstamped-!RANDOM!"
    set "ROTATED=%ROOT%\logs\server_log_!LOGSTAMP!.txt"
    if "!CRASH_STREAK!"=="1" set "ROTATED=%ROOT%\logs\server_crash_!LOGSTAMP!.txt"
    move /y "%LOGFILE%" "!ROTATED!" >nul
    powershell -NoProfile -Command "Get-ChildItem -Path (Join-Path $env:HOTWIRE_LOGROOT 'logs\server_log_*.txt') | Sort-Object LastWriteTime -Descending | Select-Object -Skip %LOG_KEEP% | Remove-Item -Force" 2>nul
)
set "HOTWIRE_LOGROOT="

REM  Tell the plugin who started the server: this launcher's version, code
REM  hash, capabilities and path, in oxide\data\Hotwire\launcher.json. Written
REM  before every start, so it follows this file. Best effort: a failure here
REM  costs the panel's view of the launcher and nothing else.
set "HOTWIRE_STATE=%ROOT%\oxide\data\Hotwire\launcher.json"
powershell -NoProfile -NonInteractive -Command "$t=[IO.File]::ReadAllText($env:HOTWIRE_SELF,[Text.Encoding]::GetEncoding(28591)); $h=''; $m=[regex]::Match($t,'(?m)^HOTWIRE_LAUNCHER_HASH=.?([0-9a-f]{64})'); if($m.Success){ $h=$m.Groups[1].Value }; [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $env:HOTWIRE_STATE)); $o=[ordered]@{ version=$env:HOTWIRE_LAUNCHER_VERSION; hash=$h; capabilities=$env:HOTWIRE_LAUNCHER_CAPABILITIES; platform='windows'; path=$env:HOTWIRE_SELF; update_mode=$env:UPDATE_MODE }; [IO.File]::WriteAllText($env:HOTWIRE_STATE, ($o | ConvertTo-Json))" >nul 2>&1
set "HOTWIRE_STATE="

echo [%date% %time%] Starting server...

REM  Timed so a crash loop can be told from a working restart. If either
REM  call fails the run is treated as a long one: erring that way keeps
REM  the server running, and the other way would stop it over a failed
REM  timestamp.
set "RUN_START=0"
for /f %%t in ('powershell -NoProfile -Command "[int]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalSeconds"') do set "RUN_START=%%t"

REM  PowerShell starts RustDedicated.exe with the argument list from the
REM  last good read of hotwire.cfg, and waits for it to exit.
call :hotwire_ps launch

set "RUN_END=0"
for /f %%t in ('powershell -NoProfile -Command "[int]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalSeconds"') do set "RUN_END=%%t"
set "RUN_SECONDS=99999"
if not "!RUN_START!"=="0" if not "!RUN_END!"=="0" set /a RUN_SECONDS=RUN_END-RUN_START

if !RUN_SECONDS! LSS %CRASH_SECONDS% (
    set /a CRASH_STREAK+=1
) else (
    set /a CRASH_STREAK=0
)

if "%RESTART_ON_EXIT%"=="0" (
    echo [%date% %time%] Server exited after !RUN_SECONDS!s. hotwire.restart_on_exit is 0 -- not relaunching.
    exit /b 0
)

if not "%MAX_CRASH_STREAK%"=="0" if !CRASH_STREAK! GEQ %MAX_CRASH_STREAK% goto crashstop

REM  Back off, so a permanently broken config does not relaunch four
REM  times a minute forever -- and does not run hotwire-before.bat that
REM  often either, which for anyone hooking a backup in is the expensive
REM  part.
set "DELAY=%RESTART_DELAY%"
if not "%CRASH_BACKOFF%"=="0" if !CRASH_STREAK! GEQ 2 set "DELAY=30"
if not "%CRASH_BACKOFF%"=="0" if !CRASH_STREAK! GEQ 3 set "DELAY=60"
if not "%CRASH_BACKOFF%"=="0" if !CRASH_STREAK! GEQ 4 set "DELAY=120"
if not "%CRASH_BACKOFF%"=="0" if !CRASH_STREAK! GEQ 5 set "DELAY=300"

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
echo [%date% %time%] setting in hotwire.cfg, a port already in use, or a
echo [%date% %time%] corrupt save. On a machine with more than one server,
echo [%date% %time%] check each has its own ports in hotwire.cfg -- two
echo [%date% %time%] servers on the same port is exactly this. Another copy
echo [%date% %time%] of this launcher already running would do it too.
echo [%date% %time%]
echo [%date% %time%] Set hotwire.max_crash_streak 0 in hotwire.cfg to loop
echo [%date% %time%] forever instead.
echo [%date% %time%] ====================================================
pause
exit /b 1


REM ======================================================================
REM  THE CALLS INTO POWERSHELL
REM ======================================================================

REM  :hotwire_load reads the settings. PowerShell prints what it has to say
REM  on stderr, straight to this window, and hands cmd its settings on
REM  stdout as HWSET NAME=value lines, the last one HW_LOAD: ok, fatal (a
REM  first read that must stop) or kept (a later read that failed, so the
REM  last good settings stay).
:hotwire_load
set "HW_LOAD="
set "HOTWIRE_MODE=load"
set "HOTWIRE_ROOT=%ROOT%"
for /f "usebackq delims=" %%L in (`powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "!HW_PS!"`) do (
    set "HW_LINE=%%L"
    if "!HW_LINE:~0,6!"=="HWSET " for /f "tokens=1,* delims==" %%A in ("!HW_LINE:~6!") do set "%%A=%%B"
)
set "HW_LINE="
set "HOTWIRE_MODE="
exit /b 0

REM  :hotwire_ps <edits|launch> runs one part, and returns its exit code.
:hotwire_ps
set "HOTWIRE_MODE=%~1"
set "HOTWIRE_ROOT=%ROOT%"
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "!HW_PS!"
set "HW_EXIT=!errorlevel!"
set "HOTWIRE_MODE="
exit /b !HW_EXIT!

REM ======================================================================
REM  THE LAUNCHER'S CODE HASH, AND ITS POWERSHELL
REM
REM     Never run by cmd: every path above ends before this. The hash is
REM     stamped at release by tools/launcher-hash.sh; the calls above hand
REM     everything from the #HOTWIRE-PS line down to PowerShell, so it is
REM     written as ordinary PowerShell rather than through cmd's quoting
REM     rules.
REM ======================================================================
exit /b 0
HOTWIRE_LAUNCHER_HASH="af65a087d60fae927b6601c7dd3fda7a8d11f5bb476d5f206b4461a120a3bc3b"

#HOTWIRE-PS
# hotwire.bat's PowerShell. cmd hands everything from the line above down to PowerShell, and HOTWIRE_MODE says
# which part to run:
#   load    read hotwire.cfg and hotwire-secrets.cfg, check every line, hand cmd the launcher's own settings,
#           and keep the server's argument list for the start
#   edits   carry out a wipe or a permanent convar the plugin asked for, by writing hotwire.cfg
#   launch  start RustDedicated.exe with that argument list, and wait for it
#
# The settings are read as data, one line at a time, and never run. A line is a name, spaces, then a value; a
# value with spaces is in double quotes and holds none inside; no control characters. Each value is checked for
# what it sets before it is used: a line that fails is ignored and named by check, and the default stays. The
# few settings a wrong default would turn into a different server -- the save folder, the map and the ports --
# are not defaulted: a bad one stops the first start, and on a later restart the last good settings are kept.
# The rules are hotwire.sh's, line for line. Windows PowerShell 5.1, ASCII only.
$ErrorActionPreference = 'Stop'
$root = $env:HOTWIRE_ROOT
$cfg = Join-Path $root 'hotwire.cfg'
$secretsCfg = Join-Path $root 'hotwire-secrets.cfg'
$argsFile = Join-Path $root 'hotwire\launch-args.json'

# Everything said goes to stderr: in load mode stdout carries the settings to cmd.
function Say([string]$message) { [Console]::Error.WriteLine('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $message) }
function Rule { [Console]::Error.WriteLine('========================================================') }

# hotwire.<name> -> variable, kind, default. cmd reads these, so every kind here is checked to hold nothing cmd
# treats as syntax.
$hwSettings = @{
    'hotwire.update_mode'              = @('UPDATE_MODE', 'mode', 'auto')
    'hotwire.steamcmd'                 = @('STEAMCMD', 'steamcmd', 'C:\steamcmd\steamcmd.exe')
    'hotwire.steam_branch'             = @('STEAM_BRANCH', 'word', 'public')
    'hotwire.max_days_without_update'  = @('MAX_DAYS_WITHOUT_UPDATE', 'int', '14')
    'hotwire.update_on_new_build'      = @('UPDATE_ON_NEW_BUILD', 'bool', '1')
    'hotwire.fast_rust_updates'        = @('FAST_RUST_UPDATES', 'bool', '0')
    'hotwire.recover_refused_update'   = @('RECOVER_REFUSED_UPDATE', 'bool', '1')
    'hotwire.build_check_hours'        = @('BUILD_CHECK_HOURS', 'int', '6')
    'hotwire.steam_tries'              = @('MAX_STEAM_TRIES', 'int1', '5')
    'hotwire.steam_retry_seconds'      = @('STEAM_RETRY_SECONDS', 'int', '60')
    'hotwire.steamcmd_wait_minutes'    = @('STEAMCMD_WAIT_MINUTES', 'int', '60')
    'hotwire.install_framework'        = @('INSTALL_FRAMEWORK', 'bool', '1')
    'hotwire.skip_unchanged_framework' = @('SKIP_UNCHANGED_FRAMEWORK', 'bool', '1')
    'hotwire.verify_framework'         = @('VERIFY_FRAMEWORK', 'bool', '1')
    'hotwire.restart_on_exit'          = @('RESTART_ON_EXIT', 'bool', '1')
    'hotwire.restart_delay'            = @('RESTART_DELAY', 'int', '15')
    'hotwire.crash_seconds'            = @('CRASH_SECONDS', 'int', '60')
    'hotwire.max_crash_streak'         = @('MAX_CRASH_STREAK', 'int', '10')
    'hotwire.crash_backoff'            = @('CRASH_BACKOFF', 'bool', '1')
    'hotwire.rotate_logs'              = @('ROTATE_LOGS', 'bool', '1')
    'hotwire.log_keep'                 = @('LOG_KEEP', 'int1', '14')
    'hotwire.rcon_password_min'        = @('RCON_PASSWORD_MIN', 'int1', '8')
    'hotwire.check_options'            = @('CHECK_OPTIONS', 'bool', '1')
    'hotwire.backups'                  = @('BACKUPS', 'bool', '1')
}
# Rust convars the launcher itself reads -> kind, default.
$cvSettings = @{
    'server.hostname'    = @('text', '')
    'server.description' = @('text', '')
    'server.tags'        = @('tags', '')
    'server.maxplayers'  = @('int', '')
    'server.identity'    = @('identity', '')
    'server.seed'        = @('seed', '')
    'server.worldsize'   = @('worldsize', '')
    'server.port'        = @('port', '28015')
    'server.queryport'   = @('port', '28017')
    'rcon.port'          = @('port', '28016')
    'server.level'       = @('text', 'Procedural Map')
    'server.levelurl'    = @('url', '')
    'rcon.web'           = @('bool', '1')
}
# The settings that turn into a different server when defaulted.
$criticalKinds = @('identity', 'seed', 'worldsize', 'port', 'url')

# One line -> @{ Name; Value } or @{ Why }.
function Read-CfgLine([string]$line) {
    $m = [regex]::Match($line, '^([A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+)(\s+(.*))?$')
    if (-not $m.Success) { return @{ Why = 'not a setting: a name, a space, then a value' } }
    $v = $m.Groups[4].Value.TrimEnd()
    if ($v.StartsWith('"')) {
        $q = [regex]::Match($v, '^"([^"]*)"$')
        if (-not $q.Success) { return @{ Why = 'a quoted value must start and end with a double quote, and hold none inside' } }
        $v = $q.Groups[1].Value
    } elseif ($v -match '\s') { return @{ Why = 'a value with spaces must be in double quotes' } }
    elseif ($v.Contains('"')) { return @{ Why = 'a double quote inside the value' } }
    if ($v -match '[\x00-\x1F\x7F]') { return @{ Why = 'a control character in the value' } }
    if ($v.Length -gt 1024) { return @{ Why = 'longer than 1024 characters' } }
    return @{ Name = $m.Groups[1].Value; Value = $v }
}

# '' when the value may be used, or why not. An empty value always passes: it means the default.
function Test-CfgValue([string]$kind, [string]$v) {
    if ($v -eq '') { return '' }
    switch ($kind) {
        'int'       { if ($v -cnotmatch '^[0-9]{1,9}$') { return 'must be a whole number' } }
        'int1'      { if ($v -cnotmatch '^[0-9]{1,9}$' -or [long]$v -lt 1) { return 'must be a whole number of 1 or more' } }
        'bool'      { if ($v -cnotmatch '^[01]$') { return 'must be 0 or 1' } }
        'mode'      { if ($v -cnotmatch '^(auto|always|hotwire|off)$') { return 'must be auto, always, hotwire or off' } }
        'word'      { if ($v -cnotmatch '^[A-Za-z0-9_.-]+$') { return 'letters, digits, _ . - only' } }
        'steamcmd'  { if ($v -cnotmatch '^[A-Za-z]:\\[^"%!^&|<>]*\\steamcmd\.exe$') { return 'must be a full path to steamcmd.exe, with none of " % ! ^ & | < > in it' } }
        'text'      { }
        'tags'      { if ($v -cnotmatch '^[A-Za-z0-9,_-]+$') { return 'tags separated by commas, with no spaces' } }
        'identity'  { if ($v -cnotmatch '^[A-Za-z0-9_-]{1,64}$') { return 'letters, digits, _ and - only: it names a folder' } }
        'seed'      { if ($v -cnotmatch '^[0-9]{1,10}$' -or [long]$v -gt 2147483647) { return 'must be a whole number from 0 to 2147483647' } }
        'worldsize' { if ($v -cnotmatch '^[0-9]{4}$' -or [int]$v -lt 1000 -or [int]$v -gt 6000) { return 'must be a whole number from 1000 to 6000' } }
        'port'      { if ($v -cnotmatch '^[0-9]{1,5}$' -or [int]$v -lt 1 -or [int]$v -gt 65535) { return 'must be a port number from 1 to 65535' } }
        'url'       { if ($v -cnotmatch '^https?://\S+$') { return 'must be an http:// or https:// address' } }
        default     { return ('unknown kind ' + $kind) }
    }
    return ''
}

# hotwire.cfg -> what it sets, and every line that was not used.
function Read-Config {
    $r = @{
        Missing = $false; Values = @{}; Extra = [ordered]@{}; Known = @{}
        Problems = New-Object 'System.Collections.Generic.List[string]'
        Fatal = New-Object 'System.Collections.Generic.List[string]'
        Unknown = New-Object 'System.Collections.Generic.List[string]'
    }
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { $r.Missing = $true; $r.Fatal.Add('hotwire.cfg is missing'); return $r }
    $n = 0; $listed = $true
    foreach ($raw in [IO.File]::ReadAllLines($cfg)) {
        $n++
        $line = $raw.TrimStart()
        # The file's own list is every name above its OTHER CONVARS heading, on or off (#name value): what the option
        # check knows as spelled right. Names added below it are the ones worth a second look.
        if ($line.StartsWith('#') -and $line.Contains('OTHER CONVARS')) { $listed = $false }
        $off = [regex]::Match($line, '^#([A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+)\s')
        if ($off.Success) { if ($listed) { $r.Known[$off.Groups[1].Value.ToLowerInvariant()] = 1 }; continue }
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $p = Read-CfgLine $line
        if ($p.Why) { $r.Problems.Add('line ' + $n + ': ' + $p.Why); continue }
        $name = $p.Name; $lower = $name.ToLowerInvariant()
        if ($listed) { $r.Known[$lower] = 1 }
        if ($lower -eq 'rcon.password') { $r.Problems.Add('line ' + $n + ': rcon.password: belongs in hotwire-secrets.cfg, never here; ignored'); continue }
        $kind = $null
        if ($hwSettings.ContainsKey($lower)) { $kind = $hwSettings[$lower][1] } elseif ($cvSettings.ContainsKey($lower)) { $kind = $cvSettings[$lower][0] }
        if ($kind) {
            $why = Test-CfgValue $kind $p.Value
            if ($why) {
                if ($criticalKinds -contains $kind) { $r.Fatal.Add('line ' + $n + ': ' + $name + ': ' + $why) }
                else { $r.Problems.Add('line ' + $n + ': ' + $name + ': ' + $why + '; the default is used') }
                continue
            }
            $r.Values[$lower] = $p.Value
            continue
        }
        if ($lower.StartsWith('hotwire.')) { $r.Problems.Add('line ' + $n + ': ' + $name + ': not a launcher setting; ignored'); continue }
        # Any other Rust convar, passed through as it is. Empty means the default.
        if ($p.Value -eq '') { continue }
        $r.Extra[$lower] = @($name, $p.Value)
    }
    foreach ($k in $r.Extra.Keys) { if (-not $r.Known.ContainsKey($k)) { $r.Unknown.Add($r.Extra[$k][0]) } }
    return $r
}

# A launcher setting as it is used: the file's value, or the default. For a number, a switch or a path an empty
# value is the default too; for the Steam branch empty means "let Steam keep the last one".
function Get-HwValue($r, [string]$key) {
    $spec = $hwSettings[$key]
    if ($r.Values.ContainsKey($key)) {
        $v = [string]$r.Values[$key]
        if ($v -ne '' -or $spec[1] -eq 'word') { return $v }
    }
    return $spec[2]
}

# A server setting as it is used: the file's value, even empty (the game's default), or the launcher's default.
function Get-CvValue($r, [string]$key) {
    if ($r.Values.ContainsKey($key)) { return [string]$r.Values[$key] }
    return $cvSettings[$key][1]
}

# hotwire-secrets.cfg -> @{ Password; Why }. Read as data, like hotwire.cfg; only rcon.password is taken from it.
function Read-Secret([int]$minimum) {
    if (-not (Test-Path -LiteralPath $secretsCfg -PathType Leaf)) {
        return @{ Why = 'No hotwire-secrets.cfg beside the launcher. Copy hotwire-secrets.example.cfg to hotwire-secrets.cfg and set rcon.password.' }
    }
    $n = 0; $password = ''
    foreach ($raw in [IO.File]::ReadAllLines($secretsCfg)) {
        $n++
        $line = $raw.TrimStart()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $p = Read-CfgLine $line
        if ($p.Why) { Say ('hotwire-secrets.cfg line ' + $n + ': ' + $p.Why + '; ignored.'); continue }
        if ($p.Name.ToLowerInvariant() -eq 'rcon.password') { $password = $p.Value }
        else { Say ('hotwire-secrets.cfg line ' + $n + ': ' + $p.Name + ': only rcon.password belongs here; ignored.') }
    }
    if ($password -eq '') { return @{ Why = 'hotwire-secrets.cfg does not set rcon.password.' } }
    if ($password -eq 'change_me') { return @{ Why = "rcon.password is still the example 'change_me'. Set a real one in hotwire-secrets.cfg." } }
    if ($password.Length -lt $minimum) { return @{ Why = ('rcon.password is shorter than hotwire.rcon_password_min (' + $minimum + ').') } }
    return @{ Password = $password }
}

# The server's argument list, without the password and the log file, which the start adds.
function Get-ServerArgs($r) {
    $a = New-Object 'System.Collections.Generic.List[string]'
    $a.Add('-batchmode'); $a.Add('-nographics')
    $add = { param($name, $value) if ($value -ne '') { $a.Add('+' + $name); $a.Add($value) } }
    & $add 'server.identity' (Get-CvValue $r 'server.identity')
    $levelUrl = Get-CvValue $r 'server.levelurl'
    if ($levelUrl -ne '') { & $add 'server.levelurl' $levelUrl }
    else {
        & $add 'server.level' (Get-CvValue $r 'server.level')
        & $add 'server.seed' (Get-CvValue $r 'server.seed')
        & $add 'server.worldsize' (Get-CvValue $r 'server.worldsize')
    }
    foreach ($k in 'server.port', 'server.queryport', 'rcon.port', 'server.maxplayers', 'server.hostname', 'server.description', 'server.tags', 'rcon.web') {
        & $add $k (Get-CvValue $r $k)
    }
    foreach ($k in $r.Extra.Keys) { & $add $r.Extra[$k][0] $r.Extra[$k][1] }
    return ,$a
}

# One argument as Windows programs split a command line: quoted when it has a space, with backslashes doubled
# only where they come before a quote.
function Format-Arg([string]$arg) {
    if ($arg -ne '' -and $arg -notmatch '[\s"]') { return $arg }
    $out = New-Object Text.StringBuilder
    [void]$out.Append('"'); $slashes = 0
    foreach ($ch in $arg.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$out.Append('\' * ($slashes * 2 + 1)); [void]$out.Append('"') }
        else { [void]$out.Append('\' * $slashes); [void]$out.Append($ch) }
        $slashes = 0
    }
    [void]$out.Append('\' * ($slashes * 2)); [void]$out.Append('"')
    return $out.ToString()
}

# ---- load ----------------------------------------------------------------------------------------------------
function Invoke-Load {
    $first = $env:HOTWIRE_FIRST -eq '1'
    $quiet = $env:HOTWIRE_QUIET -eq '1'
    $r = Read-Config
    if ($r.Fatal.Count -gt 0) {
        if ($first) {
            Rule
            if ($r.Missing) {
                Say ('No hotwire.cfg beside the launcher (' + $cfg + ').')
                Say '  A new server: copy hotwire.example.cfg to hotwire.cfg and fill in sections 1 and 2.'
                Say '  A server you already run: the start-script converter at https://afkpanel.com/get-started'
                Say '  makes one from your old start script.'
                Say '  Hotwire does not start without it: on the defaults it would open an empty save folder,'
                Say '  which looks like a wipe.'
            } else {
                Say 'hotwire.cfg has settings that would change which server this is, so it does not start:'
                foreach ($f in $r.Fatal) { Say ('  ' + $f) }
            }
            Rule
            Write-Output 'HWSET HW_LOAD=fatal'
        } else {
            Rule
            Say 'hotwire.cfg changed and is not usable now; starting with the settings from the last start:'
            foreach ($f in $r.Fatal) { Say ('  ' + $f) }
            Rule
            Write-Output 'HWSET HW_LOAD=kept'
        }
        return
    }

    $minimum = [int](Get-HwValue $r 'hotwire.rcon_password_min')
    $secret = Read-Secret $minimum
    if ($secret.Why) {
        Rule
        if ($first) { Say $secret.Why; Rule; Write-Output 'HWSET HW_LOAD=fatal'; return }
        Say ($secret.Why + ' Starting with the settings from the last start.'); Rule
        Write-Output 'HWSET HW_LOAD=kept'
        return
    }

    if (-not $quiet) {
        if ($first -or $env:CHECK_ONLY) {
            if ($r.Problems.Count -eq 0) { Say 'hotwire.cfg read: every line is a setting.' }
            else {
                Say ('hotwire.cfg: ' + $r.Problems.Count + ' line(s) not used:')
                foreach ($p in $r.Problems) { Say ('  ' + $p) }
            }
        } elseif ($r.Problems.Count -gt 0) {
            Say ('hotwire.cfg: ' + $r.Problems.Count + ' line(s) not used; hotwire.bat check lists them.')
        }
        # The option check: a convar name that is not in hotwire.cfg's own list is probably misspelled. A warning,
        # never a stop: Rust ignores a name it does not know, and the list is not every convar Rust has.
        if ((Get-HwValue $r 'hotwire.check_options') -eq '0') { Say 'Option check skipped (hotwire.check_options 0).' }
        elseif ($r.Unknown.Count -eq 0) { Say 'Options look right.' }
        else { foreach ($u in $r.Unknown) { Say ($u + " is not in hotwire.cfg's list of convars. Is it spelled right?") } }
    }

    # The argument list for the start. Check mode changes nothing, this file included.
    if (-not $env:CHECK_ONLY) {
        $folder = Split-Path -Parent $argsFile
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Force -Path $folder) }
        [IO.File]::WriteAllText($argsFile, (ConvertTo-Json -InputObject ([string[]](Get-ServerArgs $r)) -Compress))
    }
    foreach ($key in $hwSettings.Keys) { Write-Output ('HWSET ' + $hwSettings[$key][0] + '=' + (Get-HwValue $r $key)) }
    # The password stays in this process's environment, where the old launcher kept it too, in base64 so cmd
    # handles only letters, digits, + / and =.
    Write-Output ('HWSET HOTWIRE_RCON64=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($secret.Password)))
    Write-Output 'HWSET HW_LOAD=ok'
}

# ---- edits ---------------------------------------------------------------------------------------------------
# Set-CfgValues: write settings into hotwire.cfg in one pass. The line that sets each is changed where it is; a
# setting that is off in the list (#name value) is switched on in its place; anything else is added at the end.
# A value is written in double quotes when it has spaces or is empty. The caller has already checked every name
# and value; a double quote or a control character never reaches here. The file is written whole beside the old
# one and swapped into place, keeping its permissions. Returns $true when written.
function Set-CfgValues([object[]]$pairs) {
    try {
        if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { return $false }
        $bytes = [IO.File]::ReadAllBytes($cfg)
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes)
        if ($bom) { $text = $text.Substring(1) }
        $eol = "`n"; if ($text.Contains("`r`n")) { $eol = "`r`n" }
        $lines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($l in ($text -split "`r?`n")) { $lines.Add($l) }
        foreach ($pair in $pairs) {
            $name = [string]$pair[0]; $value = [string]$pair[1]; $want = $name.ToLowerInvariant()
            $shown = $value; if ($value -eq '' -or $value -match '\s') { $shown = '"' + $value + '"' }
            $new = '{0,-27} {1}' -f $name, $shown
            $done = -1; $off = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $first = ($lines[$i].TrimStart() -split '[ \t]+')[0]
                if ($first.ToLowerInvariant() -eq $want) { $done = $i; break }
                if ($off -lt 0 -and $first.StartsWith('#') -and $first.Substring(1).ToLowerInvariant() -eq $want) { $off = $i }
            }
            $at = $done; if ($at -lt 0) { $at = $off }
            if ($at -ge 0) { $lines[$at] = $new }
            elseif ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.Insert($lines.Count - 1, $new) }
            else { $lines.Add($new) }
        }
        $out = [string]::Join($eol, $lines)
        $tmp = Join-Path $root ('.hotwire.cfg.' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($tmp, $out, (New-Object Text.UTF8Encoding($bom)))
        # [NullString]::Value, because PowerShell hands a .NET string parameter '' for $null.
        [IO.File]::Replace($tmp, $cfg, [NullString]::Value)
        return $true
    } catch {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Say ('Could not write hotwire.cfg: ' + $_.Exception.Message)
        return $false
    }
}

# True when a forced wipe must wait: the installed build is unreadable, or it is the build the wipe was armed on
# (no update yet). Writes WIPE.result so the plugin knows to try again.
function Test-ForcedWipeWaits {
    param([string]$armedBuild, [string]$cycle, [string]$result)
    $appid = $env:APPID; if (-not $appid) { $appid = '258550' }
    $acf = Join-Path $root ('steamapps\appmanifest_' + $appid + '.acf')
    $installed = ''
    if (Test-Path -LiteralPath $acf) {
        $q = [char]34
        $m = [regex]::Match([IO.File]::ReadAllText($acf), $q + 'buildid' + $q + '\s+' + $q + '(\d+)' + $q)
        if ($m.Success) { $installed = $m.Groups[1].Value }
    }
    if (-not $installed) {
        Say ('Forced wipe (cycle ' + $cycle + '): the installed build cannot be read, so the wipe waits. Starting unchanged.')
        [IO.File]::WriteAllText($result, "deferred: installed build unknown`n")
        return $true
    }
    if ($armedBuild -and $installed -eq $armedBuild) {
        Say ('Forced wipe (cycle ' + $cycle + '): still build ' + $installed + ', no update yet. Starting the old world; the wipe waits.')
        [IO.File]::WriteAllText($result, 'deferred: no new build (installed ' + $installed + ")`n")
        return $true
    }
    Say ('Forced wipe (cycle ' + $cycle + '): build ' + $armedBuild + ' -> ' + $installed + ', the update arrived.')
    return $false
}

function Invoke-Edits {
    $wipeName = $env:WIPE_FLAG; if (-not $wipeName) { $wipeName = 'WIPE.flag' }

    # ---- Wipe (capability: wipe) -------------------------------------------------------------------------
    # A wipe is a restart with a flag. The new seed (and size) is written into hotwire.cfg, Rust finds no save by
    # that name and generates a new world, and the old save is left on disk. Every value is checked here before
    # anything is written or deleted, a stale flag or one already carried out never fires, and if the seed cannot
    # be written the wipe is cancelled and the server starts unchanged.
    $flag = Join-Path $root $wipeName
    $result = Join-Path $root 'WIPE.result'
    $cycleFile = Join-Path $root 'hotwire\wipe-cycle'
    if (Test-Path -LiteralPath $flag) {
        $w = @{}
        foreach ($l in [IO.File]::ReadAllLines($flag)) {
            $parts = $l.Trim().Split(' ', 2)
            if ($parts.Count -eq 2 -and -not $w.ContainsKey($parts[0])) { $w[$parts[0]] = $parts[1].Trim() }
        }
        $seed = [string]$w['seed']; $size = [string]$w['size']; $bp = [string]$w['blueprints']; $cycle = [string]$w['cycle']; $expires = [string]$w['expires']
        $forced = [string]$w['forced']; $armedBuild = [string]$w['armed_build']
        if (-not $bp) { $bp = 'keep' }
        $done = ''
        if ($cycle -and (Test-Path -LiteralPath $cycleFile)) { $done = ([IO.File]::ReadAllText($cycleFile)).Trim() }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $why = ''
        if ($cycle -and $done -eq $cycle) {
            Remove-Item -LiteralPath $flag -Force
            Say ('Wipe for cycle ' + $cycle + ' already done; ignoring the flag.')
        } elseif ($expires -match '^\d+$' -and [long]$expires -lt $now) {
            Remove-Item -LiteralPath $flag -Force
            Say 'The wipe flag has expired; ignoring it. Starting unchanged.'
        } elseif ($forced -eq '1' -and (Test-ForcedWipeWaits $armedBuild $cycle $result)) {
            # A forced wipe rides the monthly update: applied only in a start whose update changed the installed
            # build. The flag stays for the next start inside its window; the plugin tries again.
        } else {
            if ($seed -notmatch '^\d{1,10}$' -or [long]$seed -gt 2147483647) { $why = 'seed is not a whole number from 0 to 2147483647' }
            elseif ($size -and ($size -notmatch '^\d{1,5}$' -or [int]$size -lt 1000 -or [int]$size -gt 6000)) { $why = 'size is not a whole number from 1000 to 6000' }
            elseif ('keep', 'rename', 'delete' -notcontains $bp) { $why = 'blueprints must be keep, rename or delete' }
            if (-not $why) {
                $pairs = @(, @('server.seed', $seed))
                if ($size) { $pairs += , @('server.worldsize', $size) }
                if (-not (Set-CfgValues $pairs)) { $why = 'could not write the new seed' }
            }
            if ($why) {
                Rule; Say ('Wipe CANCELLED: ' + $why + '. Starting unchanged.'); Rule
                [IO.File]::WriteAllText($result, 'cancelled: ' + $why + "`n")
                Remove-Item -LiteralPath $flag -Force
            } else {
                # Blueprints, in the save folder. Matched by pattern: the version in the name changes between builds.
                # player.tokens.db and everything else is left alone.
                $identity = [string](Read-Config).Values['server.identity']
                if (-not $identity) { $identity = 'my_server_identity' }
                $count = 0
                $folder = Join-Path $root ('server\' + $identity)
                if ($bp -ne 'keep' -and (Test-Path -LiteralPath $folder)) {
                    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter 'player.blueprints.*.db' -File)) {
                        if ($bp -eq 'delete') { Remove-Item -LiteralPath $f.FullName -Force }
                        else { Rename-Item -LiteralPath $f.FullName -NewName ($f.Name + '.wiped-' + $stamp) }
                        $count++
                    }
                }
                # The cycle is recorded and the flag cleared last, so a crash part-way re-runs the wipe safely.
                if ($cycle) {
                    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cycleFile))
                    [IO.File]::WriteAllText($cycleFile, $cycle)
                }
                Remove-Item -LiteralPath $flag -Force
                $sizeText = 'unchanged'; if ($size) { $sizeText = $size }
                $bpText = 'kept'; if ($bp -ne 'keep') { $bpText = $bp + ' (' + $count + ' file(s))' }
                [IO.File]::WriteAllText($result, 'applied: seed ' + $seed + ' size ' + $sizeText + ' blueprints ' + $bpText + "`n")
                Say ('Wipe applied: seed ' + $seed + ', size ' + $sizeText + ', blueprints ' + $bpText + '. The new world generates on this start; the old save is left on disk.')
            }
        }
    }

    # ---- Permanent convars (capability: convar_persist) -----------------------------------------------------
    # CONVAR.request holds one "<convar> <value>" per line. It is a typed set, never a console passthrough: the
    # name must be a dotted convar and the value carries no double quote or control character. The map-defining
    # convars and rcon.password are refused (they belong to wipe and the secrets file), hotwire.* is refused (the
    # launcher's own settings are the admin's), and a convar the launcher reads itself must pass that setting's
    # own check.
    $request = Join-Path $root 'CONVAR.request'
    if (Test-Path -LiteralPath $request) {
        $log = New-Object 'System.Collections.Generic.List[string]'
        foreach ($l in [IO.File]::ReadAllLines($request)) {
            if ($l -eq '') { continue }
            $parts = $l.Split(' ', 2)
            $name = $parts[0]; $value = $null
            if ($parts.Count -eq 2) { $value = $parts[1] }
            $why = ''
            if ($name -cnotmatch '^[a-z][a-z0-9]*(\.[a-z0-9_]+)+$') { $why = 'not a dotted convar name' }
            elseif ($name.StartsWith('hotwire.')) { $why = 'a launcher setting, never set through the panel' }
            elseif ('server.seed', 'server.worldsize', 'server.level', 'server.levelurl' -contains $name) { $why = 'map-defining, belongs to wipe not the convar editor' }
            elseif ($name -eq 'rcon.password') { $why = 'a secret, never set through the panel' }
            elseif ($null -eq $value -or $value -match '[\x00-\x1F\x7F]') { $why = 'missing or non-printable value' }
            elseif ($value.Contains('"')) { $why = 'value has a double quote' }
            elseif ($value.Length -gt 1024) { $why = 'value longer than 1024 characters' }
            elseif ($cvSettings.ContainsKey($name)) { $why = Test-CfgValue $cvSettings[$name][0] $value }
            if (-not $why -and -not (Set-CfgValues @(, @($name, $value)))) { $why = 'could not write settings' }
            if ($why) { $log.Add('reject ' + $name + ' : ' + $why) } else { $log.Add('applied ' + $name + ' ' + $value) }
        }
        [IO.File]::WriteAllText((Join-Path $root 'CONVAR.result'), (($log -join "`n") + "`n"))
        Remove-Item -LiteralPath $request -Force
        $applied = @($log | Where-Object { $_.StartsWith('applied ') }).Count
        Say ('Convar persist: applied ' + $applied + ', rejected ' + ($log.Count - $applied) + ' (details in CONVAR.result).')
    }
}

# ---- launch --------------------------------------------------------------------------------------------------
# The arguments reach RustDedicated.exe as one command line built here, never through cmd, so no character in a
# value can become a command.
function Invoke-Launch {
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in (ConvertFrom-Json ([IO.File]::ReadAllText($argsFile)))) { $list.Add([string]$a) }
    $password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$env:HOTWIRE_RCON64))
    $list.Add('+rcon.password'); $list.Add($password)
    $list.Add('-logfile'); $list.Add([string]$env:LOGFILE)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $root 'RustDedicated.exe'
    $psi.Arguments = [string]::Join(' ', @($list | ForEach-Object { Format-Arg $_ }))
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    # The server does not need the password in its environment: it has it on its command line.
    [void]$psi.EnvironmentVariables.Remove('HOTWIRE_RCON64')
    $p = [Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    exit $p.ExitCode
}

try {
    switch ($env:HOTWIRE_MODE) {
        'load'   { Invoke-Load }
        'edits'  { Invoke-Edits }
        'launch' { Invoke-Launch }
        default  { Say ('Unknown HOTWIRE_MODE ' + $env:HOTWIRE_MODE); exit 2 }
    }
} catch {
    Say ('hotwire.bat (' + $env:HOTWIRE_MODE + '): ' + $_.Exception.Message)
    exit 1
}
exit 0
