@echo off
setlocal EnableDelayedExpansion

REM ==[ H O T W I R E ]===================================================
REM  Hotwire launcher for Windows. Version: HOTWIRE_LAUNCHER_VERSION below.
REM  Built by xman2000 and Claude.  MIT License.
REM  https://github.com/xman2000/hotwire
REM
REM  Settings are in hotwire.cfg and the RCON password in
REM  hotwire-secrets.cfg, both beside this file. This file holds no
REM  settings, so replacing it with a newer release keeps yours.
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
set "HOTWIRE_LAUNCHER_VERSION=1.1.21"
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
REM     3.  Put hotwire.bat in the same folder as RustDedicated.exe. The
REM         launcher treats its own folder as the server folder.
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
REM     Optional: src\Hotwire.cs at the address above. It schedules
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

REM  HW_PS passes PowerShell everything from the #HOTWIRE-PS line down, and
REM  HOTWIRE_MODE picks the part to run; the parts are listed there. The
REM  line holds no double quote, percent sign or exclamation mark, so cmd
REM  passes it through unchanged.
set "HW_PS=$t=[IO.File]::ReadAllText($env:HOTWIRE_SELF,[Text.Encoding]::GetEncoding(28591)); $i=$t.LastIndexOf('#'+'HOTWIRE-PS'); if($i -ge 0){ Invoke-Expression $t.Substring($i) } else { exit 9 }"

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
if defined HOTWIRE_FIRST if not "!HW_LOAD!"=="ok" (
    if not defined HW_LOAD echo [%date% %time%] Could not read the settings: PowerShell did not respond.
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
set "HOTWIRE_MODE=load"
set "HOTWIRE_ROOT=%ROOT%"
for /f "usebackq delims=" %%L in (`powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "!HW_PS!"`) do (
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
    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "!HW_PS!"
) else (
    set "HOTWIRE_SEND_WAIT=0"
    start "" /b powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "!HW_PS!"
)
set "HOTWIRE_SEND_WAIT="
set "HOTWIRE_MODE="
exit /b 0

REM  :hotwire_ps edits, launch, backup or report. Runs that part and returns
REM  its exit code.
:hotwire_ps
set "HOTWIRE_MODE=%~1"
set "HOTWIRE_ROOT=%ROOT%"
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "!HW_PS!"
set "HW_EXIT=!errorlevel!"
set "HOTWIRE_MODE="
exit /b !HW_EXIT!

REM ======================================================================
REM  CODE HASH AND POWERSHELL
REM
REM     cmd never runs what follows: every path above exits first.
REM     tools/launcher-hash.sh stamps the hash at release. Everything from
REM     the #HOTWIRE-PS line down is passed to PowerShell, so it is written
REM     as plain PowerShell, free of cmd's quoting rules.
REM ======================================================================
exit /b 0
HOTWIRE_LAUNCHER_HASH="9873ed3f55fb3cb918015424b1a8930e2472baf888e2630c4023c634e22ca31a"

#HOTWIRE-PS
# hotwire.bat's PowerShell. cmd passes everything from the line above down, and HOTWIRE_MODE picks the part to run:
#   load    read hotwire.cfg and hotwire-secrets.cfg, check every line, pass the launcher's settings to cmd, and
#           save the server's arguments for the start
#   edits   apply a wipe or a permanent convar the plugin asked for, by writing hotwire.cfg
#   launch  start RustDedicated.exe with those arguments and wait for it to exit
#   backup  back up the stopped server before an update or a wipe, when one is asked for
#   report  write a session or launcher report to the spool
#   send    send the spool's reports to AFKPanel
#
# Settings are read as data, one line at a time, and never run. A line is a name, spaces, then a value. A value
# with spaces goes in double quotes and cannot contain one; no control characters. Each value is checked before
# use: a line that fails is ignored, check lists it, and the default applies. A bad value for the settings that
# would make a different server if defaulted (the save folder, the map and the ports) is not replaced: it stops
# the first start, and a later restart keeps the last good settings. The rules match hotwire.sh line for line.
# Windows PowerShell 5.1, ASCII only.
$ErrorActionPreference = 'Stop'
$root = $env:HOTWIRE_ROOT
$cfg = Join-Path $root 'hotwire.cfg'
$secretsCfg = Join-Path $root 'hotwire-secrets.cfg'
$argsFile = Join-Path $root 'hotwire\launch-args.json'

# Messages go to stderr, because in load mode stdout carries the settings to cmd.
function Say([string]$message) { [Console]::Error.WriteLine('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $message) }
function Rule { [Console]::Error.WriteLine('========================================================') }

# hotwire.<name>: cmd variable, kind, default. cmd receives these, so each kind is checked to contain nothing cmd
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
    'hotwire.forced_wipe_steam_minutes' = @('FORCED_WIPE_STEAM_MINUTES', 'int', '15')
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
# Rust convars the launcher reads itself: kind, default.
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
# Kinds that would make a different server if defaulted: a bad value stops the start instead.
$criticalKinds = @('identity', 'seed', 'worldsize', 'port', 'url')

# One line: returns @{ Name; Value } or @{ Why }.
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

# Returns '' when the value is usable, or the reason it is not. An empty value always passes: it means the default.
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

# Reads hotwire.cfg: what it sets, and every line not used.
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
        # Every name above the OTHER CONVARS heading, set or commented out (#name value), is the file's own list: the
        # option check treats those as spelled correctly. It questions names added below the heading.
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
            # Numbers are passed on in base 10: cmd reads a leading zero as octal, so 08 would break its arithmetic.
            $value = $p.Value
            if ($value -ne '' -and @('int', 'int1', 'seed', 'worldsize', 'port') -contains $kind) { $value = [string][long]$value }
            $r.Values[$lower] = $value
            continue
        }
        if ($lower.StartsWith('hotwire.')) { $r.Problems.Add('line ' + $n + ': ' + $name + ': not a launcher setting; ignored'); continue }
        # Any other Rust convar is passed through unchanged. Empty means the default.
        if ($p.Value -eq '') { continue }
        $r.Extra[$lower] = @($name, $p.Value)
    }
    foreach ($k in $r.Extra.Keys) { if (-not $r.Known.ContainsKey($k)) { $r.Unknown.Add($r.Extra[$k][0]) } }
    return $r
}

# A launcher setting as used: the file's value or the default. For a number, a switch or a path, empty also means
# the default; for the Steam branch, empty means Steam keeps the branch it has.
function Get-HwValue($r, [string]$key) {
    $spec = $hwSettings[$key]
    if ($r.Values.ContainsKey($key)) {
        $v = [string]$r.Values[$key]
        if ($v -ne '' -or $spec[1] -eq 'word') { return $v }
    }
    return $spec[2]
}

# A server setting as used: the file's value, even empty (the game's default), or the launcher's default.
function Get-CvValue($r, [string]$key) {
    if ($r.Values.ContainsKey($key)) { return [string]$r.Values[$key] }
    return $cvSettings[$key][1]
}

# Reads hotwire-secrets.cfg as data, like hotwire.cfg, and takes only rcon.password: returns @{ Password } or @{ Why }.
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
    if ($password -eq 'change_me') { return @{ Why = "rcon.password is still the example value 'change_me'. Set your own in hotwire-secrets.cfg." } }
    if ($password.Length -lt $minimum) { return @{ Why = ('rcon.password is shorter than hotwire.rcon_password_min (' + $minimum + ').') } }
    return @{ Password = $password }
}

# The server's arguments, without the RCON password and the log file, which Invoke-Launch adds.
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

# Quotes one argument the way Windows programs split a command line: in quotes when it has a space, with
# backslashes doubled only before a quote.
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
                Say '  The launcher does not start without it: with the defaults the server would open an empty'
                Say '  save folder, which looks like a wipe.'
            } else {
                Say 'The server was not started. These settings in hotwire.cfg would change which server this is:'
                foreach ($f in $r.Fatal) { Say ('  ' + $f) }
            }
            Rule
            Write-Output 'HWSET HW_LOAD=fatal'
        } else {
            Rule
            Say 'hotwire.cfg changed and cannot be used. Starting with the settings from the last start:'
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
        # The option check: a convar name not in hotwire.cfg's own list is probably misspelled. It only warns: Rust
        # ignores names it does not know, and the list does not hold every convar Rust has.
        if ((Get-HwValue $r 'hotwire.check_options') -eq '0') { Say 'Option check skipped (hotwire.check_options 0).' }
        elseif ($r.Unknown.Count -eq 0) { Say 'Options look right.' }
        else { foreach ($u in $r.Unknown) { Say ($u + " is not in hotwire.cfg's list of convars. Check the spelling.") } }
    }

    # The arguments for the start. Check mode writes nothing, this file included.
    if (-not $env:CHECK_ONLY) {
        $folder = Split-Path -Parent $argsFile
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Force -Path $folder) }
        [IO.File]::WriteAllText($argsFile, (ConvertTo-Json -InputObject ([string[]](Get-ServerArgs $r)) -Compress))
    }
    foreach ($key in $hwSettings.Keys) { Write-Output ('HWSET ' + $hwSettings[$key][0] + '=' + (Get-HwValue $r $key)) }
    # The password stays in this process's environment, as in the old launcher, base64-encoded so cmd handles
    # only letters, digits, + / and =.
    Write-Output ('HWSET HOTWIRE_RCON64=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($secret.Password)))
    Write-Output 'HWSET HW_LOAD=ok'
}

# ---- edits ---------------------------------------------------------------------------------------------------
# Set-CfgValues writes settings into hotwire.cfg in one pass. A setting's line is changed in place; a setting
# commented out in the list (#name value) is uncommented in place; anything else is added at the end. A value with
# spaces, or an empty one, is written in double quotes. The caller has checked every name and value, so no double
# quote or control character reaches here. The new file is written beside the old one and swapped in, keeping its
# permissions. Returns $true when written.
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
        # [NullString]::Value, because PowerShell passes '' for $null to a .NET string parameter.
        [IO.File]::Replace($tmp, $cfg, [NullString]::Value)
        return $true
    } catch {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Say ('Could not write hotwire.cfg: ' + $_.Exception.Message)
        return $false
    }
}

# True when a forced wipe must wait: the installed build cannot be read, or it is still the build the wipe was set
# up on (no update yet). Writes WIPE.result so the plugin tries again.
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
        Say ('Forced wipe (cycle ' + $cycle + '): the installed build cannot be read, so the wipe waits. Starting without wiping.')
        [IO.File]::WriteAllText($result, "deferred: installed build unknown`n")
        return $true
    }
    if ($armedBuild -and $installed -eq $armedBuild) {
        Say ('Forced wipe (cycle ' + $cycle + '): still build ' + $installed + ', no update yet. Starting the old world; the wipe waits.')
        [IO.File]::WriteAllText($result, 'deferred: no new build (installed ' + $installed + ")`n")
        return $true
    }
    Say ('Forced wipe (cycle ' + $cycle + '): the build changed from ' + $armedBuild + ' to ' + $installed + '.')
    return $false
}

function Invoke-Edits {
    $wipeName = $env:WIPE_FLAG; if (-not $wipeName) { $wipeName = 'WIPE.flag' }

    # ---- Wipe (capability: wipe) -------------------------------------------------------------------------
    # A wipe is a restart with a flag. The new seed (and size) is written into hotwire.cfg, Rust finds no save with
    # that name and generates a new world, and the old save stays on disk. Every value is checked before anything is
    # written or deleted. A stale flag, or one already applied, never fires. If the seed cannot be written, the wipe
    # is cancelled and the server starts unchanged.
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
            Say 'The wipe flag has expired; ignoring it. Starting without wiping.'
        } elseif ($forced -eq '1' -and (Test-ForcedWipeWaits $armedBuild $cycle $result)) {
            # A forced wipe comes with the monthly update and applies only in a start whose update changed the
            # installed build. The flag stays for the next start within its window, and the plugin tries again.
        } else {
            if ($seed -notmatch '^\d{1,10}$' -or [long]$seed -gt 2147483647) { $why = 'seed is not a whole number from 0 to 2147483647' }
            elseif ($size -and ($size -notmatch '^\d{1,5}$' -or [int]$size -lt 1000 -or [int]$size -gt 6000)) { $why = 'size is not a whole number from 1000 to 6000' }
            elseif ('keep', 'rename', 'delete' -notcontains $bp) { $why = 'blueprints must be keep, rename or delete' }
            # A forced wipe's backup waits until the update is known to have arrived (above).
            if (-not $why -and $forced -eq '1' -and $w['backup'] -eq '1' -and $env:BACKUPS -ne '0') {
                Say 'Backing up the stopped server before the wipe...'
                [void](Invoke-BackupArchive 'before_wipe' ([DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'") + '-before_wipe') '' '' '' '' '')
            }
            if (-not $why) {
                $pairs = @(, @('server.seed', $seed))
                if ($size) { $pairs += , @('server.worldsize', $size) }
                if (-not (Set-CfgValues $pairs)) { $why = 'could not write the new seed' }
            }
            if ($why) {
                Rule; Say ('Wipe cancelled: ' + $why + '. Starting without wiping.'); Rule
                [IO.File]::WriteAllText($result, 'cancelled: ' + $why + "`n")
                Remove-Item -LiteralPath $flag -Force
            } else {
                # Blueprints, in the save folder, matched by pattern because the version in the file name changes
                # between builds. player.tokens.db and every other file are left alone.
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
                # The cycle is recorded and the flag removed last, so a crash part-way through reruns the wipe safely.
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
    # CONVAR.request holds one "<convar> <value>" per line. Each line sets one convar; nothing reaches the console.
    # The name must be a dotted convar and the value must hold no double quote or control character. Refused: the
    # map convars and rcon.password (they belong to wipe and the secrets file), and hotwire.* (the launcher's own
    # settings are the admin's). A convar the launcher reads itself must pass that setting's check.
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
        Say ('Permanent convars: ' + $applied + ' applied, ' + ($log.Count - $applied) + ' refused; details in CONVAR.result.')
    }
}

# ---- launch --------------------------------------------------------------------------------------------------
# The arguments reach RustDedicated.exe as one command line built here, never through cmd, so no character in a
# value can run as a command.
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
    # Clear a claim left by a backup that was cut short; the next backup clears the staging folder it names.
    Remove-Item -LiteralPath ($backupFlag + '.work') -Force -ErrorAction SilentlyContinue
    $p = [Diagnostics.Process]::Start($psi)
    # While the server runs, pick up the backups Hotwire asks for and run them at the lowest priority. A backup in
    # progress finishes before the server's exit is handled.
    while (-not $p.WaitForExit(5000)) {
        if ($env:BACKUPS -ne '0' -and (Test-Path -LiteralPath $backupFlag)) {
            try { Invoke-BackupFromFlag } catch { Say ('Backup: ' + $_.Exception.Message) }
        }
    }
    $p.WaitForExit()
    exit $p.ExitCode
}

# ---- backups ---------------------------------------------------------------------------------------------------
# The launcher's half of Hotwire's backups, as in hotwire.sh, except that Windows has no zstd, so an archive is a zip
# made and checked with what Windows already has. The plugin decides when a backup runs. While the server is up, the
# plugin copies what only the game can copy safely into backup\<identity>\.staging-<run> and writes BACKUP.flag. The
# launcher finishes the backup at the lowest priority: it adds the save (checked unchanged across the copy), the
# plugins and the map, writes a MANIFEST of every file's SHA-256, zips it, checks every file in the zip against the
# MANIFEST, removes old backups, and leaves a result for Hotwire to report. Between runs, before an update or a wipe,
# it backs up the stopped server itself. Nothing here can stop the server starting: a failed backup records why in its
# result and in backup\<identity>\backup.log.
$backupConf = [IO.Path]::Combine($root, 'hotwire', 'backup.conf')
$backupFlag = Join-Path $root 'BACKUP.flag'
$sep = [string][IO.Path]::DirectorySeparatorChar

function Get-BackupConf {
    $c = @{}
    if (Test-Path -LiteralPath $backupConf -PathType Leaf) {
        foreach ($l in [IO.File]::ReadAllLines($backupConf)) {
            $p = $l.Split(' ', 2)
            if ($p.Count -eq 2 -and -not $c.ContainsKey($p[0])) { $c[$p[0]] = $p[1].Trim() }
        }
    }
    return $c
}
function Get-BackupInt($conf, [string]$key, [long]$default) {
    $v = [string]$conf[$key]
    if ($v -match '\A[0-9]{1,9}\z') { return [long]$v }
    return $default
}
function Get-BackupSwitch($conf, [string]$key, [string]$default) {
    $v = [string]$conf[$key]
    if ($v -eq '') { return $default }
    return $v
}

# The save folder's name: a folder name, never a path, and never 0 to 3, which are Rust's own server.backup folders.
function Get-BackupIdentity($conf) {
    $id = [string]$conf['identity']
    if (-not $id) { $id = [string](Read-Config).Values['server.identity'] }
    if (-not $id) { $id = 'my_server_identity' }
    if ($id -cnotmatch '\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z' -or @('0', '1', '2', '3') -contains $id) { return $null }
    return $id
}

# A framework folder Hotwire named in backup.conf, used only if it is inside this server folder.
function Get-BackupDir($conf, [string]$key, [string]$default) {
    $d = [string]$conf[$key]
    if (-not $d) { $d = $default }
    $full = [IO.Path]::GetFullPath($d)
    if ($full.StartsWith($root.TrimEnd($sep) + $sep, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Container)) { return $full }
    return $null
}

function Add-BackupLog([string]$dest, [string]$line) {
    try {
        $f = Join-Path $dest 'backup.log'
        [IO.File]::AppendAllText($f, (Get-UtcStamp ([DateTimeOffset]::UtcNow)) + ' ' + $line + "`n")
        if ((Get-Item -LiteralPath $f).Length -gt 5242880) { Move-Item -LiteralPath $f -Destination ($f + '.1') -Force }
    } catch { }
}

function Write-BackupResult([string]$dest, [string]$run, [string[]]$lines) {
    try {
        $dir = Join-Path $dest '.results'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
        $tmp = Join-Path $dir ('.' + $run + '.tmp')
        [IO.File]::WriteAllText($tmp, ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination (Join-Path $dir ($run + '.result')) -Force
    } catch { }
}

function Get-FileSha256([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }

# Copy a folder's files into another, keeping the tree; $skip is a top-level folder left out.
function Copy-BackupTree([string]$from, [string]$to, [string]$skip) {
    $base = $from.TrimEnd($sep)
    foreach ($f in @(Get-ChildItem -LiteralPath $from -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($base.Length + 1)
        if ($skip -and ($rel -ieq $skip -or $rel.StartsWith($skip + $sep, [StringComparison]::OrdinalIgnoreCase))) { continue }
        $target = Join-Path $to $rel
        $folder = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Force -Path $folder) }
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force
    }
}

# A zip of one file or a whole folder. Entry names use forward slashes, as zip expects. The caller writes it as .part
# and checks it before renaming it into place.
function New-BackupZip([string]$from, [string]$to, [switch]$Single) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Force }
    $zip = [IO.Compression.ZipFile]::Open($to, [IO.Compression.ZipArchiveMode]::Create)
    try {
        if ($Single) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $from, (Split-Path -Leaf $from), [IO.Compression.CompressionLevel]::Optimal)
        } else {
            $base = $from.TrimEnd($sep)
            foreach ($f in @(Get-ChildItem -LiteralPath $from -File -Recurse -Force | Sort-Object FullName)) {
                $name = $f.FullName.Substring($base.Length + 1).Replace($sep, '/')
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $name, [IO.Compression.CompressionLevel]::Optimal)
            }
        }
    } finally { $zip.Dispose() }
}

# Every file in the zip read back and hashed: true when each matches the MANIFEST and none is missing or extra.
function Test-BackupZip([string]$path, $expected) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $seen = 0
        foreach ($e in $zip.Entries) {
            if ($e.FullName -eq 'MANIFEST') { continue }
            $want = $expected[$e.FullName]
            if (-not $want) { return $false }
            $s = $e.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $got = -join ($sha.ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose(); $s.Dispose() }
            if ($got -ne $want) { return $false }
            $seen++
        }
        return $seen -eq $expected.Count
    } catch { return $false } finally { $zip.Dispose() }
}

# Keeps everything from the last keep_recent_hours; then the newest backup of each day for keep_daily days, of each
# week for keep_weekly weeks and of each month for keep_monthly months; the newest keep_wipes before-wipe backups; and
# always the newest backup. Then applies the size cap, oldest first, never removing the newest. A map that no backup
# uses is removed too.
function Invoke-BackupRotate([string]$dest, $conf) {
    $now = [DateTimeOffset]::UtcNow
    $recent = (Get-BackupInt $conf 'keep_recent_hours' 24) * 3600
    $daily = Get-BackupInt $conf 'keep_daily' 7; $weekly = Get-BackupInt $conf 'keep_weekly' 4
    $monthly = Get-BackupInt $conf 'keep_monthly' 3; $wipes = Get-BackupInt $conf 'keep_wipes' 3
    $cap = (Get-BackupInt $conf 'max_total_mb' 0) * 1048576
    $nowMonth = $now.Year * 12 + $now.Month
    $seen = @{}; $keep = New-Object 'System.Collections.Generic.List[string]'; $drop = New-Object 'System.Collections.Generic.List[string]'
    $first = $true; $wipeCount = 0
    $archives = @(Get-ChildItem -LiteralPath $dest -File | Where-Object { $_.Name -like '*.zip' -or $_.Name -like '*.tar.zst' } | Sort-Object Name -Descending)
    foreach ($a in $archives) {
        $stamp = ($a.Name -split '-', 2)[0]
        if ($stamp -notmatch '\A\d{8}T\d{6}Z\z') { continue }
        $when = [DateTime]::ParseExact($stamp, "yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
        $age = ($now.UtcDateTime - $when).TotalSeconds
        if ($a.Name -like '*-before_wipe.*') {
            $wipeCount++
            if ($wipeCount -le $wipes -or $first) { $keep.Add($a.FullName) } else { $drop.Add($a.FullName) }
            $first = $false; continue
        }
        $thursday = $when.AddDays(3 - (([int]$when.DayOfWeek + 6) % 7))
        $d = 'd' + $when.ToString('yyyyMMdd'); $m = 'm' + $when.ToString('yyyyMM')
        $w = 'w' + $thursday.Year + '-' + [Globalization.CultureInfo]::InvariantCulture.Calendar.GetWeekOfYear($thursday, [Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
        $k = $false
        if ($first -or $age -lt $recent) { $k = $true }
        elseif ($age -lt $daily * 86400 -and -not $seen.ContainsKey($d)) { $k = $true }
        elseif ($age -lt $weekly * 7 * 86400 -and -not $seen.ContainsKey($w)) { $k = $true }
        elseif (($nowMonth - ($when.Year * 12 + $when.Month)) -lt $monthly -and -not $seen.ContainsKey($m)) { $k = $true }
        $first = $false
        if ($k) { $keep.Add($a.FullName); $seen[$d] = 1; $seen[$w] = 1; $seen[$m] = 1 } else { $drop.Add($a.FullName) }
    }
    $removed = 0
    foreach ($f in $drop) { Remove-BackupArchive $f; $removed++; Add-BackupLog $dest ('rotate: removed ' + (Split-Path -Leaf $f)) }
    if ($cap -gt 0) {
        $total = 0L
        foreach ($f in @(Get-ChildItem -LiteralPath $dest -File | Where-Object { $_.Name -like '*.zip' -or $_.Name -like '*.tar.zst' })) { $total += $f.Length }
        $maps = Join-Path $dest 'maps'
        if (Test-Path -LiteralPath $maps) { foreach ($f in @(Get-ChildItem -LiteralPath $maps -File)) { $total += $f.Length } }
        for ($i = $keep.Count - 1; $i -gt 0 -and $total -gt $cap; $i--) {
            $total -= (Get-Item -LiteralPath $keep[$i]).Length
            Remove-BackupArchive $keep[$i]; $removed++
            Add-BackupLog $dest ('rotate: removed ' + (Split-Path -Leaf $keep[$i]) + ' (over the ' + $cap + ' byte cap)')
        }
    }
    $maps = Join-Path $dest 'maps'
    if (Test-Path -LiteralPath $maps) {
        $named = @{}
        foreach ($meta in @(Get-ChildItem -LiteralPath $dest -File -Filter '*.meta')) {
            foreach ($l in [IO.File]::ReadAllLines($meta.FullName)) { if ($l.StartsWith('map ')) { $named[$l.Substring(4)] = 1 } }
        }
        foreach ($mf in @(Get-ChildItem -LiteralPath $maps -File -Filter '*.zip')) {
            $name = $mf.Name.Substring(0, $mf.Name.Length - 4)
            if (-not $named.ContainsKey($name)) { Remove-Item -LiteralPath $mf.FullName -Force; Add-BackupLog $dest ('rotate: removed map ' + $name + ' (no backup uses it)') }
        }
    }
    return $removed
}
function Remove-BackupArchive([string]$f) {
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    $meta = ($f -replace '\.tar\.zst\z', '' -replace '\.zip\z', '') + '.meta'
    Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
}

# One backup, start to finish, at the lowest priority. With a staging folder it finishes a live backup Hotwire
# prepared; without one, the server is stopped and this copies everything. Returns $true on success.
function Invoke-BackupArchive([string]$trigger, [string]$run, [string]$staging, [string]$savName, [string]$savSize, [string]$savMtime, [string]$sets) {
    $self = [Diagnostics.Process]::GetCurrentProcess()
    $priority = $self.PriorityClass
    try { $self.PriorityClass = [Diagnostics.ProcessPriorityClass]::Idle } catch { }
    try {
        $conf = Get-BackupConf
        $started = Get-UtcStamp ([DateTimeOffset]::UtcNow)
        $t0 = [DateTime]::UtcNow
        if (-not $sets) {
            $sets = 'world'
            if ((Get-BackupSwitch $conf 'map' '1') -eq '1') { $sets += ',map' }
            if ((Get-BackupSwitch $conf 'config' '1') -eq '1') { $sets += ',config' }
            if ((Get-BackupSwitch $conf 'oxide' '1') -eq '1') { $sets += ',oxide' }
        }
        $setList = @($sets.Split(',') | Where-Object { $_ })
        $setWords = $setList -join ' '
        $id = Get-BackupIdentity $conf
        if (-not $id) { Say ('Backup ' + $run + ': the save folder''s name is not usable, so nothing was backed up.'); return $false }
        $saveDir = [IO.Path]::Combine($root, 'server', $id)
        $dest = [IO.Path]::Combine($root, 'backup', $id)
        foreach ($d in @($dest, (Join-Path $dest 'maps'), (Join-Path $dest '.results'))) { if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Force -Path $d) } }

        # One backup at a time per save folder; a second one is refused instead of waiting.
        $lock = $null
        try { $lock = [IO.File]::Open((Join-Path $dest '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch {
            Add-BackupLog $dest ($run + ' refused: another backup is running')
            Write-BackupResult $dest $run @(('run ' + $run), ('trigger ' + $trigger), 'status refused', 'code busy', ('started ' + $started), ('finished ' + (Get-UtcStamp ([DateTimeOffset]::UtcNow))))
            if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
            return $false
        }
        try {
            # Remove what a backup that was cut short left behind.
            Get-ChildItem -LiteralPath $dest -Force | Where-Object { $_.Name -like '.work-*' -or $_.Name -like '*.part' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Add-BackupLog $dest ($run + ' start: trigger ' + $trigger + ', sets ' + $setWords)
            $fail = ''; $failDetail = ''
            $work = Join-Path $dest ('.work-' + $run)
            $bytesIn = 0L; $bytesOut = 0L; $files = 0; $sha = ''; $newMap = ''; $mapName = ''; $archiveMs = 0

            # The free-space floor: a backup must never fill the disk.
            $floor = (Get-BackupInt $conf 'min_free_mb' 5120) * 1048576
            $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($dest))).AvailableFreeSpace
            $need = 0L
            if (Test-Path -LiteralPath $saveDir) { foreach ($f in @(Get-ChildItem -LiteralPath $saveDir -File | Where-Object { $_.Name -like '*.sav' -or $_.Name -like '*.db' -or $_.Name -like '*.db-wal' })) { $need += $f.Length } }
            if (($free - $need) -lt $floor) { $fail = 'disk_low'; $failDetail = 'free ' + $free + ', floor ' + $floor }

            if (-not $fail) {
                if ($staging) {
                    if (-not (Test-Path -LiteralPath $staging)) { $fail = 'no_staging'; $failDetail = $staging }
                    else { try { Move-Item -LiteralPath $staging -Destination $work -ErrorAction Stop } catch { $fail = 'no_staging'; $failDetail = 'could not take ' + $staging } }
                } else {
                    [void](New-Item -ItemType Directory -Force -Path $work)
                    # The server is stopped, so nothing is writing and the files are consistent as they are.
                    if ($setList -contains 'world' -and (Test-Path -LiteralPath $saveDir)) {
                        $db = [IO.Path]::Combine($work, 'world', 'db'); [void](New-Item -ItemType Directory -Force -Path $db)
                        foreach ($f in @(Get-ChildItem -LiteralPath $saveDir -File | Where-Object { $_.Name -like '*.db' -or $_.Name -like '*.db-wal' })) { Copy-Item -LiteralPath $f.FullName -Destination $db -Force }
                    }
                    if ($setList -contains 'config' -and (Test-Path -LiteralPath (Join-Path $saveDir 'cfg'))) { Copy-BackupTree (Join-Path $saveDir 'cfg') (Join-Path $work 'cfg') '' }
                    if ($setList -contains 'oxide') {
                        foreach ($sub in @('config', 'data', 'lang')) {
                            $src = Get-BackupDir $conf ($sub + '_dir') ([IO.Path]::Combine($root, 'oxide', $sub))
                            # Hotwire's own data holds this server's panel keys: never in a backup.
                            if ($src) { Copy-BackupTree $src ([IO.Path]::Combine($work, 'oxide', $sub)) 'Hotwire' }
                        }
                    }
                }
            }

            # The save, copied here because it can be large, and checked unchanged across the copy.
            if (-not $fail -and $setList -contains 'world') {
                if (-not $savName) {
                    $newest = @(Get-ChildItem -LiteralPath $saveDir -File -Filter '*.sav' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
                    if ($newest.Count -gt 0) { $savName = $newest[0].Name }
                }
                $savPath = Join-Path $saveDir $savName
                if ($savName -cnotmatch '\A[A-Za-z0-9_.-]+\.sav\z' -or -not (Test-Path -LiteralPath $savPath -PathType Leaf)) { $fail = 'no_save'; $failDetail = $(if ($savName) { $savName } else { 'none found' }) }
                else {
                    [void](New-Item -ItemType Directory -Force -Path (Join-Path $work 'world'))
                    $stat = { $i = Get-Item -LiteralPath $savPath; [string]$i.Length + ' ' + [string]([DateTimeOffset]$i.LastWriteTimeUtc).ToUnixTimeSeconds() }
                    $same = $false
                    for ($try = 1; $try -le 2 -and -not $same; $try++) {
                        $s1 = & $stat
                        if ($savSize -and $s1 -ne ($savSize + ' ' + $savMtime)) { $s2 = 'moved' }
                        else {
                            try { Copy-Item -LiteralPath $savPath -Destination ([IO.Path]::Combine($work, 'world', $savName)) -Force -ErrorAction Stop; $s2 = & $stat } catch { $s2 = 'unreadable' }
                        }
                        if ($s1 -eq $s2) { $same = $true } else { $savSize = ''; Start-Sleep -Seconds 2 }
                    }
                    if (-not $same) { $fail = 'sav_changed'; $failDetail = $savName }
                }
            }
            if (-not $fail -and $setList -contains 'oxide') {
                $plugins = Get-BackupDir $conf 'plugins_dir' ([IO.Path]::Combine($root, 'oxide', 'plugins'))
                if ($plugins) {
                    $pd = [IO.Path]::Combine($work, 'oxide', 'plugins'); [void](New-Item -ItemType Directory -Force -Path $pd)
                    foreach ($f in @(Get-ChildItem -LiteralPath $plugins -File -Filter '*.cs')) { Copy-Item -LiteralPath $f.FullName -Destination $pd -Force }
                }
            }
            # The launcher's settings: hotwire.cfg, which holds no secret. hotwire-secrets.cfg is never backed up.
            if (-not $fail -and $setList -contains 'config' -and (Test-Path -LiteralPath $cfg)) { Copy-Item -LiteralPath $cfg -Destination (Join-Path $work 'hotwire.cfg') -Force }

            # The map: kept once per map, zipped on its own, and named in every backup that needs it.
            if (-not $fail -and $setList -contains 'map') {
                $map = @(Get-ChildItem -LiteralPath $saveDir -File -Filter '*.map' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
                if ($map.Count -gt 0) {
                    $mapName = $map[0].Name
                    $kept = [IO.Path]::Combine($dest, 'maps', $mapName + '.zip')
                    if (-not (Test-Path -LiteralPath $kept)) {
                        try {
                            New-BackupZip $map[0].FullName ($kept + '.part') -Single
                            $mapSha = @{}; $mapSha[$mapName] = Get-FileSha256 $map[0].FullName
                            if (-not (Test-BackupZip ($kept + '.part') $mapSha)) { throw 'the map zip did not check out' }
                            Move-Item -LiteralPath ($kept + '.part') -Destination $kept -Force; $newMap = $mapName
                        } catch {
                            Remove-Item -LiteralPath ($kept + '.part') -Force -ErrorAction SilentlyContinue
                            Add-BackupLog $dest ($run + ': the map could not be kept (the backup goes on)'); $mapName = ''
                        }
                    }
                }
            }

            $name = $run + '.zip'
            if (-not $fail) {
                $expected = @{}; $lines = New-Object 'System.Collections.Generic.List[string]'
                foreach ($f in @(Get-ChildItem -LiteralPath $work -File -Recurse -Force | Sort-Object FullName)) {
                    $rel = $f.FullName.Substring($work.TrimEnd($sep).Length + 1).Replace($sep, '/')
                    $h = Get-FileSha256 $f.FullName
                    $expected[$rel] = $h; $lines.Add($h + '  ./' + $rel); $bytesIn += $f.Length; $files++
                }
                $head = @(('run ' + $run), ('trigger ' + $trigger), ('identity ' + $id), ('save ' + $savName), ('map ' + $mapName), ('sets ' + $setWords), ('created ' + $started), ('launcher ' + $env:HOTWIRE_LAUNCHER_VERSION))
                [IO.File]::WriteAllText((Join-Path $work 'MANIFEST'), (($head + $lines) -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
                $files++
                $t1 = [DateTime]::UtcNow
                $part = Join-Path $dest ($name + '.part')
                try {
                    New-BackupZip $work $part
                    if (-not (Test-BackupZip $part $expected)) { throw 'a file in the zip does not match the MANIFEST' }
                    Move-Item -LiteralPath $part -Destination (Join-Path $dest $name) -Force
                    $archiveMs = [long]([DateTime]::UtcNow - $t1).TotalMilliseconds
                    $bytesOut = (Get-Item -LiteralPath (Join-Path $dest $name)).Length
                    $sha = 'sha256:' + (Get-FileSha256 (Join-Path $dest $name))
                    [IO.File]::WriteAllText((Join-Path $dest ($run + '.meta')), ('run ' + $run + "`ntrigger " + $trigger + "`nmap " + $mapName + "`nsha256 " + $sha + "`nbytes " + $bytesOut + "`n"), (New-Object Text.UTF8Encoding($false)))
                } catch {
                    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                    $fail = 'archive_failed'; $failDetail = [string]$_.Exception.Message
                }
            }
            if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
            if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
            if ($fail) { Add-BackupLog $dest ($run + ' failed: ' + $fail + ' ' + $failDetail) }

            $removed = 0
            if (-not $fail) { $removed = Invoke-BackupRotate $dest $conf }
            $count = 0; $total = 0L
            foreach ($f in @(Get-ChildItem -LiteralPath $dest -File | Where-Object { $_.Name -like '*.zip' -or $_.Name -like '*.tar.zst' })) { $count++; $total += $f.Length }
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $dest 'maps') -File -ErrorAction SilentlyContinue)) { $total += $f.Length }
            $freeNow = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($dest))).AvailableFreeSpace
            $status = 'ok'; if ($fail) { $status = 'failed' }; if ($fail -eq 'disk_low') { $status = 'refused' }
            $dash = { param($v) if ([string]$v) { [string]$v } else { '-' } }
            Write-BackupResult $dest $run @(('run ' + $run), ('trigger ' + $trigger), ('status ' + $status), ('code ' + (& $dash $fail)), ('sets ' + $setWords),
                ('archive ' + $(if ($fail) { '-' } else { $name })), ('sha256 ' + (& $dash $sha)), ('bytes_in ' + $bytesIn), ('bytes_out ' + $bytesOut),
                ('files ' + $files), ('archive_ms ' + $archiveMs), ('total_ms ' + [long]([DateTime]::UtcNow - $t0).TotalMilliseconds), ('map ' + (& $dash $mapName)),
                ('new_map ' + (& $dash $newMap)), ('removed ' + $removed), ('archives ' + $count), ('stored_bytes ' + $total), ('free_bytes ' + $freeNow),
                ('started ' + $started), ('finished ' + (Get-UtcStamp ([DateTimeOffset]::UtcNow))))
            if ($fail) { Say ('Backup ' + $run + ' did not complete (' + $fail + '); see ' + (Join-Path $dest 'backup.log') + '.'); return $false }
            Add-BackupLog $dest ($run + ' ok: ' + $name + ', ' + $bytesIn + ' bytes in, ' + $bytesOut + ' out, ' + $files + ' files, ' + $archiveMs + ' ms, ' + $sha + ', removed ' + $removed)
            Say ('Backup ' + $run + ': ' + $name + ' (' + $bytesOut + ' bytes).')
            return $true
        } finally { $lock.Dispose() }
    } finally { try { $self.PriorityClass = $priority } catch { } }
}

# A live backup Hotwire prepared: claim the flag, then finish the backup.
function Invoke-BackupFromFlag {
    $claim = $backupFlag + '.work'
    try { Move-Item -LiteralPath $backupFlag -Destination $claim -Force -ErrorAction Stop } catch { return }
    $w = @{}
    foreach ($l in [IO.File]::ReadAllLines($claim)) { $p = $l.Split(' ', 2); if ($p.Count -eq 2 -and -not $w.ContainsKey($p[0])) { $w[$p[0]] = $p[1].Trim() } }
    Remove-Item -LiteralPath $claim -Force -ErrorAction SilentlyContinue
    $run = [string]$w['run']; $trigger = [string]$w['trigger']; $size = [string]$w['save_size']; $mtime = [string]$w['save_mtime']; $sets = [string]$w['sets']
    if ($run -cnotmatch '\A[0-9]{8}T[0-9]{6}Z-[a-z_]{1,24}\z') { Say 'Backup flag ignored: no usable run id.'; return }
    if (@('scheduled', 'manual') -notcontains $trigger) { Say 'Backup flag ignored: unknown trigger.'; return }
    if ($size -notmatch '\A[0-9]+\z' -or $mtime -notmatch '\A[0-9]+\z') { $size = ''; $mtime = '' }
    if ($sets -cnotmatch '\A[a-z,]{0,40}\z') { $sets = '' }
    $id = Get-BackupIdentity (Get-BackupConf)
    if (-not $id) { return }
    [void](Invoke-BackupArchive $trigger $run ([IO.Path]::Combine($root, 'backup', $id, '.staging-' + $run)) ([string]$w['save']) $size $mtime $sets)
}

# Between runs, back up the stopped server before an update or a wipe. A wipe asks for a backup in WIPE.flag
# ("backup 1"); an update gets one when Hotwire's backup settings ask for it. A forced wipe may not happen on this
# start, so its backup is taken in the wipe step once that is known.
function Invoke-BackupBeforeLaunch {
    if ($env:BACKUPS -eq '0') { return }
    $trigger = ''
    $flag = Join-Path $root 'WIPE.flag'
    if (Test-Path -LiteralPath $flag) {
        $w = @{}
        foreach ($l in [IO.File]::ReadAllLines($flag)) { $p = $l.Trim().Split(' ', 2); if ($p.Count -eq 2 -and -not $w.ContainsKey($p[0])) { $w[$p[0]] = $p[1].Trim() } }
        $done = ''; $state = [IO.Path]::Combine($root, 'hotwire', 'wipe-cycle')
        if (Test-Path -LiteralPath $state) { $done = ([IO.File]::ReadAllText($state)).Trim() }
        $live = (-not $w['cycle'] -or $w['cycle'] -ne $done) -and -not ($w['expires'] -match '\A[0-9]+\z' -and [long]$w['expires'] -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        if ($w['backup'] -eq '1' -and $w['forced'] -ne '1' -and $live) { $trigger = 'before_wipe' }
    }
    if (-not $trigger -and $env:DO_UPDATE -eq '1') {
        $conf = Get-BackupConf
        if ((Get-BackupSwitch $conf 'enabled' '0') -eq '1' -and (Get-BackupSwitch $conf 'before_update' '1') -eq '1') { $trigger = 'before_update' }
    }
    if (-not $trigger) { return }
    Say ('Backing up the stopped server before the ' + $(if ($trigger -eq 'before_wipe') { 'wipe' } else { 'update' }) + '...')
    [void](Invoke-BackupArchive $trigger ([DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'") + '-' + $trigger) '' '' '' '' '')
}

# ---- reports to AFKPanel -------------------------------------------------------------------------------------
# The session report after each run, and the launcher report when a crash streak stops the launcher, as hotwire.sh
# sends them: the same envelope, signed with the launcher's own key (hotwire\keys.json, written by connect), and
# never sent while a start waits. A report is written to the spool and sent in the background; one that cannot be
# sent waits for a later try. Nothing here delays or stops the server.
$spoolDir = Join-Path $root 'hotwire\launcher-spool'
$spoolMax = 500
$spoolDays = 7

function Read-JsonFile([string]$path) {
    try { if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } } catch { }
    return $null
}

# The panel, the key and the connection a report belongs to; $null when this server is not connected.
function Get-Reporting {
    $connect = Read-JsonFile (Join-Path $root 'hotwire\connect.json')
    $keys = Read-JsonFile (Join-Path $root 'hotwire\keys.json')
    if (-not $connect -or -not $keys) { return $null }
    $url = ([string]$connect.panel_url).TrimEnd('/')
    if (-not $url -or -not $keys.key_id -or -not $keys.secret) { return $null }
    # Which panel, and which server on it, a held report was made for. A report is never sent to another.
    return @{ Url = $url; Key = [string]$keys.key_id; Secret = [string]$keys.secret; Origin = ($url + '|' + [string]$connect.server_id) }
}

function Get-HexSha256([byte[]]$bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

function Get-HexHmac([string]$secret, [string]$text) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $hmac = New-Object Security.Cryptography.HMACSHA256 (, $utf8.GetBytes($secret))
    try { return -join ($hmac.ComputeHash($utf8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) } finally { $hmac.Dispose() }
}

function Get-UtcStamp([DateTimeOffset]$when) { return $when.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }

# Write one report to the spool: kind, report id, sent_at, payload, connection, one per line, as hotwire.sh does.
function Add-SpoolReport([string]$kind, [string]$payload) {
    $r = Get-Reporting
    if (-not $r) { return }
    if (-not (Test-Path -LiteralPath $spoolDir)) { [void](New-Item -ItemType Directory -Force -Path $spoolDir) }
    $rid = [Guid]::NewGuid().ToString()
    $now = [DateTimeOffset]::UtcNow
    $file = Join-Path $spoolDir ([string]$now.ToUnixTimeSeconds() + '-' + $rid)
    [IO.File]::WriteAllText($file + '.tmp', ($kind, $rid, (Get-UtcStamp $now), $payload, $r.Origin -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath ($file + '.tmp') -Destination $file -Force
    $held = @(Get-ChildItem -LiteralPath $spoolDir -File | Where-Object { -not $_.Name.StartsWith('.') -and -not $_.Name.EndsWith('.tmp') } | Sort-Object LastWriteTime)
    if ($held.Count -gt $spoolMax) { $held | Select-Object -First ($held.Count - $spoolMax) | Remove-Item -Force -ErrorAction SilentlyContinue }
}

# POSTs one held report, signed now; its report id and sent_at stay as made. Returns the HTTP status, or 0 for no answer.
function Send-Report($r, [string]$kind, [string]$rid, [string]$sentAt, [string]$payload) {
    $body = '{"contract":1,"report_id":"' + $rid + '","sent_at":"' + $sentAt + '","source":"script","source_version":"' + $env:HOTWIRE_LAUNCHER_VERSION + '","kind":"' + $kind + '","payload":' + $payload + '}'
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($body)
    $ts = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $nonceBytes = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); try { $rng.GetBytes($nonceBytes) } finally { $rng.Dispose() }
    $nonce = -join ($nonceBytes | ForEach-Object { $_.ToString('x2') })
    $sig = Get-HexHmac $r.Secret ('POST /api/v1/report' + "`n" + $ts + "`n" + $nonce + "`n" + (Get-HexSha256 $bytes))
    $headers = @{ 'X-Hotwire-Key' = $r.Key; 'X-Hotwire-Timestamp' = $ts; 'X-Hotwire-Nonce' = $nonce; 'X-Hotwire-Signature' = $sig }
    try {
        $response = Invoke-WebRequest -Uri ($r.Url + '/api/v1/report') -Method Post -Body $bytes -ContentType 'application/json' -Headers $headers -UseBasicParsing -TimeoutSec 15
        return [int]$response.StatusCode
    } catch {
        $status = 0
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        return $status
    }
}

# Sends held reports, oldest first, at most 50 per pass:
#   accepted                                 deleted
#   no answer, 429 or 5xx                    stop; try again later
#   any other refusal                        dropped, because the same bytes would be refused again
#   older than 7 days, or another connection dropped
# One sender at a time; HOTWIRE_SEND_WAIT is how many seconds to wait for another sender to finish.
function Invoke-Send {
    $r = Get-Reporting
    if (-not $r -or -not (Test-Path -LiteralPath $spoolDir)) { return }
    $wait = 0; [void][int]::TryParse([string]$env:HOTWIRE_SEND_WAIT, [ref]$wait)
    $deadline = (Get-Date).AddSeconds($wait)
    $lock = $null
    while ($null -eq $lock) {
        try { $lock = [IO.File]::Open((Join-Path $spoolDir '.sending'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { if ((Get-Date) -ge $deadline) { return }; Start-Sleep -Seconds 1 }
    }
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $sent = 0; $dropped = 0; $expired = 0; $elsewhere = 0
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        foreach ($f in @(Get-ChildItem -LiteralPath $spoolDir -File | Where-Object { -not $_.Name.StartsWith('.') -and -not $_.Name.EndsWith('.tmp') } | Sort-Object LastWriteTime)) {
            if ($sent -ge 50) { break }
            $lines = [IO.File]::ReadAllLines($f.FullName)
            if ($lines.Count -lt 4 -or -not $lines[0]) { Remove-Item -LiteralPath $f.FullName -Force; continue }
            $made = 0L
            if ([long]::TryParse(($f.Name -split '-', 2)[0], [ref]$made) -and ($now - $made) -gt ($spoolDays * 86400)) {
                Remove-Item -LiteralPath $f.FullName -Force; $expired++; continue
            }
            if ($lines.Count -ge 5 -and $lines[4] -and $lines[4] -ne $r.Origin) { Remove-Item -LiteralPath $f.FullName -Force; $elsewhere++; continue }
            $code = Send-Report $r $lines[0] $lines[1] $lines[2] $lines[3]
            if ($code -ge 200 -and $code -lt 300) { Remove-Item -LiteralPath $f.FullName -Force; $sent++ }
            elseif ($code -eq 0 -or $code -eq 429 -or $code -ge 500) { break }
            else { Remove-Item -LiteralPath $f.FullName -Force; $dropped++; Say ('A held ' + $lines[0] + ' report was refused (HTTP ' + $code + ') and dropped, because it would be refused again.') }
        }
        if ($sent -gt 0) { Say ('Sent ' + $sent + ' held report(s) to AFKPanel.') }
        if ($expired -gt 0) { Say ('Dropped ' + $expired + ' report(s) held more than ' + $spoolDays + ' days.') }
        if ($elsewhere -gt 0) { Say ('Dropped ' + $elsewhere + ' report(s) made for another panel or another server.') }
    } finally { $lock.Dispose() }
}

# Writes the report cmd asks for: HOTWIRE_REPORT is session or launcher.
function Invoke-Report {
    $bool = { param($v) if ([string]$v -eq '1') { 'true' } else { 'false' } }
    if ($env:HOTWIRE_REPORT -eq 'session') {
        $started = [string]$env:HOTWIRE_STARTED_AT
        if ($started -notmatch '\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z') { $started = Get-UtcStamp ([DateTimeOffset]::UtcNow) }
        $exit = 0; [void][int]::TryParse([string]$env:HOTWIRE_RUST_EXIT, [ref]$exit)
        $p = '{"started_at":"' + $started + '","ended_at":"' + (Get-UtcStamp ([DateTimeOffset]::UtcNow)) + '","exit_code":' + $exit + ',"crashed":' + (& $bool $env:HOTWIRE_CRASHED)
        $acf = Join-Path $root 'steamapps\appmanifest_258550.acf'
        if (Test-Path -LiteralPath $acf) {
            $m = [regex]::Match([IO.File]::ReadAllText($acf), [char]34 + 'buildid' + [char]34 + '\s+' + [char]34 + '(\d+)' + [char]34)
            if ($m.Success) { $p += ',"rust_build_id":"' + $m.Groups[1].Value + '"' }
        }
        $kept = (Test-Path -LiteralPath (Join-Path $root 'UPDATE.flag')) -or (Test-Path -LiteralPath (Join-Path $root 'VALIDATE.flag'))
        $p += ',"update":{"attempted":' + (& $bool $env:HOTWIRE_UPDATE_ATTEMPTED) + ',"steam_ok":' + (& $bool $env:STEAM_OK) + ',"framework_ok":' + (& $bool $env:FRAMEWORK_OK) + ',"flag_kept":' + $(if ($kept) { 'true' } else { 'false' }) + '}}'
        Add-SpoolReport 'session' $p
    } elseif ($env:HOTWIRE_REPORT -eq 'launcher') {
        $streak = 0; [void][int]::TryParse([string]$env:CRASH_STREAK, [ref]$streak)
        $log = @(Get-ChildItem -LiteralPath (Join-Path $root 'logs') -Filter 'server_crash_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $preserved = if ($log.Count -gt 0) { 'logs/' + $log[0].Name } else { '' }
        $detail = [string]$streak + ' consecutive runs under ' + [string]$env:CRASH_SECONDS + 's'
        Add-SpoolReport 'launcher' ('{"state":"stopped","reason":"crash_streak","detail":"' + $detail + '","crash_streak":' + $streak + ',"preserved_log":"' + $preserved + '"}')
    }
}

try {
    switch ($env:HOTWIRE_MODE) {
        'load'   { Invoke-Load }
        'edits'  { Invoke-Edits }
        'launch' { Invoke-Launch }
        'backup' { Invoke-BackupBeforeLaunch }
        'report' { Invoke-Report }
        'send'   { Invoke-Send }
        default  { Say ('Unknown HOTWIRE_MODE ' + $env:HOTWIRE_MODE); exit 2 }
    }
} catch {
    Say ('hotwire.bat (' + $env:HOTWIRE_MODE + '): ' + $_.Exception.Message)
    exit 1
}
exit 0
