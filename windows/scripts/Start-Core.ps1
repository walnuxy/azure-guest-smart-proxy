# Internal core-only start helper. Called by the supervisor, never a detached launcher.
# Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Common.ps1')
Ensure-StateDirectory
if (Test-Path -LiteralPath (Join-Path $script:StateRoot 'disabled.flag')) { throw 'Guest proxy is persistently disabled; only explicit Start-GuestProxy.ps1 may enable it.' }
$deploymentPath = Join-Path $script:StateRoot 'deployment.json'
if (!(Test-Path -LiteralPath $deploymentPath)) { throw 'Inspect this computer, then run Configure-GuestProxy.ps1 first.' }
$deployment = Read-JsonFile $deploymentPath
if ($deployment.ComputerName -ne $env:COMPUTERNAME) { throw 'This deployment belongs to another computer. Inspect and configure locally.' }
$verifiedCore = Get-CorePath
if ($verifiedCore -ne $deployment.CorePath -or (Get-GuestFileHash -LiteralPath $verifiedCore -Algorithm SHA256).Hash -ne $deployment.CoreSha256) { throw 'The selected core changed since configuration. Re-inspect and reconfigure before starting; no unverified core was executed.' }
$configPath = Join-Path $script:StateRoot 'config.json'
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:PackageRoot))).Replace('-','').Substring(0,16) } finally { $sha.Dispose() }
$mutex = New-Object Threading.Mutex($false, ('Local\CodexGuestProxy-Core-' + $hash))
$locked = $false
try {
    try { $locked = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Another startup is in progress. Retry shortly.' }
    $listeners = Get-Listeners
    $existing = @($listeners | Where-Object { $_.LocalPort -eq $deployment.MixedPort -and $_.LocalAddress -in @('127.0.0.1','0.0.0.0','::1','::') }) | Select-Object -First 1
    $pidPath = Join-Path $script:StateRoot 'listener.json'
    if ($existing) {
        if (!(Test-Path -LiteralPath $pidPath)) { throw 'Configured proxy port is occupied by an unrelated process. Stop here and re-inspect; do not terminate it.' }
        $tracked = Read-JsonFile $pidPath
        $owner = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $existing.OwningProcess) -ErrorAction SilentlyContinue
        if ($existing.OwningProcess -ne $tracked.ListenerPid -or !$owner -or $owner.ExecutablePath -ne $deployment.CorePath -or !$owner.CommandLine.Contains($configPath)) { throw 'Configured port owner differs from the tracked guest instance; refusing to take it over.' }
        $version = Invoke-GuestApi '/version'
        Write-Output ('Guest proxy already running at http://127.0.0.1:' + $deployment.MixedPort + ' (' + $version.version + ')')
        return
    }
    $apiOccupied = @($listeners | Where-Object { $_.LocalPort -eq $deployment.ApiPort })
    if ($apiOccupied.Count) { throw 'Configured control port is occupied. Re-inspect and configure; do not stop the existing process.' }
    $arguments = '-d "' + $script:StateRoot + '" -f "' + $configPath + '"'
    $process = Start-Process -FilePath $deployment.CorePath -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $script:StateRoot 'stdout.log') -RedirectStandardError (Join-Path $script:StateRoot 'stderr.log') -PassThru
    $listener = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $process.Refresh()
        if ($process.HasExited) { throw 'Guest core exited before opening its local listener. The deploying Codex should inspect the local logs without exposing keys.' }
        $listener = @(Get-Listeners | Where-Object { $_.LocalPort -eq $deployment.MixedPort -and $_.OwningProcess -eq $process.Id }) | Select-Object -First 1
        if ($listener) { break }
        Start-Sleep -Milliseconds 100
    }
    if (!$listener) {
        if (!$process.HasExited) { Stop-Process -Id $process.Id }
        throw 'Guest proxy did not open its listener in time; its own process was stopped.'
    }
    Write-JsonFile ([ordered]@{ ListenerPid = [int]$listener.OwningProcess; CorePath = $deployment.CorePath; ConfigPath = $configPath; StartedUtc = [DateTime]::UtcNow.ToString('o'); MixedPort = $deployment.MixedPort; ApiPort = $deployment.ApiPort }) $pidPath
    $version = Invoke-GuestApi '/version'
    Write-Output ('Guest proxy ready at http://127.0.0.1:' + $deployment.MixedPort + '; actual listener PID ' + $listener.OwningProcess + '; core ' + $version.version)
    Write-Output 'System proxy, TUN, original local proxies and Codex settings remain unchanged.'
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
