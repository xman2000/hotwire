# hotwire.ps1's update reporting, read out of the file by the PowerShell parser and run off Windows: the lines a start
# says about its update, its reason, the session report's update block, and SteamCMD's failures through Update-Rust with
# a stand-in. Called by tests/launcher-update/run.sh; prints "name|have|want" lines. What this cannot prove: the update
# decision itself, which is inline in Invoke-Main, and Windows PowerShell 5.1.
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'launcher/hotwire.ps1'), [ref]$t, [ref]$e)
if ($e.Count -gt 0) { "hotwire.ps1 parses|$($e.Count) errors|0 errors"; exit }
$want = @('Say', 'Set-UpdateReason', 'Get-UpdateJson', 'Get-Env', 'Get-Num', 'Update-Rust', 'Invoke-UpdateModeRequest', 'Set-CfgValues', 'Send-UpdateProgress', 'Invoke-Report', 'Invoke-SteamUpdate', 'Get-ForcedWipeDeadline', 'Test-FilesCorrupt', 'Move-RefusedRecord', 'Restore-RefusedRecord', 'Get-InstalledBuild', 'Set-FastRustMark')
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }

$work = $env:HOTWIRE_TEST_WORK
$root = $work
$AppId = '258550'
$Acf = Join-Path $work 'appmanifest_258550.acf'
$WipeFlag = 'WIPE.flag'
$UpdateStamp = Join-Path $work 'no-stamp'
$script:UpdateCapture = $false
$script:UpdateLog = New-Object System.Collections.ArrayList
$script:UpdateReason = ''
$script:UpdateEffective = ''
# The reports this run would send, kept here instead of in the spool.
$script:Sent = New-Object System.Collections.ArrayList
function Add-SpoolReport([string]$kind, [string]$payload) { [void]$script:Sent.Add($kind + ' ' + $payload) }
function Start-BackgroundSend { }
# The settings reader, as far as this setting goes: the last line that sets it, unless the test says the file is unusable.
function Import-Settings([switch]$Quiet) {
    if ($script:CfgBroken) { return 'kept' }
    $m = Select-String -LiteralPath $cfg -Pattern '^hotwire\.update_mode\s+(\S+)' | Select-Object -Last 1
    if ($m) { $env:UPDATE_MODE = $m.Matches[0].Groups[1].Value }
    return 'ok'
}

Say 'before the decision'
$script:UpdateCapture = $true
Say 'hotwire.update_mode is off: not updating.'
Say ('a "quoted" \ backslash ' + [char]9 + 'tab')
$script:UpdateCapture = $false
Say 'the backup'
"hotwire.ps1 keeps only the update's lines|$($script:UpdateLog.Count)|2"
"hotwire.ps1 stamps each line with its time|$($script:UpdateLog[0] -match '^\[\d\d:\d\d:\d\d\] hotwire\.update_mode is off')|True"

Set-UpdateReason 'mode_off'; Set-UpdateReason 'steamcmd_failed'
"hotwire.ps1 keeps the first reason|$($script:UpdateReason)|mode_off"

$env:UPDATE_MODE = 'off'; $script:UpdateEffective = 'off'
$env:HOTWIRE_UPDATE_ATTEMPTED = '0'; $env:STEAM_OK = '0'; $env:FRAMEWORK_OK = '0'
New-Item -ItemType File -Path (Join-Path $work 'UPDATE.flag') -Force | Out-Null
$d = ConvertFrom-Json ('{"x":0' + (Get-UpdateJson) + '}')
"hotwire.ps1 reports the setting as written|$($d.update.mode)|off"
"hotwire.ps1 reports the mode it followed|$($d.update.effective_mode)|off"
"hotwire.ps1 reports why|$($d.update.reason)|mode_off"
"hotwire.ps1 reports a waiting flag|$($d.update.flag_kept)|True"
"hotwire.ps1 sends the lines as valid JSON|$($d.update.log[1].EndsWith('a "quoted" \ backslash ' + [char]9 + 'tab'))|True"
Remove-Item -LiteralPath (Join-Path $work 'UPDATE.flag')

for ($i = 0; $i -lt 50; $i++) { $script:UpdateCapture = $true; Say ('line ' + $i) }
"hotwire.ps1 sends at most 40 lines|$($script:UpdateLog.Count)|40"

# Update-Rust against a SteamCMD that is missing, then one that fails.
$script:UpdateLog.Clear(); $script:UpdateReason = ''
$env:STEAMCMD = Join-Path $work 'no-such-steamcmd'
[void](Update-Rust $false '' '')
"hotwire.ps1 says SteamCMD is missing|$($script:UpdateReason)|steamcmd_missing"

$script:UpdateReason = ''
$env:STEAMCMD = Join-Path $work 'steamcmd'; $env:MAX_STEAM_TRIES = '1'; $env:STEAM_RETRY_SECONDS = '0'; $env:STEAMCMD_UPDATE_MINUTES = '1'
$ok = Update-Rust $false '' ''
"hotwire.ps1 reports SteamCMD's failure|$($ok)|False"
"hotwire.ps1 says SteamCMD failed|$($script:UpdateReason)|steamcmd_failed"

"hotwire.ps1 reports each SteamCMD try while it runs|$(@($script:Sent | Where-Object { $_.StartsWith('update ') }).Count)|1"
$p = ConvertFrom-Json ($script:Sent[0].Substring(7))
"hotwire.ps1 names the step and the try|$($p.step) $($p.attempt) $($p.of)|steamcmd 1 1"

# An update mode AFKPanel asked for.
$cfg = Join-Path $work 'hotwire.cfg'
$request = Join-Path $work 'UPDATE_MODE.request'
[IO.File]::WriteAllText($cfg, "server.hostname ""Test""`nhotwire.update_mode         off`n")
[IO.File]::WriteAllText($request, "auto`n")
$env:UPDATE_MODE = 'off'
"hotwire.ps1 applies auto|$(Invoke-UpdateModeRequest)|True"
"hotwire.ps1 writes it into hotwire.cfg|$((Select-String -LiteralPath $cfg -Pattern '^hotwire\.update_mode\s+auto$').Count)|1"
"hotwire.ps1 leaves a receipt|$([IO.File]::ReadAllText((Join-Path $work 'UPDATE_MODE.result')).Trim())|applied auto (was off)"
"hotwire.ps1 uses the request up|$(Test-Path -LiteralPath $request)|False"

$env:UPDATE_MODE = 'auto'
[IO.File]::WriteAllText($request, "off`n")
"hotwire.ps1 refuses off|$(Invoke-UpdateModeRequest)|False"
"hotwire.ps1 leaves hotwire.cfg alone|$((Select-String -LiteralPath $cfg -Pattern '^hotwire\.update_mode\s+auto$').Count)|1"
"hotwire.ps1 says why|$([IO.File]::ReadAllText((Join-Path $work 'UPDATE_MODE.result')).Trim())|reject off : the panel sets auto or always only"

$env:UPDATE_MODE = 'off'
[IO.File]::WriteAllText($cfg, "hotwire.update_mode         off`n")
[IO.File]::WriteAllText($request, "auto`n")
$script:CfgBroken = $true
[void](Invoke-UpdateModeRequest)
$script:CfgBroken = $false
"hotwire.ps1 does not claim a mode an unusable hotwire.cfg kept from|$([IO.File]::ReadAllText((Join-Path $work 'UPDATE_MODE.result')).Trim())|reject auto : hotwire.cfg was written but cannot be used now, so the last start's settings stay"
"hotwire.ps1 keeps the last start's mode then|$($env:UPDATE_MODE)|off"

