# Requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath = '', [int[]]$AdditionalProxyPorts = @(), [string[]]$ApplicationPath = @())
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')

# Read process identity and socket metadata only. Never read auth.json,
# process environments, command lines, request payloads, cookies or tokens.
$runtimePath = Join-Path $script:StateRoot 'deployment.json'
$entryPort = 17890
if (Test-Path -LiteralPath $runtimePath) {
    $runtime = Read-JsonFile $runtimePath
    $entryPort = [int]$runtime.MixedPort
}
$ports = @(@($entryPort, 17890, 5188, 5180, 7890, 7891, 7897) + $AdditionalProxyPorts | Select-Object -Unique)
$processes = @(Get-CimInstance Win32_Process -Property Name,ProcessId,ParentProcessId,ExecutablePath,CreationDate -ErrorAction SilentlyContinue)
$byId = @{}
foreach ($process in $processes) { $byId[[int]$process.ProcessId] = $process }

function Get-AppEvidence($Process) {
    $path = [string]$Process.ExecutablePath
    if ($ApplicationPath -contains $path) { return 'ExplicitInspectedApplicationPath' }
    if ($path -match '(?i)[\\/]Codex(?: Web GPT)?[\\/]|[\\/]OpenAI\.Codex[_\\/]' -or $Process.Name -match '(?i)^codex(?:[-_ ].*)?\.exe$') { return 'CodexPathOrExecutableEvidence' }
    if ($path -match '(?i)[\\/]OpenAI\.ChatGPT[^\\/]*[\\/]') { return 'ChatGPTPackagePathEvidence' }
    if ($Process.Name -eq 'ChatGPT.exe') { return 'NameOnly-UnclassifiedApp' }
    return 'RelatedChildProcess'
}

$appIds = @{}
foreach ($process in $processes) {
    if ($ApplicationPath -contains [string]$process.ExecutablePath -or $process.Name -match '(?i)^(codex(?:[-_ ].*)?|ChatGPT)\.exe$' -or [string]$process.ExecutablePath -match '(?i)[\\/]Codex(?: Web GPT)?[\\/]|[\\/]OpenAI\.(Codex|ChatGPT)[_\\/-]') { $appIds[[int]$process.ProcessId] = $true }
}
# Include children and helpers of path-identified applications, but do not
# assign the ChatGPT product identity merely because a file is ChatGPT.exe.
for ($generation = 0; $generation -lt 6; $generation++) {
    foreach ($process in $processes) {
        if ($appIds.ContainsKey([int]$process.ParentProcessId)) { $appIds[[int]$process.ProcessId] = $true }
    }
}
$apps = @()
foreach ($process in $processes) {
    if (!$appIds.ContainsKey([int]$process.ProcessId)) { continue }
    $ancestors = @()
    $parentId = [int]$process.ParentProcessId
    $seen = @{}
    for ($depth = 0; $depth -lt 6 -and $byId.ContainsKey($parentId) -and !$seen.ContainsKey($parentId); $depth++) {
        $seen[$parentId] = $true
        $parent = $byId[$parentId]
        if ($parent.CreationDate -and $process.CreationDate -and $parent.CreationDate -gt $process.CreationDate) {
            $ancestors += [pscustomobject]@{ ProcessId = $parentId; IdentityEvidence = 'ParentPidReused-CannotAttribute' }
            break
        }
        $ancestors += [pscustomobject]@{ ProcessId = [int]$parent.ProcessId; Name = $parent.Name; ExecutablePath = $parent.ExecutablePath; CreatedUtc = $(if ($parent.CreationDate) { $parent.CreationDate.ToUniversalTime().ToString('o') } else { $null }) }
        $parentId = [int]$parent.ParentProcessId
    }
    $apps += [pscustomobject]@{ ProcessId = [int]$process.ProcessId; ParentProcessId = [int]$process.ParentProcessId; Name = $process.Name; ExecutablePath = $process.ExecutablePath; CreatedUtc = $(if ($process.CreationDate) { $process.CreationDate.ToUniversalTime().ToString('o') } else { $null }); IdentityEvidence = (Get-AppEvidence $process); Ancestors = $ancestors }
}
$connectionError = ''
$connections = @()
try { $connections = @(Get-NetTCPConnection -ErrorAction Stop) } catch { $connectionError = 'TCP enumeration unavailable; no route conclusion can be drawn.' }
$listeners = @($connections | Where-Object { $_.State -eq 'Listen' -and $ports -contains [int]$_.LocalPort } | ForEach-Object {
    $owner = $byId[[int]$_.OwningProcess]
    [pscustomobject]@{ Address = $_.LocalAddress; Port = [int]$_.LocalPort; ProcessId = [int]$_.OwningProcess; Name = $(if ($owner) { $owner.Name } else { $null }); ExecutablePath = $(if ($owner) { $owner.ExecutablePath } else { $null }) }
})
$routes = @($connections | Where-Object { $appIds.ContainsKey([int]$_.OwningProcess) -and $_.RemoteAddress -in @('127.0.0.1', '::1', '::ffff:127.0.0.1') -and $ports -contains [int]$_.RemotePort } | ForEach-Object {
    [pscustomobject]@{ ProcessId = [int]$_.OwningProcess; LocalAddress = $_.LocalAddress; LocalPort = [int]$_.LocalPort; RemoteAddress = $_.RemoteAddress; RemotePort = [int]$_.RemotePort; State = [string]$_.State; IsDeploymentEntry = ([int]$_.RemotePort -eq $entryPort) }
})
$report = [ordered]@{
    SchemaVersion = 1; GeneratedUtc = [DateTime]::UtcNow.ToString('o'); ComputerName = $env:COMPUTERNAME
    DeploymentPort = $entryPort; ObservedPorts = $ports; Processes = $apps; ProxyListeners = $listeners; AppProxyConnections = $routes
    EnumerationError = $connectionError; ModelGeneration = 'NotTested'
    Limits = @('Socket snapshot proves a connection to a local port, not which authenticated model request used it.', 'An idle app may have no connection during the snapshot; absence does not prove direct access.', 'Executable path and parent identity may be unavailable without sufficient Windows rights.', 'No running process environment was read; this report does not prove .env adoption.', 'No software was started, stopped or reconfigured. No authentication files or tokens were collected.')
}
if (!$ReportPath) { $ReportPath = Join-Path $script:StateRoot ('diagnostics/route-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json') }
$reportDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
if (!(Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
Write-JsonFile $report $ReportPath
Protect-PrivateFile $ReportPath
Write-Output ('Route evidence: ' + $ReportPath)
Write-Output ('App/helper processes: ' + $apps.Count + '; observed local proxy connections: ' + $routes.Count)
Write-Output 'No authenticated model request was made. Send a real message in the intended application and run this snapshot while the request is active.'
