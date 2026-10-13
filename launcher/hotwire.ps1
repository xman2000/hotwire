# hotwire.ps1: the Hotwire launcher for Windows. hotwire.bat starts it, and starts it again when it exits with 75,
# which is how a hotwire.ps1 replaced while the server runs takes over at the next restart. PowerShell reads this whole
# file before it runs, so replacing it while the launcher runs is safe.
#
# It starts the Rust server and starts it again when it exits; it updates Rust and Oxide when the update mode says so,
# carries out the wipes and permanent convars the plugin asks for, finishes the backups the plugin prepares, and
# reports to AFKPanel once connected. See docs/LAUNCHER.md.
#
# Settings are read as data, one line at a time, and never run. A line is a name, spaces, then a value. A value
# with spaces goes in double quotes and cannot contain one; no control characters. Each value is checked before
# use: a line that fails is ignored, check lists it, and the default applies. A bad value for the settings that
# would make a different server if defaulted (the save folder, the map and the ports) is not replaced: it stops
# the first start, and a later restart keeps the last good settings. The rules match hotwire.sh line for line.
# Windows PowerShell 5.1, ASCII only.
$ErrorActionPreference = 'Stop'
# Who this launcher is, for the plugin: written to oxide\data\Hotwire\launcher.json before every start. The plugin
# offers only the features in the capability list; settings_file means the settings come from hotwire.cfg.
$LauncherVersion = '1.1.40'
$LauncherCapabilities = 'supervise,update,framework_verify,crash_backstop,log_rotate,convar_persist,wipe,wipe_same_map,wipe_custom_map,backup,settings_file,rcon_optional,wipe_permit,wipe_permit_blueprints,update_mode_set,update_progress,start_steps,self_update'
# HOTWIRE_ROOT_OVERRIDE is set only by the launcher itself, when it checks a downloaded update against this server's
# settings before installing it (Invoke-SelfUpdate): the copy runs from hotwire\self-update\stage\.
$root = $(if ($env:HOTWIRE_ROOT_OVERRIDE) { $env:HOTWIRE_ROOT_OVERRIDE } else { $PSScriptRoot })
$cfg = Join-Path $root 'hotwire.cfg'
$secretsCfg = Join-Path $root 'hotwire-secrets.cfg'
$argsFile = Join-Path $root 'hotwire\launch-args.json'

# Messages go straight to the window (stderr), because the settings step hands its settings over on stdout.
function Say([string]$message) {
    [Console]::Error.WriteLine('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $message)
    # What this start said about its update, for the session report, so AFKPanel can show why a start did or did not
    # update. Only the launcher's own lines between the update decision and the end of the update.
    if ($script:UpdateCapture -and $script:UpdateLog.Count -lt 40) {
        $line = $message; if ($line.Length -gt 300) { $line = $line.Substring(0, 300) }
        [void]$script:UpdateLog.Add('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $line)
    }
}
$script:UpdateCapture = $false
$script:UpdateLog = New-Object System.Collections.ArrayList
$script:UpdateReason = ''
$script:UpdateEffective = ''
# Why this start did not update, or the first thing that failed. AFKPanel shows its own words for each code.
function Set-UpdateReason([string]$code) { if (-not $script:UpdateReason) { $script:UpdateReason = $code } }
function Rule { [Console]::Error.WriteLine('========================================================') }

# hotwire.<name>: environment variable, kind, default. Some reach SteamCMD's command line, so each kind is checked to
# contain nothing a command line treats as syntax.
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
    'hotwire.steamcmd_update_minutes'  = @('STEAMCMD_UPDATE_MINUTES', 'int', '60')
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
    'hotwire.hook_timeout_minutes'     = @('HOOK_TIMEOUT_MINUTES', 'int1', '30')
    'hotwire.self_update'              = @('SELF_UPDATE', 'selfupdate', 'off')
    'hotwire.self_update_days'         = @('SELF_UPDATE_DAYS', 'int', '3')
    'hotwire.self_update_channel'      = @('SELF_UPDATE_CHANNEL', 'channel', 'release')
    'hotwire.self_update_test_key'     = @('SELF_UPDATE_TEST_KEY', 'bool', '0')
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
        'selfupdate' { if ($v -cnotmatch '^(auto|off)$') { return 'must be auto or off' } }
        'channel'   { if ($v -cnotmatch '^(release|dev)$') { return 'must be release or dev' } }
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

# One line that is not used as written: for check, and for AFKPanel through launcher.json.
function Add-CfgNote($r, [int]$n, [string]$name, [bool]$critical, [string]$what) {
    $shown = 'line ' + $n + ': '; if ($name) { $shown = $shown + $name + ': ' }
    $r.Problems.Add($shown + $what)
    $r.Report.Add([ordered]@{ line = $n; setting = $name; critical = $critical; problem = $what })
}

# Reads hotwire.cfg: what it sets, and every line not used.
function Read-Config {
    $r = @{
        Missing = $false; Values = @{}; Extra = [ordered]@{}; Known = @{}
        Problems = New-Object 'System.Collections.Generic.List[string]'
        Fatal = New-Object 'System.Collections.Generic.List[string]'
        Unknown = New-Object 'System.Collections.Generic.List[string]'
        # The same lines for AFKPanel, in launcher.json: line, setting, critical, problem. Never a value.
        Report = New-Object 'System.Collections.Generic.List[object]'
    }
    $used = @{}
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
        if ($p.Why) {
            # A line whose value cannot be read is not used, so a setting it names keeps its default. For the settings
            # that decide which server this is (save folder, map, ports) that is a different server, so it is marked.
            $nm = [regex]::Match($line, '^([A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+)(\s|$)')
            $named = ''; $k = $null
            if ($nm.Success) {
                $named = $nm.Groups[1].Value; $ln = $named.ToLowerInvariant()
                if ($hwSettings.ContainsKey($ln)) { $k = $hwSettings[$ln][1] } elseif ($cvSettings.ContainsKey($ln)) { $k = $cvSettings[$ln][0] }
            }
            if ($k) { Add-CfgNote $r $n $named ($criticalKinds -contains $k) ($p.Why + '; the line is not used, so the default is') }
            else { Add-CfgNote $r $n $named $false $p.Why }
            continue
        }
        $name = $p.Name; $lower = $name.ToLowerInvariant()
        if ($listed) { $r.Known[$lower] = 1 }
        if ($lower -eq 'rcon.password') { Add-CfgNote $r $n 'rcon.password' $false 'belongs in hotwire-secrets.cfg, never here; ignored'; continue }
        $kind = $null
        if ($hwSettings.ContainsKey($lower)) { $kind = $hwSettings[$lower][1] } elseif ($cvSettings.ContainsKey($lower)) { $kind = $cvSettings[$lower][0] }
        if ($kind) {
            $why = Test-CfgValue $kind $p.Value
            if ($why) {
                if ($criticalKinds -contains $kind) {
                    $r.Fatal.Add('line ' + $n + ': ' + $name + ': ' + $why)
                    $r.Report.Add([ordered]@{ line = $n; setting = $name; critical = $true; problem = ($why + '; the settings from the last good read are used') })
                }
                else { Add-CfgNote $r $n $name $false ($why + '; the default is used') }
                continue
            }
            # Numbers are passed on in base 10, so a leading zero never changes one.
            $value = $p.Value
            if ($value -ne '' -and @('int', 'int1', 'seed', 'worldsize', 'port') -contains $kind) { $value = [string][long]$value }
            # Set twice: the later line is the one used, and the one a wipe or a saved convar edits.
            if ($used.ContainsKey($lower)) { Add-CfgNote $r $n $name ($criticalKinds -contains $kind) ('also set on line ' + $used[$lower] + '; line ' + $n + ' is used') }
            $used[$lower] = $n
            $r.Values[$lower] = $value
            continue
        }
        if ($lower.StartsWith('hotwire.')) { Add-CfgNote $r $n $name $false 'not a launcher setting; ignored'; continue }
        # Any other Rust convar is passed through unchanged. Empty means the default.
        if ($p.Value -eq '') { continue }
        if ($used.ContainsKey($lower)) { Add-CfgNote $r $n $name $false ('also set on line ' + $used[$lower] + '; line ' + $n + ' is used') }
        $used[$lower] = $n
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

# Reads hotwire-secrets.cfg as data, like hotwire.cfg, and takes only rcon.password.
# The RCON password is optional: Hotwire does not use RCON, and Rust runs with RCON off when it is given no password.
# Returns @{ Password } (empty: RCON off, with Off saying why) or @{ Why } for a password set but unusable.
function Read-Secret([int]$minimum) {
    if (-not (Test-Path -LiteralPath $secretsCfg -PathType Leaf)) {
        return @{ Password = ''; Off = 'RCON is off: no hotwire-secrets.cfg. Hotwire does not need RCON; set rcon.password there to turn it on.' }
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
    if ($password -eq '') { return @{ Password = ''; Off = 'RCON is off: hotwire-secrets.cfg sets no rcon.password.' } }
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
    # A password set but unusable never stops a start: the last good one is kept, or RCON stays off.
    $keepPassword = $false
    if ($secret.Why) {
        Rule; Say $secret.Why
        if ([string]$script:Rcon64 -ne '') { Say 'Starting with the RCON password from the last start.'; $keepPassword = $true }
        else { Say 'Starting with RCON off until it is fixed.' }
        Rule
    } elseif ($secret.Off -and -not $quiet) { Say $secret.Off }

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
    # The password stays in this process's environment, as in the old launcher, base64-encoded so the environment
    # holds only letters, digits, + / and =.
    if (-not $keepPassword) { Write-Output ('HWSET HOTWIRE_RCON64=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$secret.Password))) }
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
                # The last line that sets it, the one the reader uses: changing the first left the old value in force.
                if ($first.ToLowerInvariant() -eq $want) { $done = $i; continue }
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

# AFKPanel's public key for wipe permissions, as the RSA modulus and exponent (Windows PowerShell 5.1 cannot read a PEM).
# Wipes are part of AFKPanel Pro: a wipe runs only with AFKPanel's signed permission for this server, this wipe and this
# map, checked here. The private half is AFKPanel's alone.
$WipePermitModulus = 'otv0GyyUvwmrVHLcq+1yFZHmZbxBIr+coTcMKK2trfccv/9i/k8+7SjO1k/TnP0qRkOn7swCfYYovTvxeFB/7DYAMCzdPOM74ZZ+KPfCAjdv+hQ7F57VooZd+/nCdbc6UK/2Md5obkocKveFsZDGDXTS4b3P1wt9VlV6x/VlObVqmWSBPAyhLHaS3xiaC7jjr2x9HZk5aGXxNvk/xgt8W8Tt26vAr1xc3INBmfK49fFgCYQrj+rKOtnRkTbEd0/f/TY8qg5uUgOC6cSQkt2US0WRrC6izC/8cBt8WXH6JNHs3+Rqogrbl76AMQjvQTZ5swNbZvxZEo+LRdcAKJdjVQWnxfmBLc/4tlbfeCh4NoLpLqcgAttxRLqom6/6xNRVbB2eWUlx8qYFIecxknGL++ylOpnqKbNtA3KziFvH+GVqvsf1kSW8dDAeRQLwdY3JoIybQNKkd3DZBk8a4HVs/HzyrC8U7xraCdmG2FqxQY/WKnYFvvz0u8CFAebxRukh'
$WipePermitExponent = 'AQAB'

# Whether a wipe permission verifies: RSA, SHA-256, over the seven lines AFKPanel signed, rebuilt from the flag.
# Version 2 signs the blueprints too and is tried first; version 1 is what AFKPanel signed before this launcher said it
# checks version 2, so a permission made then still wipes. Once version 2 is signed, a changed blueprints line fails.
function Test-OxideZipEntries([string]$zip) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            if ($archive.Entries.Count -eq 0) { return $false }
            foreach ($e in $archive.Entries) {
                $n = $e.FullName.Replace('\', '/')
                if (-not $n.StartsWith('RustDedicated_Data/') -or $n -match '(^|/)\.\.(/|$)' -or $n.StartsWith('/') -or $n -match '^[A-Za-z]:') { return $false }
            }
            return $true
        } finally { $archive.Dispose() }
    } catch { return $false }
}

function Test-WipePermit([string]$server, [string]$cycle, [string]$seed, [string]$size, [string]$levelUrl, [string]$expires, [string]$permit, [string]$modulus, [string]$exponent, [string]$blueprints = '') {
    try {
        $params = New-Object Security.Cryptography.RSAParameters
        $params.Modulus = [Convert]::FromBase64String($modulus)
        $params.Exponent = [Convert]::FromBase64String($exponent)
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        $rsa.ImportParameters($params)
        $signature = [Convert]::FromBase64String($permit)
        $utf8 = New-Object Text.UTF8Encoding($false)
        if ($blueprints) {
            $text = 'hotwire-wipe-permit 2' + "`n" + 'server ' + $server + "`n" + 'cycle ' + $cycle + "`n" + 'seed ' + $seed + "`n" + 'size ' + $size + "`n" + 'levelurl ' + $levelUrl + "`n" + 'blueprints ' + $blueprints + "`n" + 'expires ' + $expires + "`n"
            if ($rsa.VerifyData($utf8.GetBytes($text), 'SHA256', $signature)) { return $true }
        }
        $text = 'hotwire-wipe-permit 1' + "`n" + 'server ' + $server + "`n" + 'cycle ' + $cycle + "`n" + 'seed ' + $seed + "`n" + 'size ' + $size + "`n" + 'levelurl ' + $levelUrl + "`n" + 'expires ' + $expires + "`n"
        return [bool]$rsa.VerifyData($utf8.GetBytes($text), 'SHA256', $signature)
    } catch { return $false }
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
        $forced = [string]$w['forced']; $armedBuild = [string]$w['armed_build']; $levelUrl = [string]$w['levelurl']
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
            elseif ($levelUrl -and ($levelUrl -cnotmatch '^https?://\S+$' -or $levelUrl -match '["''`$\\]' -or $levelUrl.Length -gt 500)) { $why = 'the map address must be an http:// or https:// address with no quote, $ or backslash' }
            # The settings in use are the last good ones because hotwire.cfg has a line that changes which server this is:
            # a wipe written now would be recorded as done while the server boots on the old ones.
            elseif ($env:HOTWIRE_LOAD_STATE -eq 'kept') { $why = 'hotwire.cfg has a setting that cannot be used, so the last good settings are in use; fix it first' }
            # Wipes are part of AFKPanel Pro: AFKPanel's permission for this server, this wipe and this map, checked against
            # the values exactly as the flag carries them, before anything is backed up, written or renamed.
            if (-not $why) {
                $permit = [string]$w['permit']; $permitExpires = [string]$w['permit_expires']; $permitServer = [string]$w['server']
                $connect = Read-JsonFile (Join-Path $root 'hotwire\connect.json')
                $myServer = ''; if ($connect -and $null -ne $connect.server_id) { $myServer = [string]$connect.server_id }
                if (-not $permit) { $why = 'no permission from AFKPanel (wipes are part of AFKPanel Pro)' }
                elseif ($permitExpires -notmatch '^\d+$' -or [long]$permitExpires -le $now) { $why = 'AFKPanel''s permission has expired' }
                elseif (-not $myServer -or $permitServer -ne $myServer) { $why = 'AFKPanel''s permission is for another server' }
                elseif (-not (Test-WipePermit $permitServer $cycle $seed $size $levelUrl $permitExpires $permit $WipePermitModulus $WipePermitExponent $bp)) { $why = 'AFKPanel''s permission does not match this wipe' }
            }
            # A forced wipe's backup waits until the update is known to have arrived (above).
            if (-not $why -and $forced -eq '1' -and $w['backup'] -eq '1' -and $env:BACKUPS -ne '0') {
                Say 'Backing up the stopped server before the wipe...'
                [void](Invoke-BackupArchive 'before_wipe' ([DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'") + '-before_wipe') '' '' '' '' '')
            }
            # The map change first, all of it or none: a custom map is its address; a generated map is its seed (and
            # size), and a custom map set before is cleared, or Rust would keep loading it.
            if (-not $why) {
                if ($levelUrl) { $pairs = @(, @('server.levelurl', $levelUrl)) }
                else {
                    $pairs = @(, @('server.seed', $seed))
                    if ($size) { $pairs += , @('server.worldsize', $size) }
                    if ([string](Read-Config).Values['server.levelurl']) { $pairs += , @('server.levelurl', '') }
                }
                if (-not (Set-CfgValues $pairs)) { $why = 'could not write the new map' }
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
                # A fresh world, even on the same map. Rust names a save after its map (level, size, seed and protocol,
                # or a custom map's file name) and loads that save if it exists, so the same seed or the same custom map
                # would bring the old world back. Every world save in the folder is set aside (renamed, never deleted):
                # the .sav, its numbered copies and its .navmesh. A custom map's downloaded copy goes too, so a map
                # changed at the same address is fetched again; a generated map's .map stays.
                # The cycle is recorded and the flag removed before any file is renamed: the new map is already in
                # hotwire.cfg, so running this wipe again at a later start would set the new world aside too. A file that
                # cannot be renamed (another program holds it) is named and left; the wipe is still done.
                if ($cycle) {
                    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cycleFile))
                    [IO.File]::WriteAllText($cycleFile, $cycle)
                }
                Remove-Item -LiteralPath $flag -Force
                $notMoved = New-Object 'System.Collections.Generic.List[string]'
                $setAside = 0
                if (Test-Path -LiteralPath $folder) {
                    $wstamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    foreach ($f in @(Get-ChildItem -LiteralPath $folder -File)) {
                        $n = $f.Name
                        if ($n.Contains('.wiped-')) { continue }
                        $isWorld = $n.EndsWith('.sav') -or $n -match '\.sav\.[0-9]' -or $n.EndsWith('.navmesh')
                        $isCustomMap = $levelUrl -and $n.EndsWith('.map') -and $n -cnotmatch '^[a-z0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.map$'
                        if (-not ($isWorld -or $isCustomMap)) { continue }
                        try { Rename-Item -LiteralPath $f.FullName -NewName ($n + '.wiped-' + $wstamp) -ErrorAction Stop; $setAside++ }
                        catch { $notMoved.Add($n) }
                    }
                }
                if ($bp -ne 'keep' -and (Test-Path -LiteralPath $folder)) {
                    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter 'player.blueprints.*.db' -File)) {
                        try {
                            if ($bp -eq 'delete') { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
                            else { Rename-Item -LiteralPath $f.FullName -NewName ($f.Name + '.wiped-' + $stamp) -ErrorAction Stop }
                            $count++
                        } catch { $notMoved.Add($f.Name) }
                    }
                }
                if ($notMoved.Count -gt 0) {
                    Rule
                    Say ('Could not move ' + $notMoved.Count + ' file(s), which another program had open: ' + ($notMoved -join ', ') + '.')
                    Say 'The wipe is done; Rust may load an old world file it finds there. Close the program holding it, delete the file, and restart.'
                    Rule
                }
                $sizeText = 'unchanged'; if ($size) { $sizeText = $size }
                $bpText = 'kept'; if ($bp -ne 'keep') { $bpText = $bp + ' (' + $count + ' file(s))' }
                if ($levelUrl) {
                    [IO.File]::WriteAllText($result, 'applied: map ' + $levelUrl + ' blueprints ' + $bpText + "`n")
                    $mapText = 'custom map ' + $levelUrl
                } else {
                    [IO.File]::WriteAllText($result, 'applied: seed ' + $seed + ' size ' + $sizeText + ' blueprints ' + $bpText + "`n")
                    $mapText = 'seed ' + $seed + ', size ' + $sizeText
                }
                Say ('Wipe applied: ' + $mapText + ', blueprints ' + $bpText + '. A new world starts on this start; ' + $setAside + ' old world file(s) were renamed *.wiped-* and left on disk.')
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

# ---- Update mode from AFKPanel (capability: update_mode_set) ---------------------------------------------------
# The plugin leaves UPDATE_MODE.request holding one word. Only auto and always are taken: off and hotwire stay something
# the admin writes into hotwire.cfg. It is applied before the update decision, so a waiting UPDATE.flag installs on this
# same start. The receipt is UPDATE_MODE.result; the request is removed either way. True when hotwire.cfg changed.
function Invoke-UpdateModeRequest {
    $request = Join-Path $root 'UPDATE_MODE.request'
    if (-not (Test-Path -LiteralPath $request)) { return $false }
    $result = Join-Path $root 'UPDATE_MODE.result'
    Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    $was = Get-Env 'UPDATE_MODE'
    $want = ''
    # The plugin writes a plain file; a link is not followed.
    if (((Get-Item -LiteralPath $request -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-Item -LiteralPath $request -Force -ErrorAction SilentlyContinue
        try { [IO.File]::WriteAllText($result, "reject : UPDATE_MODE.request is a link, not a file`n") } catch { }
        Say ('UPDATE_MODE.request is a link, not a file, so it was not read. hotwire.update_mode stays ' + $was + '.')
        return $false
    }
    try { $want = ([IO.File]::ReadAllText($request)) -replace '\s', '' } catch { }
    if ($want.Length -gt 16) { $want = $want.Substring(0, 16) }
    Remove-Item -LiteralPath $request -Force -ErrorAction SilentlyContinue
    if ($want -cne 'auto' -and $want -cne 'always') {
        try { [IO.File]::WriteAllText($result, 'reject ' + $want + " : the panel sets auto or always only`n") } catch { }
        Say ('AFKPanel asked for update mode ''' + $want + ''', which is not auto or always. hotwire.update_mode stays ' + $was + '.')
        return $false
    }
    if ($want -ceq $was) {
        try { [IO.File]::WriteAllText($result, 'unchanged ' + $want + "`n") } catch { }
        Say ('AFKPanel asked for update mode ' + $want + '; hotwire.update_mode is already ' + $want + '.')
        return $false
    }
    if (Set-CfgValues @(, @('hotwire.update_mode', $want))) {
        # Read back: a hotwire.cfg the launcher cannot use keeps the last start's settings, and then the mode did not change.
        try { [void](Import-Settings -Quiet) } catch { Say ('Could not read the settings: ' + $_.Exception.Message) }
        if ((Get-Env 'UPDATE_MODE') -cne $want) {
            try { [IO.File]::WriteAllText($result, 'reject ' + $want + " : hotwire.cfg was written but cannot be used now, so the last start's settings stay`n") } catch { }
            Say ('hotwire.update_mode ' + $want + ' was written into hotwire.cfg, but the file cannot be used now, so this start keeps ' + $was + '. Run hotwire.bat check.')
            return $true
        }
        try { [IO.File]::WriteAllText($result, 'applied ' + $want + ' (was ' + $was + ")`n") } catch { }
        Say ('Update mode set to ' + $want + ' from AFKPanel (was ' + $was + '); hotwire.cfg now says hotwire.update_mode ' + $want + '.')
        return $true
    }
    try { [IO.File]::WriteAllText($result, 'reject ' + $want + " : could not write hotwire.cfg`n") } catch { }
    Say ('AFKPanel asked for update mode ' + $want + ', but hotwire.cfg could not be written. hotwire.update_mode stays ' + $was + '.')
    return $false
}

# ---- Hotwire's own updates (capability: self_update) ------------------------------------------------------------
# As in hotwire.sh, step for step: off unless hotwire.cfg says hotwire.self_update auto or AFKPanel's "Update Hotwire"
# button asks (HOTWIRE_UPDATE.request). Before a start, with the server stopped: the newest release on the channel that
# is old enough and newer than what is installed; its manifest must be signed by a key below (AFKPanel never holds
# them); each file must match the manifest; the new hotwire.ps1 must pass check against this server's hotwire.cfg. The
# current files go to hotwire\previous\, the new ones in, and hotwire\self-update\applied says so. A new hotwire.ps1
# takes over at once (exit 75). Probation: the new plugin must write loaded.json within $SuProbationSeconds, or the
# previous plugin goes back while the server runs; a crash before then puts both previous files back; a new hotwire.ps1
# that fails before the server starts is put back by hotwire.bat. After any of these, automatic updates stop until an
# admin asks again. Nothing here can stop a start.
$SuFeed = 'https://api.github.com/repos/xman2000/hotwire/releases?per_page=30'
$SuDownload = 'https://github.com/xman2000/hotwire/releases/download'
# For the tests only. Still nothing installs unless a trusted key signed it.
if ($env:HOTWIRE_SELF_UPDATE_FEED) { $SuFeed = $env:HOTWIRE_SELF_UPDATE_FEED }
if ($env:HOTWIRE_SELF_UPDATE_DOWNLOAD) { $SuDownload = $env:HOTWIRE_SELF_UPDATE_DOWNLOAD }
# id = public key, P-256, X then Y in hex. The test key is trusted only where hotwire.cfg says hotwire.self_update_test_key 1.
$SuKeys = [ordered]@{}
$SuTestKeyId = 'test-2026-10-12'
$SuTestKey = 'e21f6da76eae1d3bed968459d952541bf0e38ec238d19e010a8e87f701b8f9ebbe8fcacd624a39db52b46f5ed8dbdbd54f3ff1b2d21ea29df2ce890ed429bb31'
$SuDir = [IO.Path]::Combine($root, 'hotwire', 'self-update')
$SuPrevious = [IO.Path]::Combine($root, 'hotwire', 'previous')
$SuApplied = Join-Path $SuDir 'applied'
$SuRolledBack = Join-Path $SuDir 'rolled-back'
$SuState = Join-Path $SuDir 'state'
$SuPlugin = [IO.Path]::Combine($root, 'oxide', 'plugins', 'Hotwire.cs')
$SuLoaded = [IO.Path]::Combine($root, 'oxide', 'data', 'Hotwire', 'loaded.json')
$SuProbationSeconds = 1200

function Get-SuState([string]$key) {
    try { foreach ($l in [IO.File]::ReadAllLines($SuState)) { if ($l.StartsWith($key + '=')) { return $l.Substring($key.Length + 1) } } } catch { }
    return ''
}
function Set-SuState([hashtable]$values) {
    try {
        [void](New-Item -ItemType Directory -Force -Path $SuDir)
        $lines = New-Object 'System.Collections.Generic.List[string]'
        if (Test-Path -LiteralPath $SuState) { foreach ($l in [IO.File]::ReadAllLines($SuState)) { if (-not ($values.Keys | Where-Object { $l.StartsWith($_ + '=') })) { $lines.Add($l) } } }
        foreach ($k in $values.Keys) { $lines.Add($k + '=' + ([string]$values[$k] -replace '[\r\n]', ' ')) }
        [IO.File]::WriteAllLines($SuState + '.tmp', $lines)
        Move-Item -LiteralPath ($SuState + '.tmp') -Destination $SuState -Force
    } catch { }
}
function Set-SuBlocked([string]$reason, [string]$tag) {
    Set-SuState @{ blocked = '1'; reason = $reason; blocked_tag = $tag; blocked_at = (Get-UtcStamp ([DateTimeOffset]::UtcNow)) }
}
function Get-PluginVersion {
    try { $m = [regex]::Match([IO.File]::ReadAllText($SuPlugin), '\[Info\("Hotwire", "[^"]*", "([0-9.]+)"\)\]'); if ($m.Success) { return $m.Groups[1].Value } } catch { }
    return ''
}
# Whether version a is newer than b (dotted numbers).
function Test-SuNewer([string]$a, [string]$b) {
    if (-not $a) { return $false }
    if (-not $b) { return $true }
    try { return ([version]$a) -gt ([version]$b) } catch { return $false }
}
function ConvertFrom-Hex([string]$hex) {
    $bytes = New-Object byte[] ($hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    return , $bytes
}
# True when a trusted key signed the manifest. The signature file is "key <id>" and "sig <base64 of r and s>".
function Test-ReleaseSignature([string]$manifest, [string]$sigFile) {
    $script:SuWhy = ''
    $id = ''; $sig = ''
    try {
        foreach ($l in [IO.File]::ReadAllLines($sigFile)) {
            if ($l -cmatch '^key ([A-Za-z0-9._-]{1,64})$') { $id = $Matches[1] }
            elseif ($l -cmatch '^sig ([A-Za-z0-9+/=]{80,100})$') { $sig = $Matches[1] }
        }
    } catch { }
    if (-not $id -or -not $sig) { $script:SuWhy = 'the signature file is not in the expected form'; return $false }
    $rs = [Convert]::FromBase64String($sig)
    if ($rs.Length -ne 64) { $script:SuWhy = 'the signature is not 64 bytes'; return $false }
    $keys = [ordered]@{}
    foreach ($k in $SuKeys.Keys) { $keys[$k] = $SuKeys[$k] }
    if ((Get-Env 'SELF_UPDATE_TEST_KEY') -eq '1') { $keys[$SuTestKeyId] = $SuTestKey }
    if (-not $keys.Contains($id)) { $script:SuWhy = 'it is not signed by a key this launcher trusts (key ' + $id + ')'; return $false }
    $pub = ConvertFrom-Hex $keys[$id]
    $q = New-Object Security.Cryptography.ECPoint
    $q.X = $pub[0..31]; $q.Y = $pub[32..63]
    $p = New-Object Security.Cryptography.ECParameters
    $p.Curve = [Security.Cryptography.ECCurve]::CreateFromValue('1.2.840.10045.3.1.7')
    $p.Q = $q
    $ec = [Security.Cryptography.ECDsa]::Create($p)
    try { $ok = $ec.VerifyData([IO.File]::ReadAllBytes($manifest), $rs, [Security.Cryptography.HashAlgorithmName]::SHA256) } finally { $ec.Dispose() }
    if (-not $ok) { $script:SuWhy = 'its signature does not match (key ' + $id + ')' }
    return [bool]$ok
}

# SELF_UPDATE.request from AFKPanel: "off", "auto <days>", or "retry", written into hotwire.cfg as the update mode is.
# The channel and the test key stay the admin's, in hotwire.cfg.
function Invoke-SelfUpdateRequest {
    $request = Join-Path $root 'SELF_UPDATE.request'
    if (-not (Test-Path -LiteralPath $request)) { return }
    $result = Join-Path $root 'SELF_UPDATE.result'
    Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    if (((Get-Item -LiteralPath $request -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-Item -LiteralPath $request -Force -ErrorAction SilentlyContinue
        try { [IO.File]::WriteAllText($result, "reject : not a file`n") } catch { }
        return
    }
    $text = ''
    try { $text = ([IO.File]::ReadAllText($request)).Trim() } catch { }
    Remove-Item -LiteralPath $request -Force -ErrorAction SilentlyContinue
    $parts = @($text -split '\s+')
    $answer = ''
    switch -CaseSensitive ($parts[0]) {
        'off' {
            if (Set-CfgValues @(, @('hotwire.self_update', 'off'))) { try { [void](Import-Settings -Quiet) } catch { }; $answer = 'applied off'; Say 'Hotwire''s automatic updates turned off from AFKPanel.' }
            else { $answer = 'reject off : could not write hotwire.cfg' }
        }
        'auto' {
            $days = $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
            if ($days -cnotmatch '^[0-9]{1,3}$') { $answer = 'reject auto : days must be 0 to 999' }
            elseif (Set-CfgValues @(@('hotwire.self_update', 'auto'), @('hotwire.self_update_days', $days))) {
                try { [void](Import-Settings -Quiet) } catch { }
                Set-SuState @{ blocked = '0'; reason = '' }
                $answer = 'applied auto ' + $days
                Say ('Hotwire''s automatic updates turned on from AFKPanel: releases at least ' + $days + ' days old.')
            } else { $answer = 'reject auto : could not write hotwire.cfg' }
        }
        'retry' { Set-SuState @{ blocked = '0'; reason = '' }; $answer = 'applied retry'; Say 'Hotwire''s automatic updates resume: AFKPanel asked to try again.' }
        default { $answer = 'reject : not off, auto or retry' }
    }
    try { [IO.File]::WriteAllText($result, $answer + "`n") } catch { }
}

# The files an update replaced go back, and automatic updates stop. $launcherToo when hotwire.ps1 was replaced as well.
function Undo-SelfUpdate([string]$reason, [string]$from) {
    $tag = ''
    try { foreach ($l in [IO.File]::ReadAllLines($from)) { if ($l.StartsWith('tag ')) { $tag = $l.Substring(4) } } } catch { }
    $launcherToo = $false
    try { $launcherToo = @([IO.File]::ReadAllLines($from) | Where-Object { $_.StartsWith('launcher ') }).Count -gt 0 } catch { }
    try { if (Test-Path -LiteralPath (Join-Path $SuPrevious 'Hotwire.cs')) { Copy-Item -LiteralPath (Join-Path $SuPrevious 'Hotwire.cs') -Destination $SuPlugin -Force } } catch { }
    if ($launcherToo -and $reason -ne 'launcher_failed') {
        try { if (Test-Path -LiteralPath (Join-Path $SuPrevious 'hotwire.ps1')) { Copy-Item -LiteralPath (Join-Path $SuPrevious 'hotwire.ps1') -Destination (Join-Path $root 'hotwire.ps1') -Force } } catch { }
    }
    Remove-Item -LiteralPath $SuApplied, $SuRolledBack -Force -ErrorAction SilentlyContinue
    Set-SuBlocked $reason $tag
    Set-SuState @{ last_tag = $tag; last_result = 'rolled_back'; last_at = (Get-UtcStamp ([DateTimeOffset]::UtcNow)) }
    Say ('The update to Hotwire ' + $tag + ' was rolled back (' + $reason + '). Automatic updates are off until you retry in AFKPanel.')
    Send-Step 'hotwire_update' 'failed' ([ordered]@{ tag = $tag; reason = $reason; rolled_back = $true })
}

# The newest release on the channel this server may take, or '' with $script:SuWhy.
function Get-SuRelease([bool]$now) {
    $feed = Join-Path $SuDir 'feed.json'
    [void](New-Item -ItemType Directory -Force -Path $SuDir)
    $stale = $true
    try { $stale = ((Get-Date) - (Get-Item -LiteralPath $feed).LastWriteTime).TotalHours -ge 1 } catch { }
    if ($now -or $stale) {
        try { Invoke-WebRequest -UseBasicParsing -Uri $SuFeed -Headers @{ Accept = 'application/vnd.github+json' } -TimeoutSec 15 -OutFile ($feed + '.tmp'); Move-Item -LiteralPath ($feed + '.tmp') -Destination $feed -Force }
        catch { $script:SuWhy = 'GitHub''s release list did not answer'; return '' }
    }
    $channel = Get-Env 'SELF_UPDATE_CHANNEL'
    $days = Get-Num 'SELF_UPDATE_DAYS' 3
    try {
        foreach ($r in @(ConvertFrom-Json ([IO.File]::ReadAllText($feed)))) {
            $tag = [string]$r.tag_name
            if ($channel -eq 'dev') { if ($tag -cnotmatch '^(release|dev)-[0-9A-Za-z.-]+$') { continue } }
            elseif ($tag -cnotmatch '^release-[0-9A-Za-z.-]+$' -or $r.prerelease) { continue }
            # Windows PowerShell 5.1 leaves the date as text; PowerShell 7 has already made it a date.
            $published = $r.published_at
            if ($published -is [DateTime]) { $publishedUtc = $published.ToUniversalTime() }
            else { $publishedUtc = [DateTimeOffset]::Parse([string]$published, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
            $age = ((Get-Date).ToUniversalTime() - $publishedUtc).TotalDays
            if (-not $now -and $age -lt $days) { continue }
            return $tag
        }
    } catch { }
    $script:SuWhy = 'no release is old enough yet'
    return ''
}

# The update. Returns $true when hotwire.ps1 was replaced: the caller exits 75 so hotwire.bat runs the new one.
function Invoke-SelfUpdate {
    if ($script:CheckOnly) { return $false }
    Invoke-SelfUpdateRequest
    if (Test-Path -LiteralPath $SuRolledBack) { Undo-SelfUpdate 'launcher_failed' $SuRolledBack }
    $nowRequest = Join-Path $root 'HOTWIRE_UPDATE.request'
    $now = Test-Path -LiteralPath $nowRequest
    Remove-Item -LiteralPath $nowRequest -Force -ErrorAction SilentlyContinue
    if ($now) { Set-SuState @{ blocked = '0'; reason = '' } }
    if ((Get-Env 'SELF_UPDATE') -ne 'auto' -and -not $now) { return $false }
    if ((Get-SuState 'blocked') -eq '1') { Say ('Hotwire''s automatic updates are paused after a rolled-back update (' + (Get-SuState 'reason') + '). Retry in AFKPanel.'); return $false }
    if (Test-Path -LiteralPath (Join-Path $root $WipeFlag)) { Say 'A wipe is waiting, so Hotwire''s own update waits for the next start.'; return $false }
    $tag = Get-SuRelease $now
    if (-not $tag) { if ($now) { Say ('Update Hotwire: ' + $script:SuWhy + '.') }; return $false }
    $stage = Join-Path $SuDir 'stage'
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Force -Path $stage)
    $mPath = Join-Path $stage 'manifest.json'; $sPath = Join-Path $stage 'manifest.sig'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri ($SuDownload + '/' + $tag + '/manifest.json') -TimeoutSec 30 -OutFile $mPath
        Invoke-WebRequest -UseBasicParsing -Uri ($SuDownload + '/' + $tag + '/manifest.sig') -TimeoutSec 30 -OutFile $sPath
    } catch { if ($now) { Say ('Update Hotwire: ' + $tag + ' has no signed manifest to download.') }; return $false }
    if (-not (Test-ReleaseSignature $mPath $sPath)) {
        Say ('Hotwire ' + $tag + ' was not installed: ' + $script:SuWhy + '.')
        Send-Step 'hotwire_update' 'failed' ([ordered]@{ tag = $tag; reason = 'signature' })
        return $false
    }
    $m = ConvertFrom-Json ([IO.File]::ReadAllText($mPath))
    if ([string]$m.tag -cne $tag) { Say ('Hotwire ' + $tag + ' was not installed: its manifest names another release.'); return $false }
    $pluginNow = Get-PluginVersion; $pluginNew = [string]$m.plugin; $launcherNew = [string]$m.launcher_windows
    $wantPlugin = Test-SuNewer $pluginNew $pluginNow
    $wantLauncher = Test-SuNewer $launcherNew $LauncherVersion
    if (-not $wantPlugin -and -not $wantLauncher) { if ($now) { Say ('Update Hotwire: this server already runs ' + $tag + ' or newer.') }; return $false }
    Say ('Updating Hotwire to ' + $tag + ' (plugin ' + $pluginNow + ' -> ' + $pluginNew + ', launcher ' + $LauncherVersion + ' -> ' + $launcherNew + ')...')
    Send-Step 'hotwire_update' 'begun' ([ordered]@{ tag = $tag })
    $files = @(); if ($wantPlugin) { $files += 'Hotwire.cs' }; if ($wantLauncher) { $files += 'hotwire.ps1' }
    foreach ($f in $files) {
        $sha = [string]$m.files.$f
        $ok = $false
        try {
            Invoke-WebRequest -UseBasicParsing -Uri ($SuDownload + '/' + $tag + '/' + $f) -TimeoutSec 120 -OutFile (Join-Path $stage $f)
            $ok = $sha -cmatch '^[0-9a-f]{64}$' -and (Get-FileSha256 (Join-Path $stage $f)) -ceq $sha
        } catch { }
        if (-not $ok) {
            Say ('Hotwire ' + $tag + ' was not installed: ' + $f + ' did not download, or is not the file the signed manifest names.')
            Send-Step 'hotwire_update' 'failed' ([ordered]@{ tag = $tag; reason = 'download' })
            return $false
        }
    }
    # The new launcher checks this server's own settings before it is trusted with them.
    if ($wantLauncher) {
        $env:HOTWIRE_ROOT_OVERRIDE = $root
        try { & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $stage 'hotwire.ps1') check *> (Join-Path $stage 'check.log'); $checked = $LASTEXITCODE -eq 0 } catch { $checked = $false }
        finally { $env:HOTWIRE_ROOT_OVERRIDE = '' }
        if (-not $checked) {
            Say ('Hotwire ' + $tag + ' was not installed: its launcher refused this server''s settings. See hotwire\self-update\stage\check.log.')
            Send-Step 'hotwire_update' 'failed' ([ordered]@{ tag = $tag; reason = 'check' })
            Set-SuBlocked 'check_failed' $tag
            return $false
        }
    }
    try {
        [void](New-Item -ItemType Directory -Force -Path $SuPrevious)
        $note = @(('tag ' + $tag), ('at ' + (Get-UtcStamp ([DateTimeOffset]::UtcNow))))
        if ($wantPlugin) { $note += ('plugin ' + $(if ($pluginNow) { $pluginNow } else { 'none' }) + ' ' + $pluginNew) }
        if ($wantLauncher) { $note += ('launcher ' + $LauncherVersion + ' ' + $launcherNew) }
        [IO.File]::WriteAllLines($SuApplied + '.tmp', [string[]]$note)
        if ($wantPlugin) {
            if (Test-Path -LiteralPath $SuPlugin) { Copy-Item -LiteralPath $SuPlugin -Destination (Join-Path $SuPrevious 'Hotwire.cs') -Force }
            Copy-Item -LiteralPath (Join-Path $stage 'Hotwire.cs') -Destination $SuPlugin -Force
        }
        if ($wantLauncher) {
            Copy-Item -LiteralPath (Join-Path $root 'hotwire.ps1') -Destination (Join-Path $SuPrevious 'hotwire.ps1') -Force
            Copy-Item -LiteralPath (Join-Path $stage 'hotwire.ps1') -Destination (Join-Path $root 'hotwire.ps1') -Force
        }
        Move-Item -LiteralPath ($SuApplied + '.tmp') -Destination $SuApplied -Force
    } catch {
        Say ('Hotwire ' + $tag + ' could not be put in place: ' + $_.Exception.Message + '. The previous files go back.')
        if (Test-Path -LiteralPath ($SuApplied + '.tmp')) { Move-Item -LiteralPath ($SuApplied + '.tmp') -Destination $SuApplied -Force -ErrorAction SilentlyContinue; Undo-SelfUpdate 'install_failed' $SuApplied }
        return $false
    }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Set-SuState @{ last_tag = $tag; last_result = 'installed'; last_at = (Get-UtcStamp ([DateTimeOffset]::UtcNow)) }
    Say ('Hotwire ' + $tag + ' is installed. It is on probation until the plugin says it loaded.')
    Send-Step 'hotwire_update' 'done' ([ordered]@{ tag = $tag; plugin = $pluginNew; launcher = $launcherNew })
    if ($wantLauncher) { Say 'The new launcher takes over now.'; Send-Now; return $true }
    return $false
}

# Probation while the server runs, called every 2 seconds by Invoke-Launch. The new plugin must write loaded.json with
# its version; a launcher-only update passes once the server has run hotwire.crash_seconds.
function Test-SuProbation([long]$since) {
    if (-not (Test-Path -LiteralPath $SuApplied)) { return }
    $lines = @(); try { $lines = [IO.File]::ReadAllLines($SuApplied) } catch { return }
    $want = ''; $tag = ''
    foreach ($l in $lines) { if ($l.StartsWith('plugin ')) { $want = ($l -split ' ')[2] } elseif ($l.StartsWith('tag ')) { $tag = $l.Substring(4) } }
    $nowS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not $want) {
        if ($nowS - $since -ge (Get-Num 'CRASH_SECONDS' 60)) {
            Remove-Item -LiteralPath $SuApplied -Force -ErrorAction SilentlyContinue
            Set-SuState @{ last_result = 'loaded'; last_at = (Get-UtcStamp ([DateTimeOffset]::UtcNow)) }
            Say ('Hotwire ' + $tag + ' passed probation: the server is running on the new launcher.')
            Send-Step 'hotwire_update' 'loaded' ([ordered]@{ tag = $tag })
        }
        return
    }
    try {
        $info = Get-Item -LiteralPath $SuLoaded -ErrorAction Stop
        if (([DateTimeOffset]$info.LastWriteTimeUtc).ToUnixTimeSeconds() -ge $since -and [IO.File]::ReadAllText($SuLoaded) -match ('"version":\s*"' + [regex]::Escape($want) + '"')) {
            Remove-Item -LiteralPath $SuApplied -Force -ErrorAction SilentlyContinue
            Set-SuState @{ last_result = 'loaded'; last_at = (Get-UtcStamp ([DateTimeOffset]::UtcNow)) }
            Say ('Hotwire ' + $tag + ' passed probation: plugin ' + $want + ' loaded.')
            Send-Step 'hotwire_update' 'loaded' ([ordered]@{ tag = $tag; plugin = $want })
            return
        }
    } catch { }
    if ($nowS - $since -ge $SuProbationSeconds) { Undo-SelfUpdate 'plugin_not_loaded' $SuApplied }
}

# What launcher.json says about Hotwire's own updates, for the plugin to pass to AFKPanel.
function Get-SelfUpdateState {
    $probation = ''
    try { foreach ($l in [IO.File]::ReadAllLines($SuApplied)) { if ($l.StartsWith('tag ')) { $probation = $l.Substring(4) } } } catch { }
    return [ordered]@{
        mode = (Get-Env 'SELF_UPDATE'); days = (Get-Num 'SELF_UPDATE_DAYS' 3); channel = (Get-Env 'SELF_UPDATE_CHANNEL')
        blocked = ((Get-SuState 'blocked') -eq '1'); reason = (Get-SuState 'reason'); blocked_tag = (Get-SuState 'blocked_tag')
        last_tag = (Get-SuState 'last_tag'); last_result = (Get-SuState 'last_result'); last_at = (Get-SuState 'last_at'); probation = $probation
    }
}

# An update report while the update runs (capability: update_progress): which step, and for SteamCMD which try. Between
# server runs the plugin is not running, so without it AFKPanel hears nothing until the server starts, however long
# SteamCMD retries. Sent in the background like every report; the update never waits on it.
function Send-UpdateProgress([string]$step, [int]$attempt = 0, [int]$of = 0) {
    try {
        $env:HOTWIRE_REPORT = 'update'; $env:HOTWIRE_UPDATE_STEP = $step
        $env:HOTWIRE_UPDATE_TRY = [string]$attempt; $env:HOTWIRE_UPDATE_OF = [string]$of
        Invoke-Report
    } catch { } finally { $env:HOTWIRE_REPORT = ''; $env:HOTWIRE_UPDATE_STEP = ''; $env:HOTWIRE_UPDATE_TRY = ''; $env:HOTWIRE_UPDATE_OF = '' }
    Start-BackgroundSend
}

# Each step of this start for AFKPanel's run page (start_step, capability: start_steps): the update check, the backup,
# the hooks, each SteamCMD try and how far it has got, Oxide, a wipe, the launch and Rust's boot. StartId is the time
# this start began preparing, the same on every step of it. Sent in the background like every report; no step waits on
# it, and nothing is sent in check mode. $more holds the step's other fields: a number, a boolean or text.
$script:StartId = ''
$script:CheckOnly = $false
function Send-Step([string]$step, [string]$state, [Collections.IDictionary]$more = $null) {
    if (-not $script:StartId -or $script:CheckOnly) { return }
    try {
        $p = '{"start_id":"' + $script:StartId + '","step":' + (ConvertTo-Json -InputObject $step -Compress) + ',"state":' + (ConvertTo-Json -InputObject $state -Compress)
        if ($more) {
            foreach ($k in $more.Keys) {
                $v = $more[$k]
                if ($null -eq $v -or [string]$v -eq '') { continue }
                if ($v -is [bool]) { $j = $(if ($v) { 'true' } else { 'false' }) }
                elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { $j = ([double]$v).ToString([Globalization.CultureInfo]::InvariantCulture) }
                else { $j = ConvertTo-Json -InputObject ([string]$v) -Compress }
                $p += ',"' + $k + '":' + $j
            }
        }
        Add-SpoolReport 'start_step' ($p + '}')
    } catch { }
    Start-BackgroundSend
}

# A step's fields with more to add: a copy, so the try's own fields are not changed.
function Copy-Fields([Collections.IDictionary]$fields) {
    $copy = [ordered]@{}
    foreach ($k in $fields.Keys) { $copy[$k] = $fields[$k] }
    return $copy
}

# SteamCMD's progress line, "Update state (0x61) downloading, progress: 45.12 (2758000000 / 6111760987)", reported at
# most every 15 seconds. Null for a line that is not one.
$script:SteamProgressAt = [DateTime]::MinValue
function Read-SteamProgress([string]$line, [int]$attempt, [int]$of) {
    $m = [regex]::Match($line, 'Update state \(0x[0-9a-fA-F]+\) ([a-z]+)[a-z ]*, progress: ([0-9]+(\.[0-9]+)?) \(([0-9]+) / ([0-9]+)\)')
    if (-not $m.Success -or $m.Groups[5].Value -eq '0') { return }
    if (((Get-Date) - $script:SteamProgressAt).TotalSeconds -lt 15) { return }
    $script:SteamProgressAt = Get-Date
    $more = [ordered]@{ attempt = $attempt; phase = $m.Groups[1].Value; percent = [double]::Parse($m.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture); bytes = [long]$m.Groups[4].Value; total = [long]$m.Groups[5].Value }
    if ($of -gt 0) { $more.of = $of }
    Send-Step 'steamcmd' 'progress' $more
}

# Rust's boot, read from its own log file while it runs: each milestone once, then "Server startup complete" and
# "SteamServer Connected". Read between the launcher's other checks while the server runs; it stops at Steam's connection
# or after an hour. A line a Rust build no longer prints is simply not reported.
$script:BootSeen = @{}
$script:BootOffset = 0L
$script:BootUntil = [DateTime]::MinValue
$script:BootRest = ''
function Start-BootWatch { $script:BootSeen = @{}; $script:BootOffset = 0L; $script:BootRest = ''; $script:BootUntil = (Get-Date).AddHours(1) }
function Read-BootLines([string]$path) {
    if ((Get-Date) -gt $script:BootUntil -or $script:BootSeen.ContainsKey('steam')) { return }
    try {
        if (-not (Test-Path -LiteralPath $path)) { return }
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            if ($fs.Length -lt $script:BootOffset) { $script:BootOffset = 0L; $script:BootRest = '' }
            if ($fs.Length -eq $script:BootOffset) { return }
            [void]$fs.Seek($script:BootOffset, [IO.SeekOrigin]::Begin)
            $n = [int][Math]::Min($fs.Length - $script:BootOffset, 8388608)
            $buf = New-Object byte[] $n; $got = $fs.Read($buf, 0, $n); $script:BootOffset += $got
        } finally { $fs.Dispose() }
        $text = $script:BootRest + [Text.Encoding]::UTF8.GetString($buf, 0, $got)
        $lines = $text -split "\n"
        $script:BootRest = $lines[-1]
        foreach ($line in $lines[0..($lines.Count - 2)]) { Read-BootLine $line.TrimEnd([char]13) }
    } catch { }
}
function Read-BootLine([string]$line) {
    $m = ''; $more = [ordered]@{}
    if ($line.Contains('[Bootstrap] Opening Bundles done')) { $m = 'bundles' }
    elseif ($line.Contains('Loading Oxide Core')) { $m = 'oxide' }
    elseif ($line.Contains('Loaded plugin Hotwire ')) { $m = 'hotwire' }
    elseif ($line.Contains('Generating procedural map')) { $m = 'map' }
    elseif ($line.Contains('Spawning World')) { $m = 'world' }
    elseif ($line.Contains('is now fully built')) { $m = 'navmesh' }
    elseif ($line.Contains('Server startup complete')) {
        if (-not $script:BootSeen.ContainsKey('startup')) { $script:BootSeen['startup'] = $true; Send-Step 'boot' 'done' }
        return
    } elseif ($line.Contains('SteamServer Connected')) {
        if (-not $script:BootSeen.ContainsKey('steam')) { $script:BootSeen['steam'] = $true; Send-Step 'steam' 'done' }
        return
    } else {
        $w = [regex]::Match($line, 'Asset Warmup \(([0-9]+)/([0-9]+)\)')
        $e = [regex]::Match($line, 'Spawning ([0-9]+) entities from save')
        if ($w.Success -and $w.Groups[1].Value -eq $w.Groups[2].Value) { $m = 'warmup' }
        elseif ($e.Success) { $m = 'entities'; $more.count = [long]$e.Groups[1].Value }
    }
    if (-not $m -or $script:BootSeen.ContainsKey($m)) { return }
    $script:BootSeen[$m] = $true
    $more.milestone = $m
    Send-Step 'boot' 'progress' $more
}

# ---- launch --------------------------------------------------------------------------------------------------
# The arguments reach RustDedicated.exe as one command line built here, never through cmd, so no character in a
# value can run as a command.
function Invoke-Launch {
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in (ConvertFrom-Json ([IO.File]::ReadAllText($argsFile)))) { $list.Add([string]$a) }
    $password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$script:Rcon64))
    # No password, no RCON: Rust starts no RCON listener when it is given none.
    if ($password -ne '') { $list.Add('+rcon.password'); $list.Add($password) }
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
    $suSince = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Start-BootWatch
    # While the server runs, pick up the backups Hotwire asks for and run them at the lowest priority. A backup in
    # progress finishes before the server's exit is handled. Rust's boot is read from its log between those checks.
    while (-not $p.WaitForExit(2000)) {
        Read-BootLines ([string]$env:LOGFILE)
        Test-SuProbation $suSince
        if ($env:BACKUPS -ne '0' -and (Test-Path -LiteralPath $backupFlag)) {
            try { Invoke-BackupFromFlag } catch { Say ('Backup: ' + $_.Exception.Message) }
        }
    }
    $p.WaitForExit()
    return $p.ExitCode
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
        # The panel keys, wherever a backup.conf folder points: the launcher's hotwire\ and the plugin's oxide\data\Hotwire\.
        $launcherKeys = [IO.Path]::Combine($root, 'hotwire') + $sep
        $pluginKeys = [IO.Path]::Combine($root, 'oxide', 'data', 'Hotwire') + $sep
        if ($f.FullName.StartsWith($launcherKeys, [StringComparison]::OrdinalIgnoreCase) -or $f.FullName.StartsWith($pluginKeys, [StringComparison]::OrdinalIgnoreCase)) { continue }
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
    Send-Step 'backup' 'begun' @{ detail = 'Before the ' + $(if ($trigger -eq 'before_wipe') { 'wipe' } else { 'update' }) }
    $ok = $false
    try { $ok = [bool](Invoke-BackupArchive $trigger ([DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'") + '-' + $trigger) '' '' '' '' '') }
    finally {
        if ($ok) { Send-Step 'backup' 'done' } else { Send-Step 'backup' 'failed' @{ detail = 'The backup did not finish; the start carried on. The Backups tab says why once the server reports it.' } }
    }
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

# The signature AFKPanel checks: HMAC-SHA256 over "POST /api/v1/report", the timestamp, the nonce and the body's
# SHA-256, one per line. tests/launcher-signing checks it against the shared conformance vector.
function Get-ReportSignature([string]$secret, [string]$ts, [string]$nonce, [byte[]]$bytes) {
    return Get-HexHmac $secret ('POST /api/v1/report' + "`n" + $ts + "`n" + $nonce + "`n" + (Get-HexSha256 $bytes))
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
    $sig = Get-ReportSignature $r.Secret $ts $nonce $bytes
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
        # A report written while this sender runs is sent by it too: another pass, at most 5, while reports remain and
        # AFKPanel answers. A start report written during the last SteamCMD try's send otherwise waited for the next stop.
        $stopped = $false
        for ($pass = 0; $pass -lt 5 -and -not $stopped; $pass++) {
        $files = @(Get-ChildItem -LiteralPath $spoolDir -File | Where-Object { -not $_.Name.StartsWith('.') -and -not $_.Name.EndsWith('.tmp') } | Sort-Object LastWriteTime)
        if ($files.Count -eq 0) { break }
        foreach ($f in $files) {
            if ($sent -ge 50 * ($pass + 1)) { break }
            $lines = [IO.File]::ReadAllLines($f.FullName)
            if ($lines.Count -lt 4 -or -not $lines[0]) { Remove-Item -LiteralPath $f.FullName -Force; continue }
            $made = 0L
            if ([long]::TryParse(($f.Name -split '-', 2)[0], [ref]$made) -and ($now - $made) -gt ($spoolDays * 86400)) {
                Remove-Item -LiteralPath $f.FullName -Force; $expired++; continue
            }
            if ($lines.Count -ge 5 -and $lines[4] -and $lines[4] -ne $r.Origin) { Remove-Item -LiteralPath $f.FullName -Force; $elsewhere++; continue }
            $code = Send-Report $r $lines[0] $lines[1] $lines[2] $lines[3]
            if ($code -ge 200 -and $code -lt 300) { Remove-Item -LiteralPath $f.FullName -Force; $sent++ }
            elseif ($code -eq 0 -or $code -eq 429 -or $code -ge 500) { $stopped = $true; break }
            else { Remove-Item -LiteralPath $f.FullName -Force; $dropped++; Say ('A held ' + $lines[0] + ' report was refused (HTTP ' + $code + ') and dropped, because it would be refused again.') }
        }
        }
        if ($sent -gt 0) { Say ('Sent ' + $sent + ' held report(s) to AFKPanel.') }
        if ($expired -gt 0) { Say ('Dropped ' + $expired + ' report(s) held more than ' + $spoolDays + ' days.') }
        if ($elsewhere -gt 0) { Say ('Dropped ' + $elsewhere + ' report(s) made for another panel or another server.') }
    } finally { $lock.Dispose() }
}

# The session report's "update" field: what this start's update did.
function Get-UpdateJson {
    $bool = { param($v) if ([string]$v -eq '1') { 'true' } else { 'false' } }
    $kept = (Test-Path -LiteralPath (Join-Path $root 'UPDATE.flag')) -or (Test-Path -LiteralPath (Join-Path $root 'VALIDATE.flag'))
    $since = ''
    try { if (Test-Path -LiteralPath $UpdateStamp) { $since = ',"days_since_success":' + [long][math]::Floor(((Get-Date) - (Get-Item -LiteralPath $UpdateStamp).LastWriteTime).TotalDays) } } catch { }
    $extra = ',"mode":' + (ConvertTo-Json -InputObject ([string](Get-Env 'UPDATE_MODE')) -Compress) + ',"effective_mode":' + (ConvertTo-Json -InputObject ([string]$script:UpdateEffective) -Compress)
    if ($script:UpdateReason) { $extra = $extra + ',"reason":' + (ConvertTo-Json -InputObject ([string]$script:UpdateReason) -Compress) }
    if ($script:UpdateLog.Count -gt 0) {
        $lines = @(); foreach ($l in $script:UpdateLog) { $lines += (ConvertTo-Json -InputObject (([string]$l) -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '') -Compress) }
        $extra = $extra + ',"log":[' + ($lines -join ',') + ']'
    }
    return ',"update":{"attempted":' + (& $bool $env:HOTWIRE_UPDATE_ATTEMPTED) + ',"steam_ok":' + (& $bool $env:STEAM_OK) + ',"framework_ok":' + (& $bool $env:FRAMEWORK_OK) + ',"flag_kept":' + $(if ($kept) { 'true' } else { 'false' }) + $since + $extra + '}'
}

# Writes the report HOTWIRE_REPORT names: session (after a run), session_start (as the server starts) or launcher.
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
        # The build Steam has on this branch, from the launcher's last build check; left out when it is not known.
        if ([string]$env:HOTWIRE_PUBLIC_BUILD -match '\A\d+\z') { $p += ',"rust_build_public":"' + $env:HOTWIRE_PUBLIC_BUILD + '"' }
        # Runs in a row that ended under hotwire.crash_seconds, this one included.
        $streak = 0; [void][int]::TryParse([string]$env:CRASH_STREAK, [ref]$streak)
        $p += ',"fast_fail_count":' + $streak
        # From this run's log: Oxide's "Failed to call hook" lines, and, when the plugin never loaded (so it never sent
        # the log itself), the last 40 lines, at most 8 KB. AFKPanel masks card numbers, IP addresses and Steam IDs
        # before storing them, as it does every log line.
        $runLog = [string]$env:LOGFILE
        if ($runLog -and (Test-Path -LiteralPath $runLog)) {
            try {
                $fs = [IO.File]::Open($runLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try { $reader = New-Object IO.StreamReader($fs); $text = $reader.ReadToEnd() } finally { $fs.Dispose() }
                $lines = $text -split "\r?\n"
                $p += ',"hook_errors":' + @($lines | Where-Object { $_.Contains('Failed to call hook ') }).Count
                if (-not $text.Contains('Loaded plugin Hotwire')) {
                    $tail = (@($lines | Select-Object -Last 40) -join "`n") -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
                    if ($tail.Length -gt 8000) { $tail = $tail.Substring($tail.Length - 8000) }
                    $p += ',"log_tail":' + (ConvertTo-Json -InputObject $tail -Compress)
                }
            } catch { }
        }
        $p += (Get-UpdateJson) + (Get-LauncherHooksJson) + '}'
        Add-SpoolReport 'session' $p
    } elseif ($env:HOTWIRE_REPORT -eq 'session_start') {
        # As the server starts, keyed by the same started_at as the report after it exits, so AFKPanel shows where a
        # slow start went while the server runs.
        $started = [string]$env:HOTWIRE_STARTED_AT
        if ($started -notmatch '\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z') { return }
        $id = $(if ([string]$env:HOTWIRE_START_ID -match '\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z') { ',"start_id":"' + $env:HOTWIRE_START_ID + '"' } else { '' })
        Add-SpoolReport 'session' ('{"started_at":"' + $started + '"' + $id + (Get-UpdateJson) + (Get-LauncherHooksJson) + '}')
    } elseif ($env:HOTWIRE_REPORT -eq 'update') {
        $p = '{"step":' + (ConvertTo-Json -InputObject ([string]$env:HOTWIRE_UPDATE_STEP) -Compress) + ',"mode":' + (ConvertTo-Json -InputObject ([string](Get-Env 'UPDATE_MODE')) -Compress) + ',"effective_mode":' + (ConvertTo-Json -InputObject ([string]$script:UpdateEffective) -Compress)
        if ([string]$env:HOTWIRE_UPDATE_TRY -match '\A[1-9][0-9]{0,3}\z') { $p += ',"attempt":' + $env:HOTWIRE_UPDATE_TRY }
        if ([string]$env:HOTWIRE_UPDATE_OF -match '\A[1-9][0-9]{0,3}\z') { $p += ',"of":' + $env:HOTWIRE_UPDATE_OF }
        if ([string]$env:HOTWIRE_INSTALLED_BUILD -match '\A\d+\z') { $p += ',"rust_build_id":"' + $env:HOTWIRE_INSTALLED_BUILD + '"' }
        if ([string]$env:HOTWIRE_PUBLIC_BUILD -match '\A\d+\z') { $p += ',"rust_build_public":"' + $env:HOTWIRE_PUBLIC_BUILD + '"' }
        Add-SpoolReport 'update' ($p + '}')
    } elseif ($env:HOTWIRE_REPORT -eq 'launcher') {
        $streak = 0; [void][int]::TryParse([string]$env:CRASH_STREAK, [ref]$streak)
        $log = @(Get-ChildItem -LiteralPath (Join-Path $root 'logs') -Filter 'server_crash_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $preserved = if ($log.Count -gt 0) { 'logs/' + $log[0].Name } else { '' }
        $detail = [string]$streak + ' consecutive runs under ' + [string]$env:CRASH_SECONDS + 's'
        Add-SpoolReport 'launcher' ('{"state":"stopped","reason":"crash_streak","detail":' + (ConvertTo-Json -InputObject $detail -Compress) + ',"crash_streak":' + $streak + ',"preserved_log":' + (ConvertTo-Json -InputObject $preserved -Compress) + '}')
    }
}

# ---- the launcher ----------------------------------------------------------------------------------------------
# What hotwire.bat did in cmd up to 1.1.23, step for step: read the settings, decide whether to update, update Rust
# and Oxide, run the hooks, apply a wipe or a permanent convar, start the server, report, and start it again.

$AppId = '258550'
$UpdateFlag = 'UPDATE.flag'
$ValidateFlag = 'VALIDATE.flag'
$WipeFlag = 'WIPE.flag'
# Where code comes from is fixed here and never read from hotwire.cfg: other tools may write that file, and a data
# file must not decide what is downloaded or run.
$FrameworkVersionFile = [IO.Path]::Combine($root, 'RustDedicated_Data', 'Managed', 'Oxide.Rust.dll')
$FrameworkUrl = 'https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust.zip'
$FrameworkReleases = 'https://api.github.com/repos/OxideMod/Oxide.Rust/releases/latest'
$FrameworkAsset = 'Oxide.Rust.zip'
$LogFile = [IO.Path]::Combine($root, 'logs', 'server_log.txt')
$UpdateStamp = [IO.Path]::Combine($root, 'logs', 'last_update.txt')
$HookBefore = Join-Path $root 'hotwire-before.bat'
$HookAfter = Join-Path $root 'hotwire-after.bat'
$Acf = [IO.Path]::Combine($root, 'steamapps', 'appmanifest_' + $AppId + '.acf')
$LauncherBat = Join-Path $root 'hotwire.bat'
$script:LauncherExit = 0

# A launcher setting as a number, from what the settings step handed over; $default when it is not a number.
function Get-Num([string]$name, [long]$default = 0) {
    $v = [Environment]::GetEnvironmentVariable($name)
    $n = 0L
    if ([long]::TryParse([string]$v, [ref]$n)) { return $n }
    return $default
}
function Get-Env([string]$name) { return [string][Environment]::GetEnvironmentVariable($name) }

# Waits for a key, as cmd's pause did, so a message that stops the launcher stays on screen. Without a console to
# read from it returns at once.
function Wait-Key {
    [Console]::Error.WriteLine('Press any key to continue . . .')
    try { [void][Console]::ReadKey($true) } catch { }
}

# The settings step's answer: its HWSET lines become this process's environment, which every other step reads.
# Returns ok, fatal (a first read that must stop) or kept (a later read failed; the last good settings stay).
function Import-Settings([switch]$Quiet) {
    $env:HOTWIRE_QUIET = $(if ($Quiet) { '1' } else { '' })
    $state = ''
    foreach ($line in @(Invoke-Load)) {
        $text = [string]$line
        if (-not $text.StartsWith('HWSET ')) { continue }
        $pair = $text.Substring(6); $i = $pair.IndexOf('=')
        if ($i -lt 1) { continue }
        $name = $pair.Substring(0, $i); $value = $pair.Substring($i + 1)
        # The RCON password stays in this process, never in the environment every child inherits (SteamCMD, hooks,
        # the report sender): a hook that dumped its environment would have recorded it.
        if ($name -eq 'HW_LOAD') { $state = $value }
        elseif ($name -eq 'HOTWIRE_RCON64') { $script:Rcon64 = $value }
        else { [Environment]::SetEnvironmentVariable($name, $value) }
    }
    $env:HOTWIRE_QUIET = ''
    return $state
}

# The installed build, from Steam's install record; '' when it cannot be read.
function Get-InstalledBuild {
    try {
        if (Test-Path -LiteralPath $Acf) {
            $q = [char]34
            $m = [regex]::Match([IO.File]::ReadAllText($Acf), $q + 'buildid' + $q + '\s+' + $q + '(\d+)' + $q)
            if ($m.Success) { return $m.Groups[1].Value }
        }
    } catch { }
    return ''
}

# Steam's current build on the branch, through one SteamCMD run, cached for hotwire.build_check_hours. buildid also
# appears under every depot, so this finds "branches", then the branch, then the buildid inside it: the first buildid
# in the output belongs to a depot. Skipped, not waited for, while another server holds SteamCMD. '' when unknown.
function Get-PublicBuild([string]$branch, [long]$hours) {
    $cache = [IO.Path]::Combine($root, 'logs', 'build_check.txt')
    $out = [IO.Path]::Combine($root, 'logs', '.appinfo.tmp')
    $sc = Get-Env 'STEAMCMD'
    try {
        if (Test-Path -LiteralPath $cache) {
            $age = ((Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime).TotalHours
            if ($age -lt $hours) { return ([IO.File]::ReadAllText($cache)).Trim() }
        }
        if (-not (Test-Path -LiteralPath $sc)) { return '' }
        $lock = $null
        try { $lock = [IO.File]::Open((Join-Path (Split-Path -Parent $sc) 'hotwire-steamcmd.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { return '' }
        try {
            $p = Start-Process -FilePath $sc -ArgumentList @('+login', 'anonymous', '+app_info_update', '1', '+app_info_print', $AppId, '+quit') -RedirectStandardOutput $out -NoNewWindow -PassThru
            if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; return '' }
            if (-not (Test-Path -LiteralPath $out)) { return '' }
            $q = [char]34
            $t = [IO.File]::ReadAllText($out)
            $i = $t.IndexOf($q + 'branches' + $q)
            if ($i -lt 0) { return '' }
            $j = $t.IndexOf($q + $branch + $q, $i)
            if ($j -lt 0) { return '' }
            $m = [regex]::Match($t.Substring($j), $q + 'buildid' + $q + '\s+' + $q + '(\d+)' + $q)
            if (-not $m.Success) { return '' }
            [IO.File]::WriteAllText($cache, $m.Groups[1].Value)
            return $m.Groups[1].Value
        } finally {
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            $lock.Dispose()
        }
    } catch { return '' }
}

# Fast Rust updates. Steam updates a game by patching its files, and Oxide has replaced some of them, so on a modded
# server Steam's first try at a new build fails with "Corrupt game files" (state 0x486). Steam then marks the install
# Files Corrupt in steamapps\appmanifest (StateFlags bit 128), and its next run checks every file and succeeds. Setting
# that mark before the first try skips the failed one. Steam does not document this record, so exactly one line is
# changed, the change is checked before it is saved, a copy is kept in hotwire\, and if Steam ignores the mark the
# update takes its usual second try.
function Set-FastRustMark {
    if (-not (Test-Path -LiteralPath $Acf)) { return }
    $q = [char]34; $nl = [char]10
    $re = '\A\s*' + $q + 'StateFlags' + $q + '\s+' + $q + '4' + $q + '\s*\z'
    $lines = [IO.File]::ReadAllText($Acf).Split($nl); $hit = @()
    for ($i = 0; $i -lt $lines.Length; $i++) { if ($lines[$i].TrimEnd([char]13) -match $re) { $hit += $i } }
    if ($hit.Count -ne 1) { Say 'Fast Rust updates: Steam''s install record has an unexpected format, so it is left unchanged.'; return }
    $new = [string[]]$lines.Clone(); $new[$hit[0]] = $lines[$hit[0]].Replace($q + '4' + $q, $q + '132' + $q); $tmp = $Acf + '.hotwire-tmp'
    try {
        [IO.File]::WriteAllText($tmp, [string]::Join($nl, $new))
        $back = [IO.File]::ReadAllText($tmp).Split($nl); $diff = 0
        for ($i = 0; $i -lt $lines.Length; $i++) { if ($back[$i] -ne $lines[$i]) { $diff++ } }
        if ($back.Length -ne $lines.Length -or $diff -ne 1) { throw 'unexpected' }
        $dir = Join-Path $root 'hotwire'; if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
        Copy-Item -LiteralPath $Acf -Destination (Join-Path $dir 'appmanifest-before-update.acf') -Force
        [IO.File]::Replace($tmp, $Acf, [NullString]::Value)
        Say 'Fast Rust updates: Steam will check every game file before this update, so it finishes in one try.'
    } catch {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Say 'Fast Rust updates: Steam''s install record could not be changed, so it is left as it was.'
    }
}

# Whether Steam marked the install Files Corrupt (StateFlags bit 128).
function Test-FilesCorrupt {
    try {
        $m = [regex]::Match([IO.File]::ReadAllText($Acf), 'StateFlags' + [char]34 + '\s+' + [char]34 + '([0-9]+)')
        return ($m.Success -and ([int64]$m.Groups[1].Value -band 128))
    } catch { return $false }
}

# One SteamCMD update run, one at a time on this machine. Servers can share one SteamCMD, and two runs at once are not
# known to be safe, so the run first opens hotwire-steamcmd.lock beside steamcmd.exe, unshared; Windows releases an
# open file when its process ends, however it ends, and hotwire-setup uses the same lock. Returns SteamCMD's exit
# code, 97 after waiting hotwire.steamcmd_wait_minutes for another server, or 96 when Steam refused a file list of
# the installed build: SteamCMD reads those from a cache every server using it shares, asks Steam only when they are
# missing, and Steam refuses an old Rust build's lists to an anonymous login.
# The part of SteamCMD's output file not shown yet: written to this window line by line, each line read for progress.
# Returns how far the file has been read.
function Show-SteamOutput([string]$path, [long]$from, [ref]$rest, [int]$attempt, [int]$of) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $from }
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            if ($fs.Length -le $from) { return $from }
            [void]$fs.Seek($from, [IO.SeekOrigin]::Begin)
            $n = [int][Math]::Min($fs.Length - $from, 8388608)
            $buf = New-Object byte[] $n; $got = $fs.Read($buf, 0, $n)
        } finally { $fs.Dispose() }
        $lines = ($rest.Value + [Text.Encoding]::UTF8.GetString($buf, 0, $got)) -split "\n"
        $rest.Value = $lines[-1]
        foreach ($line in $lines[0..($lines.Count - 2)]) {
            $line = $line.TrimEnd([char]13)
            [Console]::Out.WriteLine($line)
            Read-SteamProgress $line $attempt $of
        }
        return $from + $got
    } catch { return $from }
}

function Invoke-SteamUpdate([bool]$validate, [int]$attempt = 0, [int]$of = 0) {
    $sc = Get-Env 'STEAMCMD'; $q = [char]34
    $a = '+force_install_dir ' + $q + $root + $q + ' +login anonymous +app_update ' + $AppId
    $branch = Get-Env 'STEAM_BRANCH'
    if (-not [string]::IsNullOrWhiteSpace($branch)) { $a = $a + ' -beta ' + $branch }
    if ($validate) { $a = $a + ' validate' }
    $a = $a + ' +quit'
    $wait = Get-Num 'STEAMCMD_WAIT_MINUTES' 60
    $deadline = (Get-Date).AddMinutes($wait)
    $lock = Join-Path (Split-Path -Parent $sc) 'hotwire-steamcmd.lock'; $h = $null; $said = $false
    while ($null -eq $h) {
        try { $h = [IO.File]::Open($lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch {
            if ((Get-Date) -gt $deadline) { Say ('Another server has been using SteamCMD for over ' + $wait + ' minutes. Not waiting any longer.'); return 97 }
            if (-not $said) { Say 'Another server is using SteamCMD. Waiting for it to finish...'; $said = $true }
            Start-Sleep -Seconds 5
        }
    }
    try {
        $lg = Join-Path (Split-Path -Parent $sc) 'logs\content_log.txt'; $before = 0
        if (Test-Path -LiteralPath $lg) { $before = (Get-Item -LiteralPath $lg).Length }
        $inst = @()
        if (Test-Path -LiteralPath $Acf) { foreach ($x in [regex]::Matches([IO.File]::ReadAllText($Acf), $q + 'manifest' + $q + '\s+' + $q + '([0-9]+)' + $q)) { $inst += $x.Groups[1].Value } }
        # Bounded by hotwire.steamcmd_update_minutes (0: no limit): a SteamCMD that hangs would otherwise keep this server
        # down and hold the lock every other server on the machine waits for. Returns 95 when it was stopped.
        # SteamCMD's output goes to a file that is shown in this window as it is written and read for its progress line.
        $out = Join-Path $root 'hotwire\steamcmd-output.txt'
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath $sc -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $out
        # Reading the handle now keeps the exit code: Windows PowerShell 5.1 can lose it for a process started this way.
        [void]$p.Handle
        $limit = Get-Num 'STEAMCMD_UPDATE_MINUTES' 60
        $clock = [Diagnostics.Stopwatch]::StartNew(); $read = 0L; $rest = ''
        $script:SteamProgressAt = [DateTime]::MinValue
        while (-not $p.WaitForExit(1000)) {
            $read = Show-SteamOutput $out $read ([ref]$rest) $attempt $of
            if ($limit -gt 0 -and $clock.Elapsed.TotalMinutes -ge $limit) {
                # SteamCMD and anything it started, so the next update does not meet a SteamCMD still running.
                try { [void](& taskkill.exe /T /F /PID $p.Id 2>&1) } catch { }
                try { if (-not $p.HasExited) { $p.Kill() } } catch { }
                Say ('SteamCMD did not finish within ' + $limit + ' minutes (hotwire.steamcmd_update_minutes) and was stopped.')
                return 95
            }
        }
        $p.WaitForExit()
        $read = Show-SteamOutput $out $read ([ref]$rest) $attempt $of
        if ($rest) { [Console]::Out.WriteLine($rest) }
        $code = $p.ExitCode
        if ($code -ne 0 -and (Get-Env 'RECOVER_REFUSED_UPDATE') -eq '1' -and $inst.Count -gt 0 -and (Test-Path -LiteralPath $lg)) {
            $len = (Get-Item -LiteralPath $lg).Length
            if ($len -lt $before) { $before = 0 }
            if ($len -gt $before) {
                $fs = [IO.File]::Open($lg, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try { [void]$fs.Seek($before, [IO.SeekOrigin]::Begin); $n = [int][Math]::Min($len - $before, 4194304); $buf = New-Object byte[] $n; [void]$fs.Read($buf, 0, $n) } finally { $fs.Dispose() }
                foreach ($line in [Text.Encoding]::UTF8.GetString($buf).Split([char]10)) {
                    if ($line.Contains('Failed to get manifest request code') -and $line.Contains('Access Denied')) {
                        $mm = [regex]::Match($line, 'Manifest: ([0-9]+)')
                        if ($mm.Success -and ($inst -contains $mm.Groups[1].Value)) { $code = 96 }
                    }
                }
            }
        }
        return $code
    } finally { $h.Dispose() }
}

# A refused update: without Steam's install record SteamCMD compares the files on disk with the new build and
# downloads what differs, so the record is moved to hotwire\ and the update runs once more. True when it was moved.
function Move-RefusedRecord {
    if (-not (Test-Path -LiteralPath $Acf)) { return $false }
    try {
        $dir = Join-Path $root 'hotwire'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
        Move-Item -LiteralPath $Acf -Destination (Join-Path $dir 'appmanifest-refused.acf') -Force
        Say 'Steam no longer serves the installed Rust build''s file list, so this update cannot patch it.'
        Say 'Setting Steam''s install record aside and updating again: Steam checks the files on disk and downloads what changed.'
        return $true
    } catch { return $false }
}

# After a refused update that still failed: if Steam left no usable install record, the old one is put back.
function Restore-RefusedRecord {
    $saved = [IO.Path]::Combine($root, 'hotwire', 'appmanifest-refused.acf')
    if (-not (Test-Path -LiteralPath $saved)) { return }
    $b = Get-InstalledBuild
    if ($b -eq '' -or $b -eq '0') {
        Copy-Item -LiteralPath $saved -Destination $Acf -Force
        Say 'The update did not finish. Steam''s install record is restored.'
    }
}

# The forced wipe this update must carry, as a Unix deadline and a clock time, or $null. The flag must say forced,
# its cycle must not be done, and it must not have expired.
function Get-ForcedWipeDeadline {
    $minutes = Get-Num 'FORCED_WIPE_STEAM_MINUTES' 15
    $flag = Join-Path $root $WipeFlag
    if ($minutes -eq 0 -or -not (Test-Path -LiteralPath $flag)) { return $null }
    try {
        $w = @{}
        foreach ($l in [IO.File]::ReadAllLines($flag)) { $p = $l.Trim().Split(' ', 2); if ($p.Count -eq 2 -and -not $w.ContainsKey($p[0])) { $w[$p[0]] = $p[1].Trim() } }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $done = ''
        $state = [IO.Path]::Combine($root, 'hotwire', 'wipe-cycle')
        if (Test-Path -LiteralPath $state) { $done = ([IO.File]::ReadAllText($state)).Trim() }
        $ok = ($w['forced'] -eq '1') -and -not ($w['cycle'] -and $w['cycle'] -eq $done) -and -not ($w['expires'] -match '\A[0-9]+\z' -and [long]$w['expires'] -lt $now)
        if (-not $ok) { return $null }
        return @{ Deadline = $now + 60 * $minutes; Until = (Get-Date).AddMinutes($minutes).ToString('HH:mm') }
    } catch { return $null }
}

# Rust through SteamCMD, with its retries. True when SteamCMD finished the update.
function Update-Rust([bool]$validate, [string]$installed, [string]$public) {
    $sc = Get-Env 'STEAMCMD'
    if ((Get-Env 'FAST_RUST_UPDATES') -eq '1' -and (Get-Env 'INSTALL_FRAMEWORK') -ne '0' -and $installed -and $public -and [long]$installed -lt [long]$public) {
        Set-FastRustMark
    }
    $forced = Get-ForcedWipeDeadline
    if ($forced) { Say ('A forced wipe needs this update: if SteamCMD fails, it is retried until ' + $forced.Until + '.') }
    if (-not (Test-Path -LiteralPath $sc)) {
        Say ('SteamCMD is not at ' + $sc + '. Set hotwire.steamcmd in hotwire.cfg. Starting without updating.')
        Set-UpdateReason 'steamcmd_missing'
        Send-Step 'steamcmd' 'failed' @{ detail = 'SteamCMD is not where hotwire.steamcmd says; the server starts on what is installed.' }
        return $false
    }
    $maxTries = Get-Num 'MAX_STEAM_TRIES' 5
    $tries = 0; $quickUsed = $false; $recoveryUsed = $false
    while ($true) {
        $tries++
        $of = $(if ($tries -le $maxTries) { $maxTries } else { 0 })
        Send-UpdateProgress 'steamcmd' $tries $of
        $try = [ordered]@{ attempt = $tries }; if ($of -gt 0) { $try.of = $of }
        Send-Step 'steamcmd' 'begun' $try
        $code = Invoke-SteamUpdate $validate $tries $of
        if ($code -eq 0) {
            if ($recoveryUsed) { Say 'The update finished without the old file list. The old install record is kept in hotwire\appmanifest-refused.acf.' }
            Send-Step 'steamcmd' 'done' $try
            return $true
        }
        if ($code -eq 97) {
            Set-UpdateReason 'steamcmd_busy'
            $try.detail = 'Another server on this machine used SteamCMD for ' + (Get-Num 'STEAMCMD_WAIT_MINUTES' 60) + ' min; the server starts on what is installed.'
            Send-Step 'steamcmd' 'failed' $try
            break
        }
        if ($code -eq 95) {
            Say 'Starting what is on disk. The next update carries on from what was downloaded.'; Set-UpdateReason 'steamcmd_timeout'
            $try.detail = 'SteamCMD did not finish within ' + (Get-Num 'STEAMCMD_UPDATE_MINUTES' 60) + ' min and was stopped; the server starts on what is installed.'
            Send-Step 'steamcmd' 'failed' $try
            break
        }
        Say ('SteamCMD failed (attempt ' + $tries + ' of ' + $maxTries + ').')
        $failed = (Copy-Fields $try); $failed.exit_code = $code
        if ($code -eq 96) { $failed.exit_code = $null; $failed.detail = 'Steam no longer serves the installed Rust build''s file list.' }
        Send-Step 'steamcmd' 'failed' $failed
        if ($code -eq 96 -and -not $recoveryUsed -and (Move-RefusedRecord)) {
            $recoveryUsed = $true
            $note = (Copy-Fields $try); $note.detail = 'Steam''s install record set aside: the next try checks the files on disk and downloads what changed.'
            Send-Step 'steamcmd' 'progress' $note
            continue
        }
        if ($tries -ge $maxTries) {
            if (-not $forced -or [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $forced.Deadline) { break }
            Say ('A forced wipe needs this update: trying SteamCMD again until ' + $forced.Until + '.')
        }
        # Once per update: if a try left the install marked Files Corrupt, try again at once. Steam checks every file
        # on the next run, so waiting would change nothing.
        if (-not $quickUsed -and (Test-Path -LiteralPath $Acf) -and (Test-FilesCorrupt)) {
            $quickUsed = $true
            Say 'Steam marked the game files for a full check; trying again now.'
            $note = (Copy-Fields $try); $note.detail = 'Steam marked the game files for a full check; trying again now.'
            Send-Step 'steamcmd' 'progress' $note
            continue
        }
        $wait = (Copy-Fields $try); $wait.seconds = (Get-Num 'STEAM_RETRY_SECONDS' 60)
        Send-Step 'steamcmd' 'waiting' $wait
        Start-Sleep -Seconds (Get-Num 'STEAM_RETRY_SECONDS' 60)
    }
    Say 'SteamCMD failed. Starting without the update.'
    if ((Get-Env 'STEAMCMD') -and $script:UpdateReason -notin @('steamcmd_busy', 'steamcmd_timeout')) {
        Send-Step 'steamcmd' 'failed' ([ordered]@{ attempt = $tries; detail = 'SteamCMD failed on every try; the server starts on what is installed.' })
    }
    Set-UpdateReason 'steamcmd_failed'
    if ($recoveryUsed) { Restore-RefusedRecord }
    return $false
}

# Oxide. One request for GitHub's latest Oxide release gives both its tag, compared with the installed Oxide, and its
# download, checked against the SHA-256 GitHub publishes. uMod's feed is not used: it has named the old Oxide for over
# an hour after GitHub had the new one. Oxide is third-party and changes with every Rust release, so Hotwire has no
# hash of its own to pin it to; the SHA-256 proves the file is the one GitHub holds for the release, not who built
# it. True when Oxide is in place afterwards.
function Send-OxideFailed([string]$why) { Send-Step 'oxide' 'failed' @{ detail = $why } }

function Update-Oxide([string]$buildBefore, [bool]$validated = $false) {
    if ((Get-Env 'INSTALL_FRAMEWORK') -eq '0') {
        Say 'Vanilla server: hotwire.install_framework is 0, so Oxide is not installed.'
        return $true
    }
    Send-UpdateProgress 'oxide'
    Send-Step 'oxide' 'begun'
    $from = $FrameworkUrl; $sha = ''; $tag = ''
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $r = Invoke-RestMethod -Uri $FrameworkReleases -TimeoutSec 25 -Headers @{ Accept = 'application/vnd.github+json' }
        $t = [string]$r.tag_name
        if ($t -match '\Av?[0-9]+(\.[0-9]+)+\z') { $tag = $t.TrimStart('v') }
        $asset = @($r.assets | Where-Object { $_.name -eq $FrameworkAsset })[0]
        $d = [string]$asset.digest; $u = [string]$asset.browser_download_url
        if ($u -like 'https://github.com/*') {
            $from = $u
            if ($d.Length -eq 71 -and $d -like 'sha256:*') { $sha = $d.Substring(7).ToLower() }
        }
    } catch { }
    if ((Get-Env 'VERIFY_FRAMEWORK') -eq '0') { $sha = '' }

    # If SteamCMD changed the installed build, the game's own managed files were just rewritten, so Oxide must be
    # extracted over them whatever its version. Skipping the extract is safe only when the build did not change.
    $buildAfter = Get-InstalledBuild
    $extract = $true
    if ((Get-Env 'SKIP_UNCHANGED_FRAMEWORK') -eq '1' -and $buildBefore -and $buildAfter) {
        if ($validated) {
            # A validate puts the game's own files back without changing the build, so Oxide's version still matches
            # and the server would start without it. Oxide goes back over them.
            Say 'A validate put the game''s own files back, so Oxide is installed again.'
        } elseif ($buildBefore -ne $buildAfter) {
            Say ('Rust changed from build ' + $buildBefore + ' to ' + $buildAfter + ', so Oxide is installed again.')
        } elseif (-not $tag) {
            Say 'GitHub did not return Oxide''s latest version, so the installed one cannot be compared. Installing Oxide.'
        } else {
            # The first three parts of the installed Oxide's file version, such as 2.0.7801.0, against GitHub's tag,
            # such as 2.0.7801.
            $v = ''
            try { if (Test-Path -LiteralPath $FrameworkVersionFile) { $v = [string](Get-Item -LiteralPath $FrameworkVersionFile).VersionInfo.FileVersion } } catch { }
            if ([string]::IsNullOrWhiteSpace($v)) {
                Say 'Could not read the installed Oxide''s version. Installing Oxide.'
            } else {
                $vn = (($v.Trim() -split '\.') + @('0', '0', '0'))[0..2] -join '.'
                $ln = (($tag.Trim() -split '\.') + @('0', '0', '0'))[0..2] -join '.'
                Say ('Oxide: installed ' + $vn + ', GitHub ' + $ln)
                if ($vn -eq $ln) {
                    Say 'Rust and Oxide are both unchanged, so Oxide is not installed again.'
                    Send-Step 'oxide' 'done' ([ordered]@{ version = $vn; detail = 'Oxide and the game are unchanged, so nothing was downloaded.' })
                    $extract = $false
                }
            }
        }
    }
    if (-not $extract) { return $true }

    if ((Get-Env 'VERIFY_FRAMEWORK') -eq '1' -and -not $sha) { Say 'GitHub did not return Oxide''s SHA-256, so this download cannot be checked.' }
    if ($sha) { Say ('Downloading Oxide ' + $tag + ' from GitHub and checking its SHA-256.') } else { Say 'Downloading Oxide from GitHub without a check.' }
    $zip = Join-Path $root 'OxideMod.zip'
    try {
        # curl -f fails on an HTTP error instead of saving the error page, which would otherwise be extracted over a
        # working install. It gives up on a stalled download (under 1 byte a second for 2 minutes), not a slow one.
        # curl.exe by name: in Windows PowerShell, curl is another command. Started as its own process so its
        # progress reaches the window.
        # At most 30 minutes in all, so a connection that trickles can never hold the start. Windows Server 2016 has no
        # curl.exe: there PowerShell's own download is used, with the same limit.
        $q = [char]34
        if (Get-Command 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue) {
            $c = Start-Process -FilePath 'curl.exe' -ArgumentList ('-fSL -A Mozilla/5.0 --connect-timeout 30 --speed-limit 1 --speed-time 120 --max-time 1800 ' + $q + $from + $q + ' --output ' + $q + $zip + $q) -NoNewWindow -Wait -PassThru
            if ($c.ExitCode -ne 0) { Say 'Oxide download failed. Starting with the Oxide already installed.'; Set-UpdateReason 'oxide_download_failed'; Send-OxideFailed 'The download from GitHub failed; the installed Oxide is kept.'; return $false }
        } else {
            try { Invoke-WebRequest -Uri $from -OutFile $zip -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 1800 }
            catch { Say 'Oxide download failed. Starting with the Oxide already installed.'; Set-UpdateReason 'oxide_download_failed'; Send-OxideFailed 'The download from GitHub failed; the installed Oxide is kept.'; return $false }
        }
        # Every entry under RustDedicated_Data/ and none climbing out of it, as setup checks: on the unverified path a
        # changed zip could otherwise write anywhere this account can.
        if (-not (Test-OxideZipEntries $zip)) { Say 'The Oxide download is not a zip of files under RustDedicated_Data/. It is not installed.'; Set-UpdateReason 'oxide_not_a_zip'; Send-OxideFailed 'The download was not the expected zip, so it was not installed.'; return $false }
        if ($sha) {
            $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLower()
            if ($got -ne $sha) {
                Say ('Downloaded SHA-256: ' + $got)
                Say ('The download does not match GitHub''s SHA-256 for Oxide ' + $tag + ' (' + $sha + '). It is not installed: the')
                Say 'server starts with the Oxide it has, and the next restart tries again.'
                Set-UpdateReason 'oxide_hash_mismatch'
                Send-OxideFailed 'The download did not match the SHA-256 GitHub lists, so it was not installed.'
                return $false
            }
            Say ('SHA-256 matches GitHub''s for Oxide ' + $tag + '.')
        }
        try { Expand-Archive -Force -LiteralPath $zip -DestinationPath $root } catch { Say 'Oxide could not be extracted.'; Set-UpdateReason 'oxide_extract_failed'; Send-OxideFailed 'Oxide could not be unpacked into the server folder; the installed one is kept.'; return $false }
        Send-Step 'oxide' 'done' ([ordered]@{ version = $tag; detail = $(if ($sha) { 'SHA-256 matches GitHub''s.' } else { 'Installed without a SHA-256 check.' }) })
        return $true
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

# One of your own hook files, in a cmd of its own, so its variables and any exit stay inside it. A hook still running at
# hotwire.hook_timeout_minutes is stopped with everything it started, and the start carries on. Its time, exit code and
# whether it was stopped go to AFKPanel in the session report ($slot is before or after). Returns ok, failed or stopped.
$script:HookRuns = @{}
$script:HookLimitSeconds = $null   # the launcher's own tests set it; they cannot wait a minute
$script:HookShellForTests = $null  # and run the hook with this instead of cmd.exe, off Windows
function Invoke-Hook([string]$path, [string]$slot) {
    $name = Split-Path -Leaf $path
    Send-Step ('hook_' + $slot) 'begun' @{ detail = $name }
    $limit = if ($script:HookLimitSeconds) { [double]$script:HookLimitSeconds } else { 60.0 * (Get-Num 'HOOK_TIMEOUT_MINUTES' 30) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    if ($script:HookShellForTests) {
        $p = Start-Process -FilePath $script:HookShellForTests -ArgumentList ([char]34 + $path + [char]34) -NoNewWindow -PassThru
    } else {
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /c call ' + [char]34 + $path + [char]34) -NoNewWindow -PassThru
    }
    $null = $p.Handle  # keeps the exit code readable once the process has gone
    $stopped = $false
    while (-not $p.WaitForExit(500)) {
        if ($clock.Elapsed.TotalSeconds -ge $limit) {
            $stopped = $true
            Say ((Split-Path -Leaf $path) + ' was still running after ' + (Get-Num 'HOOK_TIMEOUT_MINUTES' 30) + ' minutes (hotwire.hook_timeout_minutes); stopping it and starting anyway.')
            $taskkill = Get-Command 'taskkill.exe' -ErrorAction SilentlyContinue
            if ($taskkill) { & $taskkill.Source /T /F /PID $p.Id *> $null } else { try { $p.Kill($true) } catch { try { $p.Kill() } catch { } } }
            [void]$p.WaitForExit(10000)
            break
        }
    }
    $clock.Stop()
    $seconds = ([math]::Round($clock.Elapsed.TotalSeconds, 1)).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
    if ($stopped) {
        $script:HookRuns[$slot] = '{"seconds":' + $seconds + ',"exit_code":null,"timed_out":true}'
        Send-Step ('hook_' + $slot) 'failed' ([ordered]@{ seconds = [double]$clock.Elapsed.TotalSeconds; detail = $name + ' was stopped after ' + (Get-Num 'HOOK_TIMEOUT_MINUTES' 30) + ' min; the start carried on.' })
        return 'stopped'
    }
    $code = [int]$p.ExitCode
    $script:HookRuns[$slot] = '{"seconds":' + $seconds + ',"exit_code":' + $code + ',"timed_out":false}'
    Send-Step ('hook_' + $slot) $(if ($code -eq 0) { 'done' } else { 'failed' }) ([ordered]@{ seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1); exit_code = $code; detail = $name })
    if ($code -eq 0) { return 'ok' } else { return 'failed' }
}

# The hooks this start ran, as the session report's "launcher_hooks" field, or nothing when neither ran.
function Get-LauncherHooksJson {
    $parts = @()
    foreach ($slot in @('before', 'after')) { if ($script:HookRuns.ContainsKey($slot)) { $parts += '"' + $slot + '":' + $script:HookRuns[$slot] } }
    if ($parts.Count -eq 0) { return '' }
    return ',"launcher_hooks":{' + ($parts -join ',') + '}'
}

# Keep the previous log: -logfile empties the file on every start, so without this a restart would erase the log of
# what went wrong. A crash loop restarts every few seconds, and trimming to hotwire.log_keep would soon delete the log
# that explains it, so the first log of a crash streak is saved as server_crash_*, which the trim never deletes. Later
# crashes in the streak rotate normally: they repeat the first, and keeping them all would fill the disk.
function Move-ServerLog([long]$crashStreak) {
    if ((Get-Env 'ROTATE_LOGS') -eq '0' -or -not (Test-Path -LiteralPath $LogFile)) { return }
    try {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $name = 'server_log_' + $stamp + '.txt'
        if ($crashStreak -eq 1) { $name = 'server_crash_' + $stamp + '.txt' }
        Move-Item -LiteralPath $LogFile -Destination ([IO.Path]::Combine($root, 'logs', $name)) -Force
        # The folder by its literal name (a [ in it is not a wildcard), the files by the pattern.
        Get-ChildItem -LiteralPath ([IO.Path]::Combine($root, 'logs')) -Filter 'server_log_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip (Get-Num 'LOG_KEEP' 14) | Remove-Item -Force
    } catch { Say ('Could not rotate the server log: ' + $_.Exception.Message) }
}

# Tells the plugin which launcher started the server: version, capabilities and path, in
# oxide\data\Hotwire\launcher.json. The plugin works out the launcher's code hash from hotwire.bat and the file it
# names (this one), and AFKPanel compares it with the released launchers'. If writing fails, only AFKPanel's view of
# the launcher is affected.
function Write-LauncherState {
    try {
        $state = [IO.Path]::Combine($root, 'oxide', 'data', 'Hotwire', 'launcher.json')
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $state))
        # hotwire.cfg's lines that are not used as written: the plugin passes them to AFKPanel, which raises them as a
        # problem. The setting's name and what is wrong, never its value. At most 20.
        $problems = @()
        try { $problems = @((Read-Config).Report | Select-Object -First 20) } catch { }
        $o = [ordered]@{ version = $LauncherVersion; capabilities = $LauncherCapabilities; platform = 'windows'; path = $LauncherBat; update_mode = (Get-Env 'UPDATE_MODE'); config_problems = $problems; self_update = (Get-SelfUpdateState) }
        [IO.File]::WriteAllText($state, (ConvertTo-Json -InputObject $o -Depth 4))
    } catch { }
}

# Sends held reports in a separate process, so the server starts without waiting for AFKPanel.
function Start-BackgroundSend {
    try {
        # Waits up to 30 s for a sender already running, so this report is not left for the next stop.
        $env:HOTWIRE_MODE = 'send'; $env:HOTWIRE_SEND_WAIT = '30'
        $q = [char]34
        [void](Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $q + $PSCommandPath + $q) -NoNewWindow)
    } catch { } finally { $env:HOTWIRE_MODE = ''; $env:HOTWIRE_SEND_WAIT = '' }
}

# Sends held reports now, waiting up to a minute for a sender already running: the launcher is about to stop.
function Send-Now {
    try { $env:HOTWIRE_SEND_WAIT = '60'; Invoke-Send } catch { } finally { $env:HOTWIRE_SEND_WAIT = '' }
}

# The file's own size and time when it started, so a replaced hotwire.ps1 is noticed before the next start.
function Get-SelfStamp {
    try { $i = Get-Item -LiteralPath $PSCommandPath; return [string]$i.Length + ':' + [string]$i.LastWriteTimeUtc.Ticks } catch { return '' }
}

function Invoke-Main([string[]]$argv) {
    $checkOnly = @($argv | Where-Object { $_ -eq 'check' }).Count -gt 0
    $env:CHECK_ONLY = $(if ($checkOnly) { '1' } else { '' })
    $env:HOTWIRE_ROOT = $root
    $env:HOTWIRE_LAUNCHER_VERSION = $LauncherVersion
    $env:HOTWIRE_LAUNCHER_CAPABILITIES = $LauncherCapabilities
    $env:APPID = $AppId
    $env:WIPE_FLAG = $WipeFlag
    $env:LOGFILE = $LogFile
    Say ('Hotwire launcher ' + $LauncherVersion + ' (Windows)')

    if (-not (Test-Path -LiteralPath (Join-Path $root 'RustDedicated.exe'))) {
        Rule
        Say 'No RustDedicated.exe in:'
        Say ('  ' + $root)
        Say 'hotwire.bat and hotwire.ps1 must be in the same folder as RustDedicated.exe.'
        Say 'If they are, Rust is not fully installed.'
        Rule
        Wait-Key; $script:LauncherExit = 2; return
    }
    # One launcher per server folder. A second one would update, back up and wipe under the server the first one runs,
    # then crash-loop on its ports. The file stays open, unshared, for this process's life; Windows closes it however
    # the process ends. Check mode changes nothing, so it runs beside a launcher.
    if (-not $checkOnly) {
        $lockDir = Join-Path $root 'hotwire'
        if (-not (Test-Path -LiteralPath $lockDir)) { try { [void](New-Item -ItemType Directory -Path $lockDir) } catch { } }
        try { $script:FolderLock = [IO.File]::Open((Join-Path $lockDir 'launcher.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch {
            Rule
            Say 'Another launcher is already running this server, in this folder:'
            Say ('  ' + $root)
            Say 'Close that one first. Two launchers in one folder would update and wipe under a running server.'
            Rule
            # 3, not 2: a second launcher refused is not a broken one, so hotwire.bat never rolls back over it.
            Wait-Key; $script:LauncherExit = 3; return
        }
    }
    Set-Location -LiteralPath $root
    [Environment]::CurrentDirectory = $root
    $logs = Join-Path $root 'logs'
    if (-not (Test-Path -LiteralPath $logs)) { try { [void](New-Item -ItemType Directory -Path $logs) } catch { } }
    if (-not (Test-Path -LiteralPath $logs)) {
        Rule
        Say ('Cannot create ' + $logs)
        Say 'Old server logs and the update stamp are kept there. Without it, a crash leaves no log to read and the'
        Say 'update backstop never runs.'
        Say 'Check the permissions on the server folder.'
        Rule
        Wait-Key; $script:LauncherExit = 2; return
    }

    $self = Get-SelfStamp
    $crashStreak = 0L
    $first = $true
    while ($true) {
        # ---- read hotwire.cfg and hotwire-secrets.cfg --------------------------------------------------------------
        # On the first read, a missing file or a bad save folder, map or port stops the launcher with the reason.
        # Later reads keep the last good settings instead.
        $env:HOTWIRE_FIRST = $(if ($first) { '1' } else { '' })
        $load = ''
        try { $load = Import-Settings } catch { Say ('Could not read the settings: ' + $_.Exception.Message) }
        if ($first -and $load -ne 'ok') { Say 'Not starting.'; Wait-Key; $script:LauncherExit = 2; return }
        $first = $false
        $env:HOTWIRE_FIRST = ''

        $updateAttempted = $false; $steamOk = $false; $frameworkOk = $false
        $script:UpdateLog.Clear(); $script:UpdateReason = ''; $script:UpdateEffective = ''
        $script:StartId = Get-UtcStamp ([DateTimeOffset]::UtcNow); $script:CheckOnly = [bool]$checkOnly
        Send-Step 'check' 'begun'
        # Hotwire's own update goes first, while nothing else has changed: a new hotwire.ps1 takes over at once (exit 75).
        if (Invoke-SelfUpdate) { $script:LauncherExit = 75; return }
        $branchName = Get-Env 'STEAM_BRANCH'; if (-not $branchName) { $branchName = 'public' }
        $mode = Get-Env 'UPDATE_MODE'

        try {
            # ---- who decides updates on this start ---------------------------------------------------------------------
            # In auto mode the Hotwire plugin rewrites UPDATE.schedule in the server folder every 15 minutes while it has
            # an update scheduled. If that file is missing, over two hours old or unreadable, nothing is scheduling
            # updates, so this start updates as in always mode, which keeps the server joinable.
            $script:UpdateCapture = $true
            # An update mode AFKPanel asked for is written first, so this start's update decision already follows it.
            if (-not $checkOnly -and (Invoke-UpdateModeRequest)) { $mode = Get-Env 'UPDATE_MODE' }
            $effective = $mode
            if ($mode -eq 'auto') {
                $effective = 'always'
                $marker = Join-Path $root 'UPDATE.schedule'
                try { if ((Test-Path -LiteralPath $marker) -and (((Get-Date) - (Get-Item -LiteralPath $marker).LastWriteTime).TotalHours -lt 2)) { $effective = 'hotwire' } } catch { }
                if ($effective -eq 'hotwire') { Say 'hotwire.update_mode is auto: the Hotwire plugin schedules updates.' }
                else { Say 'hotwire.update_mode is auto, and the Hotwire plugin has no update schedule.' }
            }

            # ---- the installed build and Steam's ----------------------------------------------------------------------
            # If anything here fails, both builds are unknown and the usual rules apply.
            $installed = ''; $public = ''
            $checkHours = Get-Num 'BUILD_CHECK_HOURS' 6
            if ($checkHours -ne 0) {
                # When flags decide updates, the answer must be current: a cached answer from before a Rust release
                # would start the old build. The cache is used only during a crash streak.
                $hours = $checkHours
                if ($effective -ne 'always' -and $effective -ne 'off' -and $crashStreak -eq 0) { $hours = 0 }
                $installed = Get-InstalledBuild
                $env:HOTWIRE_INSTALLED_BUILD = [string]$installed
                $public = Get-PublicBuild $branchName $hours
                $env:HOTWIRE_PUBLIC_BUILD = [string]$public
                # An answer not believed (older than the install on public, below) is not sent to AFKPanel as Steam's build.
                if ($installed -and $public -and (Get-Env 'STEAM_BRANCH') -eq 'public' -and [long]$installed -gt [long]$public) { $env:HOTWIRE_PUBLIC_BUILD = '' }
                if (-not $installed) {
                    Say 'Rust build: cannot read the installed build from'
                    Say ('  ' + $Acf)
                } elseif (-not $public) {
                    Say ('Rust build: installed ' + $installed + '. Steam did not answer, so the usual rules apply.')
                } elseif ($installed -eq $public) {
                    Say ('Rust build: installed ' + $installed + ', ' + $branchName + ' ' + $public + '. Up to date.')
                } elseif ([long]$installed -gt [long]$public -and (Get-Env 'STEAM_BRANCH') -eq 'public') {
                    # SteamCMD has answered with a build older than the installed public one (measured on Windows,
                    # 2026-10-07), so an answer older than the install is not believed: it counts as not knowing.
                    Say ('Rust build: installed ' + $installed + ', public ' + $public + '. Steam''s answer is older than this install,')
                    Say 'and SteamCMD can answer with an old build, so whether this install is current is not known.'
                } elseif ([long]$installed -gt [long]$public) {
                    Say ('Rust build: installed ' + $installed + ', ' + $branchName + ' ' + $public + '. This server is newer than')
                    Say ('Steam''s ' + $branchName + ' branch, so it is on another branch, such as staging. The next update moves')
                    Say ('it to ' + $branchName + ', as hotwire.steam_branch says.')
                } else {
                    Rule
                    Say ('Rust build: installed ' + $installed)
                    Say ('            ' + $branchName + '    ' + $public)
                    Say 'A NEWER BUILD IS AVAILABLE.'
                    Say 'Players'' games update themselves, so once the new build changes the protocol, this server turns them away.'
                    if ($effective -eq 'off') { Say 'hotwire.update_mode is off, so the launcher does not update it.' }
                    elseif ($effective -eq 'hotwire' -and (Get-Env 'UPDATE_ON_NEW_BUILD') -ne '1') { Say ('Create ' + $UpdateFlag + ' in ' + $root + ' to update on the next start.') }
                    else { Say 'A normal start updates the server before starting it.' }
                    Rule
                }
            }

            # ---- update or plain restart ------------------------------------------------------------------------------
            # UPDATE.flag updates Rust with SteamCMD, then Oxide, then starts; VALIDATE.flag does the same and has
            # SteamCMD check every file of the install. You, a scheduled task, or the plugin can create either flag.
            $script:UpdateEffective = $effective
            $doUpdate = $false; $doValidate = $false
            $updateFlagPath = Join-Path $root $UpdateFlag; $validateFlagPath = Join-Path $root $ValidateFlag
            if ($effective -eq 'off') {
                Say 'hotwire.update_mode is off: not updating.'
                Set-UpdateReason 'mode_off'
                if (Test-Path -LiteralPath $updateFlagPath) { Say ($UpdateFlag + ' is left in place and ignored.') }
                if (Test-Path -LiteralPath $validateFlagPath) { Say ($ValidateFlag + ' is left in place and ignored.') }
            } else {
                if ($effective -eq 'always') { $doUpdate = $true; Say ('hotwire.update_mode is ' + $mode + ': updating before the start.') }
                if (Test-Path -LiteralPath $updateFlagPath) { $doUpdate = $true; Say ($UpdateFlag + ' found: updating before the start.') }
                if (Test-Path -LiteralPath $validateFlagPath) { $doUpdate = $true; $doValidate = $true; Say ($ValidateFlag + ' found: updating and checking every file.') }
                if ($effective -ne 'always' -and -not $doUpdate) {
                    # A newer build on Steam is checked before the day count: a server that is behind updates now, and
                    # one that is current is left alone however long it has been. Unknown is not the same as current: a
                    # server left on an old build turns every player away after a Rust release, so when the build cannot
                    # be checked, the launcher updates. A server set to public (not left empty) that looks newer than
                    # Steam's public build counts as not checked; on any other branch a newer build is a test branch, and not behind.
                    if ((Get-Env 'UPDATE_ON_NEW_BUILD') -eq '1') {
                        if (-not $installed -or -not $public) {
                            $doUpdate = $true
                            Say 'Updating: could not check whether this install has Steam''s current build.'
                        } elseif ((Get-Env 'STEAM_BRANCH') -eq 'public' -and [long]$installed -gt [long]$public) {
                            $doUpdate = $true
                            Say ('Updating: Steam answered public ' + $public + ', older than installed ' + $installed + ', so the answer is not trusted.')
                        } elseif ($installed -ne $public -and [long]$installed -lt [long]$public) {
                            $doUpdate = $true
                            Say ('Updating: installed build ' + $installed + ' is behind Steam''s ' + $public + '.')
                        }
                    }
                    # The backstop: in hotwire mode, after hotwire.max_days_without_update days with no update, update.
                    # A missing stamp counts as no update ever, so a new install updates on its first start. Days are
                    # rounded down, so 13.6 days do not trigger a 14-day backstop half a day early.
                    $maxDays = Get-Num 'MAX_DAYS_WITHOUT_UPDATE' 14
                    if (-not $doUpdate -and $maxDays -ne 0) {
                        $days = 9999
                        try { if (Test-Path -LiteralPath $UpdateStamp) { $days = [long][math]::Floor(((Get-Date) - (Get-Item -LiteralPath $UpdateStamp).LastWriteTime).TotalDays) } } catch { }
                        if ($days -ge $maxDays) {
                            $doUpdate = $true
                            Rule
                            Say ('No update in ' + $days + ' days: updating now.')
                            Say 'A server that never updates turns players away after a Rust release. To update on a schedule'
                            Say 'instead, set hotwire.update_mode always in hotwire.cfg, or schedule updates in the plugin.'
                            Rule
                        }
                    }
                }
            }

            if (-not $doUpdate -and $effective -ne 'off') { Set-UpdateReason 'not_needed' }
            if ($checkOnly) {
                if ($doUpdate) { Say 'Check mode: a normal start would update here. Nothing is installed.'; Set-UpdateReason 'check_only' }
                else { Say 'Check mode: a normal start would not update.' }
                $doUpdate = $false
            }
            # The backup and the before-start hook speak for themselves; their lines are not the update's.
            $script:UpdateCapture = $false
            $env:DO_UPDATE = $(if ($doUpdate) { '1' } else { '0' })
            $check = [ordered]@{ update = [bool]$doUpdate; mode = $mode; effective_mode = $effective }
            if ($installed -match '\A\d+\z') { $check.rust_build_id = [string]$installed }
            if ([string]$env:HOTWIRE_PUBLIC_BUILD -match '\A\d+\z') { $check.rust_build_public = [string]$env:HOTWIRE_PUBLIC_BUILD }
            if (-not $doUpdate -and $script:UpdateReason) { $check.reason = $script:UpdateReason }
            Send-Step 'check' 'done' $check
            $script:HookRuns = @{}

            if (-not $checkOnly) {
                # Back up the stopped server before an update or a wipe changes it.
                try { Invoke-BackupBeforeLaunch } catch { Say ('Backup: ' + $_.Exception.Message) }
                # hotwire-before.bat runs before every start, ahead of any update. If it fails, the launcher says so and
                # starts anyway. Check mode runs no hooks.
                if (Test-Path -LiteralPath $HookBefore) {
                    Say 'Running hotwire-before.bat...'
                    if ((Invoke-Hook $HookBefore 'before') -eq 'failed') { Say 'hotwire-before.bat failed; starting anyway.' }
                }
            }

            if ($doUpdate) {
                $updateAttempted = $true
                $script:UpdateCapture = $true
                $steamOk = Update-Rust $doValidate $installed $public
                $frameworkOk = Update-Oxide $installed $doValidate

                # Delete the flags and reset the backstop only when the update completed: deleting a flag after a
                # failure would make the next restart skip the update, and resetting the stamp on every failed try would
                # stop the backstop from ever running. The backstop reads the stamp's modified time; the text is for
                # people.
                if ($steamOk -and $frameworkOk) {
                    foreach ($f in @($updateFlagPath, $validateFlagPath)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
                    try { [IO.File]::WriteAllText($UpdateStamp, 'Last update: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n") } catch { }
                    # Both can fail on permissions even though the update worked: a flag that stays makes every restart
                    # update, and a missing stamp makes the backstop treat the server as never updated.
                    if (Test-Path -LiteralPath $updateFlagPath) {
                        Say ('WARNING: ' + $UpdateFlag + ' could not be deleted after a successful update, so every restart will update.')
                        Say 'Check the permissions on the server folder.'
                    }
                    if (Test-Path -LiteralPath $validateFlagPath) {
                        Say ('WARNING: ' + $ValidateFlag + ' could not be deleted after a successful update, so every restart will check')
                        Say 'every file, which is slow. Check the permissions on the server folder.'
                    }
                    if (-not (Test-Path -LiteralPath $UpdateStamp)) {
                        Say 'WARNING: could not write the update stamp at'
                        Say ('  ' + $UpdateStamp)
                        Say 'The backstop reads it, so it will treat this server as never updated.'
                    }
                } else {
                    Rule
                    Say 'The update did not complete.'
                    Say ('Any ' + $UpdateFlag + ' or ' + $ValidateFlag + ' is kept and the update stamp is not reset, so the next start tries again.')
                    Rule
                }

                $script:UpdateCapture = $false
                # hotwire-after.bat runs after every update attempt, successful or not.
                if (Test-Path -LiteralPath $HookAfter) {
                    Say 'Running hotwire-after.bat...'
                    if ((Invoke-Hook $HookAfter 'after') -eq 'failed') { Say 'hotwire-after.bat failed; starting anyway.' }
                }
            } elseif (-not $checkOnly) {
                $script:UpdateCapture = $true; Say 'Restarting without updating Rust or Oxide.'; $script:UpdateCapture = $false
            }
        } catch {
            $script:UpdateCapture = $false
            # Nothing before the start may keep the server from starting.
            Say ('Before the start: ' + $_.Exception.Message + ' Starting anyway.')
        }

        # ---- wipes and permanent convars --------------------------------------------------------------------------------
        # When AFKPanel asks for a wipe or a permanent convar, the plugin leaves WIPE.flag or CONVAR.request in the
        # server folder. Between runs, while the server is stopped, every value is checked, written into hotwire.cfg,
        # and the file is read again so this start uses it. Check mode changes nothing.
        if ($checkOnly) {
            Say 'Check mode: the server is not started.'
            $script:LauncherExit = 0; return
        }
        if ((Test-Path -LiteralPath (Join-Path $root $WipeFlag)) -or (Test-Path -LiteralPath (Join-Path $root 'CONVAR.request'))) {
            $env:HOTWIRE_LOAD_STATE = $load
            $wipeResult = Join-Path $root 'WIPE.result'; $wipeBefore = $(if (Test-Path -LiteralPath $wipeResult) { (Get-Item -LiteralPath $wipeResult).LastWriteTimeUtc } else { [DateTime]::MinValue })
            try { Invoke-Edits } catch { Say ('Wipe or convar: ' + $_.Exception.Message) }
            try {
                if ((Test-Path -LiteralPath $wipeResult) -and (Get-Item -LiteralPath $wipeResult).LastWriteTimeUtc -gt $wipeBefore) {
                    $said = ([IO.File]::ReadAllText($wipeResult)).Trim()
                    if ($said.StartsWith('applied: ')) { Send-Step 'wipe' 'done' @{ detail = $said.Substring(9) } }
                }
            } catch { }
            try { [void](Import-Settings -Quiet) } catch { Say ('Could not read the settings: ' + $_.Exception.Message) }
        }

        # ---- start ------------------------------------------------------------------------------------------------------
        Move-ServerLog $crashStreak
        Write-LauncherState
        $startedAt = Get-UtcStamp ([DateTimeOffset]::UtcNow)
        $env:HOTWIRE_REPORT = 'session_start'; $env:HOTWIRE_STARTED_AT = $startedAt; $env:HOTWIRE_START_ID = $script:StartId
        $env:HOTWIRE_UPDATE_ATTEMPTED = $(if ($updateAttempted) { '1' } else { '0' })
        $env:STEAM_OK = $(if ($steamOk) { '1' } else { '0' }); $env:FRAMEWORK_OK = $(if ($frameworkOk) { '1' } else { '0' })
        try { Invoke-Report } catch { }
        $env:HOTWIRE_REPORT = ''
        # Held reports go in the background, this start's among them; the server starts without waiting.
        Start-BackgroundSend
        Say 'Starting the server...'
        Send-Step 'launch' 'done'
        $runStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $rustExit = 0
        try { $rustExit = Invoke-Launch } catch { Say ('Could not start the server: ' + $_.Exception.Message); $rustExit = -1 }
        $runSeconds = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $runStart

        $crashed = $runSeconds -lt (Get-Num 'CRASH_SECONDS' 60)
        if ($crashed) { $crashStreak++ } else { $crashStreak = 0 }
        # A crash while an update of Hotwire is still on probation puts the previous files back before the next start.
        if ($crashed -and (Test-Path -LiteralPath $SuApplied)) { Undo-SelfUpdate 'crashed' $SuApplied }

        # The session report: how this run ended and what its update did, written to the spool and sent in the
        # background.
        $env:HOTWIRE_REPORT = 'session'; $env:HOTWIRE_STARTED_AT = $startedAt; $env:HOTWIRE_RUST_EXIT = [string]$rustExit
        $env:HOTWIRE_CRASHED = $(if ($crashed) { '1' } else { '0' })
        $env:HOTWIRE_UPDATE_ATTEMPTED = $(if ($updateAttempted) { '1' } else { '0' })
        $env:STEAM_OK = $(if ($steamOk) { '1' } else { '0' }); $env:FRAMEWORK_OK = $(if ($frameworkOk) { '1' } else { '0' })
        $env:CRASH_STREAK = [string]$crashStreak
        try { Invoke-Report } catch { }
        $env:HOTWIRE_REPORT = ''

        if ((Get-Env 'RESTART_ON_EXIT') -eq '0') {
            Say ('Server exited after ' + $runSeconds + 's. hotwire.restart_on_exit is 0, so it is not restarted.')
            Send-Now
            $script:LauncherExit = 0; return
        }
        Start-BackgroundSend

        $maxStreak = Get-Num 'MAX_CRASH_STREAK' 10
        if ($maxStreak -ne 0 -and $crashStreak -ge $maxStreak) {
            # The launcher report: the launcher has stopped for good, which a missing heartbeat cannot tell apart from a
            # network outage. Nothing is waiting to start, so it is sent now.
            $env:HOTWIRE_REPORT = 'launcher'
            try { Invoke-Report } catch { }
            $env:HOTWIRE_REPORT = ''
            Send-Now
            Rule
            Say ('STOPPED. ' + $maxStreak + ' crashes in a row, each under ' + (Get-Num 'CRASH_SECONDS' 60) + 's. The server does not start, and')
            Say 'restarting it again will not help.'
            Say ''
            Say 'Read the log from the first crash:'
            Say ('  ' + [IO.Path]::Combine($root, 'logs', 'server_crash_*.txt'))
            Say 'Common causes: a bad setting in hotwire.cfg, a port already in use, or a corrupt save. With more than one'
            Say 'server on this machine, check that each has its own ports in hotwire.cfg. A second copy of this launcher'
            Say 'already running causes this too.'
            Say ''
            Say 'To keep restarting instead, set hotwire.max_crash_streak 0 in hotwire.cfg.'
            Rule
            Wait-Key; $script:LauncherExit = 2; return
        }

        # Back off, so a broken setting does not restart the server four times a minute forever, or run
        # hotwire-before.bat that often, which is costly when it makes a backup.
        $delay = Get-Num 'RESTART_DELAY' 15
        if ((Get-Env 'CRASH_BACKOFF') -ne '0') {
            if ($crashStreak -ge 2) { $delay = 30 }
            if ($crashStreak -ge 3) { $delay = 60 }
            if ($crashStreak -ge 4) { $delay = 120 }
            if ($crashStreak -ge 5) { $delay = 300 }
        }
        if ($crashStreak -gt 0) {
            Say ('Server exited after ' + $runSeconds + 's, which counts as a crash.')
            if ($maxStreak -eq 0) { Say ('Crash ' + $crashStreak + '. Retrying in ' + $delay + 's.') }
            else { Say ('Crash ' + $crashStreak + ' of ' + $maxStreak + '. Retrying in ' + $delay + 's.') }
        } else {
            Say ('Server exited. Restarting in ' + $delay + 's. Press Ctrl+C to stop.')
        }
        Start-Sleep -Seconds $delay

        # A hotwire.ps1 replaced while the server ran takes over here: hotwire.bat starts it again (exit 75), as if the
        # window had been opened again.
        if ((Get-SelfStamp) -ne $self) {
            Say 'hotwire.ps1 has changed: starting the new copy.'
            $script:LauncherExit = 75; return
        }
    }
}

try {
    if ($env:HOTWIRE_MODE -eq 'send') { Invoke-Send; exit 0 }
    Invoke-Main $args
    exit $script:LauncherExit
} catch {
    # An error nothing above expected: say it and wait, so the window does not close on a server that is not running.
    Rule
    Say ('The launcher stopped on an error it did not expect: ' + $_.Exception.Message)
    Say 'The server is not running. Fix what the message names, then run hotwire.bat again.'
    Rule
    Wait-Key
    exit 2
}
