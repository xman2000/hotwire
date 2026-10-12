# hotwire.ps1's update reporting, read out of the file by the PowerShell parser and run off Windows: the lines a start
# says about its update, its reason, the session report's update block, and SteamCMD's failures through Update-Rust with
# a stand-in. Called by tests/launcher-update/run.sh; prints "name|have|want" lines. What this cannot prove: the update
# decision itself, which is inline in Invoke-Main, and Windows PowerShell 5.1.
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'launcher/hotwire.ps1'), [ref]$t, [ref]$e)
if ($e.Count -gt 0) { "hotwire.ps1 parses|$($e.Count) errors|0 errors"; exit }
$want = @('Say', 'Set-UpdateReason', 'Get-UpdateJson', 'Get-Env', 'Get-Num', 'Update-Rust', 'Invoke-SteamUpdate', 'Get-ForcedWipeDeadline', 'Test-FilesCorrupt', 'Move-RefusedRecord', 'Restore-RefusedRecord', 'Get-InstalledBuild', 'Set-FastRustMark')
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
