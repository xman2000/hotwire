# hotwire.ps1's hook functions, read out of the file by the PowerShell parser and run off Windows with bash standing in
# for cmd.exe. Called by tests/launcher-hooks/run.sh; prints "name|have|want" lines. What this cannot prove: cmd.exe,
# taskkill's process tree on Windows, and Windows PowerShell 5.1.
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'launcher/hotwire.ps1'), [ref]$t, [ref]$e)
if ($e.Count -gt 0) { "hotwire.ps1 parses|$($e.Count) errors|0 errors"; exit }
'hotwire.ps1 parses|0 errors|0 errors'
$want = @('Say', 'Get-Num', 'Get-UtcStamp', 'Invoke-Hook', 'Get-LauncherHooksJson', 'Get-UpdateJson', 'Invoke-Report')
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
function Say([string]$message) { }

$work = $env:HOTWIRE_TEST_WORK
$root = $work
$UpdateStamp = Join-Path $work 'no-stamp'
$script:HookRuns = @{}
$script:HookLimitSeconds = 2
$script:HookShellForTests = 'bash'

$slow = Join-Path $work 'slow.sh'
$quick = Join-Path $work 'quick.sh'
$r1 = Invoke-Hook $slow 'before'
$r2 = Invoke-Hook $quick 'after'
"hotwire.ps1 stops a hook at the limit|$r1|stopped"
"hotwire.ps1 reports a failed hook|$r2|failed"
$d = ConvertFrom-Json ('{"x":0' + (Get-LauncherHooksJson) + '}')
"hotwire.ps1 marks the stopped hook timed out|$($d.launcher_hooks.before.timed_out)|True"
"hotwire.ps1 sends no exit code for a stopped hook|$($null -eq $d.launcher_hooks.before.exit_code)|True"
"hotwire.ps1 times a stopped hook near the limit|$($d.launcher_hooks.before.seconds -ge 2 -and $d.launcher_hooks.before.seconds -lt 14)|True"
"hotwire.ps1 records a finished hook's exit code|$($d.launcher_hooks.after.exit_code)|3"
$child = Get-Content -Raw (Join-Path $work 'child.pid') -ErrorAction SilentlyContinue
$alive = $false; if ($child) { $alive = $null -ne (Get-Process -Id ([int]$child.Trim()) -ErrorAction SilentlyContinue) }
"hotwire.ps1 stops what a hook started|$alive|False"

$script:HookRuns = @{}
"hotwire.ps1 leaves launcher_hooks out when no hook ran|$(Get-LauncherHooksJson)|"

$script:HookRuns = @{ before = '{"seconds":1.5,"exit_code":0,"timed_out":false}' }
$script:spooled = @()
function Add-SpoolReport([string]$kind, [string]$payload) { $script:spooled += , @($kind, $payload) }
$env:HOTWIRE_REPORT = 'session_start'; $env:HOTWIRE_STARTED_AT = '2026-10-08T12:00:00Z'
$env:HOTWIRE_UPDATE_ATTEMPTED = '1'; $env:STEAM_OK = '1'; $env:FRAMEWORK_OK = '1'
Invoke-Report
"hotwire.ps1 writes a session report at the start|$($script:spooled[0][0])|session"
$s = ConvertFrom-Json $script:spooled[0][1]
"hotwire.ps1's start report carries started_at|$($s.started_at.ToString('yyyy-MM-ddTHH:mm:ssZ'))|2026-10-08T12:00:00Z"
"hotwire.ps1's start report carries the update|$($s.update.steam_ok)|True"
"hotwire.ps1's start report carries the hooks|$($s.launcher_hooks.before.seconds)|1.5"
