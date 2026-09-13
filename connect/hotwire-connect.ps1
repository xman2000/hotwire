<#
    hotwire-connect -- connect a Rust server to Hotwire Panel, or explain why it will not.

    https://github.com/xman2000/hotwire            MIT (c) 2026 xman2000

    Connecting is optional and reversible. Nothing here is required to run a Rust server, and
    `detach` leaves the machine exactly as it was found.

    THIS SCRIPT IS A GUEST ON SOMEONE ELSE'S MACHINE.

    It never overwrites a file that already exists without being told to, never touches anything
    outside the server directory, and says what it is about to do before it does it. Where it
    cannot be certain, it stops and explains what it looked for rather than guessing. Every error
    names three things: what was attempted, what was found instead, and what you can do about it.

    Requires Windows PowerShell 5.1, which ships with Windows Server 2016 and later.

    Usage:
        .\hotwire-connect.ps1 doctor  [-Root DIR] [-Panel URL]
        .\hotwire-connect.ps1 connect [-Root DIR]          # asks for the code
        .\hotwire-connect.ps1 status  [-Root DIR]
        .\hotwire-connect.ps1 detach  [-Root DIR]
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [string]$Root,
    [string]$Panel,
    [string]$Code,
    [string]$Name,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Version = '0.1.0'
$DefaultPanel = 'https://hotpanel.on-forge.com'

# Windows PowerShell 5.1 still negotiates TLS 1.0 by default on some builds, and the panel will
# simply refuse the connection with nothing useful in the message. Named here so it is a decision
# rather than a mystery.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------------------------------------------------------ output --
function Write-Ok   ($m) { Write-Host "  [ ok ] $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Bad  ($m) { Write-Host "  [fail] $m" -ForegroundColor Red }
function Write-Note ($m) { Write-Host "        $m" -ForegroundColor DarkGray }
function Write-Head ($m) { Write-Host ""; Write-Host $m -ForegroundColor White }

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
    exit 1
}

function Confirm-Step([string]$Question) {
    if ($Yes) { Write-Note "(-Yes) $Question"; return $true }
    $answer = Read-Host "  $Question [y/N]"
    return $answer -match '^[yY]'
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

    Write-Host "hotwire-connect $Version -- checking this machine"
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
        else { Write-Note "Next: .\hotwire-connect.ps1 connect" }
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
    if ($Secret) {
        # Readable by this machine's administrators and the account the server runs as; not by
        # everyone with a login. The file holds a signing key.
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
    if (-not (Confirm-Step "Connect this server to the panel?")) { Write-Host "  Nothing was changed."; return 0 }

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
        Write-Note "Run 'doctor' to check this machine, then 'connect -Code ...'."
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

function Show-Help {
@'
hotwire-connect -- connect a Rust server to Hotwire Panel

  doctor    Check this machine: tools, signing, your server, the panel, the clock.
            Read-only, changes nothing, safe any time.
  connect   Connect to the panel. Asks for the code; no need to type it here.
  status    Show what this server is connected to.
  detach    Disconnect. Leaves the server running exactly as it is.

Options
  -Root DIR    The Rust server directory (default: found from the current one)
  -Panel URL   The panel to talk to (default: recorded at connect)
  -Yes         Do not ask for confirmation (for unattended runs)

Connecting is optional and reversible. Your server does not need a panel to run.
'@ | Write-Host
}

switch ($Command.ToLowerInvariant()) {
    'doctor'   { exit (Invoke-Doctor) }
    'connect'  { exit (Invoke-Connect) }
    'status'   { exit (Invoke-Status) }
    'detach'   { exit (Invoke-Detach) }
    default    { Show-Help; if ($Command -eq 'help') { exit 0 } else { exit 1 } }
}
