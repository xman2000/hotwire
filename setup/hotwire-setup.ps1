<#
    hotwire-setup -- install a Rust server on Windows, and connect it to Hotwire Panel if you want to.

    https://github.com/xman2000/hotwire            MIT (c) 2026 xman2000

    Double-click hotwire-setup.bat, which sits beside this file. With no command it first checks
    is Rust installed in this folder, is the clock right, is Hotwire installed, is the RCON password
    valid, is it connected -- then shows a menu and suggests what to do next. Right-click it and choose "Run as administrator"
    if you are installing, so the firewall and clock steps can act rather than only report.

    The .bat exists because Windows will not run a .ps1 by double-click, and by default refuses to run
    one at all. It changes no Windows setting.

    THIS SCRIPT IS A GUEST ON SOMEONE ELSE'S MACHINE.

    Every step says what it is about to do and waits for an answer; Enter takes the one in capitals. It
    never overwrites what it did not create without asking, never touches a Rust server it did not
    install, and stops to explain rather than guess. Every error names three things: what was tried,
    what was found, and what to do about it.

    Nothing here is required to run a Rust server. Connecting is optional, and `detach` undoes it.

    Requires Windows PowerShell 5.1, which ships with Windows 10 and Windows Server 2016 and later.

    Commands (from a console: .\hotwire-setup.bat <command>):
        install   Pre-flight checks everything, then installs only what is missing. Asks before every step.
        doctor    Check this machine is ready to connect. Changes nothing.
        connect   Connect to the panel. Asks for the code.
        status    What this server is connected to.
        detach    Disconnect. The server keeps running.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [string]$Root,
    [string]$SteamCmd = 'C:\steamcmd',
    [string]$Panel,
    [string]$Code,
    [string]$Name,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Version = '0.1.0'

# Captured here: inside a function, $PSBoundParameters describes that function, not this script.
$SteamCmdGiven = $PSBoundParameters.ContainsKey('SteamCmd')

# Relative to PowerShell's current location. [IO.Path]::GetFullPath resolves against the process's
# working directory instead, which is not the same thing and silently points somewhere else.
function Resolve-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path).TrimEnd('\')
}
$AppId = '258550'
$DefaultPanel = 'https://hotpanel.on-forge.com'

# Every URL below was checked on 2026-09-13. umod.org/games/rust/download answers 301 to
# github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust.zip -- the Windows bundle.
# The Linux bundle is a different file with the same entry names, so the redirect target is checked.
$SteamCmdZipUrl = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'
$OxideZipUrl = 'https://umod.org/games/rust/download'

# Hotwire itself, from the branch this script ships on: the launcher there knows INSTALL_FRAMEWORK, which
# a vanilla install needs. Repoint at main when the branch merges. GitHub serves both with LF line
# endings (checked 2026-09-13), which cmd.exe misreads in a .bat, so the launcher is saved with CRLF.
$LauncherUrl = 'https://raw.githubusercontent.com/xman2000/hotwire/connect-and-report/launcher/hotwire.bat'
$PluginUrl = 'https://raw.githubusercontent.com/xman2000/hotwire/connect-and-report/src/Hotwire.cs'

$Docs = [ordered]@{
    'This guide, step by step'  = 'https://github.com/xman2000/hotwire/blob/connect-and-report/docs/INSTALL-WINDOWS.md'
    'SteamCMD (Valve)'          = 'https://developer.valvesoftware.com/wiki/SteamCMD'
    'Creating a server (Rust)'  = 'https://wiki.facepunch.com/rust/Creating-a-server'
    'Rust+ companion (Rust)'    = 'https://wiki.facepunch.com/rust/rust-companion-server'
    'Oxide (uMod)'              = 'https://umod.org/games/rust'
    'Oxide source and releases' = 'https://github.com/OxideMod/Oxide.Rust'
    'Hotwire (source)'          = 'https://github.com/xman2000/hotwire'
}

# The same layout hotwire.bat ships with (section 4.1). If you change the ports there, change the
# firewall rules to match -- a rule for the wrong port looks exactly like a rule that works.
$GamePort = 28015    # UDP, server.port
$QueryPort = 28017   # UDP, server.queryport -- the server browser. Without it the server is invisible.
$RconPort = 28016    # TCP, rcon.port -- never opened by this script
$AppPort = 28083     # TCP, Rust+: the larger of server.port and rcon.port, plus 67 (Rust wiki)

# Rust's own published floor (wiki.facepunch.com/rust/Creating-a-server). Warned about, not enforced:
# a small test server runs on less, and refusing would be guessing at what the reader wants.
$MinFreeDiskGB = 15
$MinRamGB = 12

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Windows PowerShell 5.1 redraws its progress bar for every block it downloads, which makes a 13 MB
# file take minutes. Downloads here say what they are doing instead.
$ProgressPreference = 'SilentlyContinue'

$script:Changed = New-Object System.Collections.Generic.List[string]

# ------------------------------------------------------------------ output --
function Write-Ok   ($m) { Write-Host "  [ ok ] $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Bad  ($m) { Write-Host "  [fail] $m" -ForegroundColor Red }
function Write-Note ($m) { Write-Host "        $m" -ForegroundColor DarkGray }
function Write-Head ($m) { Write-Host ""; Write-Host $m -ForegroundColor White; Write-Host ('-' * $m.Length) -ForegroundColor DarkGray }

function Write-Why([string[]]$Lines) {
    foreach ($line in $Lines) { Write-Host "  $line" }
    Write-Host ""
}

# ----------------------------------------------------------- look and feel --
# Plain ASCII on purpose: Windows PowerShell 5.1 reads a file without a byte-order mark as the local
# code page, so a box-drawing character here would arrive as mojibake. Colour does the rest.
$script:StepNo = 0
$script:StepTotal = 0

function Show-Banner {
    $art = @(
        ' ____   _   _  ____   _____ ',
        '|  _ \ | | | |/ ___| |_   _|',
        '| |_) || | | |\___ \   | |  ',
        '|  _ < | |_| | ___) |  | |  ',
        '|_| \_\ \___/ |____/   |_|  '
    )
    $shades = @('Yellow', 'DarkYellow', 'Red', 'Red', 'DarkRed')
    Write-Host ""
    Write-Host "              W E L C O M E    T O" -ForegroundColor Gray
    Write-Host ""
    for ($i = 0; $i -lt $art.Count; $i++) { Write-Host ("            " + $art[$i]) -ForegroundColor $shades[$i] }
    Write-Host ""
    Write-Host "        -=[ " -NoNewline -ForegroundColor DarkGray
    Write-Host "supported by " -NoNewline -ForegroundColor Gray
    Write-Host "H O T W I R E" -NoNewline -ForegroundColor Cyan
    Write-Host " ]=-" -ForegroundColor DarkGray
    Write-Host ("                 setup {0}" -f $Version) -ForegroundColor DarkGray
    Write-Host ""
}

# A heavy rule and the step's place in the plan, so a long install always says where it is.
function Write-Step([string]$Title) {
    $script:StepNo++
    $label = if ($script:StepTotal) { "STEP $($script:StepNo) OF $($script:StepTotal)" } else { "STEP $($script:StepNo)" }
    Write-Host ""
    Write-Host ("  " + ('=' * 72)) -ForegroundColor DarkCyan
    Write-Host "  >> " -NoNewline -ForegroundColor Yellow
    Write-Host "$label   " -NoNewline -ForegroundColor DarkCyan
    Write-Host $Title.ToUpper() -ForegroundColor White
    Write-Host ("  " + ('=' * 72)) -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Frame([string]$Title) {
    Write-Host ""
    Write-Host "  .--[ " -NoNewline -ForegroundColor DarkCyan
    Write-Host $Title.ToUpper() -NoNewline -ForegroundColor White
    Write-Host (" ]" + ('-' * [math]::Max(4, 64 - $Title.Length)) + ".") -ForegroundColor DarkCyan
}

function Write-Group([string]$Name) { Write-Host ""; Write-Host "  $Name" -ForegroundColor Cyan }

# One line of a pre-flight: status, what was checked, what was found.
function Write-Check([string]$Status, [string]$Label, [string]$Detail) {
    $tag = @{ ok = '[ ok ]'; no = '[ -- ]'; warn = '[warn]'; fail = '[FAIL]'; info = '[ .. ]' }[$Status]
    $color = @{ ok = 'Green'; no = 'Gray'; warn = 'Yellow'; fail = 'Red'; info = 'DarkGray' }[$Status]
    Write-Host ("    {0} " -f $tag) -NoNewline -ForegroundColor $color
    Write-Host ("{0,-17}" -f $Label) -NoNewline -ForegroundColor White
    Write-Host $Detail -ForegroundColor $color
}

function Write-Box([string[]]$Lines, [string]$Color = 'DarkCyan') {
    $width = ($Lines | Measure-Object -Property Length -Maximum).Maximum + 4
    Write-Host ""
    Write-Host ("  +" + ('=' * $width) + "+") -ForegroundColor $Color
    foreach ($line in $Lines) { Write-Host ("  |  " + $line.PadRight($width - 2) + "|") -ForegroundColor $Color }
    Write-Host ("  +" + ('=' * $width) + "+") -ForegroundColor $Color
}

# Ctrl+C during a countdown stops the script with nothing started -- the point of counting down is that
# the last moment to change your mind is visible.
function Show-Countdown([int]$Seconds, [string]$What) {
    Write-Host ""
    for ($i = $Seconds; $i -ge 1; $i--) {
        $bar = ('#' * ($Seconds - $i + 1)).PadRight($Seconds, '.')
        Write-Host ("`r  [{0}]  {1} in {2}...   Ctrl+C stops it " -f $bar, $What, $i) -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host ("`r  [{0}]  {1} now.{2}" -f ('#' * $Seconds), $What, (' ' * 30)) -ForegroundColor Green
}

# Three parts, always. "Failed to install" helps nobody at three in the morning.
function Stop-Politely {
    param([string]$Tried, [string]$Found, [string]$Fix)
    Write-Host ""
    Write-Host "Cannot continue." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Tried : $Tried"
    Write-Host "  Found : $Found"
    Write-Host "  Fix   : $Fix"
    Write-Host ""
    Write-Summary
    exit 1
}

# Enter takes the answer shown in capitals. -DefaultYes is for installing what someone downloaded this
# to install -- SteamCMD, Oxide, the plugin -- and connecting to the panel, each asked only when it is
# not already there. Everything that replaces, removes or goes beyond that defaults to no.
# -Yes answers for connect and detach, which are run unattended; install never takes it.
$script:YesAllowed = $false
function Confirm-Step([string]$Question, [switch]$DefaultYes) {
    if ($Yes -and $script:YesAllowed) { Write-Note "(-Yes) $Question"; return $true }
    if ($DefaultYes) {
        $answer = Read-Host "  $Question [Y/n]"
        return $answer -notmatch '^\s*[nN]'
    }
    $answer = Read-Host "  $Question [y/N]"
    return $answer -match '^\s*[yY]'
}

function Write-Summary {
    if ($script:Changed.Count -eq 0) { Write-Note "Nothing on this machine was changed."; return }
    Write-Host "  Changed on this machine:"
    foreach ($c in $script:Changed) { Write-Host "    $c" }
}

# ------------------------------------------------------------- the record --
# What this script finished, kept beside the server. It is how a second run knows the folder is one
# it started, and so may carry on in, rather than somebody else's server it must leave alone.
function Get-RecordFile([string]$d) { Join-Path $d 'hotwire\install.json' }

function Read-Record([string]$d) {
    $f = Get-RecordFile $d
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) }
    catch {
        Stop-Politely "reading $f" "it is not valid JSON" `
            "if you edited it, undo the edit; if not, delete it only if you are sure this folder holds nothing but a half-finished install"
    }
}

function Save-Record([string]$d, [string]$Step) {
    $record = Read-Record $d
    $done = @()
    $started = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($record) {
        $done = @($record.done)
        if ($record.started_at) { $started = [string]$record.started_at }
    }
    if ($Step -and ($done -notcontains $Step)) { $done += $Step }
    $body = [ordered]@{
        installer = "hotwire-setup $Version"
        started_at = $started
        updated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        steamcmd = $SteamCmd
        done = $done
    }
    $f = Get-RecordFile $d
    $isNew = -not (Test-Path -LiteralPath $f)
    New-Item -ItemType Directory -Path (Split-Path $f -Parent) -Force | Out-Null
    # UTF-8 without a BOM, because a BOM is invisible and breaks every reader that is not expecting one.
    [System.IO.File]::WriteAllText($f, ($body | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    if ($isNew) { $script:Changed.Add("created $f") }
}

function Test-Done([string]$d, [string]$Step) {
    $record = Read-Record $d
    return ($record -and (@($record.done) -contains $Step))
}

# ---------------------------------------------------------------- helpers --
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeGB([string]$Path) {
    $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($Path))
    return [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
}

function Invoke-Download([string]$Url, [string]$OutFile, [string]$What) {
    Write-Note "downloading $What"
    Write-Note "from $Url"
    try {
        $response = Invoke-WebRequest -Uri $Url -OutFile $OutFile -UserAgent 'Mozilla/5.0' -UseBasicParsing -PassThru -TimeoutSec 300
    } catch {
        Stop-Politely "downloading $What from $Url" "$($_.Exception.Message)" `
            "check this machine can reach the internet, then run the script again -- it carries on where it stopped"
    }
    $size = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1MB, 1)
    Write-Ok "downloaded $What ($size MB)"
    return $response
}

# ------------------------------------------------------------- 1. machine --
# The two things nothing else can work around. Everything else is a pre-flight line, not a stop.
function Test-Requirements {
    if ($env:OS -ne 'Windows_NT') {
        Stop-Politely "checking this is Windows" "OS reports '$env:OS'" "on Linux, follow docs/INSTALL-LINUX.md instead"
    }
    $ps = $PSVersionTable.PSVersion
    if ($ps.Major -lt 5 -or ($ps.Major -eq 5 -and $ps.Minor -lt 1)) {
        Stop-Politely "checking PowerShell" "version $ps" "install Windows Management Framework 5.1 from Microsoft, then run this again"
    }
}

# The clock. Two reasons it is checked before anything is downloaded:
#   - hours or days out, HTTPS certificate checks fail and every download here fails with a message
#     about trust rather than time;
#   - minutes out, Hotwire Panel refuses every signed request later (its window is 300 seconds) with
#     a message that says nothing about clocks.
# Measured against the Date header of the SteamCMD download server, which this script contacts
# anyway, so checking costs no extra party a request.
function Get-ClockSkew {
    try {
        $r = Invoke-WebRequest -Uri $SteamCmdZipUrl -Method Head -UseBasicParsing -TimeoutSec 15
        $remote = [datetime]::ParseExact([string]$r.Headers['Date'], 'r', [Globalization.CultureInfo]::InvariantCulture)
        return ((Get-Date).ToUniversalTime() - $remote).TotalSeconds
    } catch { return $null }
}

function Test-InstallClock {
    Write-Step "Clock"
    $skew = Get-ClockSkew
    if ($null -eq $skew) {
        Write-Warn "could not compare this machine's clock with the internet's"
        Write-Note "If the downloads below fail with a certificate error, the clock is the first suspect."
        return
    }
    $abs = [math]::Abs($skew)
    $direction = if ($skew -gt 0) { 'ahead' } else { 'behind' }
    if ($abs -le 30) { Write-Ok ("clock is right ({0:N0}s from Steam's servers)" -f $abs); return }

    if ($abs -le 300) { Write-Warn ("clock is {0:N0}s {1} -- fine for now, but drifting" -f $abs, $direction) }
    else { Write-Bad ("clock is {0:N0}s {1}" -f $abs, $direction) }
    Write-Note "Downloads tolerate some drift. Hotwire Panel, if you connect later, refuses anything over 300s."

    $service = Get-Service -Name W32Time -ErrorAction SilentlyContinue
    if (-not $service) { Write-Note "The Windows Time service is not installed. Fix: Settings > Time > 'Sync now'."; return }
    Write-Note "Windows Time service: $($service.Status), start type $($service.StartType)"

    if (-not $script:IsAdmin) {
        Write-Note "Fixing it needs Administrator. Later, as Administrator: w32tm /resync"
        return
    }
    if ($service.StartType -eq 'Disabled') {
        Write-Note "The time service is disabled, which is a choice someone made. Not changing it."
        Write-Note "Fix it yourself if that was not deliberate: Settings > Time > 'Set time automatically'."
        return
    }

    Write-Host ""
    Write-Why @(
        "Windows can ask its time server for the correct time now. This starts the Windows Time",
        "service if it is stopped, and runs: w32tm /resync"
    )
    if (-not (Confirm-Step "Sync the clock now?")) { Write-Note "Left as it is."; return }

    try {
        if ($service.Status -ne 'Running') {
            Start-Service -Name W32Time
            $script:Changed.Add("started the Windows Time service")
        }
        & w32tm /resync | ForEach-Object { Write-Note $_ }
        if ($LASTEXITCODE -ne 0) { Write-Warn "w32tm could not sync (exit $LASTEXITCODE). Try Settings > Time > 'Sync now'." }
        else { $script:Changed.Add("synced the clock with w32tm /resync") }
    } catch { Write-Warn "could not sync the clock: $($_.Exception.Message)" }

    $after = Get-ClockSkew
    if ($null -ne $after) {
        if ([math]::Abs($after) -le 30) { Write-Ok ("clock is now right ({0:N0}s)" -f [math]::Abs($after)) }
        else { Write-Warn ("clock is still {0:N0}s out" -f [math]::Abs($after)) }
    }
}

# ----------------------------------------------------------- 2. directory --
function Select-Directory {
    Write-Head "Where the server goes"

    $d = $Root
    if (-not $d) {
        $here = (Get-Location).Path
        Write-Why @(
            "The Rust server is about 12 GB of files plus its saves and logs. It gets its own folder,",
            "and everything this script installs for the server goes inside it."
        )
        Write-Host "  This folder: $here"
        Write-Host ""
        if (Confirm-Step "Install the Rust server here?") { $d = $here }
        else {
            Write-Note "A short path with no spaces is easiest, for example C:\rustserver"
            $d = (Read-Host "  Type the folder to use (Enter on its own to stop)").Trim().Trim('"')
            if (-not $d) { Write-Summary; exit 0 }
        }
    }

    $d = Resolve-FullPath $d

    # A trailing backslash inside quotes escapes the quote when SteamCMD reads its command line, and
    # a drive root would scatter a server's files among everything else on the disk.
    if ($d.Length -le 2) {
        Stop-Politely "using '$d' for the server" "that is the root of a drive" "choose a folder, for example C:\rustserver"
    }
    # Belt and braces behind hotwire-setup.bat: an elevated prompt starts in System32, and a Rust
    # server inside the Windows folder would be a disaster to find and worse to remove.
    if ($env:SystemRoot -and ($d -eq $env:SystemRoot -or $d -like "$env:SystemRoot\*")) {
        Stop-Politely "using '$d' for the server" "that is inside the Windows folder" `
            "put hotwire-setup.bat in the folder you want the server in (for example C:\rustserver) and start it from there"
    }
    if ($d.TrimEnd('\') -eq $SteamCmd.TrimEnd('\')) {
        Stop-Politely "using '$d' for the server" "that is where SteamCMD goes" "choose a separate folder, for example C:\rustserver"
    }
    if ($d -like "$env:ProgramFiles*" -or ($env:ProgramW6432 -and $d -like "$env:ProgramW6432*") -or (${env:ProgramFiles(x86)} -and $d -like "${env:ProgramFiles(x86)}*")) {
        Write-Warn "that is inside Program Files"
        Write-Note "Windows protects that folder: the server may be unable to write its saves and logs"
        Write-Note "unless it always runs as Administrator. C:\rustserver avoids the problem."
        if (-not (Confirm-Step "Use it anyway?")) { Write-Summary; exit 0 }
    }
    if ($d -match ' ') {
        Write-Warn "the path contains a space"
        Write-Note "This script quotes it correctly. Hand-written start scripts often do not; if one of"
        Write-Note "yours ever fails to find the server, the space is the first thing to check."
    }

    if (Test-Path -LiteralPath $d -PathType Leaf) {
        Stop-Politely "using '$d' for the server" "that is a file, not a folder" "choose a folder"
    }

    $record = if (Test-Path -LiteralPath $d) { Read-Record $d } else { $null }
    $hasServer = Test-Path -LiteralPath (Join-Path $d 'RustDedicated.exe')

    # The guest rule. A server we did not install belongs to someone who set it up their
    # own way. Updating it through here would replace files with no backup and no way back.
    if ($hasServer -and -not $record) {
        Stop-Politely "installing into $d" "a Rust server is already there, and this script did not install it" `
            "to keep it and add Hotwire, follow the guide from step 6; to start over, choose an empty folder"
    }

    if ($record) {
        Write-Ok "carrying on with an install started here on $($record.started_at)"
        if (@($record.done).Count -gt 0) { Write-Note ("already finished: " + (@($record.done) -join ', ')) }
        if ($record.steamcmd -and -not $SteamCmdGiven) { $script:SteamCmd = [string]$record.steamcmd }
    } elseif (Test-Path -LiteralPath $d) {
        $items = @(Get-ChildItem -LiteralPath $d -Force)
        if ($items.Count -gt 0) {
            Write-Warn "$d already holds $($items.Count) item(s)"
            $items | Select-Object -First 8 | ForEach-Object { Write-Note $_.Name }
            if ($items.Count -gt 8) { Write-Note "..." }
            Write-Note "Nothing there is deleted. The server's files are added beside them, and a file with"
            Write-Note "the same name as one of the server's would be replaced."
            if (-not (Confirm-Step "Install into this folder anyway?")) { Write-Summary; exit 0 }
        } else { Write-Ok "$d is empty" }
    } else {
        Write-Note "$d does not exist yet and will be created."
    }

    return $d
}

# ------------------------------------------------------------ pre-flight --
# Everything install could do, checked first and changed by none of it. The plan is whatever this finds
# missing, so a second run on a finished server does nothing, and a half-finished one does only the rest.

# The firewall profiles in force right now. A rule for Private networks does nothing on a machine whose
# connection is Public, so "open" has to mean open on the network in use. $null when it cannot be told.
function Get-ActiveFirewallProfiles {
    try {
        $names = @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object {
            $category = [string]$_.NetworkCategory
            if ($category -eq 'DomainAuthenticated') { 'Domain' } else { $category }
        } | Select-Object -Unique)
        if ($names.Count -gt 0) { return $names }
    } catch { }
    return $null
}

function Test-RuleApplies($Rule, $ActiveProfiles) {
    if ($null -eq $ActiveProfiles) { return $true }
    $ruleProfile = [string]$Rule.Profile
    if (-not $ruleProfile -or $ruleProfile -eq 'Any') { return $true }
    foreach ($name in $ActiveProfiles) { if ($ruleProfile -match "\b$name\b") { return $true } }
    return $false
}

# Allow and block rules for one port that apply on the network in use, and allow rules that exist but
# only for a network type this machine is not on.
function Get-PortState([string]$Protocol, [int]$Port, $ActiveProfiles) {
    $rules = @(Get-InboundPortRules $Protocol $Port)
    $applying = @($rules | Where-Object { Test-RuleApplies $_ $ActiveProfiles })
    return [pscustomobject]@{
        Allows    = @($applying | Where-Object { $_.Action -eq 'Allow' })
        Blocks    = @($applying | Where-Object { $_.Action -eq 'Block' })
        Elsewhere = @($rules | Where-Object { $_.Action -eq 'Allow' -and -not (Test-RuleApplies $_ $ActiveProfiles) })
    }
}

function Get-InstallState([string]$d) {
    $s = [ordered]@{ Dir = $d }
    $s.PsVersion = [string]$PSVersionTable.PSVersion
    $s.IsAdmin = Test-Admin
    $script:IsAdmin = $s.IsAdmin
    $s.RamGB = $null
    try { $s.RamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } catch { }
    $s.FreeGB = $null
    try { $s.FreeGB = Get-FreeGB $d } catch { }
    $s.ClockSkew = Get-ClockSkew

    $s.SteamCmdExe = Join-Path $SteamCmd 'steamcmd.exe'
    $s.HasSteamCmd = Test-Path -LiteralPath $s.SteamCmdExe
    $s.HasRust = Test-Path -LiteralPath (Join-Path $d 'RustDedicated.exe')
    $s.RustBuild = if ($s.HasRust) { Get-InstalledBuild $d } else { $null }
    $s.RustDone = $s.HasRust -and [bool]$s.RustBuild -and (Test-Done $d 'rust')

    $oxideDll = Join-Path $d 'RustDedicated_Data\Managed\Oxide.Rust.dll'
    $s.HasOxide = Test-Path -LiteralPath $oxideDll
    $s.OxideVersion = if ($s.HasOxide) { [string](Get-Item -LiteralPath $oxideDll).VersionInfo.FileVersion } else { $null }

    $launcher = Join-Path $d 'hotwire.bat'
    $s.HasLauncher = Test-Path -LiteralPath $launcher
    $s.LauncherVanilla = $s.HasLauncher -and (Select-String -LiteralPath $launcher -SimpleMatch 'set "INSTALL_FRAMEWORK=0"' -Quiet)

    $plugin = Join-Path $d 'oxide\plugins\Hotwire.cs'
    $s.HasPlugin = Test-Path -LiteralPath $plugin
    $s.PluginVersion = $null
    if ($s.HasPlugin) {
        try {
            $m = [regex]::Match([IO.File]::ReadAllText($plugin), '\[Info\("Hotwire",\s*"[^"]*",\s*"([^"]+)"\)\]')
            if ($m.Success) { $s.PluginVersion = $m.Groups[1].Value }
        } catch { }
    }

    $s.RconProblem = if ($s.HasLauncher) { Get-SecretsProblem $d } else { $null }

    $s.Connected = Test-Path -LiteralPath (Get-StateFile $d)
    $s.Identity = $null
    if ($s.Connected) { try { $s.Identity = [string](Read-State $d).identity } catch { } }

    $s.FirewallError = $null; $s.ActiveProfiles = $null; $s.FirewallOn = $null
    $s.Game = $null; $s.Query = $null; $s.RconOpen = @(); $s.ProgramRules = @()
    try {
        $s.ActiveProfiles = Get-ActiveFirewallProfiles
        $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
        $relevant = if ($s.ActiveProfiles) { @($profiles | Where-Object { $s.ActiveProfiles -contains $_.Name }) } else { $profiles }
        $s.FirewallOn = @($relevant | Where-Object { $_.Enabled -eq 'True' }).Count -gt 0
        $s.Game = Get-PortState 'UDP' $GamePort $s.ActiveProfiles
        $s.Query = Get-PortState 'UDP' $QueryPort $s.ActiveProfiles
        $s.RconOpen = @((Get-PortState 'TCP' $RconPort $s.ActiveProfiles).Allows)
        $active = $s.ActiveProfiles
        $s.ProgramRules = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore |
            Where-Object { $_.Program -like '*\RustDedicated.exe' } | Get-NetFirewallRule |
            Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' -and (Test-RuleApplies $_ $active) })
    } catch { $s.FirewallError = $_.Exception.Message }

    return [pscustomobject]$s
}

function Write-PortCheck([string]$Label, $Port, $FirewallOn) {
    if ($FirewallOn -eq $false) { Write-Check info $Label "reachable -- the firewall is off"; return }
    if ($Port.Blocks.Count -gt 0) { Write-Check fail $Label "BLOCKED by '$($Port.Blocks[0].DisplayName)' -- a block beats every allow"; return }
    if ($Port.Allows.Count -gt 0) { Write-Check ok $Label "open: '$($Port.Allows[0].DisplayName)' $(Get-RemoteText $Port.Allows[0])"; return }
    if ($Port.Elsewhere.Count -gt 0) { Write-Check no $Label "closed here -- '$($Port.Elsewhere[0].DisplayName)' only covers $($Port.Elsewhere[0].Profile) networks"; return }
    Write-Check no $Label "closed"
}

function Show-InstallState($s, [string]$Title) {
    Write-Frame $Title
    Write-Host "    folder: $($s.Dir)" -ForegroundColor DarkGray

    Write-Group "This machine"
    Write-Check ok 'PowerShell' $s.PsVersion
    if ($s.IsAdmin) { Write-Check ok 'Administrator' 'yes' }
    else { Write-Check warn 'Administrator' 'no -- the firewall and the clock can be checked, not changed' }
    if ($null -eq $s.RamGB) { Write-Check warn 'Memory' 'could not be read' }
    elseif ($s.RamGB -ge $MinRamGB) { Write-Check ok 'Memory' "$($s.RamGB) GB" }
    else { Write-Check warn 'Memory' "$($s.RamGB) GB -- Rust recommends $MinRamGB GB" }
    if ($null -eq $s.FreeGB) { Write-Check warn 'Disk' "free space could not be read -- Rust recommends $MinFreeDiskGB GB" }
    elseif ($s.FreeGB -ge $MinFreeDiskGB) { Write-Check ok 'Disk' "$($s.FreeGB) GB free" }
    else { Write-Check warn 'Disk' "$($s.FreeGB) GB free -- Rust recommends $MinFreeDiskGB GB" }
    if ($null -eq $s.ClockSkew) { Write-Check warn 'Clock' "could not be compared with Steam's servers" }
    else {
        $abs = [math]::Abs($s.ClockSkew); $dir = if ($s.ClockSkew -gt 0) { 'ahead' } else { 'behind' }
        if ($abs -le 30) { Write-Check ok 'Clock' ("right ({0:N0}s from Steam's servers)" -f $abs) }
        elseif ($abs -le 300) { Write-Check warn 'Clock' ("{0:N0}s {1} -- drifting" -f $abs, $dir) }
        else { Write-Check fail 'Clock' ("{0:N0}s {1} -- Hotwire Panel would refuse every request" -f $abs, $dir) }
    }

    Write-Group "Rust"
    if ($s.HasSteamCmd) { Write-Check ok 'SteamCMD' $s.SteamCmdExe } else { Write-Check no 'SteamCMD' "not installed ($SteamCmd)" }
    if ($s.RustDone) { Write-Check ok 'Rust server' "build $($s.RustBuild)" }
    elseif ($s.HasRust) { Write-Check warn 'Rust server' 'download not finished' }
    else { Write-Check no 'Rust server' 'not installed' }
    if ($s.HasOxide) { Write-Check ok 'Oxide' $s.OxideVersion } else { Write-Check no 'Oxide' 'not installed -- without it, a vanilla server' }

    Write-Group "Hotwire"
    if (-not $s.HasLauncher) { Write-Check no 'Start script' 'no hotwire.bat' }
    elseif ($s.HasOxide -and $s.LauncherVanilla) { Write-Check warn 'Start script' 'hotwire.bat is set for vanilla, but Oxide is installed' }
    elseif (-not $s.HasOxide -and -not $s.LauncherVanilla -and $s.HasRust) { Write-Check warn 'Start script' 'hotwire.bat will install Oxide on this vanilla server' }
    else { Write-Check ok 'Start script' $(if ($s.LauncherVanilla) { 'hotwire.bat (vanilla)' } else { 'hotwire.bat' }) }
    if ($s.HasPlugin) { Write-Check ok 'Plugin' $(if ($s.PluginVersion) { "Hotwire $($s.PluginVersion)" } else { 'Hotwire.cs' }) }
    else { Write-Check no 'Plugin' 'not installed' }
    if (-not $s.HasLauncher) { Write-Check info 'RCON password' 'set with the start script' }
    elseif ($s.RconProblem) { Write-Check fail 'RCON password' "$($s.RconProblem) -- hotwire.bat will not start" }
    else { Write-Check ok 'RCON password' 'set, and hotwire.bat will accept it' }
    if ($s.Connected) { Write-Check ok 'Hotwire Panel' $(if ($s.Identity) { "connected as '$($s.Identity)'" } else { 'connected' }) }
    else { Write-Check no 'Hotwire Panel' 'not connected' }

    Write-Group "Firewall"
    if ($s.FirewallError) { Write-Check warn 'Windows Firewall' "could not be read: $($s.FirewallError)" }
    else {
        $network = if ($s.ActiveProfiles) { ($s.ActiveProfiles -join ', ') + ' network' } else { 'network type unknown' }
        if ($s.FirewallOn) { Write-Check ok 'Windows Firewall' "on ($network)" }
        else { Write-Check warn 'Windows Firewall' "OFF ($network) -- every port is reachable, RCON included" }
        Write-PortCheck "Game  UDP $GamePort" $s.Game $s.FirewallOn
        Write-PortCheck "Query UDP $QueryPort" $s.Query $s.FirewallOn
        if ($s.RconOpen.Count -gt 0) { Write-Check warn "RCON  TCP $RconPort" "OPEN: '$($s.RconOpen[0].DisplayName)' $(Get-RemoteText $s.RconOpen[0])" }
        elseif ($s.FirewallOn) { Write-Check ok "RCON  TCP $RconPort" 'closed, as it should be' }
        foreach ($r in $s.ProgramRules) {
            if ($r.Action -eq 'Allow') { Write-Check warn 'RustDedicated' "'$($r.DisplayName)' allows the program $(Get-RemoteText $r) -- RCON too, if it names no port" }
            else { Write-Check fail 'RustDedicated' "'$($r.DisplayName)' blocks the program -- players cannot connect" }
        }
    }
}

# What the pre-flight found missing, in the order it has to be done.
function Get-InstallPlan($s) {
    $plan = New-Object System.Collections.Generic.List[object]
    $add = { param($Key, $Title, $Why) $plan.Add([pscustomobject]@{ Key = $Key; Title = $Title; Why = $Why }) }

    if ($null -ne $s.ClockSkew -and [math]::Abs($s.ClockSkew) -gt 30) { & $add 'clock' 'Clock' ("{0:N0}s out" -f [math]::Abs($s.ClockSkew)) }
    if (-not $s.RustDone) {
        & $add 'steamcmd' 'SteamCMD' $(if ($s.HasSteamCmd) { 'let it update itself before the download' } else { 'install it -- Rust downloads through it' })
        & $add 'rust' 'Rust server' $(if ($s.HasRust) { 'finish the download' } else { 'download it, about 12 GB' })
    }
    if (-not $s.HasOxide) { & $add 'oxide' 'Oxide' 'install it, or say no for a vanilla server' }
    if (-not $s.HasLauncher) { & $add 'launcher' 'Start script' 'install hotwire.bat, or say no to use your own' }
    if (-not $s.HasPlugin) { & $add 'plugin' 'Hotwire plugin' 'install it -- needs Oxide' }
    if (-not $s.HasLauncher -or $s.RconProblem) { & $add 'rcon' 'RCON password' $(if ($s.RconProblem) { "fix it: $($s.RconProblem)" } else { 'set it, for hotwire.bat' }) }
    $portsShut = $s.FirewallError -or ($s.FirewallOn -and ($s.Game.Allows.Count -eq 0 -or $s.Query.Allows.Count -eq 0 -or $s.Game.Blocks.Count -gt 0 -or $s.Query.Blocks.Count -gt 0))
    if ($portsShut) { & $add 'firewall' 'Firewall' "open UDP $GamePort and $QueryPort" }
    if (-not $s.Connected) { & $add 'panel' 'Hotwire Panel' 'connect this server' }
    return $plan.ToArray()
}

function Show-InstallPlan($Plan, $s) {
    Write-Frame 'Flight plan'
    if ($Plan.Count -eq 0) { return }
    Write-Host ""
    $n = 0
    foreach ($step in $Plan) {
        $n++
        $note = if (-not $s.IsAdmin -and $step.Key -in @('clock', 'firewall')) { '   (report only -- not Administrator)' } else { '' }
        Write-Host ("    {0,2}.  " -f $n) -NoNewline -ForegroundColor Yellow
        Write-Host ("{0,-16}" -f $step.Title) -NoNewline -ForegroundColor White
        Write-Host ($step.Why + $note) -ForegroundColor Gray
    }
    if (($Plan | Where-Object { $_.Key -eq 'rust' }) -and $null -ne $s.FreeGB -and $s.FreeGB -lt $MinFreeDiskGB) {
        Write-Host ""
        Write-Warn "only $($s.FreeGB) GB free for a download of about 12 GB"
    }
    Write-Host ""
    Write-Note "Every step still says what it will do and asks first."
}

function Show-Finish([string]$d, $s) {
    $ready = $s.HasRust -and $s.RustDone -and $s.HasLauncher -and -not $s.RconProblem
    if ($ready) {
        Write-Box @('A L L   S Y S T E M S   G O', '', 'This Rust server is ready to start.') 'Green'
    } else {
        Write-Box @('N O T   R E A D Y   Y E T', '', 'The pre-flight lines marked above say what is left.') 'Yellow'
    }
    Write-Host ""
    Write-Summary
    Write-Host ""
    if ($s.HasLauncher) {
        Write-Host "  Next:" -ForegroundColor Cyan
        Write-Host "    1. Open hotwire.bat in Notepad and set your server's name and description."
        Write-Host "       The top of the file explains every option."
        Write-Host "    2. Start the server: double-click hotwire.bat."
        Write-Host ""
        Write-Note "The first start takes several minutes while the map generates."
    } elseif ($s.HasRust) {
        Write-Host "  Start the server with your own start script. hotwire.bat is here any time: run install again."
    }
    Write-Note "Run install again any time; the pre-flight decides what is left to do."
}

# ------------------------------------------------------------ 3. steamcmd --
function Install-SteamCmd([string]$d) {
    Write-Step "SteamCMD"
    $exe = Join-Path $SteamCmd 'steamcmd.exe'

    if (Test-Path -LiteralPath $exe) {
        Write-Ok "SteamCMD is already at $exe -- reusing it"
        # A SteamCMD that was unpacked but never run updates itself the first time it is asked to do
        # anything, and on a real Windows machine that run exited (code 7) before downloading Rust. So
        # it gets its self-update run here, on its own, whether or not it has had one before. Already
        # current, this takes a few seconds. Its exit code is not judged: the download step is.
        Write-Note "letting SteamCMD update itself first..."
        Write-Host ""
        & $exe +quit | Out-Host
        Write-Host ""
        Save-Record $d 'steamcmd'
        return $exe
    }

    Write-Why @(
        "SteamCMD is Valve's command-line Steam client. It is how Rust server files are downloaded",
        "and, later, updated. It needs no Steam account for Rust.",
        "",
        "This downloads steamcmd.zip from Valve, unpacks it into $SteamCmd, and runs it once so it",
        "can finish installing itself. That first run prints a lot and takes a minute or two.",
        "",
        "More: $($Docs['SteamCMD (Valve)'])"
    )
    if (-not (Confirm-Step "Install SteamCMD into $SteamCmd?" -DefaultYes)) {
        Write-Note "The Rust server is downloaded through SteamCMD, so install stops here."
        Write-Summary; exit 0
    }

    $zip = Join-Path $env:TEMP 'hotwire-steamcmd.zip'
    [void](Invoke-Download $SteamCmdZipUrl $zip 'SteamCMD')
    try {
        New-Item -ItemType Directory -Path $SteamCmd -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $SteamCmd -Force
    } catch {
        Stop-Politely "unpacking SteamCMD into $SteamCmd" "$($_.Exception.Message)" `
            "if that is a permissions error, right-click hotwire-setup.bat and choose 'Run as administrator', or pass -SteamCmd with a folder you own"
    } finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    $script:Changed.Add("installed SteamCMD into $SteamCmd")

    if (-not (Test-Path -LiteralPath $exe)) {
        Stop-Politely "installing SteamCMD" "no steamcmd.exe in $SteamCmd after unpacking" `
            "Valve may have changed the download; get it by hand from $($Docs['SteamCMD (Valve)'])"
    }

    Write-Host ""
    Write-Note "running SteamCMD once so it can update itself..."
    Write-Host ""
    # Out-Host, so SteamCMD's output is shown rather than returned from this function.
    & $exe +quit | Out-Host
    # Its exit code on this first run is not something this script relies on: whether SteamCMD
    # works is proven by the next step, which checks for the files it was asked to download.
    Write-Host ""
    Write-Ok "SteamCMD is ready"
    Save-Record $d 'steamcmd'
    return $exe
}

# ---------------------------------------------------------------- 4. rust --
function Get-InstalledBuild([string]$d) {
    $acf = Join-Path $d "steamapps\appmanifest_$AppId.acf"
    if (-not (Test-Path -LiteralPath $acf)) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($acf), '"buildid"\s+"(\d+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Install-Rust([string]$d, [string]$exe) {
    Write-Step "The Rust server"

    if (Test-Done $d 'rust') {
        Write-Ok "already downloaded (build $(Get-InstalledBuild $d))"
        Write-Note "Updating it later is the launcher's job, not this script's."
        return
    }

    Write-Why @(
        "This downloads the Rust dedicated server -- Steam app $AppId -- into $d.",
        "It is free, and 'anonymous' below is a real Steam login, not a placeholder.",
        "",
        "About 12 GB. SteamCMD prints its progress as it goes; long pauses are normal.",
        "If it is interrupted, run this script again: SteamCMD resumes rather than starting over.",
        "",
        "The command is:",
        "  steamcmd +force_install_dir `"$d`" +login anonymous +app_update $AppId +quit",
        "",
        "More: $($Docs['Creating a server (Rust)'])"
    )
    if (-not (Confirm-Step "Download the Rust server?" -DefaultYes)) {
        Write-Note "The Rust server is what this installs, so install stops here."
        Write-Summary; exit 0
    }
    Show-Countdown 3 'Downloading'

    while ($true) {
        Write-Host ""
        & $exe +force_install_dir $d +login anonymous +app_update $AppId +quit | Out-Host
        $code = $LASTEXITCODE
        Write-Host ""

        # The same test hotwire.bat uses (any non-zero exit is a failure), plus the files themselves.
        $build = Get-InstalledBuild $d
        if ($code -eq 0 -and (Test-Path -LiteralPath (Join-Path $d 'RustDedicated.exe')) -and $build) {
            Write-Ok "Rust server downloaded (build $build)"
            $script:Changed.Add("downloaded the Rust server into $d (build $build)")
            Save-Record $d 'rust'
            return
        }

        Write-Bad "SteamCMD did not finish the download (exit code $code)"
        if (-not (Test-Path -LiteralPath (Join-Path $d 'RustDedicated.exe'))) { Write-Note "RustDedicated.exe is not in $d yet." }
        Write-Note "The last lines SteamCMD printed above usually say why: disk space, network, or a Steam outage."
        Write-Note "Trying again resumes the download."
        Write-Host ""
        if (-not (Confirm-Step "Try the download again?")) { Write-Summary; exit 1 }
    }
}

# --------------------------------------------------------------- 5. oxide --
function Install-Oxide([string]$d) {
    Write-Step "Oxide"
    $dll = Join-Path $d 'RustDedicated_Data\Managed\Oxide.Rust.dll'

    if ((Test-Done $d 'oxide') -and (Test-Path -LiteralPath $dll)) {
        Write-Ok ("Oxide is installed (" + (Get-Item -LiteralPath $dll).VersionInfo.FileVersion + ")")
        return
    }

    Write-Why @(
        "Oxide (uMod) is what lets a Rust server run plugins. Hotwire's own plugin needs it.",
        "",
        "This downloads the Windows build of Oxide and unpacks it over the server, replacing some of",
        "the game's own files in RustDedicated_Data\Managed. That is how Oxide works.",
        "",
        "One thing worth knowing now: every time SteamCMD updates the server, it puts the game's",
        "original files back and Oxide stops loading until it is installed again. hotwire.bat does",
        "that for you after every update. A hand-written start script has to do it too.",
        "",
        "More: $($Docs['Oxide (uMod)'])"
    )
    if (-not (Confirm-Step "Install Oxide?" -DefaultYes)) {
        Write-Warn "Skipped: this is a vanilla server, and it cannot run plugins."
        Write-Note "The start script is set up to match, so it will not install Oxide either."
        Write-Note "Run install again any time to add Oxide."
        return
    }

    $zip = Join-Path $env:TEMP 'hotwire-oxide.zip'
    $response = Invoke-Download $OxideZipUrl $zip 'Oxide for Rust'
    try {
        # Windows PowerShell 5.1 exposes the final URL as ResponseUri; PowerShell 7 as RequestMessage.
        $finalUrl = [string]$response.BaseResponse.ResponseUri
        if (-not $finalUrl -and $response.BaseResponse.RequestMessage) { $finalUrl = [string]$response.BaseResponse.RequestMessage.RequestUri }
        if ($finalUrl -match '-linux\.zip') {
            Stop-Politely "downloading Oxide for Windows" "the download came from $finalUrl, which is the Linux build" `
                "download the Windows build by hand from $($Docs['Oxide source and releases']) (Oxide.Rust.zip)"
        }

        # Check the archive is what it claims before it is unpacked over a server: a saved error page
        # force-extracted over RustDedicated_Data is the one way this step could do harm.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
            $ok = @($archive.Entries | Where-Object { $_.FullName -eq 'RustDedicated_Data/Managed/Oxide.Rust.dll' }).Count -gt 0
            $archive.Dispose()
        } catch { $ok = $false }
        if (-not $ok) {
            Stop-Politely "checking the Oxide download" "it is not a zip containing RustDedicated_Data/Managed/Oxide.Rust.dll" `
                "nothing was unpacked; try again later, or download it by hand from $($Docs['Oxide source and releases'])"
        }

        Expand-Archive -LiteralPath $zip -DestinationPath $d -Force
    } finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }

    if (-not (Test-Path -LiteralPath $dll)) {
        Stop-Politely "installing Oxide" "no Oxide.Rust.dll in RustDedicated_Data\Managed after unpacking" `
            "run the script again; if it happens twice, install Oxide by hand from $($Docs['Oxide (uMod)'])"
    }
    $version = (Get-Item -LiteralPath $dll).VersionInfo.FileVersion
    Write-Ok "Oxide $version installed"
    Write-Note "Its oxide\ folder appears the first time the server starts. That is normal."
    $script:Changed.Add("installed Oxide $version into $d")
    $launcherFile = Join-Path $d 'hotwire.bat'
    if ((Test-Path -LiteralPath $launcherFile) -and (Select-String -LiteralPath $launcherFile -SimpleMatch 'set "INSTALL_FRAMEWORK=0"' -Quiet)) {
        Write-Warn "hotwire.bat is set up for a vanilla server, so it will not keep Oxide updated"
        Write-Note "In hotwire.bat, change set `"INSTALL_FRAMEWORK=0`" to 1."
    }
    Save-Record $d 'oxide'
}

# ------------------------------------------------------------ 6. launcher --
# Sets the lines hotwire.bat needs for this install -- ROOT, STEAMCMD and, for a vanilla server,
# INSTALL_FRAMEWORK -- and returns the file with CRLF line endings. Returns $null when the text is not
# the launcher this script knows: a changed default, an older launcher, or an error page.
function Set-LauncherPaths([string]$Text, [string]$RootDir, [string]$SteamCmdExe, [bool]$Vanilla = $false) {
    $rootLine = 'set "ROOT=C:\rustserver"'
    $steamLine = 'set "STEAMCMD=C:\steamcmd\steamcmd.exe"'
    $frameworkLine = 'set "INSTALL_FRAMEWORK=1"'
    $lines = ($Text -replace "`r`n", "`n") -split "`n"
    if (@($lines | Where-Object { $_ -eq $rootLine }).Count -ne 1) { return $null }
    if (@($lines | Where-Object { $_ -eq $steamLine }).Count -ne 1) { return $null }
    if ($Vanilla -and @($lines | Where-Object { $_ -eq $frameworkLine }).Count -ne 1) { return $null }
    $lines = $lines | ForEach-Object {
        if ($_ -eq $rootLine) { "set `"ROOT=$RootDir`"" }
        elseif ($_ -eq $steamLine) { "set `"STEAMCMD=$SteamCmdExe`"" }
        elseif ($Vanilla -and $_ -eq $frameworkLine) { 'set "INSTALL_FRAMEWORK=0"' }
        else { $_ }
    }
    return ($lines -join "`r`n")
}

function Install-Launcher([string]$d) {
    Write-Step "Start script"
    $launcher = Join-Path $d 'hotwire.bat'
    # No Oxide means a vanilla server, and the launcher has to be told, or it installs Oxide on its
    # first update.
    $vanilla = -not (Test-Path -LiteralPath (Join-Path $d 'RustDedicated_Data\Managed\Oxide.Rust.dll'))

    if (Test-Path -LiteralPath $launcher) {
        Write-Ok "hotwire.bat is already here -- left as it is"
        if ($vanilla -and (Select-String -LiteralPath $launcher -SimpleMatch 'set "INSTALL_FRAMEWORK=0"' -Quiet) -eq $false) {
            Write-Warn "this is a vanilla server, and hotwire.bat may install Oxide when it updates"
            Write-Note "To keep it vanilla, set `"INSTALL_FRAMEWORK=0`" in hotwire.bat."
        }
        Save-Record $d 'launcher'
        return
    }

    $steamCmdExe = Join-Path $SteamCmd 'steamcmd.exe'
    $why = @(
        "hotwire.bat is Hotwire's start script: it starts the server, brings it back when it stops,",
        "and installs Rust updates. Every schedule in it ships switched off, so it cannot restart",
        "anything by surprise.",
        "",
        "This downloads it from the public repository and sets it up for this install:",
        "  ROOT              = $d",
        "  STEAMCMD          = $steamCmdExe"
    )
    if ($vanilla) { $why += "  INSTALL_FRAMEWORK = 0     no Oxide here, so it runs a vanilla server" }
    $why += @("", "Say no to start the server with a script of your own instead.", "", "More: $($Docs['Hotwire (source)'])")
    Write-Why $why

    if (-not (Confirm-Step "Install hotwire.bat as the start script?" -DefaultYes)) {
        Write-Note "Skipped: you will start the server your own way. The RCON password step is skipped"
        Write-Note "too, because your start script is what sets it."
        return
    }

    # hotwire.bat runs with delayed expansion on. A ! or % in ROOT is eaten before the path is used,
    # and a quote, caret or ampersand breaks the lines that use it.
    if ($d -match '[!%"^&]') {
        Stop-Politely "setting ROOT in hotwire.bat to $d" "the path contains one of ! % `" ^ &, which a .bat cannot use safely" `
            "install into a folder without those characters, for example C:\rustserver"
    }

    $tmp = Join-Path $env:TEMP 'hotwire-launcher.bat'
    [void](Invoke-Download $LauncherUrl $tmp 'the Hotwire launcher')
    try { $text = [IO.File]::ReadAllText($tmp) }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

    $edited = Set-LauncherPaths $text $d $steamCmdExe $vanilla
    if ($null -eq $edited) {
        Stop-Politely "setting up the downloaded hotwire.bat" "it does not contain the lines this script changes" `
            "nothing was written; download launcher\hotwire.bat by hand from $($Docs['Hotwire (source)']) and set ROOT and STEAMCMD near the top"
    }
    [IO.File]::WriteAllText($launcher, $edited, [System.Text.UTF8Encoding]::new($false))
    if ($vanilla) {
        Write-Ok "hotwire.bat written for a vanilla server, with ROOT and STEAMCMD set for this install"
        $script:Changed.Add("created $launcher (ROOT, STEAMCMD, INSTALL_FRAMEWORK=0)")
    } else {
        Write-Ok "hotwire.bat written, with ROOT and STEAMCMD set for this install"
        $script:Changed.Add("created $launcher (ROOT and STEAMCMD set)")
    }
    Save-Record $d 'launcher'
}

# ----------------------------------------------------------- 7. the plugin --
# Asked, defaulting to yes. No carries on with the install; it is skipped when Oxide was declined.
function Install-Plugin([string]$d) {
    Write-Step "Hotwire plugin"
    $pluginDir = Join-Path $d 'oxide\plugins'
    $plugin = Join-Path $pluginDir 'Hotwire.cs'

    if (Test-Path -LiteralPath $plugin) {
        Write-Ok "oxide\plugins\Hotwire.cs is already here -- left as it is"
        Save-Record $d 'plugin'
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $d 'RustDedicated_Data\Managed\Oxide.Rust.dll'))) {
        Write-Note "Skipped: the plugin runs on Oxide, which is not installed."
        return
    }

    Write-Why @(
        "The Hotwire plugin adds scheduled, announced restarts: it counts down in game, kicks with a",
        "reason, saves, and hands over to hotwire.bat. Every schedule ships switched off."
    )
    if (-not (Test-Path -LiteralPath (Join-Path $d 'hotwire.bat'))) {
        Write-Warn "there is no hotwire.bat: a scheduled restart quits the server, and your own start"
        Write-Note "script has to start it again."
    }
    if (-not (Confirm-Step "Install the Hotwire plugin?" -DefaultYes)) {
        Write-Note "Skipped. Run install again any time to add it."
        return
    }

    $tmp = Join-Path $env:TEMP 'hotwire-plugin.cs'
    [void](Invoke-Download $PluginUrl $tmp 'the Hotwire plugin')
    $source = [IO.File]::ReadAllText($tmp)
    $info = [regex]::Match($source, '\[Info\("Hotwire",\s*"[^"]*",\s*"([^"]+)"\)\]')
    if (-not $info.Success) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Stop-Politely "checking the downloaded Hotwire.cs" "it is not the Hotwire plugin" `
            "nothing was written; download src\Hotwire.cs by hand from $($Docs['Hotwire (source)'])"
    }
    New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null
    Move-Item -LiteralPath $tmp -Destination $plugin -Force
    Write-Ok "Hotwire plugin $($info.Groups[1].Value) written to oxide\plugins"
    Write-Note "Oxide compiles it the first time the server starts."
    $script:Changed.Add("created $plugin (Hotwire $($info.Groups[1].Value))")
    Save-Record $d 'plugin'
}

# ---------------------------------------------------------------- 8. rcon --
# Letters and digits only, without look-alikes (0/O, 1/l/I), so it survives being read off a screen;
# 32 of 56 symbols is about 185 bits. Rejection sampling keeps every symbol equally likely. The
# launcher refuses a password with a quote in it, and none of these can be one.
function New-RconPassword {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $limit = 256 - (256 % $alphabet.Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $byte = [byte[]]::new(1)
    $sb = New-Object System.Text.StringBuilder
    try {
        while ($sb.Length -lt 32) {
            $rng.GetBytes($byte)
            if ($byte[0] -lt $limit) { [void]$sb.Append($alphabet[$byte[0] % $alphabet.Length]) }
        }
    } finally { $rng.Dispose() }
    return $sb.ToString()
}

# The launcher's own refusals, in its words (hotwire.bat section 2), plus two a .bat file imposes: for /f
# skips a line starting with a semicolon, and a batch file treats % as the start of a variable.
function Test-RconPassword([string]$Password) {
    if (-not $Password) { return 'it is empty' }
    if ($Password.Length -lt 8) { return 'it is under 8 characters' }
    if ($Password -eq 'change_me') { return 'it is still the example value, change_me' }
    if ($Password.Contains('"')) { return 'it contains a double quote' }
    if ($Password.StartsWith(';')) { return 'it starts with a semicolon' }
    if ($Password.Contains('%')) { return 'it contains %, which a .bat file does not keep as written' }
    return $null
}

# What is wrong with the RCON password in secrets.bat, or $null when hotwire.bat will accept it. Reads
# the last set "RCON_PASSWORD=..." line, the form the launcher and install both write.
function Get-SecretsProblem([string]$d) {
    $f = Join-Path $d 'secrets.bat'
    if (-not (Test-Path -LiteralPath $f)) { return 'there is no secrets.bat' }
    try { $text = [IO.File]::ReadAllText($f) } catch { return 'secrets.bat could not be read by this account' }
    $found = [regex]::Matches($text, '(?im)^[ \t]*set[ \t]+"RCON_PASSWORD=(.*)"[ \t]*\r?$')
    if ($found.Count -eq 0) { return 'secrets.bat has no line reading set "RCON_PASSWORD=..."' }
    return (Test-RconPassword $found[$found.Count - 1].Groups[1].Value)
}

function Read-SecretText([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Install-RconPassword([string]$d) {
    Write-Step "RCON password"
    $secrets = Join-Path $d 'secrets.bat'

    if (-not (Test-Path -LiteralPath (Join-Path $d 'hotwire.bat'))) {
        Write-Note "Skipped: there is no hotwire.bat, so your own start script sets the RCON password."
        return
    }

    if (Test-Path -LiteralPath $secrets) {
        $problem = Get-SecretsProblem $d
        if (-not $problem) {
            Write-Ok "secrets.bat is already here, and hotwire.bat will accept its password -- left as it is"
            Save-Record $d 'rcon'
            return
        }
        Write-Bad "secrets.bat is here, but $problem -- hotwire.bat will not start the server"
        if (-not (Confirm-Step "Set a new RCON password in its place?")) {
            Write-Note "Left as it is. Fix $secrets before starting the server."
            return
        }
    }

    Write-Why @(
        "RCON is remote control of your server: anyone with this password can run commands on it,",
        "so treat it like this machine's administrator password.",
        "",
        "hotwire.bat reads it from secrets.bat, beside it, and will not start the server if it is",
        "under 8 characters, is 'change_me', or contains a double quote.",
        "",
        "Press Enter and a strong one is made for you: 32 random letters and digits, shown once and",
        "copied to your clipboard. Or type your own -- it is not shown as you type, and you type it",
        "twice."
    )

    $generated = $false
    while ($true) {
        $first = Read-SecretText "  RCON password (Enter to generate one)"
        if (-not $first) { $password = New-RconPassword; $generated = $true; break }
        $problem = Test-RconPassword $first
        if ($problem) { Write-Bad "that will not work: $problem. Try another, or press Enter to generate one."; continue }
        $second = Read-SecretText "  Type it again"
        if ($second -cne $first) { Write-Bad "the two did not match. Try again."; continue }
        $password = $first
        break
    }

    $body = "@echo off`r`n" +
        "REM The RCON password for this server. RCON is remote control of the machine: treat this`r`n" +
        "REM like a root password. Never share this file, and never commit it anywhere.`r`n" +
        "set `"RCON_PASSWORD=$password`"`r`n"
    [IO.File]::WriteAllText($secrets, $body, [System.Text.UTF8Encoding]::new($false))
    $script:Changed.Add("wrote $secrets (the RCON password)")
    try { Set-SecretAcl $secrets; Write-Ok "secrets.bat written, readable only by Administrators and you" }
    catch { Write-Warn "secrets.bat written, but who can read it could not be restricted: $($_.Exception.Message)" }
    Write-Note "If the server will run under a different Windows account, give that account read access."

    if ($generated) {
        $copied = $false
        try { Set-Clipboard -Value $password; $copied = $true } catch { }
        Write-Host ""
        Write-Host "  Your RCON password:"
        Write-Host ""
        Write-Host "      $password" -ForegroundColor Yellow
        Write-Host ""
        if ($copied) { Write-Note "It is on your clipboard too." }
        else { Write-Warn "could not copy it to the clipboard -- copy it from above" }
        Write-Note "It stays in this window's scrollback until the window is closed."
        Write-Host ""
        [void](Read-Host "  Save it somewhere safe, then press Enter")
    } else {
        Write-Note "Your password was not shown and is not on the clipboard."
    }
    Save-Record $d 'rcon'
}

# ------------------------------------------------------------ 9. firewall --
# A LocalPort value is 'Any', a number, a range 'a-b', or a list of those.
function Test-PortCovered($LocalPort, [int]$Port) {
    foreach ($p in @($LocalPort)) {
        $s = [string]$p
        if ($s -match '^(\d+)-(\d+)$') { if ($Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { return $true } }
        elseif ($s -match '^\d+$') { if ([int]$s -eq $Port) { return $true } }
    }
    return $false
}

# Rules that name the port explicitly. 'Any port' rules belong to other programs and are not ours to
# judge. Read from the active store, so rules pushed by Group Policy are seen too.
function Get-InboundPortRules([string]$Protocol, [int]$Port) {
    $filters = @(Get-NetFirewallPortFilter -PolicyStore ActiveStore | Where-Object {
        $_.Protocol -eq $Protocol -and (Test-PortCovered $_.LocalPort $Port)
    })
    if ($filters.Count -eq 0) { return @() }
    return @($filters | Get-NetFirewallRule | Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' })
}

function Get-RemoteText($Rule) {
    $remote = @(($Rule | Get-NetFirewallAddressFilter).RemoteAddress) -join ', '
    if ($remote -eq 'Any') { return 'from anywhere' }
    return "from $remote"
}

function Open-Port([string]$Protocol, [int]$Port, [string]$Label) {
    try { Open-PortUnguarded $Protocol $Port $Label }
    catch {
        # The last step, and the server is already installed: a firewall error is reported, not fatal.
        Write-Bad "could not check or open $Protocol $Port ($Label): $($_.Exception.Message)"
        Write-Note "Open it by hand: wf.msc > Inbound Rules > New Rule > Port > $Protocol $Port."
    }
}

function Open-PortUnguarded([string]$Protocol, [int]$Port, [string]$Label) {
    $port = Get-PortState $Protocol $Port (Get-ActiveFirewallProfiles)

    foreach ($b in $port.Blocks) {
        Write-Bad "$Protocol $Port is BLOCKED by the rule '$($b.DisplayName)'"
        Write-Note "In Windows Firewall a block rule beats every allow rule, so no rule added here would help."
        Write-Note "Remove or disable it yourself if it is not deliberate (wf.msc > Inbound Rules)."
    }
    if ($port.Allows.Count -gt 0) {
        foreach ($a in $port.Allows) { Write-Ok "$Protocol $Port ($Label) is already open: '$($a.DisplayName)' $(Get-RemoteText $a)" }
        return
    }
    if ($port.Blocks.Count -gt 0) { return }
    foreach ($e in $port.Elsewhere) {
        Write-Note "'$($e.DisplayName)' allows $Protocol $Port, but only on $($e.Profile) networks, which this machine is not on."
    }

    New-NetFirewallRule -DisplayName "Rust $Label (Hotwire)" -Group 'Hotwire' -Direction Inbound `
        -Protocol $Protocol -LocalPort $Port -Action Allow | Out-Null
    Write-Ok "opened $Protocol $Port ($Label)"
    $script:Changed.Add("firewall: allowed inbound $Protocol $Port, rule 'Rust $Label (Hotwire)'")
}

function Set-Firewall([string]$d) {
    Write-Step "Firewall"
    Write-Why @(
        "A Rust server uses four ports. These numbers match hotwire.bat's defaults:",
        "",
        "  UDP $GamePort   game         players connect here            opened",
        "  UDP $QueryPort   query        the in-game server browser      opened -- without it the server is invisible",
        "  TCP $AppPort   Rust+        the phone companion app         only if you want it",
        "  TCP $RconPort   RCON         remote control of the server    NEVER opened here",
        "",
        "RCON is a remote console: anyone who reaches it and guesses the password runs commands on",
        "your server. Reach it from this machine or over a VPN.",
        "",
        "This is Windows Firewall only. A home router needs port forwarding, and a cloud provider has",
        "its own firewall; both are outside this machine. More: $($Docs['Creating a server (Rust)'])"
    )

    if (-not $script:IsAdmin) {
        Write-Warn "not Administrator, so no rules can be added"
        Write-Note "To open the ports: right-click hotwire-setup.bat, 'Run as administrator', and choose install."
        return
    }

    if (-not (Confirm-Step "Open UDP $GamePort and UDP $QueryPort in Windows Firewall?")) { Write-Note "No rules were added."; return }
    Open-Port 'UDP' $GamePort 'game'
    Open-Port 'UDP' $QueryPort 'query'

    Write-Host ""
    Write-Note "Rust+ lets players pair their phone with your server. More: $($Docs['Rust+ companion (Rust)'])"
    if (Confirm-Step "Also open TCP $AppPort for Rust+?") { Open-Port 'TCP' $AppPort 'Rust+' }

    Write-Note "Every rule this script adds is in the group 'Hotwire'. To remove them all:"
    Write-Note "  Remove-NetFirewallRule -Group Hotwire"
    Save-Record $d 'firewall'
}

# ----------------------------------------------------------------- signing --
# The frozen canonical form (docs/CONTRACT.md in the panel repo):
#     <METHOD> <path>`n<timestamp>`n<nonce>`n<sha256 of the raw body>
#
# Every byte matters. The body is hashed as the EXACT bytes that go on the wire -- UTF-8, no BOM,
# no trailing newline -- because a mismatch produces a 401 with no useful message on a machine
# nobody can reach inbound. `doctor` proves this implementation against the panel's published
# vector before anything else it checks.
function Get-Sha256Hex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

function Get-HmacHex([string]$Secret, [string]$Text) {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($utf8.GetBytes($Secret))
    try {
        return -join ($hmac.ComputeHash($utf8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })
    } finally { $hmac.Dispose() }
}

function Get-CanonicalString([string]$Method, [string]$Path, [string]$Timestamp, [string]$Nonce, [string]$Body) {
    return ($Method.ToUpperInvariant() + ' ' + $Path), $Timestamp, $Nonce, (Get-Sha256Hex $Body) -join "`n"
}

function Get-Signature([string]$Secret, [string]$Method, [string]$Path, [string]$Timestamp, [string]$Nonce, [string]$Body) {
    return Get-HmacHex $Secret (Get-CanonicalString $Method $Path $Timestamp $Nonce $Body)
}

function New-Nonce {
    $bytes = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

# The published conformance vector, copied from the panel's
# tests/Fixtures/contract/signature/conformance.json. If this machine cannot reproduce the signature
# below, its canonicalisation is wrong -- not the panel's. Signing is the one thing that fails
# invisibly: a canonicalisation one byte out is a 401 with no useful message, on a machine nobody
# can reach inbound. So it is checked here rather than left to be discovered.
function Test-Signing {
    $secret = 'hotwire-conformance-secret-do-not-use-in-production'
    $body = '{"contract":1,"report_id":"0193f2c1-8a4e-7c1a-9f3b-2d5e6a7b8c9d","sent_at":"2026-09-09T18:42:11Z","source":"plugin","source_version":"1.1.2","kind":"heartbeat","payload":{"players":34,"max_players":50}}'
    $expectedBodyHash = '980c7522d9ba59d5fe8e677984234ef8eb9f48e8811bf4880c735ba21c4edb67'
    $expectedSignature = '0018750ad887b85034deee8237784a18fc46f5bf3da6610ccab4794a696c5bb4'
    $ok = $true

    $bodyHash = Get-Sha256Hex $body
    if ($bodyHash -eq $expectedBodyHash) { Write-Ok "this machine hashes correctly" }
    else {
        Write-Bad "the body hash does not match the published vector"
        Write-Note "expected $expectedBodyHash"
        Write-Note "got      $bodyHash"
        Write-Note "This usually means the text was encoded with a BOM, or CRLF crept into it."
        $ok = $false
    }

    $signature = Get-Signature $secret 'POST' '/api/v1/report' '1757533331' '3f9a1c7e2b5d4086' $body
    if ($signature -eq $expectedSignature) { Write-Ok "this machine signs correctly" }
    else {
        Write-Bad "the signature does not match the published vector"
        Write-Note "expected $expectedSignature"
        Write-Note "got      $signature"
        Write-Note "Do not connect this machine yet -- please report this."
        $ok = $false
    }
    return $ok
}

# --------------------------------------------------------------- discovery --
function Find-Root {
    if ($Root) {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
            Stop-Politely "using the directory you gave with -Root" "'$Root' is not a directory" "check the path and try again"
        }
        return (Resolve-Path -LiteralPath $Root).Path
    }
    $dir = (Get-Location).Path
    for ($i = 0; $i -lt 5 -and $dir; $i++) {
        if ((Test-Path (Join-Path $dir 'RustDedicated.exe')) -or (Test-Path (Join-Path $dir 'RustDedicated'))) { return $dir }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    Stop-Politely "finding your Rust server directory" `
        "no RustDedicated.exe in $((Get-Location).Path) or its parents" `
        "run this from the server directory, or pass -Root C:\rustserver"
}

function Get-StateFile ($r)  { Join-Path $r 'hotwire\connect.json' }
function Get-KeysFile ($r)   { Join-Path $r 'hotwire\keys.json' }
function Get-PluginFile ($r) { Join-Path $r 'oxide\data\Hotwire\panel.json' }

function Read-State ($r) {
    $f = Get-StateFile $r
    if (Test-Path -LiteralPath $f) { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) }
    return $null
}

function Get-PanelUrl ($r) {
    if ($Panel) { return $Panel.TrimEnd('/') }
    $state = Read-State $r
    if ($state -and $state.panel_url) { return ([string]$state.panel_url).TrimEnd('/') }
    return $DefaultPanel
}

# ------------------------------------------------------------------ checks --
function Test-Panel([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri "$Url/up" -UseBasicParsing -TimeoutSec 10
        if ($r.StatusCode -eq 200) { Write-Ok "panel is reachable at $Url"; return $true }
    } catch {
        Write-Bad "panel did not answer at $Url"
        Write-Note "($($_.Exception.Message))"
        Write-Note "fix: check the URL, DNS, and that outbound HTTPS is allowed from this machine"
        return $false
    }
    Write-Bad "panel answered unexpectedly at $Url"
    return $false
}

# The panel refuses a timestamp more than 300s from its own, and says only that the timestamp was
# outside the window. On a fresh VM with a drifting clock that is every request, forever, with no
# hint as to why -- so it is checked early and named.
function Test-Clock([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri "$Url/up" -UseBasicParsing -TimeoutSec 10
        $remote = [datetime]::Parse($r.Headers['Date']).ToUniversalTime()
    } catch { Write-Warn "could not read the panel's clock"; return $true }

    $skew = [math]::Abs(((Get-Date).ToUniversalTime() - $remote).TotalSeconds)
    if ($skew -le 30) { Write-Ok ("clock agrees with the panel ({0:N0}s apart)" -f $skew); return $true }
    if ($skew -le 300) { Write-Warn ("clock is {0:N0}s from the panel -- inside the window, but drifting" -f $skew); return $true }

    Write-Bad ("clock is {0:N0}s from the panel -- every signed request will be refused" -f $skew)
    Write-Note 'fix: run "w32tm /resync" as Administrator, then run doctor again'
    return $false
}

function Test-Install([string]$r) {
    $ok = $true
    if ((Test-Path (Join-Path $r 'RustDedicated.exe')) -or (Test-Path (Join-Path $r 'RustDedicated'))) {
        Write-Ok "Rust server found at $r"
    } else { Write-Bad "no RustDedicated.exe in $r"; $ok = $false }

    if (Test-Path (Join-Path $r 'oxide')) { Write-Ok "Oxide is installed" }
    elseif (Test-Path (Join-Path $r 'carbon')) { Write-Ok "Carbon is installed" }
    else { Write-Warn "no Oxide or Carbon -- the plugin half cannot report until a framework is installed" }

    if (Test-Path -LiteralPath (Get-StateFile $r)) {
        $state = Read-State $r
        Write-Ok "already connected as '$($state.identity)' -- 'status' shows the details"
    } else { Write-Note "not connected yet (that is what 'connect' is for)" }
    return $ok
}

# ------------------------------------------------------------------ doctor --
# Read-only. Touches nothing, changes nothing, safe at any time on any machine.
function Invoke-Doctor {
    $r = Find-Root
    $url = Get-PanelUrl $r
    $ok = $true

    Write-Host "hotwire-setup $Version -- checking this machine"
    Write-Note "Nothing is written by this command."

    Write-Head "Tools"
    if (-not (Test-Signing)) { $ok = $false }

    Write-Head "This server"
    if (-not (Test-Install $r)) { $ok = $false }

    Write-Head "The panel"
    if (-not (Test-Panel $url)) { $ok = $false }
    if (-not (Test-Clock $url)) { $ok = $false }

    Write-Host ""
    if ($ok) {
        Write-Host "Everything needed is in place." -ForegroundColor Green
        if (Test-Path -LiteralPath (Get-StateFile $r)) { Write-Note "This server is already connected. 'detach' disconnects it." }
        else { Write-Note "Next: .\hotwire-setup.bat connect" }
        return 0
    }
    Write-Host "Something above needs fixing first." -ForegroundColor Red
    Write-Note "Each [fail] line says what to do. Nothing was changed."
    return 1
}

# ----------------------------------------------------------------- connect --
function Backup-IfPresent([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $backup = "$Path.backup-" + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Path -Destination $backup
    Write-Note "kept the previous file as $backup"
}

function Write-JsonFile([string]$Path, $Object, [switch]$Secret) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Backup-IfPresent $Path
    # UTF-8 without a BOM, because a BOM is invisible and breaks every reader that is not expecting one.
    [System.IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    if ($Secret) { Set-SecretAcl $Path }
}

# Readable by this machine's administrators, SYSTEM and the account running this script; not by
# everyone with a login. Used for anything holding a key or a password.
function Set-SecretAcl([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($who in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM', [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)) {
        try {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $who, 'FullControl', 'Allow'))
        } catch { }
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-Connect {
    $r = Find-Root
    $url = Get-PanelUrl $r

    # Asked for rather than demanded on the command line. A code typed as an argument ends up in
    # PowerShell history and in the scrollback of whoever is watching; and making someone re-run a
    # command because they did not know a parameter existed is a poor welcome.
    if (-not $Code) {
        Write-Host ""
        Write-Host "To connect this server you need a code from the panel."
        Write-Host ""
        Write-Host "  1. Open $url and sign in"
        Write-Host "  2. Go to Servers, and press ""Connect a server"""
        Write-Host "  3. Copy the code it shows you -- it looks like HW-4K2P-9XQR"
        Write-Host ""
        Write-Note "It is good for one hour and one machine. Nothing is written until you confirm."
        Write-Host ""
        $Code = (Read-Host "  Paste the code here") -replace '\s', ''
        Write-Host ""
    }

    if (-not $Code) {
        Stop-Politely "connecting this server" "no code was given" `
            "run this again and paste the code from Servers -> Connect a server in the panel"
    }

    # MEASURE TWICE. Everything connect relies on, verified before a byte is written -- a
    # half-connected server is worse than an unconnected one.
    Write-Head "Checking before changing anything"
    if (-not (Test-Panel $url)) { Stop-Politely "reaching the panel at $url" "it did not answer" "see the [fail] line above" }
    if (-not (Test-Clock $url)) {
        Stop-Politely "connecting this server" "this machine's clock is too far from the panel's" `
            'run "w32tm /resync" as Administrator, wait a moment, then try again'
    }

    # The stable key for this install. Minted once and kept: re-running connect from the same
    # machine adopts its existing server rather than creating a second one, so a rename or a
    # repair never splits its history.
    $state = Read-State $r
    $installId = if ($state -and $state.install_id) { [string]$state.install_id } else { [guid]::NewGuid().ToString() }
    if ($state -and $state.install_id) { Write-Note "This install is already known to the panel -- reconnecting will adopt it." }
    else { Write-Note "This install has no id yet; a new one was generated." }

    if (-not $Name) { $Name = $env:COMPUTERNAME }

    Write-Head "About to do this"
    Write-Host "  Panel      : $url"
    Write-Host "  Name       : $Name"
    Write-Host "  Install id : $installId"
    Write-Host "  Write      : $(Get-StateFile $r)"
    Write-Host "               $(Get-KeysFile $r)   (secret)"
    Write-Host "               $(Get-PluginFile $r)   (secret)"
    Write-Host ""
    if (-not (Confirm-Step "Connect this server to the panel?" -DefaultYes)) { Write-Host "  Nothing was changed."; return 0 }

    $payload = @{
        token = $Code; install_id = $installId; identity = $Name; name = $Name
        components = @('plugin', 'script')
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Method Post -Uri "$url/api/v1/enroll" -TimeoutSec 30 `
            -ContentType 'application/json' -Headers @{ Accept = 'application/json' } -Body $payload
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        switch ($status) {
            422 { Stop-Politely "enrolling with the code you gave" "the panel refused it as invalid or expired" `
                    "codes are single-use and last 60 minutes -- create a fresh one in the panel" }
            429 { Stop-Politely "enrolling" "the panel is rate-limiting this address" "wait a minute and try again" }
            default { Stop-Politely "enrolling" "the panel answered: $($_.Exception.Message)" `
                    "run 'doctor' to check the connection, then try again" }
        }
    }

    $server = $response.data.server
    if ($response.data.panel_url) { $url = ([string]$response.data.panel_url).TrimEnd('/') }

    $plugin = $response.data.keys | Where-Object { $_.component -eq 'plugin' } | Select-Object -First 1
    $script = $response.data.keys | Where-Object { $_.component -eq 'script' } | Select-Object -First 1

    if (-not $script) {
        Stop-Politely "reading the panel's answer" "it carried no key for the launcher component" `
            "this is a bug -- please report it with the panel's response"
    }

    Write-JsonFile (Get-StateFile $r) ([ordered]@{
        install_id = $installId; server_id = $server.id; identity = $Name
        panel_url = $url; connected_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    })
    Write-JsonFile (Get-KeysFile $r) ([ordered]@{ key_id = $script.key_id; secret = $script.secret }) -Secret

    if ($plugin) {
        # The plugin's key goes in oxide\data, NOT oxide\config: the plugin rewrites its config
        # constantly and the documented way to reset it is to delete it, which would silently
        # disconnect the server.
        Write-JsonFile (Get-PluginFile $r) ([ordered]@{
            key_id = $plugin.key_id; secret = $plugin.secret; panel_url = $url
        }) -Secret
    }

    Write-Head "Connected"
    if ($server.adopted) {
        Write-Host "  Reconnected an install the panel already knew. Its history is intact, and its"
        Write-Host "  previous keys have been revoked."
    } else {
        Write-Host "  This server is now connected as '$Name'."
    }
    Write-Host ""
    Write-Host "  Changed:"
    Write-Host "    $(Get-StateFile $r)"
    Write-Host "    $(Get-KeysFile $r)"
    if ($plugin) { Write-Host "    $(Get-PluginFile $r)" }
    Write-Host ""
    Write-Note "Nothing else on this machine was touched. 'detach' undoes all of it."
    return 0
}

# ------------------------------------------------------------------ status --
function Invoke-Status {
    $r = Find-Root
    $state = Read-State $r
    if (-not $state) {
        Write-Host "Not connected."
        Write-Note "Run 'doctor' to check this machine, then 'connect'."
        return 0
    }
    Write-Host "Connected."
    Write-Host "  Name       : $($state.identity)"
    Write-Host "  Panel      : $($state.panel_url)"
    Write-Host "  Server id  : $($state.server_id)"
    Write-Host "  Install id : $($state.install_id)"
    Write-Host "  Since      : $($state.connected_at)"
    Write-Host ""
    Write-Note "'detach' disconnects and leaves this server running exactly as it is."
    return 0
}

# ------------------------------------------------------------------ detach --
# Reversible means reversible. Removes what connect wrote and nothing else; the server keeps
# running, and the launcher and plugin carry on without a panel.
function Invoke-Detach {
    $r = Find-Root
    if (-not (Test-Path -LiteralPath (Get-StateFile $r))) { Write-Host "Not connected -- nothing to detach."; return 0 }

    Write-Head "About to do this"
    Write-Host "  Remove : $(Get-StateFile $r)"
    Write-Host "           $(Get-KeysFile $r)"
    if (Test-Path -LiteralPath (Get-PluginFile $r)) { Write-Host "           $(Get-PluginFile $r)" }
    Write-Host ""
    Write-Note "Your server keeps running. Reporting stops. Nothing else changes."
    Write-Note "Revoke the keys in the panel too -- this machine cannot do that for you."
    Write-Host ""
    if (-not (Confirm-Step "Disconnect this server from the panel?")) { Write-Host "  Nothing was changed."; return 0 }

    foreach ($f in @((Get-StateFile $r), (Get-KeysFile $r), (Get-PluginFile $r))) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
    Write-Host ""
    Write-Host "Disconnected. This machine is as it was before it connected."
    return 0
}

# ----------------------------------------------------------- 10. the panel --
# Asked last, once the server is complete. Yes runs exactly what 'connect' runs; no changes nothing.
function Invoke-PanelOffer([string]$d) {
    Write-Step "Hotwire Panel"
    if (Test-Path -LiteralPath (Get-StateFile $d)) {
        Write-Ok "this server is already connected -- 'Show the connection' in the menu says where"
        return
    }
    Write-Why @(
        "Hotwire Panel is our web panel for managing Rust servers. Connecting needs an account and a",
        "code from the panel, writes three small files in this folder, and 'Disconnect' in the menu",
        "removes them."
    )
    if (-not (Confirm-Step "Connect this server to Hotwire Panel?" -DefaultYes)) {
        Write-Note "Not connected. Connect any time from the menu."
        return
    }
    $script:Root = $d
    $null = Invoke-Connect
}

# -------------------------------------------------------------- install --
function Invoke-Install {
    $script:SteamCmd = Resolve-FullPath $SteamCmd
    Show-Banner
    if ($Yes) { Write-Note "(-Yes does not apply to install: every step asks.)" }
    Write-Why @(
        "This installs a Rust dedicated server on this machine.",
        "",
        "First a pre-flight: it checks this machine, the folder, Rust, Oxide, Hotwire, the RCON",
        "password, the firewall and the panel, and changes nothing while it looks. Then it lists what",
        "is missing and installs only that, asking before each part. Enter takes the answer in capitals.",
        "",
        "Worth keeping open while you go:"
    )
    foreach ($k in $Docs.Keys) { Write-Host ("    {0,-27} {1}" -f $k, $Docs[$k]) -ForegroundColor DarkGray }

    Test-Requirements
    $serverDir = Select-Directory

    Write-Host ""
    Write-Note "Running pre-flight checks..."
    $state = Get-InstallState $serverDir
    Show-InstallState $state 'Pre-flight'

    $plan = @(Get-InstallPlan $state)
    Show-InstallPlan $plan $state
    if ($plan.Count -eq 0) {
        Show-Finish $serverDir $state
        return
    }
    Write-Host ""
    if (-not (Confirm-Step "Go ahead?" -DefaultYes)) { Write-Summary; exit 0 }

    if (-not (Test-Path -LiteralPath $serverDir)) {
        New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
        $script:Changed.Add("created $serverDir")
    }
    Save-Record $serverDir $null

    Show-Countdown 5 'Starting'
    $script:StepTotal = $plan.Count
    $script:StepNo = 0
    foreach ($step in $plan) {
        switch ($step.Key) {
            'clock'    { Test-InstallClock }
            'steamcmd' { $null = Install-SteamCmd $serverDir }
            'rust'     { Install-Rust $serverDir (Join-Path $SteamCmd 'steamcmd.exe') }
            'oxide'    { Install-Oxide $serverDir }
            'launcher' { Install-Launcher $serverDir }
            'plugin'   { Install-Plugin $serverDir }
            'rcon'     { Install-RconPassword $serverDir }
            'firewall' { Set-Firewall $serverDir }
            'panel'    { Invoke-PanelOffer $serverDir }
        }
    }

    Write-Host ""
    Write-Note "Running post-flight checks..."
    $after = Get-InstallState $serverDir
    Show-InstallState $after 'Post-flight'
    Show-Finish $serverDir $after
}

# ----------------------------------------------------------------- menu --
# What a double-click gets. Five checks first -- is Rust here, is the clock right, is Hotwire here,
# is its RCON password valid, is it connected -- then a suggestion. All four only read; nothing starts until a number is chosen.
function Write-No ($m) { Write-Host "  [ no ] $m" -ForegroundColor Gray }

function Invoke-Menu {
    $here = (Get-Location).Path

    Show-Banner
    Write-Host "  Folder: $here"
    Write-Note "Looking around first. Nothing is changed by these checks."
    Write-Host ""

    # 1. Rust
    $hasServer = Test-Path -LiteralPath (Join-Path $here 'RustDedicated.exe')
    if ($hasServer) {
        $build = Get-InstalledBuild $here
        if ($build) { Write-Ok "Rust server is installed here (build $build)" }
        else { Write-Ok "Rust server is installed here" }
    } else { Write-No "no Rust server in this folder" }

    # 2. The clock. Measured against Valve's download server, not the panel, so looking at this menu
    # never contacts Hotwire Panel. A correct clock is correct against both.
    $skew = Get-ClockSkew
    if ($null -eq $skew) { Write-Warn "could not check the clock (no internet connection?)" }
    else {
        $abs = [math]::Abs($skew)
        $direction = if ($skew -gt 0) { 'ahead' } else { 'behind' }
        if ($abs -le 30) { Write-Ok ("clock is right ({0:N0}s from Steam's servers)" -f $abs) }
        else {
            if ($abs -le 300) { Write-Warn ("clock is {0:N0}s {1} -- drifting" -f $abs, $direction) }
            else { Write-Bad ("clock is {0:N0}s {1} -- Hotwire Panel would refuse every request" -f $abs, $direction) }
            Write-Note "fix: run this as Administrator and choose 1 (install checks and offers to sync it),"
            Write-Note "     or Settings > Time > 'Sync now'"
        }
    }

    # 3. Hotwire: the launcher beside the server, the plugin where the framework loads it
    $launcher = Test-Path -LiteralPath (Join-Path $here 'hotwire.bat')
    $plugin = $null
    foreach ($dir in @('oxide\plugins', 'carbon\plugins')) {
        $candidate = Join-Path (Join-Path $here $dir) 'Hotwire.cs'
        if (Test-Path -LiteralPath $candidate) { $plugin = "$dir\Hotwire.cs"; break }
    }
    if ($launcher) { Write-Ok "Hotwire launcher: hotwire.bat" } else { Write-No "Hotwire launcher: no hotwire.bat in this folder" }
    if ($plugin) { Write-Ok "Hotwire plugin: $plugin" } else { Write-No "Hotwire plugin: no Hotwire.cs in oxide\plugins" }

    # The RCON password, by the rules hotwire.bat applies before it starts the server. A server started
    # some other way keeps its password somewhere this cannot see.
    $rconProblem = $null
    if ($hasServer -and $launcher) {
        $rconProblem = Get-SecretsProblem $here
        if ($rconProblem) { Write-Bad "RCON password: $rconProblem -- hotwire.bat will not start the server" }
        else { Write-Ok "RCON password is set, and hotwire.bat will accept it" }
    } elseif ($hasServer) { Write-No "RCON password: not checked -- without hotwire.bat, your own start script sets it" }

    # 4. Connected
    $connected = Test-Path -LiteralPath (Get-StateFile $here)
    if ($connected) {
        $state = $null
        try { $state = Read-State $here } catch { }
        if ($state) { Write-Ok "connected to $($state.panel_url) as '$($state.identity)'" }
        else { Write-Warn "connected, but hotwire\connect.json could not be read" }
    } else { Write-No "not connected to Hotwire Panel" }

    Write-Host ""
    Write-Host "  1  Install a Rust server in this folder"
    Write-Host "  2  Check this machine is ready to connect      (changes nothing)"
    Write-Host "  3  Connect this server to Hotwire Panel"
    Write-Host "  4  Show the connection"
    Write-Host "  5  Disconnect"
    Write-Host ""
    if (-not $hasServer) { Write-Note "Suggested: 1." }
    elseif (-not $launcher) {
        # Install carries on only in a folder it started; a server set up another way gets the guide.
        if (Test-Path -LiteralPath (Get-RecordFile $here)) { Write-Note "Suggested: 1 -- it carries on from where it stopped and puts the start script in place." }
        else {
            Write-Note "Suggested: put Hotwire in place -- step 6 of the guide:"
            Write-Note "  $($Docs['This guide, step by step'])"
        }
    }
    elseif ($rconProblem) {
        if (Test-Path -LiteralPath (Get-RecordFile $here)) { Write-Note "Suggested: 1 -- install walks you through setting the RCON password." }
        else { Write-Note "Suggested: secrets.bat, beside hotwire.bat, needs a line reading: set `"RCON_PASSWORD=your password`"" }
    }
    elseif (-not $connected) { Write-Note "Suggested: 3, connect to Hotwire Panel." }
    else { Write-Note "Suggested: 4." }
    Write-Note "Enter on its own leaves without doing anything."

    $choice = ([string](Read-Host "  Choose")).Trim()
    switch ($choice) {
        '1' { return 'install' }
        '2' { return 'doctor' }
        '3' { return 'connect' }
        '4' { return 'status' }
        '5' { return 'detach' }
        default { return $null }
    }
}

function Show-Help {
@'
hotwire-setup -- install a Rust server, and connect it to Hotwire Panel if you want to

  (none)    A menu. It looks at this folder and suggests what to do next.
  install   Pre-flight checks everything, then installs only what is missing. Asks before every step.
  doctor    Check this machine is ready to connect: signing, your server, the panel, the clock.
            Read-only, changes nothing, safe any time.
  connect   Connect to the panel. Asks for the code; no need to type it here.
  status    Show what this server is connected to.
  detach    Disconnect. Leaves the server running exactly as it is.

Options
  -Root DIR       The Rust server folder (default: this one)
  -SteamCmd DIR   Where install puts SteamCMD (default: C:\steamcmd)
  -Panel URL      The panel to talk to (default: recorded at connect)
  -Yes            Do not ask -- connect and detach only; install always asks

Nothing here is required to run a Rust server. Connecting is optional and reversible.
'@ | Write-Host
}

if (-not $Command) {
    $Command = Invoke-Menu
    if (-not $Command) { Write-Note "Nothing was changed."; exit 0 }
}

switch ($Command.ToLowerInvariant()) {
    # Install's steps print as they go; anything they return is not an exit code.
    'install' { $null = Invoke-Install; exit 0 }
    'doctor'  { exit (Invoke-Doctor) }
    'connect' { $script:YesAllowed = $true; exit (Invoke-Connect) }
    'status'  { exit (Invoke-Status) }
    'detach'  { $script:YesAllowed = $true; exit (Invoke-Detach) }
    'help'    { Show-Help; exit 0 }
    default   { Show-Help; exit 1 }
}
