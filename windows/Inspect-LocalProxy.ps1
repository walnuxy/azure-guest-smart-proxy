# Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
Ensure-StateDirectory
$listeners = Get-Listeners
$selfPorts = @()
$deploymentPath = Join-Path $script:StateRoot 'deployment.json'
if (Test-Path -LiteralPath $deploymentPath) { $old = Read-JsonFile $deploymentPath; $selfPorts = @([int]$old.MixedPort, [int]$old.ApiPort) }
$descriptions = New-Object Collections.Generic.List[object]
$observedEnv = @()
foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy')) {
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ($value) {
        $safe = Get-ProxyDescription $value ('environment:' + $name)
        if ($safe) { $descriptions.Add($safe); $observedEnv += $safe }
    }
}
$wininet = $null
try { $wininet = Get-ItemProperty 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Internet Settings' } catch { }
$wininetSummary = [ordered]@{ Enabled = $false; PacPresent = $false; Endpoints = @() }
if ($wininet) {
    $wininetSummary.Enabled = ([int](Get-PropertyValue $wininet 'ProxyEnable' 0) -eq 1)
    $wininetSummary.PacPresent = ![string]::IsNullOrWhiteSpace((Get-PropertyValue $wininet 'AutoConfigURL' ''))
    foreach ($entry in ((Get-PropertyValue $wininet 'ProxyServer' '') -split ';')) {
        if (!$entry) { continue }
        $entry = $entry -replace '^\w+=', ''
        $safe = Get-ProxyDescription $entry 'WinINET'
        if ($safe) { $descriptions.Add($safe); $wininetSummary.Endpoints += $safe }
    }
}
$knownPorts = @(7890,7891,7897,7898,7899,1080,10808,10809,20171,2080,5180,5188)
$relatedProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(?:clash[^\\/]*|verge-mihomo|mihomo|gofast|v2ray[^\\/]*|xray[^\\/]*|sing-box|nekoray|nekobox|hiddify)(?:\.exe)?$' })
$relatedProcessIds = @($relatedProcesses | ForEach-Object { [int]$_.ProcessId })
foreach ($listener in $listeners) {
    $knownPort = $knownPorts -contains [int]$listener.LocalPort
    $relatedOwner = $relatedProcessIds -contains [int]$listener.OwningProcess
    if ((!$knownPort -and !$relatedOwner) -or $selfPorts -contains [int]$listener.LocalPort) { continue }
    if ($listener.LocalAddress -notin @('127.0.0.1','0.0.0.0','::','::1')) { continue }
    $origin = 'common-listener'
    if ($relatedOwner) { $origin = 'proxy-process-listener' }
    foreach ($scheme in @('http','socks5h')) { $safe = Get-ProxyDescription ($scheme + '://127.0.0.1:' + $listener.LocalPort) $origin; $descriptions.Add($safe) }
}
$results = @()
foreach ($candidate in ($descriptions | Where-Object { $_.Uri -and $selfPorts -notcontains $_.Port } | Sort-Object Uri -Unique)) {
    $listener = @($listeners | Where-Object { [int]$_.LocalPort -eq $candidate.Port -and $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::') } | Sort-Object @{ Expression = {
        switch ($_.LocalAddress) { '127.0.0.1' { 0 }; '::1' { 1 }; '0.0.0.0' { 2 }; '::' { 3 }; default { 4 } }
    } }) | Select-Object -First 1
    if (!$listener) { continue }
    $owner = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $listener.OwningProcess) -ErrorAction SilentlyContinue
    $health = Test-HttpsProxy $candidate.Uri
    $results += [pscustomobject]@{ Uri = $candidate.Uri; Port = $candidate.Port; Origin = $candidate.Origin; ProcessId = [int]$listener.OwningProcess; ProcessName = $(if ($owner) { $owner.Name } else { 'unknown' }); ExecutablePath = $(if ($owner) { $owner.ExecutablePath } else { '' }); Healthy = $health.Healthy; HttpStatus = $health.HttpStatus; ExitCode = $health.ExitCode; TestUrl = $health.TestUrl; TlsVerification = $health.TlsVerification }
}
$sources = @()
foreach ($path in (Get-RuleSourceCandidates)) {
    $rules = @(Read-SafeLocalRules $path)
    $sources += [pscustomobject]@{ Path = $path; RuleCount = $rules.Count; ContainsAcademicDirect = [bool]($rules | Where-Object { $_ -match '(ieee\.org|springer\.com|sciencedirect\.com),DIRECT' }); Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
}
$report = [ordered]@{ SchemaVersion = 1; GeneratedUtc = [DateTime]::UtcNow.ToString('o'); ComputerName = $env:COMPUTERNAME; UserName = $env:USERNAME; ProxyEnvironment = $observedEnv; WinINET = $wininetSummary; Candidates = $results; RuleSources = $sources; CredentialsRedacted = $true; SelfPortsExcluded = $selfPorts }
Write-JsonFile $report (Join-Path $script:StateRoot 'local-proxy-report.json')
Write-Output ('Inspected ' + $results.Count + ' local proxy endpoints; healthy: ' + @($results | Where-Object Healthy).Count)
$results | Select-Object Uri, ProcessName, Healthy, HttpStatus | Format-Table -AutoSize
Write-Output 'Safe report saved to state/local-proxy-report.json. No original proxy settings were changed.'
