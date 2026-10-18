# hotwire.ps1 updating Hotwire, read out of the file by the PowerShell parser and run off Windows against a release feed
# and downloads on a local web server (HOTWIRE_TEST_URL), signed with the test's own key (HOTWIRE_TEST_PUB). Called by
# tests/self-update/run.sh; prints "name|have|want" lines. The new launcher's check runs through a stand-in
# powershell.exe on the PATH that exits with HOTWIRE_TEST_CHECK_RC. What this cannot prove: Windows PowerShell 5.1,
# hotwire.bat, and the Windows file system.
# As the launcher runs: an error inside a try is caught, not printed.
$ErrorActionPreference = 'Stop'
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'launcher/hotwire.ps1'), [ref]$t, [ref]$e)
if ($e.Count -gt 0) { "hotwire.ps1 parses|$($e.Count) errors|0 errors"; exit }
$want = @('Say', 'Get-Env', 'Get-Num', 'Get-UtcStamp', 'Get-FileSha256', 'Set-CfgValues', 'Send-Step', 'Get-SuState', 'Set-SuState',
    'Set-SuBlocked', 'Get-PluginVersion', 'Test-SuNewer', 'ConvertFrom-Hex', 'Test-ReleaseSignature', 'Invoke-SelfUpdateRequest',
    'Undo-SelfUpdate', 'Get-SuRelease', 'Invoke-SelfUpdate', 'Test-SuProbation', 'Get-SelfUpdateState')
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }

$base = $env:HOTWIRE_TEST_URL
$WipeFlag = 'WIPE.flag'
$SuFeed = $base + '/feed.json'
$SuDownload = $base + '/dl'
$SuKeys = [ordered]@{ 'test-2026-10-12' = $env:HOTWIRE_TEST_PUB }
$SuProbationSeconds = 1200
$script:StartId = ''; $script:CheckOnly = $false
$script:Sent = New-Object System.Collections.ArrayList
function Add-SpoolReport([string]$kind, [string]$payload) { [void]$script:Sent.Add($kind + ' ' + $payload) }
function Start-BackgroundSend { }
function Send-Now { }
# The settings reader, for the settings this needs.
function Import-Settings([switch]$Quiet) {
    foreach ($pair in @(@('hotwire.self_update', 'SELF_UPDATE', 'off'), @('hotwire.self_update_days', 'SELF_UPDATE_DAYS', '3'),
            @('hotwire.self_update_channel', 'SELF_UPDATE_CHANNEL', 'release'))) {
        $m = Select-String -LiteralPath $cfg -Pattern ('^' + [regex]::Escape($pair[0]) + '\s+(\S+)') | Select-Object -Last 1
        [Environment]::SetEnvironmentVariable($pair[1], $(if ($m) { $m.Matches[0].Groups[1].Value } else { $pair[2] }))
    }
    return 'ok'
}

# A server folder running launcher 1.1.39 and plugin 1.1.74, and this run's paths in it.
function New-Server([string]$mode, [string]$days) {
    $script:root = Join-Path $env:HOTWIRE_TEST_WORK ('win-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Force -Path ([IO.Path]::Combine($root, 'oxide', 'plugins')), ([IO.Path]::Combine($root, 'oxide', 'data', 'Hotwire')))
    [IO.File]::WriteAllText([IO.Path]::Combine($root, 'oxide', 'plugins', 'Hotwire.cs'), "[Info(`"Hotwire`", `"xman2000`", `"1.1.74`")]`n")
    [IO.File]::WriteAllText((Join-Path $root 'hotwire.ps1'), "`$LauncherVersion = '1.1.39'`n")
    $script:cfg = Join-Path $root 'hotwire.cfg'
    [IO.File]::WriteAllText($cfg, "hotwire.self_update $mode`nhotwire.self_update_days $days`n")
    $script:LauncherVersion = '1.1.39'
    $script:SuDir = [IO.Path]::Combine($root, 'hotwire', 'self-update')
    $script:SuPrevious = [IO.Path]::Combine($root, 'hotwire', 'previous')
    $script:SuApplied = Join-Path $SuDir 'applied'
    $script:SuRolledBack = Join-Path $SuDir 'rolled-back'
    $script:SuState = Join-Path $SuDir 'state'
    $script:SuPlugin = [IO.Path]::Combine($root, 'oxide', 'plugins', 'Hotwire.cs')
    $script:SuLoaded = [IO.Path]::Combine($root, 'oxide', 'data', 'Hotwire', 'loaded.json')
    [void](Import-Settings)
}
function Get-Pv { $m = [regex]::Match([IO.File]::ReadAllText($SuPlugin), '"([0-9.]+)"\)\]'); return $m.Groups[1].Value }
function Get-Lv { $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'hotwire.ps1')), "LauncherVersion = '([0-9.]+)'"); return $m.Groups[1].Value }

New-Server 'off' '3'
"hotwire.ps1: off installs nothing|$(Invoke-SelfUpdate)|False"

New-Server 'auto' '3'
"hotwire.ps1: a signed release 5 days old installs and the launcher takes over|$(Invoke-SelfUpdate)|True"
"hotwire.ps1: the plugin|$(Get-Pv)|1.1.75"
"hotwire.ps1: the launcher|$(Get-Lv)|1.1.40"
"hotwire.ps1: the previous plugin is kept|$([IO.File]::ReadAllText((Join-Path $SuPrevious 'Hotwire.cs')).Contains('1.1.74'))|True"
"hotwire.ps1: on probation|$(Get-SuState 'last_result')/$([IO.File]::ReadAllLines($SuApplied)[0])|installed/tag release-new"
"hotwire.ps1: the steps are reported|$(@($script:Sent | Where-Object { $_ -match 'hotwire_update' }).Count -ge 0)|True"

"hotwire.ps1: probation passes when the new plugin says it loaded|$(
    [IO.File]::WriteAllText($SuLoaded, '{"version": "1.1.75"}'); Test-SuProbation ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 5); Test-Path -LiteralPath $SuApplied)|False"

New-Server 'auto' '7'
"hotwire.ps1: too young for a 7-day wait|$(Invoke-SelfUpdate)|False"
New-Server 'auto' '0'
"hotwire.ps1: early release takes today's|$([void](Invoke-SelfUpdate); Get-Pv)|1.1.76"

New-Server 'auto' '3'
$trusted = $SuKeys; $SuKeys = [ordered]@{}
"hotwire.ps1: a launcher that does not list the release's key installs nothing|$(Invoke-SelfUpdate)/$(Get-Pv)|False/1.1.74"
$SuKeys = $trusted

New-Server 'auto' '3'
$script:LauncherVersion = '1.1.99'
"hotwire.ps1: a plugin-only update keeps the launcher running|$(Invoke-SelfUpdate)/$(Get-Pv)/$(Get-Lv)|False/1.1.75/1.1.39"

New-Server 'auto' '3'
$env:HOTWIRE_TEST_CHECK_RC = '1'
"hotwire.ps1: a launcher that refuses this server's settings is not installed|$(Invoke-SelfUpdate)/$(Get-Lv)/$(Get-SuState 'reason')|False/1.1.39/check_failed"
$env:HOTWIRE_TEST_CHECK_RC = '0'
"hotwire.ps1: a paused server takes no automatic update|$(Invoke-SelfUpdate)/$(Get-Lv)|False/1.1.39"
[IO.File]::WriteAllText((Join-Path $root 'HOTWIRE_UPDATE.request'), '')
"hotwire.ps1: Update Hotwire clears the pause and installs the newest, whatever its age|$(Invoke-SelfUpdate)/$(Get-Lv)/$(Get-SuState 'blocked')|True/1.1.41/0"

New-Server 'auto' '3'
[void](Invoke-SelfUpdate)
Undo-SelfUpdate 'crashed' $SuApplied
"hotwire.ps1: a crash on probation puts both back and pauses|$(Get-Pv)/$(Get-Lv)/$(Get-SuState 'reason')|1.1.74/1.1.39/crashed"

New-Server 'off' '3'
[IO.File]::WriteAllText((Join-Path $root 'SELF_UPDATE.request'), "auto 0`r`n")
[void](Invoke-SelfUpdate)
"hotwire.ps1: AFKPanel's auto 0 is written and installs|$([IO.File]::ReadAllLines((Join-Path $root 'SELF_UPDATE.result'))[0])/$(Get-Pv)|applied auto 0/1.1.76"
[IO.File]::WriteAllText((Join-Path $root 'SELF_UPDATE.request'), "auto 3; reboot")
[void](Invoke-SelfUpdate)
"hotwire.ps1: a request that is not off, auto or retry is refused|$([IO.File]::ReadAllLines((Join-Path $root 'SELF_UPDATE.result'))[0].StartsWith('reject'))|True"

New-Server 'auto' '3'
[void](New-Item -ItemType Directory -Force -Path $SuDir)
[IO.File]::WriteAllLines($SuRolledBack, [string[]]@('launcher_failed', 'tag release-new', 'plugin 1.1.74 1.1.75'))
[IO.File]::WriteAllText($SuPlugin, "[Info(`"Hotwire`", `"xman2000`", `"1.1.75`")]`n")
[void](New-Item -ItemType Directory -Force -Path $SuPrevious)
[IO.File]::WriteAllText((Join-Path $SuPrevious 'Hotwire.cs'), "[Info(`"Hotwire`", `"xman2000`", `"1.1.74`")]`n")
[void](Invoke-SelfUpdate)
"hotwire.ps1: after hotwire.bat rolled the launcher back, the plugin goes back too and updates pause|$(Get-Pv)/$(Get-SuState 'reason')/$(Test-Path -LiteralPath $SuRolledBack)|1.1.74/launcher_failed/False"
