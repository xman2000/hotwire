@echo off
setlocal EnableDelayedExpansion

REM ==[ H O T W I R E ]===================================================
REM  Hotwire launcher for Windows. Version: HOTWIRE_LAUNCHER_VERSION below.
REM  Built by xman2000 and Claude.  MIT License.
REM  https://github.com/xman2000/hotwire
REM
REM  Settings are in hotwire.cfg and the RCON password in
REM  hotwire-secrets.cfg, both beside this file. This file and hotwire.ps1
REM  hold no settings, so replacing them with a newer release keeps yours.
REM
REM  Replace hotwire.bat and hotwire.ps1 together, from the same release,
REM  and only with this window closed: cmd reads this file while it runs,
REM  and a file changed under it runs half of one version and half of the
REM  other.
REM
REM  Usage:
REM    hotwire.bat          start the server, and restart it when it exits
REM    hotwire.bat check    check the settings and report; start nothing
REM ======================================================================

REM  Check mode reads hotwire.cfg, reports what is wrong and exits. It asks
REM  Steam for the current build but installs and starts nothing.
set "CHECK_ONLY="
if /i "%~1"=="check" set "CHECK_ONLY=1"

REM  Not settings; do not edit. Written to oxide\data\Hotwire\launcher.json
REM  before every start, with this file's code hash (HOTWIRE_LAUNCHER_HASH,
REM  near the end). The plugin offers only the features in the capability
REM  list; settings_file means the settings come from hotwire.cfg. AFKPanel
REM  shows whether the hash matches a release, and nothing depends on it.
set "HOTWIRE_LAUNCHER_VERSION=1.1.23"
set "HOTWIRE_LAUNCHER_CAPABILITIES=supervise,update,framework_verify,crash_backstop,log_rotate,convar_persist,wipe,backup,settings_file"
echo [%date% %time%] Hotwire launcher %HOTWIRE_LAUNCHER_VERSION% (Windows)

REM ======================================================================
REM  HOW THIS LAUNCHER WORKS
REM ======================================================================
REM
REM  REQUIREMENTS
REM     Windows, SteamCMD and a Rust dedicated server. PowerShell and curl,
REM     both included in Windows 10 and later, read the settings, work out
REM     dates and download files. The Hotwire plugin is optional.
REM
REM  SETUP
REM     1.  Copy hotwire.example.cfg to hotwire.cfg and fill in sections 1
REM         and 2.
REM     2.  Copy hotwire-secrets.example.cfg to hotwire-secrets.cfg and set
REM         the RCON password.
REM     3.  Put hotwire.bat and hotwire.ps1 in the same folder as
REM         RustDedicated.exe. The launcher treats its own folder as the
REM         server folder.
REM     4.  Run "hotwire.bat check", then "hotwire.bat". Leave the window
REM         open.
REM
REM  SETTINGS
REM     hotwire.cfg and hotwire-secrets.cfg are read as "name value" lines
REM     and never run as commands. A line that is not a setting is ignored,
REM     and "hotwire.bat check" lists it. Values reach Rust as separate
REM     arguments and never pass through cmd, so a server name can hold any
REM     character. hotwire.cfg is read before every start, so an edit takes
REM     effect at the next restart. The start-script converter on
REM     afkpanel.com builds a hotwire.cfg from an old start script; it never
REM     writes code.
REM
REM  HOOKS
REM     Your own commands go in hotwire-before.bat, which runs before every
REM     start, and hotwire-after.bat, which runs after an update. Both sit
REM     beside this file; start from the .example copies. If a hook fails,
REM     the launcher logs it and starts the server anyway. Check mode runs
REM     no hooks.
REM
REM  RESTARTS
REM     The launcher stays open while the server runs. When the server
REM     exits, the launcher waits hotwire.restart_delay seconds and starts
REM     it again. Close this window to stop the server for good.
REM
REM  UPDATE MODES
REM     Set hotwire.update_mode in hotwire.cfg:
REM
REM     auto       The default. Works as hotwire while the plugin has an
REM                update scheduled, and as always otherwise. The plugin
REM                keeps UPDATE.schedule current in the server folder, so
REM                turning on an update schedule in the plugin is enough.
REM
REM     always     Update Rust and Oxide on every start, like most Rust
REM                launchers.
REM
REM     hotwire    Update Rust and Oxide only when one of these is true:
REM                  - UPDATE.flag or VALIDATE.flag is in the server folder
REM                  - Steam has a newer build (hotwire.update_on_new_build)
REM                  - the launcher cannot tell whether Steam has one
REM                  - the backstop below is due
REM                A flag is deleted only after its update completes. Any
REM                other restart starts the server without updating.
REM
REM     off        Never update. Flag files are left in place and reported.
REM
REM     To create a flag by hand, in the server folder:
REM       New-Item -ItemType File UPDATE.flag
REM
REM     The backstop: in hotwire mode, if hotwire.max_days_without_update
REM     days pass with no update, the next start updates. Rust clients
REM     update themselves, and a server left on an old build refuses them.
REM
REM  SEVERAL SERVERS ON ONE MACHINE
REM     Give each server its own folder, its own copy of this file and of
REM     hotwire.cfg, and its own ports. They can share one SteamCMD: one
REM     server uses it at a time while the others wait. A whole server
REM     folder can be copied, because the launcher works on its own folder,
REM     but change the ports in the copy before starting it.
REM
REM  PLUGIN
REM     Optional: plugin\Hotwire.cs at the address above. It schedules
REM     restarts, warns players with a countdown, and writes UPDATE.flag
REM     when a scheduled restart includes an update. The plugin and the
REM     launcher talk only through files in the server folder:
REM       from the plugin    UPDATE.flag, VALIDATE.flag, UPDATE.schedule,
REM                          WIPE.flag, CONVAR.request, BACKUP.flag
REM       from the launcher  oxide\data\Hotwire\launcher.json,
REM                          WIPE.result, CONVAR.result, backup results
REM     Each works without the other.
REM
REM  DEFAULTS
REM     The defaults in hotwire.example.cfg were read from a Rust build, not
REM     copied from documentation. The launcher sets only what the server
REM     cannot run without, and the ports, which must match the firewall.
REM     Everything else keeps the game's default until you change it.
REM ======================================================================

REM ------------------------------------------------ fixed, not settings ----
REM  Download sources are fixed here and never read from hotwire.cfg:
REM  other tools may write that file, and a data file must not decide what
REM  is downloaded or run. The server folder is this file's folder, so a
REM  copied server folder brings its launcher with it.
set "ROOT=%~dp0"
if "!ROOT:~-1!"=="\" set "ROOT=!ROOT:~0,-1!"
set "APPID=258550"
set "UPDATE_FLAG=UPDATE.flag"
set "VALIDATE_FLAG=VALIDATE.flag"
set "WIPE_FLAG=WIPE.flag"
set "FRAMEWORK_VERSION_FILE=%ROOT%\RustDedicated_Data\Managed\Oxide.Rust.dll"
set "FRAMEWORK_URL=https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust.zip"
set "FRAMEWORK_RELEASES=https://api.github.com/repos/OxideMod/Oxide.Rust/releases/latest"
set "FRAMEWORK_ASSET=Oxide.Rust.zip"
set "LOGFILE=%ROOT%\logs\server_log.txt"
set "UPDATE_STAMP=%ROOT%\logs\last_update.txt"
set "HOOK_BEFORE=%ROOT%\hotwire-before.bat"
set "HOOK_AFTER=%ROOT%\hotwire-after.bat"
set "HOTWIRE_SELF=%~f0"

REM  hotwire.ps1 holds the launcher's PowerShell. It runs as a file for each
REM  step, and HOTWIRE_MODE picks the part; the parts are listed at its top.
REM  It is a separate file because antivirus software can block PowerShell
REM  that a script reads out of a file and runs as text.
set "HW_PS1=%ROOT%\hotwire.ps1"

REM  Consecutive crashes. Set before :start so the count carries over from
REM  one restart to the next.
set /a CRASH_STREAK=0

REM  Without RustDedicated.exe the server cannot start, whatever the
REM  settings say, so stop here and say why.
if not exist "%ROOT%\RustDedicated.exe" (
    echo [%date% %time%] ================================================
    echo [%date% %time%] No RustDedicated.exe in:
    echo [%date% %time%]   !ROOT!
    echo [%date% %time%] hotwire.bat must be in the same folder as
    echo [%date% %time%] RustDedicated.exe. If it is, Rust is not fully installed.
    echo [%date% %time%] ================================================
    pause & exit /b 1
)

cd /d "%ROOT%" || (echo Cannot open the folder !ROOT! & pause & exit /b 1)
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs" >nul 2>&1
if not exist "%ROOT%\logs" (
    echo [%date% %time%] ================================================
    echo [%date% %time%] Cannot create !ROOT!\logs
    echo [%date% %time%] Old server logs and the update stamp are kept there.
    echo [%date% %time%] Without it, a crash leaves no log to read and the
    echo [%date% %time%] update backstop never runs.
    echo [%date% %time%] Check the permissions on the server folder.
    echo [%date% %time%] ================================================
    pause & exit /b 1
)

REM  On the first read of hotwire.cfg, a missing file or a bad save folder,
REM  map or port stops the launcher with the reason. Later reads keep the
REM  last good settings instead.
set "HOTWIRE_FIRST=1"


:start
REM  What this start did, for the session report sent after the run.
set "UPDATE_ATTEMPTED=0"
set "STEAM_OK=0"
set "FRAMEWORK_OK=0"

REM ======================================================================
REM  READ hotwire.cfg AND hotwire-secrets.cfg
REM
REM     PowerShell reads both files as data and checks every line. cmd
REM     receives only the launcher's own settings, each checked to be a
REM     number, a word or a path with nothing cmd treats as syntax. The
REM     server's settings and the RCON password never pass through cmd:
REM     PowerShell keeps them for the start (see LAUNCH).
REM ======================================================================
call :hotwire_load
if "!HW_LOAD!"=="missing" goto :partproblem
if "!HW_LOAD!"=="mismatch" goto :partproblem
if defined HOTWIRE_FIRST if not "!HW_LOAD!"=="ok" (
    if not defined HW_LOAD echo [%date% %time%] Could not read the settings: hotwire.ps1 gave no answer.
    if not defined HW_LOAD echo [%date% %time%] If an antivirus blocked it, its protection history shows the block.
    echo [%date% %time%] Not starting.
    pause & exit /b 1
)
set "HOTWIRE_FIRST="

REM  The branch named in messages. Empty lets Steam choose, which is public
REM  on a new install.
set "BRANCH_NAME=%STEAM_BRANCH%"
if not defined BRANCH_NAME set "BRANCH_NAME=public"


REM  Who decides updates on this start. In auto mode the Hotwire plugin
REM  rewrites UPDATE.schedule in the server folder every 15 minutes while it
REM  has an update scheduled. If that file is missing, over two hours old or
REM  unreadable, nothing is scheduling updates, so this start updates as in
REM  always mode, which keeps the server joinable.
set "UPDATE_EFFECTIVE=%UPDATE_MODE%"
if /i not "%UPDATE_MODE%"=="auto" goto :updatemodeknown
set "UPDATE_EFFECTIVE=always"
set "HOTWIRE_MARKER=%ROOT%\UPDATE.schedule"
for /f %%m in ('powershell -NoProfile -NonInteractive -Command "$f=$env:HOTWIRE_MARKER; if((Test-Path -LiteralPath $f) -and (((Get-Date)-(Get-Item -LiteralPath $f).LastWriteTime).TotalHours -lt 2)){'fresh'}else{'none'}"') do if "%%m"=="fresh" set "UPDATE_EFFECTIVE=hotwire"
set "HOTWIRE_MARKER="
if /i "!UPDATE_EFFECTIVE!"=="hotwire" echo [%date% %time%] hotwire.update_mode is auto: the Hotwire plugin schedules updates.
if /i "!UPDATE_EFFECTIVE!"=="always" echo [%date% %time%] hotwire.update_mode is auto, and the Hotwire plugin has no update schedule.
:updatemodeknown

REM ======================================================================
REM  INSTALLED BUILD AND STEAM'S BUILD
REM
REM     Steam reports the current Rust build and steamapps\appmanifest holds
REM     the installed one. Comparing them shows whether this server is
REM     behind, without installing anything.
REM
REM     Asking costs one SteamCMD run, so the answer is cached for
REM     hotwire.build_check_hours and a crash loop does not ask on every
REM     restart.
REM
REM     buildid also appears under every depot, so the parser finds
REM     "branches", then the branch, then the buildid inside it. The first
REM     buildid in the file belongs to a depot and is the wrong number.
REM
REM     If another server is using SteamCMD, this check is skipped for this
REM     start instead of waiting. A due update still waits its turn below.
REM
REM     If anything here fails, such as no SteamCMD, no answer from Steam or
REM     a hang, both builds are unknown and the usual rules apply.
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
REM  When flags decide updates, the answer must be current: a cached answer
REM  from before a Rust release would start the old build. The cache is
REM  used only during a crash streak.
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
    echo [%date% %time%]   !ROOT!\steamapps\appmanifest_%APPID%.acf
) else if not defined PUBLIC_BUILD (
    echo [%date% %time%] Rust build: installed !INSTALLED_BUILD!. Steam did not
    echo [%date% %time%] answer, so the usual rules apply.
) else if "!INSTALLED_BUILD!"=="!PUBLIC_BUILD!" (
    echo [%date% %time%] Rust build: installed !INSTALLED_BUILD!, !BRANCH_NAME! !PUBLIC_BUILD!. Up to date.
) else if !INSTALLED_BUILD! GTR !PUBLIC_BUILD! (
    echo [%date% %time%] Rust build: installed !INSTALLED_BUILD!, !BRANCH_NAME! !PUBLIC_BUILD!. This
    echo [%date% %time%] server is newer than Steam's !BRANCH_NAME! branch, so it is on
    echo [%date% %time%] another branch, such as staging. The next update moves
    echo [%date% %time%] it to !BRANCH_NAME!, as hotwire.steam_branch says.
) else (
    echo [%date% %time%] ================================================
    echo [%date% %time%] Rust build: installed !INSTALLED_BUILD!
    echo [%date% %time%]             !BRANCH_NAME!    !PUBLIC_BUILD!
    echo [%date% %time%] A NEWER BUILD IS AVAILABLE.
    echo [%date% %time%] Players' games update themselves, so once the new
    echo [%date% %time%] build changes the protocol, this server turns them away.
    REM  Say what this update mode does next.
    set "HW_NEWER=updates"
    if /i "!UPDATE_EFFECTIVE!"=="off" set "HW_NEWER=off"
    if /i "!UPDATE_EFFECTIVE!"=="hotwire" if not "%UPDATE_ON_NEW_BUILD%"=="1" set "HW_NEWER=flag"
    if "!HW_NEWER!"=="updates" echo [%date% %time%] A normal start updates the server before starting it.
    if "!HW_NEWER!"=="off" echo [%date% %time%] hotwire.update_mode is off, so the launcher does not update it.
    if "!HW_NEWER!"=="flag" echo [%date% %time%] Create %UPDATE_FLAG% in !ROOT! to update on the next start.
    set "HW_NEWER="
    echo [%date% %time%] ================================================
)

:buildcheckdone


REM ======================================================================
REM  UPDATE OR PLAIN RESTART
REM
REM     UPDATE.flag     Update Rust with SteamCMD, then Oxide, then start.
REM     VALIDATE.flag   The same, and SteamCMD also checks every file of
REM                     the install. Slow: use it weekly at most, or after
REM                     a crash.
REM
REM     You, a scheduled task, or the plugin when a scheduled update is due
REM     can create either flag. In update mode off they are ignored.
REM
REM       New-Item -ItemType File UPDATE.flag     (in the server folder)
REM ======================================================================

set "DO_UPDATE=0"
set "DO_VALIDATE=0"

if /i "!UPDATE_EFFECTIVE!"=="off" (
    echo [%date% %time%] hotwire.update_mode is off: not updating.
    if exist "%ROOT%\%UPDATE_FLAG%" echo [%date% %time%] %UPDATE_FLAG% is left in place and ignored.
    if exist "%ROOT%\%VALIDATE_FLAG%" echo [%date% %time%] %VALIDATE_FLAG% is left in place and ignored.
    goto :updatedecided
)

if /i "!UPDATE_EFFECTIVE!"=="always" (
    set "DO_UPDATE=1"
    echo [%date% %time%] hotwire.update_mode is %UPDATE_MODE%: updating before the start.
)

if exist "%ROOT%\%UPDATE_FLAG%" (
    set "DO_UPDATE=1"
    echo [%date% %time%] %UPDATE_FLAG% found: updating before the start.
)
if exist "%ROOT%\%VALIDATE_FLAG%" (
    set "DO_UPDATE=1"
    set "DO_VALIDATE=1"
    echo [%date% %time%] %VALIDATE_FLAG% found: updating and checking every file.
)

REM  The backstop runs only in hotwire mode, only when nothing else asked
REM  for an update, and never when set to 0. A missing stamp counts as no
REM  update ever, so a new install updates on its first start instead of
REM  waiting out the backstop.
if /i "!UPDATE_EFFECTIVE!"=="always" goto :updatedecided
if "%DO_UPDATE%"=="1" goto :updatedecided
REM  A newer build on Steam is checked before the day count: a server that
REM  is behind updates now, and one that is current is left alone however
REM  long it has been.
if not "%UPDATE_ON_NEW_BUILD%"=="1" goto :nobuildtrigger
if not defined INSTALLED_BUILD goto :buildunknown
if not defined PUBLIC_BUILD goto :buildunknown
if "!INSTALLED_BUILD!"=="!PUBLIC_BUILD!" goto :nobuildtrigger
REM  Behind means Steam's build is higher. A server on a newer build than
REM  Steam's, as on a test branch, is not behind; updating it on every start
REM  would only run SteamCMD for nothing.
if !INSTALLED_BUILD! GTR !PUBLIC_BUILD! goto :nobuildtrigger
set "DO_UPDATE=1"
echo [%date% %time%] Updating: installed build !INSTALLED_BUILD! is behind
echo [%date% %time%] Steam's !PUBLIC_BUILD!.
goto :updatedecided
:buildunknown
REM  Unknown is not the same as current. A server left on an old build turns
REM  every player away after a Rust release, so when the build cannot be
REM  checked, the launcher updates.
set "DO_UPDATE=1"
echo [%date% %time%] Updating: could not check whether this install has
echo [%date% %time%] Steam's current build.
goto :updatedecided
:nobuildtrigger

if "%MAX_DAYS_WITHOUT_UPDATE%"=="0" goto :updatedecided

set "DAYS_SINCE_UPDATE=9999"
REM  Round down: [int] rounds to the nearest day, so 13.6 days would trigger
REM  a 14-day backstop half a day early. The path goes through an environment
REM  variable, so an apostrophe in a folder name, such as C:\Rob's server,
REM  cannot break the PowerShell command or inject into it.
set "HOTWIRE_STAMP=%UPDATE_STAMP%"
if exist "%UPDATE_STAMP%" for /f %%d in ('powershell -NoProfile -Command "[math]::Floor(((Get-Date) - (Get-Item -LiteralPath $env:HOTWIRE_STAMP).LastWriteTime).TotalDays)"') do set "DAYS_SINCE_UPDATE=%%d"
set "HOTWIRE_STAMP="

if !DAYS_SINCE_UPDATE! GEQ %MAX_DAYS_WITHOUT_UPDATE% (
    set "DO_UPDATE=1"
    echo [%date% %time%] ================================================
    echo [%date% %time%] No update in !DAYS_SINCE_UPDATE! days: updating now.
    echo [%date% %time%] A server that never updates turns players away after
    echo [%date% %time%] a Rust release. To update on a schedule instead, set
    echo [%date% %time%] hotwire.update_mode always in hotwire.cfg, or schedule
    echo [%date% %time%] updates in the plugin.
    echo [%date% %time%] ================================================
)

:updatedecided

REM  Check mode says what a normal start would do and installs nothing.
if defined CHECK_ONLY if "%DO_UPDATE%"=="1" echo [%date% %time%] Check mode: a normal start would update here. Nothing is installed.
if defined CHECK_ONLY if "%DO_UPDATE%"=="0" echo [%date% %time%] Check mode: a normal start would not update.
if defined CHECK_ONLY set "DO_UPDATE=0"

REM  Back up the stopped server before an update or a wipe changes it.
if not defined CHECK_ONLY call :hotwire_ps backup

REM  hotwire-before.bat runs before every start, ahead of any update, in its
REM  own cmd, so its variables and any exit stay inside it. If it fails, the
REM  launcher says so and starts anyway. Check mode runs no hooks.
if defined CHECK_ONLY goto :hookbeforedone
if not exist "%HOOK_BEFORE%" goto :hookbeforedone
echo [%date% %time%] Running hotwire-before.bat...
cmd /d /c call "%HOOK_BEFORE%"
if errorlevel 1 echo [%date% %time%] hotwire-before.bat failed; starting anyway.
:hookbeforedone

if "%DO_UPDATE%"=="0" (
    if not defined CHECK_ONLY echo [%date% %time%] Restarting without updating Rust or Oxide.
    goto buildargs
)
set "UPDATE_ATTEMPTED=1"

REM  Fast Rust updates. Steam updates a game by patching its files, and
REM  Oxide has replaced some of them, so on a modded server Steam's first try
REM  at a new build fails with "Corrupt game files" (state 0x486). Steam then
REM  marks the install Files Corrupt in steamapps\appmanifest (StateFlags
REM  bit 128), and its next run checks every file and succeeds. Setting that
REM  mark before the first try skips the failed one. Steam does not document
REM  this record, so exactly one line is changed, the change is checked
REM  before it is saved, a copy is kept in hotwire\, and if Steam ignores the
REM  mark the update takes its usual second try (see :steamfailed).
set "PSMARK="
set "PSMARK=!PSMARK!$f=$env:HOTWIRE_ACFPATH; $q=[char]34; $nl=[char]10; if(-not (Test-Path -LiteralPath $f)){ exit 0 }; "
set "PSMARK=!PSMARK!$re='\A\s*'+$q+'StateFlags'+$q+'\s+'+$q+'4'+$q+'\s*\z'; $lines=[IO.File]::ReadAllText($f).Split($nl); $hit=@(); "
set "PSMARK=!PSMARK!for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].TrimEnd([char]13) -match $re){ $hit+=$i } }; "
set "PSMARK=!PSMARK!if($hit.Count -ne 1){ Write-Output 'Fast Rust updates: Steam''s install record has an unexpected format, so it is left unchanged.'; exit 0 }; "
set "PSMARK=!PSMARK!$new=[string[]]$lines.Clone(); $new[$hit[0]]=$lines[$hit[0]].Replace($q+'4'+$q, $q+'132'+$q); $tmp=$f+'.hotwire-tmp'; "
set "PSMARK=!PSMARK!try{ [IO.File]::WriteAllText($tmp, [string]::Join($nl, $new)); "
set "PSMARK=!PSMARK!  $back=[IO.File]::ReadAllText($tmp).Split($nl); $diff=0; for($i=0; $i -lt $lines.Length; $i++){ if($back[$i] -ne $lines[$i]){ $diff++ } }; "
set "PSMARK=!PSMARK!  if($back.Length -ne $lines.Length -or $diff -ne 1){ throw 'unexpected' }; "
set "PSMARK=!PSMARK!  $dir=Join-Path $env:HOTWIRE_ROOT 'hotwire'; if(-not (Test-Path -LiteralPath $dir)){ [void](New-Item -ItemType Directory -Path $dir) }; "
set "PSMARK=!PSMARK!  Copy-Item -LiteralPath $f -Destination (Join-Path $dir 'appmanifest-before-update.acf') -Force; [IO.File]::Replace($tmp, $f, [NullString]::Value); "
set "PSMARK=!PSMARK!  Write-Output 'Fast Rust updates: Steam will check every game file before this update, so it finishes in one try.' "
set "PSMARK=!PSMARK!} catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; Write-Output 'Fast Rust updates: Steam''s install record could not be changed, so it is left as it was.' } "
set "PSCORRUPT=$m=[regex]::Match([IO.File]::ReadAllText($env:HOTWIRE_ACFPATH), 'StateFlags'+[char]34+'\s+'+[char]34+'([0-9]+)'); if($m.Success -and ([int64]$m.Groups[1].Value -band 128)){ exit 0 }; exit 1"
set "QUICK_RETRY_USED=0"
set "RECOVERY_USED=0"
REM  A refused update. To patch, SteamCMD needs the file lists of the
REM  installed build. It reads them from its cache and asks Steam only when
REM  they are missing, and Steam refuses an old Rust build's lists to an
REM  anonymous login. Every server using this SteamCMD shares the cache, so
REM  one server's update can leave another, still on the old build, unable
REM  to update. The SteamCMD run below reads what SteamCMD's log gained
REM  during the run and exits 96 when a list for the installed build was
REM  refused. Without Steam's install record, SteamCMD compares the files on
REM  disk with the new build and downloads what differs, so the record is
REM  moved to hotwire\ and the update runs once more. If that fails too and
REM  Steam left no usable record, the old one is put back.
set "PSASIDE=$f=$env:HOTWIRE_ACFPATH; if(-not (Test-Path -LiteralPath $f)){ exit 1 }; $dir=Join-Path $env:HOTWIRE_ROOT 'hotwire'; try{ if(-not (Test-Path -LiteralPath $dir)){ [void](New-Item -ItemType Directory -Path $dir) }; Move-Item -LiteralPath $f -Destination (Join-Path $dir 'appmanifest-refused.acf') -Force; Write-Output 'Steam no longer serves the installed Rust build''s file list, so this update cannot patch it.'; Write-Output 'Setting Steam''s install record aside and updating again: Steam checks the files on disk and downloads what changed.'; exit 0 } catch { exit 1 }"
set "PSSETTLE=$q=[char]34; $saved=Join-Path $env:HOTWIRE_ROOT 'hotwire\appmanifest-refused.acf'; $f=$env:HOTWIRE_ACFPATH; if(-not (Test-Path -LiteralPath $saved)){ exit 0 }; $b=''; if(Test-Path -LiteralPath $f){ $m=[regex]::Match([IO.File]::ReadAllText($f), $q+'buildid'+$q+'\s+'+$q+'([0-9]+)'); if($m.Success){ $b=$m.Groups[1].Value } }; if($b -eq '' -or $b -eq '0'){ Copy-Item -LiteralPath $saved -Destination $f -Force; Write-Output 'The update did not finish. Steam''s install record is restored.' }"
REM  A separate variable: the build check above clears HOTWIRE_ACF when done.
set "HOTWIRE_ACFPATH=%ROOT%\steamapps\appmanifest_%APPID%.acf"
set "HOTWIRE_ROOT=%ROOT%"
if "%FAST_RUST_UPDATES%"=="1" if not "%INSTALL_FRAMEWORK%"=="0" if defined INSTALLED_BUILD if defined PUBLIC_BUILD if !INSTALLED_BUILD! LSS !PUBLIC_BUILD! (
    powershell -NoProfile -NonInteractive -Command "!PSMARK!"
)
set "HOTWIRE_ROOT="

set /a STEAM_TRIES=0

REM  A forced wipe that needs this update. The old build cannot take players
REM  once their game has updated, so SteamCMD is retried for
REM  hotwire.forced_wipe_steam_minutes beyond the usual tries before the
REM  server starts without the update. Applies only when WIPE.flag says
REM  forced, its cycle is not done and it has not expired. 0 means no forced
REM  wipe is waiting.
set "FORCED_DEADLINE=0"
set "FORCED_UNTIL="
if not "%FORCED_WIPE_STEAM_MINUTES%"=="0" if exist "%ROOT%\%WIPE_FLAG%" (
    set "HOTWIRE_WIPEFLAG=%ROOT%\%WIPE_FLAG%"
    set "HOTWIRE_WIPESTATE=%ROOT%\hotwire\wipe-cycle"
    set "HOTWIRE_WIPEMIN=%FORCED_WIPE_STEAM_MINUTES%"
    for /f "tokens=1,2" %%a in ('powershell -NoProfile -NonInteractive -Command "$w=@{}; foreach($l in [IO.File]::ReadAllLines($env:HOTWIRE_WIPEFLAG)){ $p=$l.Trim().Split(' ',2); if($p.Count -eq 2 -and -not $w.ContainsKey($p[0])){ $w[$p[0]]=$p[1].Trim() } }; $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $done=''; if(Test-Path -LiteralPath $env:HOTWIRE_WIPESTATE){ $done=([IO.File]::ReadAllText($env:HOTWIRE_WIPESTATE)).Trim() }; $ok=($w['forced'] -eq '1') -and -not ($w['cycle'] -and $w['cycle'] -eq $done) -and -not ($w['expires'] -match '\A[0-9]+\z' -and [long]$w['expires'] -lt $now); if($ok){ $d=$now+60*[long]$env:HOTWIRE_WIPEMIN; Write-Output ([string]$d+' '+(Get-Date).AddMinutes([long]$env:HOTWIRE_WIPEMIN).ToString('HH:mm')) }"') do (
        set "FORCED_DEADLINE=%%a"
        set "FORCED_UNTIL=%%b"
    )
    set "HOTWIRE_WIPEFLAG="
    set "HOTWIRE_WIPESTATE="
    set "HOTWIRE_WIPEMIN="
)
if not "!FORCED_DEADLINE!"=="0" echo [%date% %time%] A forced wipe needs this update: if SteamCMD fails, it is retried until !FORCED_UNTIL!.
set "STEAM_OK=0"

REM  One SteamCMD run at a time on this machine. Servers can share one
REM  SteamCMD, and two runs at once are not known to be safe, so each run
REM  first opens hotwire-steamcmd.lock beside steamcmd.exe, unshared. Windows
REM  releases an open file when its process ends, however it ends, so a
REM  crash never leaves the lock held. hotwire-setup uses the same lock.
REM  After hotwire.steamcmd_wait_minutes the server starts without the
REM  update, as it does when SteamCMD fails. PowerShell builds the arguments
REM  from environment variables, so a folder name never passes through cmd.
set "PSSTEAM="
set "PSSTEAM=!PSSTEAM!$sc=$env:HOTWIRE_STEAMCMD; $q=[char]34; "
set "PSSTEAM=!PSSTEAM!$a='+force_install_dir '+$q+$env:HOTWIRE_ROOT+$q+' +login anonymous +app_update '+$env:HOTWIRE_APPID; "
set "PSSTEAM=!PSSTEAM!if(-not [string]::IsNullOrWhiteSpace($env:HOTWIRE_STEAMBRANCH)){ $a=$a+' -beta '+$env:HOTWIRE_STEAMBRANCH }; "
set "PSSTEAM=!PSSTEAM!if($env:HOTWIRE_VALIDATE -eq '1'){ $a=$a+' validate' }; $a=$a+' +quit'; "
set "PSSTEAM=!PSSTEAM!$wait=0; [void][int]::TryParse([string]$env:HOTWIRE_STEAMWAIT, [ref]$wait); $deadline=(Get-Date).AddMinutes($wait); "
set "PSSTEAM=!PSSTEAM!$lock=Join-Path (Split-Path -Parent $sc) 'hotwire-steamcmd.lock'; $h=$null; $said=$false; "
set "PSSTEAM=!PSSTEAM!while($null -eq $h){ try{ $h=[IO.File]::Open($lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { "
set "PSSTEAM=!PSSTEAM!  if((Get-Date) -gt $deadline){ Write-Output ('Another server has been using SteamCMD for over '+$wait+' minutes. Not waiting any longer.'); exit 97 }; "
set "PSSTEAM=!PSSTEAM!  if(-not $said){ Write-Output 'Another server is using SteamCMD. Waiting for it to finish...'; $said=$true }; Start-Sleep -Seconds 5 } } "
set "PSSTEAM=!PSSTEAM!try{ $lg=Join-Path (Split-Path -Parent $sc) 'logs\content_log.txt'; $before=0; if(Test-Path -LiteralPath $lg){ $before=(Get-Item -LiteralPath $lg).Length }; "
set "PSSTEAM=!PSSTEAM!  $inst=@(); if($env:HOTWIRE_ACFPATH -and (Test-Path -LiteralPath $env:HOTWIRE_ACFPATH)){ foreach($x in [regex]::Matches([IO.File]::ReadAllText($env:HOTWIRE_ACFPATH), $q+'manifest'+$q+'\s+'+$q+'([0-9]+)'+$q)){ $inst+=$x.Groups[1].Value } }; "
set "PSSTEAM=!PSSTEAM!  $p=Start-Process -FilePath $sc -ArgumentList $a -NoNewWindow -Wait -PassThru; $code=$p.ExitCode; "
set "PSSTEAM=!PSSTEAM!  if($code -ne 0 -and $env:HOTWIRE_RECOVER -eq '1' -and $inst.Count -gt 0 -and (Test-Path -LiteralPath $lg)){ $len=(Get-Item -LiteralPath $lg).Length; if($len -lt $before){ $before=0 }; "
set "PSSTEAM=!PSSTEAM!    if($len -gt $before){ $fs=[IO.File]::Open($lg, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite); try{ [void]$fs.Seek($before, [IO.SeekOrigin]::Begin); $n=[int][Math]::Min($len-$before, 4194304); $buf=New-Object byte[] $n; [void]$fs.Read($buf, 0, $n) } finally { $fs.Dispose() }; "
set "PSSTEAM=!PSSTEAM!      foreach($line in [Text.Encoding]::UTF8.GetString($buf).Split([char]10)){ if($line.Contains('Failed to get manifest request code') -and $line.Contains('Access Denied')){ $mm=[regex]::Match($line, 'Manifest: ([0-9]+)'); if($mm.Success -and ($inst -contains $mm.Groups[1].Value)){ $code=96 } } } } }; "
set "PSSTEAM=!PSSTEAM!  exit $code } finally { $h.Dispose() } "

if not exist "!STEAMCMD!" (
    echo [%date% %time%] SteamCMD is not at !STEAMCMD!. Set hotwire.steamcmd in
    echo [%date% %time%] hotwire.cfg. Starting without updating.
    goto steamsettled
)

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
if "!STEAMEXIT!"=="97" goto steamgaveup
echo [%date% %time%] SteamCMD failed (attempt !STEAM_TRIES! of %MAX_STEAM_TRIES%).
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
if !STEAM_TRIES! LSS %MAX_STEAM_TRIES% goto steamretry
if "!FORCED_DEADLINE!"=="0" goto steamgaveup
set "NOW_EPOCH=0"
for /f %%t in ('powershell -NoProfile -NonInteractive -Command "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()"') do set "NOW_EPOCH=%%t"
if !NOW_EPOCH! GEQ !FORCED_DEADLINE! goto steamgaveup
echo [%date% %time%] A forced wipe needs this update: trying SteamCMD again until !FORCED_UNTIL!.
:steamretry
REM  Once per update: if a try left the install marked Files Corrupt, try
REM  again at once. Steam checks every file on the next run, so waiting
REM  would change nothing.
if "!QUICK_RETRY_USED!"=="1" goto steamwait
if not exist "!HOTWIRE_ACFPATH!" goto steamwait
powershell -NoProfile -NonInteractive -Command "!PSCORRUPT!" >nul 2>&1
if errorlevel 1 goto steamwait
set "QUICK_RETRY_USED=1"
echo [%date% %time%] Steam marked the game files for a full check; trying again now.
goto steamupdate
:steamwait
REM  timeout fails when input is redirected, as under a task scheduler.
REM  Without the ping fallback the retry would run at once, over and over.
set /a PINGWAIT=%STEAM_RETRY_SECONDS%+1
timeout /t %STEAM_RETRY_SECONDS% /nobreak >nul 2>&1
if errorlevel 1 ping -n !PINGWAIT! 127.0.0.1 >nul 2>&1
goto steamupdate

:steamgaveup
echo [%date% %time%] SteamCMD failed. Starting without the update.
if not "!RECOVERY_USED!"=="1" goto steamsettled
set "HOTWIRE_ROOT=%ROOT%"
powershell -NoProfile -NonInteractive -Command "!PSSETTLE!"
set "HOTWIRE_ROOT="
:steamsettled

:framework
REM  Oxide. hotwire.install_framework 0 skips it for a vanilla server.
REM  curl -f fails on an HTTP error instead of saving the error page, which
REM  would otherwise be extracted over a working install.
set "FRAMEWORK_OK=0"
if "%INSTALL_FRAMEWORK%"=="0" (
    echo [%date% %time%] Vanilla server: hotwire.install_framework is 0, so Oxide is not installed.
    set "FRAMEWORK_OK=1"
    goto :frameworkdone
)

REM  One request for GitHub's latest Oxide release gives both its tag, which
REM  is compared with the installed Oxide, and its download, which is
REM  checked against the SHA-256 GitHub publishes. uMod's feed is not used:
REM  it has named the old Oxide for over an hour after GitHub had the new
REM  one. Paths go through environment variables, so an apostrophe in a
REM  folder name is safe, and the PowerShell avoids the characters that
REM  delayed expansion removes.
set "FW_FROM=%FRAMEWORK_URL%"
set "FW_GH="
set "FW_SHA="
set "FW_TAG="
set "HOTWIRE_FWREL=%FRAMEWORK_RELEASES%"
set "HOTWIRE_FWASSET=%FRAMEWORK_ASSET%"
set "HOTWIRE_FWOUT=%ROOT%\logs\.framework-release.tmp"
if exist "!HOTWIRE_FWOUT!" del "!HOTWIRE_FWOUT!"
set "PSREL="
set "PSREL=!PSREL!try{ [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 } catch {} "
set "PSREL=!PSREL!try{ $r=Invoke-RestMethod -Uri $env:HOTWIRE_FWREL -TimeoutSec 25 -Headers @{ Accept='application/vnd.github+json' }; "
set "PSREL=!PSREL!$t=[string]$r.tag_name; if($t -match '\Av?[0-9]+(\.[0-9]+)+\z'){ $t=$t.TrimStart('v') } else { $t='-' }; "
set "PSREL=!PSREL!$a=@($r.assets | Where-Object { $_.name -eq $env:HOTWIRE_FWASSET })[0]; $d=[string]$a.digest; $u=[string]$a.browser_download_url; "
set "PSREL=!PSREL!if($d.Length -eq 71 -and $d -like 'sha256:*'){ $d=$d.Substring(7).ToLower() } else { $d='-' }; "
set "PSREL=!PSREL!if($u -notlike 'https://github.com/*'){ $u='-'; $d='-' }; "
set "PSREL=!PSREL!Set-Content -LiteralPath $env:HOTWIRE_FWOUT -Value ($u+' '+$d+' '+$t) -Encoding ASCII } catch {} "
powershell -NoProfile -NonInteractive -Command "!PSREL!"
if exist "!HOTWIRE_FWOUT!" (
    for /f "usebackq tokens=1-3" %%A in ("!HOTWIRE_FWOUT!") do (
        set "FW_GH=%%A"
        set "FW_SHA=%%B"
        set "FW_TAG=%%C"
    )
    del "!HOTWIRE_FWOUT!"
)
set "HOTWIRE_FWREL="
set "HOTWIRE_FWASSET="
set "HOTWIRE_FWOUT="
set "PSREL="
if defined FW_GH if not "!FW_GH!"=="-" set "FW_FROM=!FW_GH!"
if "!FW_SHA!"=="-" set "FW_SHA="
if "!FW_TAG!"=="-" set "FW_TAG="
if "%VERIFY_FRAMEWORK%"=="0" set "FW_SHA="

REM  Read the installed build again. If SteamCMD changed it, the game's own
REM  managed files were just rewritten, so Oxide must be extracted over them
REM  whatever its version. Skipping the extract is safe only when the build
REM  did not change. This uses the build check's [char]-built regex instead
REM  of findstr with escaped quotes: cmd has no backslash escape, and a quote
REM  inside for /f breaks the line.
set "BUILD_AFTER="
set "HOTWIRE_ACF2=%ROOT%\steamapps\appmanifest_%APPID%.acf"
for /f %%B in ('powershell -NoProfile -NonInteractive -Command "$q=[char]34; $t=[IO.File]::ReadAllText($env:HOTWIRE_ACF2); $m=[regex]::Match($t, $q+'buildid'+$q+'\s+'+$q+'(\d+)'+$q); if($m.Success){ $m.Groups[1].Value }"') do set "BUILD_AFTER=%%B"
set "HOTWIRE_ACF2="

if not "%SKIP_UNCHANGED_FRAMEWORK%"=="1" goto :frameworkextract
if not defined INSTALLED_BUILD goto :frameworkextract
if not defined BUILD_AFTER goto :frameworkextract
if not "!INSTALLED_BUILD!"=="!BUILD_AFTER!" (
    echo [%date% %time%] Rust changed from build !INSTALLED_BUILD! to !BUILD_AFTER!,
    echo [%date% %time%] so Oxide is installed again.
    goto :frameworkextract
)
if not defined FW_TAG (
    echo [%date% %time%] GitHub did not return Oxide's latest version, so the
    echo [%date% %time%] installed one cannot be compared. Installing Oxide.
    goto :frameworkextract
)

REM  Compare the first three parts of the installed Oxide's file version,
REM  such as 2.0.7801.0, with GitHub's tag, such as 2.0.7801. Exit 0 means
REM  the same; 1 means different and anything else means unreadable, and
REM  both of those extract.
set "HOTWIRE_FWFILE=%FRAMEWORK_VERSION_FILE%"
set "HOTWIRE_FWTAG=!FW_TAG!"
set "PSFW="
set "PSFW=!PSFW!$ErrorActionPreference='SilentlyContinue'; $f=$env:HOTWIRE_FWFILE; "
set "PSFW=!PSFW!if([string]::IsNullOrWhiteSpace($f) -or -not (Test-Path -LiteralPath $f)){ exit 2 } "
set "PSFW=!PSFW!$v=[string](Get-Item -LiteralPath $f).VersionInfo.FileVersion; "
set "PSFW=!PSFW!if([string]::IsNullOrWhiteSpace($v)){ exit 2 } "
set "PSFW=!PSFW!$vn=(($v.Trim() -split '\.') + @('0','0','0'))[0..2] -join '.'; "
set "PSFW=!PSFW!$ln=(($env:HOTWIRE_FWTAG.Trim() -split '\.') + @('0','0','0'))[0..2] -join '.'; "
set "PSFW=!PSFW!Write-Output ('Oxide: installed '+$vn+', GitHub '+$ln); "
set "PSFW=!PSFW!if($vn -eq $ln){ exit 0 } else { exit 1 } "
powershell -NoProfile -NonInteractive -Command "!PSFW!"
set "FWSAME=!errorlevel!"
set "HOTWIRE_FWFILE="
set "HOTWIRE_FWTAG="
set "PSFW="
if "!FWSAME!"=="0" (
    echo [%date% %time%] Rust and Oxide are both unchanged, so Oxide is not
    echo [%date% %time%] installed again.
    set "FRAMEWORK_OK=1"
    goto :frameworkdone
)
if not "!FWSAME!"=="1" echo [%date% %time%] Could not read the installed Oxide's version. Installing Oxide.

:frameworkextract
REM  Oxide is third-party and changes with every Rust release, so Hotwire
REM  has no hash of its own to pin it to. The launcher checks the download
REM  against the SHA-256 GitHub publishes for it (hotwire.verify_framework).
REM  That proves the file is the one GitHub holds for the release, not who
REM  built it. When no SHA-256 is available, the download is used unchecked
REM  and the log says so. Setup pins the Hotwire launcher and plugin
REM  separately.
if "%VERIFY_FRAMEWORK%"=="1" if not defined FW_SHA echo [%date% %time%] GitHub did not return Oxide's SHA-256, so this download cannot be checked.
if defined FW_SHA (
    echo [%date% %time%] Downloading Oxide !FW_TAG! from GitHub and checking its SHA-256.
) else (
    echo [%date% %time%] Downloading Oxide from GitHub without a check.
)
set "HOTWIRE_ZIPROOT=%ROOT%"
REM  curl gives up on a stalled download (under 1 byte a second for 2
REM  minutes), but not on a slow one.
curl -fSL -A "Mozilla/5.0" --connect-timeout 30 --speed-limit 1 --speed-time 120 "!FW_FROM!" --output "%ROOT%\OxideMod.zip"
if errorlevel 1 (
    echo [%date% %time%] Oxide download failed. Starting with the Oxide already installed.
    goto :fwcleanup
)
if defined FW_SHA (
    set "HOTWIRE_FWZIP=%ROOT%\OxideMod.zip"
    set "HOTWIRE_FWSHA=!FW_SHA!"
    powershell -NoProfile -NonInteractive -Command "$h=(Get-FileHash -Algorithm SHA256 -LiteralPath $env:HOTWIRE_FWZIP).Hash.ToLower(); if($h -eq $env:HOTWIRE_FWSHA){ exit 0 } else { Write-Output ('Downloaded SHA-256: '+$h); exit 1 }"
    if errorlevel 1 (
        echo [%date% %time%] The download does not match GitHub's SHA-256 for
        echo [%date% %time%] Oxide !FW_TAG! ^(!FW_SHA!^). It is not installed: the
        echo [%date% %time%] server starts with the Oxide it has, and the next
        echo [%date% %time%] restart tries again.
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
        echo [%date% %time%] Oxide could not be extracted.
    ) else (
        set "FRAMEWORK_OK=1"
    )
)
:fwcleanup
set "HOTWIRE_ZIPROOT="
if exist "%ROOT%\OxideMod.zip" del "%ROOT%\OxideMod.zip"

:frameworkdone

REM  Delete the flag and reset the backstop only when the update completed.
REM  This point is also reached after SteamCMD fails: deleting the flag then
REM  would make the next restart skip the update, and resetting the stamp on
REM  every failed try would stop the backstop from ever running.
set "UPDATE_OK=0"
if "!STEAM_OK!"=="1" if "!FRAMEWORK_OK!"=="1" set "UPDATE_OK=1"

REM  The backstop reads UPDATE_STAMP's modified time; the text inside is for
REM  people. No comments go inside the block below: a parenthesis in one
REM  closes the block early, and REM does not stop a redirect there, so an
REM  arrow in a comment would create a file.
REM  The stamp line puts its redirect first. After the text, the character
REM  before the redirect would be the last digit of the time, and cmd reads
REM  a digit there as a handle number: 1 works, 2 sends the line to stderr,
REM  and 3 to 9 create an empty file.
if "!UPDATE_OK!"=="1" (
    if exist "%ROOT%\%UPDATE_FLAG%"   del "%ROOT%\%UPDATE_FLAG%"
    if exist "%ROOT%\%VALIDATE_FLAG%" del "%ROOT%\%VALIDATE_FLAG%"
    >"%UPDATE_STAMP%" echo Last update: %date% %time%
) else (
    echo [%date% %time%] ================================================
    echo [%date% %time%] The update did not complete.
    echo [%date% %time%] Any %UPDATE_FLAG% or %VALIDATE_FLAG% is kept and the
    echo [%date% %time%] update stamp is not reset, so the next start tries again.
    echo [%date% %time%] ================================================
)

REM  Deleting a flag and writing the stamp can both fail on permissions
REM  even though the update worked. A flag that cannot be deleted makes
REM  every restart update, with no message. A stamp that cannot be written
REM  makes the backstop treat the server as never updated. Both are
REM  warnings: the update itself succeeded.
if "!UPDATE_OK!"=="1" if exist "%ROOT%\%UPDATE_FLAG%" (
    echo [%date% %time%] WARNING: %UPDATE_FLAG% could not be deleted after a
    echo [%date% %time%] successful update, so every restart will update.
    echo [%date% %time%] Check the permissions on the server folder.
)
if "!UPDATE_OK!"=="1" if exist "%ROOT%\%VALIDATE_FLAG%" (
    echo [%date% %time%] WARNING: %VALIDATE_FLAG% could not be deleted after a
    echo [%date% %time%] successful update, so every restart will check every
    echo [%date% %time%] file, which is slow. Check the permissions on the
    echo [%date% %time%] server folder.
)
if "!UPDATE_OK!"=="1" if not exist "%UPDATE_STAMP%" (
    echo [%date% %time%] WARNING: could not write the update stamp at
    echo [%date% %time%]   !UPDATE_STAMP!
    echo [%date% %time%] The backstop reads it, so it will treat this server as
    echo [%date% %time%] never updated.
)

REM  hotwire-after.bat runs after every update attempt, successful or not,
REM  in its own cmd like hotwire-before.bat.
if not exist "%HOOK_AFTER%" goto :hookafterdone
echo [%date% %time%] Running hotwire-after.bat...
cmd /d /c call "%HOOK_AFTER%"
if errorlevel 1 echo [%date% %time%] hotwire-after.bat failed; starting anyway.
:hookafterdone



REM ======================================================================
:buildargs
REM ======================================================================
REM  WIPES AND PERMANENT CONVARS
REM
REM     When AFKPanel asks for a wipe or a permanent convar, the plugin
REM     leaves WIPE.flag or CONVAR.request in the server folder. Between
REM     runs, while the server is stopped, the PowerShell at the end of this
REM     file checks every value, writes it into hotwire.cfg, and reads the
REM     file again so this start uses it. Check mode changes nothing.
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
    echo [%date% %time%] Check mode: the server is not started.
    exit /b 0
)


REM ======================================================================
REM  LAUNCH
REM ======================================================================

REM  Keep the previous log: -logfile empties the file on every start, so
REM  without this a restart would erase the log of what went wrong.
REM
REM  A crash loop restarts every few seconds, and trimming to
REM  hotwire.log_keep would soon delete the log that explains it. So the
REM  first log of a crash streak is saved as server_crash_*, which the trim
REM  never deletes. Later crashes in the streak rotate normally: they repeat
REM  the first, and keeping them all would fill the disk.
if not "%ROTATE_LOGS%"=="0" if exist "%LOGFILE%" (
    REM  The log folder goes through an environment variable, so an
    REM  apostrophe in the path is safe.
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

REM  Tell the plugin which launcher started the server: version, code hash,
REM  capabilities and path, in oxide\data\Hotwire\launcher.json. Written
REM  before every start. If writing fails, only AFKPanel's view of the
REM  launcher is affected.
set "HOTWIRE_STATE=%ROOT%\oxide\data\Hotwire\launcher.json"
powershell -NoProfile -NonInteractive -Command "$t=[IO.File]::ReadAllText($env:HOTWIRE_SELF,[Text.Encoding]::GetEncoding(28591)); $h=''; $m=[regex]::Match($t,'(?m)^HOTWIRE_LAUNCHER_HASH=.?([0-9a-f]{64})'); if($m.Success){ $h=$m.Groups[1].Value }; [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $env:HOTWIRE_STATE)); $o=[ordered]@{ version=$env:HOTWIRE_LAUNCHER_VERSION; hash=$h; capabilities=$env:HOTWIRE_LAUNCHER_CAPABILITIES; platform='windows'; path=$env:HOTWIRE_SELF; update_mode=$env:UPDATE_MODE }; [IO.File]::WriteAllText($env:HOTWIRE_STATE, ($o | ConvertTo-Json))" >nul 2>&1
set "HOTWIRE_STATE="

REM  Send held reports in the background; the server starts without waiting.
call :hotwire_send background
echo [%date% %time%] Starting the server...
set "STARTED_AT="
for /f %%t in ('powershell -NoProfile -Command "(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')"') do set "STARTED_AT=%%t"

REM  Time the run to tell a crash loop from a normal restart. If either
REM  timestamp fails, the run counts as a long one, which keeps the server
REM  running instead of stopping it over a missing timestamp.
set "RUN_START=0"
for /f %%t in ('powershell -NoProfile -Command "[int]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalSeconds"') do set "RUN_START=%%t"

REM  PowerShell starts RustDedicated.exe with the arguments from the last
REM  good read of hotwire.cfg and waits for it to exit.
call :hotwire_ps launch
set "RUST_EXIT=!errorlevel!"

set "RUN_END=0"
for /f %%t in ('powershell -NoProfile -Command "[int]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalSeconds"') do set "RUN_END=%%t"
set "RUN_SECONDS=99999"
if not "!RUN_START!"=="0" if not "!RUN_END!"=="0" set /a RUN_SECONDS=RUN_END-RUN_START

set "CRASHED=0"
if !RUN_SECONDS! LSS %CRASH_SECONDS% (
    set /a CRASH_STREAK+=1
    set "CRASHED=1"
) else (
    set /a CRASH_STREAK=0
)

REM  The session report: how this run ended and what its update did. It is
REM  written to the spool now and sent in the background.
set "HOTWIRE_REPORT=session"
set "HOTWIRE_STARTED_AT=!STARTED_AT!"
set "HOTWIRE_RUST_EXIT=!RUST_EXIT!"
set "HOTWIRE_CRASHED=!CRASHED!"
set "HOTWIRE_UPDATE_ATTEMPTED=!UPDATE_ATTEMPTED!"
call :hotwire_ps report >nul
set "HOTWIRE_REPORT="
set "HOTWIRE_STARTED_AT="
set "HOTWIRE_RUST_EXIT="
set "HOTWIRE_CRASHED="
set "HOTWIRE_UPDATE_ATTEMPTED="

if "%RESTART_ON_EXIT%"=="0" (
    echo [%date% %time%] Server exited after !RUN_SECONDS!s. hotwire.restart_on_exit is 0, so it is not restarted.
    call :hotwire_send wait
    exit /b 0
)
call :hotwire_send background

if not "%MAX_CRASH_STREAK%"=="0" if !CRASH_STREAK! GEQ %MAX_CRASH_STREAK% goto crashstop

REM  Back off, so a broken setting does not restart the server four times a
REM  minute forever, or run hotwire-before.bat that often, which is costly
REM  when it makes a backup.
set "DELAY=%RESTART_DELAY%"
if not "%CRASH_BACKOFF%"=="0" if !CRASH_STREAK! GEQ 2 set "DELAY=30"
if not "%CRASH_BACKOFF%"=="0" if !CRASH_STREAK! GEQ 3 set "DELAY=60"
if not "%CRASH_BACKOFF%"=="0" if !CRASH_STREAK! GEQ 4 set "DELAY=120"
if not "%CRASH_BACKOFF%"=="0" if !CRASH_STREAK! GEQ 5 set "DELAY=300"

if !CRASH_STREAK! GTR 0 (
    echo [%date% %time%] Server exited after !RUN_SECONDS!s, which counts as a crash.
    if "%MAX_CRASH_STREAK%"=="0" (echo [%date% %time%] Crash !CRASH_STREAK!. Retrying in !DELAY!s.) else (echo [%date% %time%] Crash !CRASH_STREAK! of %MAX_CRASH_STREAK%. Retrying in !DELAY!s.)
) else (
    echo [%date% %time%] Server exited. Restarting in !DELAY!s. Press Ctrl+C to stop.
)
REM  The same fallback as the SteamCMD retry: without input, timeout fails,
REM  and the restart loop would run with no delay.
timeout /t !DELAY! /nobreak
if errorlevel 1 (
    set /a PINGWAIT=!DELAY!+1
    ping -n !PINGWAIT! 127.0.0.1 >nul 2>&1
)
goto start

:crashstop
REM  The launcher report: the launcher has stopped for good, which a missing
REM  heartbeat cannot tell apart from a network outage. Nothing is waiting
REM  to start, so it is sent now.
set "HOTWIRE_REPORT=launcher"
call :hotwire_ps report >nul
set "HOTWIRE_REPORT="
call :hotwire_send wait
echo [%date% %time%] ====================================================
echo [%date% %time%] STOPPED. %MAX_CRASH_STREAK% crashes in a row, each under
echo [%date% %time%] %CRASH_SECONDS%s. The server does not start, and restarting
echo [%date% %time%] it again will not help.
echo [%date% %time%]
echo [%date% %time%] Read the log from the first crash:
echo [%date% %time%]   !ROOT!\logs\server_crash_*.txt
echo [%date% %time%] Common causes: a bad setting in hotwire.cfg, a port
echo [%date% %time%] already in use, or a corrupt save. With more than one
echo [%date% %time%] server on this machine, check that each has its own
echo [%date% %time%] ports in hotwire.cfg. A second copy of this launcher
echo [%date% %time%] already running causes this too.
echo [%date% %time%]
echo [%date% %time%] To keep restarting instead, set hotwire.max_crash_streak 0
echo [%date% %time%] in hotwire.cfg.
echo [%date% %time%] ====================================================
pause
exit /b 1

:partproblem
REM  hotwire.ps1 is missing or from another release. The reason is already
REM  on screen; running half of one version and half of another is refused.
pause
exit /b 1


REM ======================================================================
REM  THE CALLS INTO POWERSHELL
REM ======================================================================

REM  :hotwire_load reads the settings. PowerShell prints its messages on
REM  stderr, straight to this window, and passes the settings to cmd on
REM  stdout as HWSET NAME=value lines. The last line sets HW_LOAD: ok, fatal
REM  (a first read that must stop) or kept (a later read failed, so the
REM  last good settings stay).
:hotwire_load
set "HW_LOAD="
if not exist "!HW_PS1!" (
    echo [%date% %time%] ================================================
    echo [%date% %time%] hotwire.ps1 is missing from !ROOT!.
    echo [%date% %time%] Put it beside hotwire.bat, from the same release.
    echo [%date% %time%] Not starting.
    echo [%date% %time%] ================================================
    set "HW_LOAD=missing"
    exit /b 0
)
set "HOTWIRE_MODE=load"
set "HOTWIRE_ROOT=%ROOT%"
for /f "usebackq delims=" %%L in (`powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "!HW_PS1!"`) do (
    set "HW_LINE=%%L"
    if "!HW_LINE:~0,6!"=="HWSET " for /f "tokens=1,* delims==" %%A in ("!HW_LINE:~6!") do set "%%A=%%B"
)
set "HW_LINE="
set "HOTWIRE_MODE="
exit /b 0

REM  :hotwire_send background or wait. Sends held reports to AFKPanel: in
REM  the background before and after a run, or, when the launcher is about
REM  to stop, at once, waiting up to a minute for a sender already running.
:hotwire_send
set "HOTWIRE_MODE=send"
set "HOTWIRE_ROOT=%ROOT%"
if "%~1"=="wait" (
    set "HOTWIRE_SEND_WAIT=60"
    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "!HW_PS1!"
) else (
    set "HOTWIRE_SEND_WAIT=0"
    start "" /b powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "!HW_PS1!"
)
set "HOTWIRE_SEND_WAIT="
set "HOTWIRE_MODE="
exit /b 0

REM  :hotwire_ps edits, launch, backup or report. Runs that part and returns
REM  its exit code.
:hotwire_ps
set "HOTWIRE_MODE=%~1"
set "HOTWIRE_ROOT=%ROOT%"
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "!HW_PS1!"
set "HW_EXIT=!errorlevel!"
set "HOTWIRE_MODE="
exit /b !HW_EXIT!

REM ======================================================================
REM  CODE HASH
REM
REM     cmd never runs what follows: every path above exits first.
REM     tools/launcher-hash.sh stamps the hash at release. It covers this
REM     file and each file named on a HOTWIRE-PART line, in that order.
REM ======================================================================
exit /b 0
REM HOTWIRE-PART hotwire.ps1
HOTWIRE_LAUNCHER_HASH="63b4b0c820ea4965f85f4118c0a54d271660a0e09c0c3bf9261435ad59e7b330"
