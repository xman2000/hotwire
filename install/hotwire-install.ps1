<#
    hotwire-install -- put a Rust dedicated server with Oxide on a Windows machine, one confirmed
    step at a time.

    https://github.com/xman2000/hotwire            MIT (c) 2026 xman2000

    What it does, in order, asking before each one:

        1. Checks this machine: Windows, PowerShell, Administrator, disk, memory, and the clock.
        2. Asks where the server goes (this folder, unless you say otherwise).
        3. Installs SteamCMD, Valve's downloader.
        4. Downloads the Rust dedicated server (Steam app 258550) through it.
        5. Installs Oxide (uMod), so the server can run plugins.
        6. Checks the Windows Firewall and opens the game and server-browser ports.

    What it never does: start the server, open the RCON port, choose passwords, touch an existing
    Rust server it did not install, or talk to Hotwire Panel. A server installed by this script is
    complete without an account anywhere.

    Stopped halfway? Run it again in the same folder. It keeps a record of what it finished in
    hotwire-install.json and carries on from there.

    Requires Windows PowerShell 5.1, which ships with Windows 10 and Windows Server 2016 and later.

    How to run it: put this file and hotwire-install.bat in the folder you want the server in, and
    double-click hotwire-install.bat -- or right-click it and choose "Run as administrator" so the
    firewall and clock steps can act. The .bat exists because Windows will not run a .ps1 by default.

    Options, passed to either file:
        -Dir C:\rustserver     where the server goes (otherwise it asks, offering the current folder)
        -SteamCmd C:\steamcmd  where SteamCMD goes
#>

[CmdletBinding()]
param(
    [string]$Dir,
    [string]$SteamCmd = 'C:\steamcmd'
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
$SteamCmd = Resolve-FullPath $SteamCmd
$AppId = '258550'

# Every URL below was checked on 2026-09-13. umod.org/games/rust/download answers 301 to
# github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust.zip -- the Windows bundle.
# The Linux bundle is a different file with the same entry names, so the redirect target is checked.
$SteamCmdZipUrl = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'
$OxideZipUrl = 'https://umod.org/games/rust/download'

$Docs = [ordered]@{
    'This guide, step by step'  = 'https://github.com/xman2000/hotwire/blob/connect-and-report/docs/INSTALL-WINDOWS.md'
    'SteamCMD (Valve)'          = 'https://developer.valvesoftware.com/wiki/SteamCMD'
    'Creating a server (Rust)'  = 'https://wiki.facepunch.com/rust/Creating-a-server'
    'Rust+ companion (Rust)'    = 'https://wiki.facepunch.com/rust/rust-companion-server'
    'Oxide (uMod)'              = 'https://umod.org/games/rust'
    'Oxide source and releases' = 'https://github.com/OxideMod/Oxide.Rust'
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

# Silence is never consent: Enter on its own is a no.
function Confirm-Step([string]$Question) {
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
function Get-RecordFile([string]$d) { Join-Path $d 'hotwire-install.json' }

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
        installer = "hotwire-install $Version"
        started_at = $started
        updated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        steamcmd = $SteamCmd
        done = $done
    }
    $f = Get-RecordFile $d
    $isNew = -not (Test-Path -LiteralPath $f)
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
function Test-Machine {
    Write-Head "1. Checking this machine"
    Write-Note "Nothing is changed in this step unless the clock needs fixing, and that is asked first."
    Write-Host ""

    if ($env:OS -ne 'Windows_NT') {
        Stop-Politely "checking this is Windows" "OS reports '$env:OS'" "on Linux, follow docs/INSTALL-LINUX.md instead"
    }
    Write-Ok "Windows"

    $ps = $PSVersionTable.PSVersion
    if ($ps.Major -lt 5 -or ($ps.Major -eq 5 -and $ps.Minor -lt 1)) {
        Stop-Politely "checking PowerShell" "version $ps" "install Windows Management Framework 5.1 from Microsoft, then run this again"
    }
    Write-Ok "PowerShell $ps"

    $script:IsAdmin = Test-Admin
    if ($script:IsAdmin) { Write-Ok "running as Administrator" }
    else {
        Write-Warn "not running as Administrator"
        Write-Note "Installing works without it. Opening firewall ports and fixing the clock do not,"
        Write-Note "so those steps will be checked and explained but skipped."
        Write-Note "To do them too: close this, right-click hotwire-install.bat, choose 'Run as administrator'."
        Write-Host ""
        if (-not (Confirm-Step "Carry on without Administrator?")) { Write-Summary; exit 0 }
    }

    try {
        $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        if ($ramGB -ge $MinRamGB) { Write-Ok "$ramGB GB of memory" }
        else {
            Write-Warn "$ramGB GB of memory -- Rust recommends $MinRamGB GB free for a server"
            Write-Note "A small map with few players can run on less. A 6000-size map will not."
        }
    } catch { Write-Warn "could not read how much memory this machine has" }

    Test-Clock
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

function Test-Clock {
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
    Write-Head "2. Where the server goes"

    $d = $Dir
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
    # Belt and braces behind hotwire-install.bat: an elevated prompt starts in System32, and a Rust
    # server inside the Windows folder would be a disaster to find and worse to remove.
    if ($env:SystemRoot -and ($d -eq $env:SystemRoot -or $d -like "$env:SystemRoot\*")) {
        Stop-Politely "using '$d' for the server" "that is inside the Windows folder" `
            "put hotwire-install.bat in the folder you want the server in (for example C:\rustserver) and start it from there"
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

    # The guest rule (ADR-0029). A server we did not install belongs to someone who set it up their
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

    $free = $null
    try { $free = Get-FreeGB $d } catch { }
    if ($null -eq $free) { Write-Warn "could not read the free space for $d (a network path?) -- Rust recommends $MinFreeDiskGB GB" }
    elseif ($free -ge $MinFreeDiskGB) { Write-Ok "$free GB free on that drive" }
    else {
        Write-Warn "$free GB free on that drive -- Rust recommends $MinFreeDiskGB GB"
        Write-Note "The download is about 12 GB and the server grows with every save."
        if (-not (Confirm-Step "Carry on with less space than recommended?")) { Write-Summary; exit 0 }
    }
    return $d
}

function Show-Plan([string]$d) {
    Write-Head "Here is the plan"
    Write-Host "  Server folder : $d"
    Write-Host "  SteamCMD      : $SteamCmd"
    Write-Host ""
    Write-Host "  3. Install SteamCMD            $(if (Test-Path (Join-Path $SteamCmd 'steamcmd.exe')) { '(already there -- reused)' })"
    Write-Host "  4. Download the Rust server    about 12 GB, usually 10-30 minutes"
    Write-Host "  5. Install Oxide               about 13 MB"
    Write-Host "  6. Firewall                    UDP $GamePort and $QueryPort; Rust+ only if you say so; never RCON"
    Write-Host ""
    Write-Note "Each step asks before it does anything. Saying no to one stops there; run the script"
    Write-Note "again whenever you like and it carries on."
    Write-Host ""
    if (-not (Confirm-Step "Start?")) { Write-Summary; exit 0 }

    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $script:Changed.Add("created $d")
    }
    Save-Record $d $null
}

# ------------------------------------------------------------ 3. steamcmd --
function Install-SteamCmd([string]$d) {
    Write-Head "3. SteamCMD"
    $exe = Join-Path $SteamCmd 'steamcmd.exe'

    if (Test-Path -LiteralPath $exe) {
        Write-Ok "SteamCMD is already at $exe -- using it as it is"
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
    if (-not (Confirm-Step "Install SteamCMD into $SteamCmd?")) { Write-Summary; exit 0 }

    $zip = Join-Path $env:TEMP 'hotwire-steamcmd.zip'
    [void](Invoke-Download $SteamCmdZipUrl $zip 'SteamCMD')
    try {
        New-Item -ItemType Directory -Path $SteamCmd -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $SteamCmd -Force
    } catch {
        Stop-Politely "unpacking SteamCMD into $SteamCmd" "$($_.Exception.Message)" `
            "if that is a permissions error, right-click hotwire-install.bat and choose 'Run as administrator', or pass -SteamCmd with a folder you own"
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
    Write-Head "4. The Rust server"

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
    if (-not (Confirm-Step "Download the Rust server now?")) { Write-Summary; exit 0 }

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
    Write-Head "5. Oxide"
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
    if (-not (Confirm-Step "Install Oxide now?")) { Write-Summary; exit 0 }

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
    Save-Record $d 'oxide'
}

# ------------------------------------------------------------ 6. firewall --
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
    $rules = Get-InboundPortRules $Protocol $Port
    $blocks = @($rules | Where-Object { $_.Action -eq 'Block' })
    $allows = @($rules | Where-Object { $_.Action -eq 'Allow' })

    foreach ($b in $blocks) {
        Write-Bad "$Protocol $Port is BLOCKED by the rule '$($b.DisplayName)'"
        Write-Note "In Windows Firewall a block rule beats every allow rule, so no rule added here would help."
        Write-Note "Remove or disable it yourself if it is not deliberate (wf.msc > Inbound Rules)."
    }
    if ($allows.Count -gt 0) {
        foreach ($a in $allows) { Write-Ok "$Protocol $Port ($Label) is already open: '$($a.DisplayName)' $(Get-RemoteText $a)" }
        return
    }
    if ($blocks.Count -gt 0) { return }

    New-NetFirewallRule -DisplayName "Rust $Label (Hotwire)" -Group 'Hotwire' -Direction Inbound `
        -Protocol $Protocol -LocalPort $Port -Action Allow | Out-Null
    Write-Ok "opened $Protocol $Port ($Label)"
    $script:Changed.Add("firewall: allowed inbound $Protocol $Port, rule 'Rust $Label (Hotwire)'")
}

function Set-Firewall([string]$d) {
    Write-Head "6. Firewall"

    Write-Why @(
        "A Rust server uses four ports. These numbers match hotwire.bat's defaults:",
        "",
        "  UDP $GamePort   game         players connect here            opened",
        "  UDP $QueryPort   query        the in-game server browser      opened -- without it the server is invisible",
        "  TCP $AppPort   Rust+        the phone companion app         only if you want it",
        "  TCP $RconPort   RCON         remote control of the server    NEVER opened here",
        "",
        "RCON is a remote console: anyone who reaches it and guesses the password runs commands on",
        "your server. Reach it from this machine or over a VPN. If you really must open it, open it",
        "to your own address only -- the guide shows how.",
        "",
        "This is Windows Firewall only. A home router needs port forwarding, and a cloud provider has",
        "its own firewall; both are outside this machine. More: $($Docs['Creating a server (Rust)'])"
    )

    try { $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore) }
    catch { Write-Warn "could not read Windows Firewall: $($_.Exception.Message)"; return }

    $on = @($profiles | Where-Object { $_.Enabled -eq 'True' })
    if ($on.Count -eq 0) {
        Write-Warn "Windows Firewall is switched off for every network profile"
        Write-Note "Every port on this machine is reachable -- including RCON once the server runs."
        Write-Note "Rules added now take effect only if the firewall is switched back on. Not switching it on:"
        Write-Note "that may be deliberate (another firewall, a cloud firewall). Check before you go live."
    } else {
        Write-Ok ("Windows Firewall is on for: " + (($on | ForEach-Object { $_.Name }) -join ', '))
    }

    # A rule scoped to the program with no port filter covers every port it listens on. An allow here
    # exposes RCON whatever the port rules say; a block here stops players. Whether Windows' 'allow
    # this app?' prompt creates exactly such a rule on current builds is not verified here (GAP 2.7).
    $programRules = @()
    try {
        $programRules = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore |
            Where-Object { $_.Program -like '*\RustDedicated.exe' } | Get-NetFirewallRule |
            Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' })
    } catch { }
    foreach ($r in $programRules) {
        if ($r.Action -eq 'Allow') {
            Write-Warn "'$($r.DisplayName)' allows RustDedicated.exe $(Get-RemoteText $r) -- if it names no port, that includes RCON"
        } else {
            Write-Bad "'$($r.DisplayName)' blocks RustDedicated.exe -- players will not be able to connect"
        }
    }

    try {
        foreach ($r in (Get-InboundPortRules 'TCP' $RconPort | Where-Object { $_.Action -eq 'Allow' })) {
            Write-Warn "RCON (TCP $RconPort) is open: '$($r.DisplayName)' $(Get-RemoteText $r)"
            Write-Note "Not changed. If that is not your own address only, remove it (wf.msc > Inbound Rules)."
        }
    } catch { Write-Warn "could not check whether RCON (TCP $RconPort) is open: $($_.Exception.Message)" }

    if (-not $script:IsAdmin) {
        Write-Host ""
        Write-Warn "not Administrator, so no rules were added"
        Write-Note "To open them: right-click hotwire-install.bat, 'Run as administrator'. It skips what is already done."
        return
    }

    Write-Host ""
    if (-not (Confirm-Step "Open UDP $GamePort and UDP $QueryPort in Windows Firewall?")) { Write-Note "No rules were added."; return }
    Open-Port 'UDP' $GamePort 'game'
    Open-Port 'UDP' $QueryPort 'query'

    Write-Host ""
    Write-Note "Rust+ lets players pair their phone with your server. It is optional, and more: $($Docs['Rust+ companion (Rust)'])"
    if (Confirm-Step "Also open TCP $AppPort for Rust+?") { Open-Port 'TCP' $AppPort 'Rust+' }

    Write-Note "Every rule this script adds is in the group 'Hotwire'. To remove them all:"
    Write-Note "  Remove-NetFirewallRule -Group Hotwire"
    Save-Record $d 'firewall'
}

# ------------------------------------------------------------------- main --
Write-Host ""
Write-Host "hotwire-install $Version -- a Rust server with Oxide, on this machine" -ForegroundColor White
Write-Host ""
Write-Why @(
    "This walks through installing a Rust dedicated server, one step at a time. Every step says",
    "what it is about to do and waits for a yes. Enter on its own always means no.",
    "",
    "It does not start the server, choose any passwords, or connect to anything of ours. When it",
    "finishes you will have a server ready to configure, and the guide takes it from there.",
    "",
    "Worth keeping open while you go:"
)
foreach ($k in $Docs.Keys) { Write-Host ("    {0,-27} {1}" -f $k, $Docs[$k]) }
Write-Host ""
if (-not (Confirm-Step "Begin?")) { Write-Note "Nothing was changed."; exit 0 }

Test-Machine
$ServerDir = Select-Directory
Show-Plan $ServerDir
$SteamCmdExe = Install-SteamCmd $ServerDir
Install-Rust $ServerDir $SteamCmdExe
Install-Oxide $ServerDir
Set-Firewall $ServerDir

Write-Head "Done"
Write-Summary
Write-Host ""
Write-Host "  Next, in the guide ($($Docs['This guide, step by step'])):"
Write-Host "    step 5  pick an RCON password"
Write-Host "    step 6  install Hotwire's launcher and plugin, and start the server"
Write-Host ""
Write-Note "The first start takes several minutes while the map generates."
Write-Note "Run this script again any time; it only does what is not done yet."
exit 0
