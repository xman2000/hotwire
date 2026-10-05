# hotwire.ps1: the PowerShell half of the Hotwire launcher for Windows. hotwire.bat runs it with -File for each step,
# and HOTWIRE_MODE picks the part to run:
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
# The release this file belongs to. hotwire.bat must be the same one: the two agree on how each step is passed.
$LauncherVersion = '1.1.22'
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
    if ([string]$env:HOTWIRE_LAUNCHER_VERSION -ne $LauncherVersion) {
        Rule
        Say ('hotwire.ps1 is version ' + $LauncherVersion + ', hotwire.bat is ' + $env:HOTWIRE_LAUNCHER_VERSION + '.')
        Say 'Replace both from the same release. Not starting.'
        Rule
        Write-Output 'HWSET HW_LOAD=mismatch'
        return
    }
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
    Say ('hotwire.ps1 (' + $env:HOTWIRE_MODE + '): ' + $_.Exception.Message)
    exit 1
}
exit 0
