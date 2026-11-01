# Requires -Version 5.1
[CmdletBinding()]
param([switch]$TestHttps)
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
$deployment = Read-JsonFile (Join-Path $script:StateRoot 'deployment.json')
$state = Invoke-GuestApi '/proxies/AUTO'
Write-Output ('HTTP entry: http://127.0.0.1:' + $deployment.MixedPort)
Write-Output ('SOCKS entry: socks5h://127.0.0.1:' + $deployment.MixedPort)
Write-Output ('Current route: ' + $state.now)
if ($TestHttps) {
    $uri = 'http://127.0.0.1:' + $deployment.MixedPort
    $health = Test-HttpsProxy $uri
    Write-Output ('OpenAI HEAD health: ' + $health.Healthy + '; HTTP ' + $health.HttpStatus + '; TLS validation enabled')
    if (!$health.Healthy) { throw 'Guest proxy failed the actual HTTPS check.' }
    $curl = Get-CurlPath
    $response = @(& $curl --silent --show-error --proxy $uri --connect-timeout 6 --max-time 12 https://chatgpt.com/cdn-cgi/trace 2>&1)
    $traceExit = $LASTEXITCODE
    foreach ($line in $response) { if ($line.ToString() -match '^(h|ip|loc|tls|colo)=') { Write-Output $line } }
    if ($traceExit -ne 0 -or !(($response -join "`n") -match '(?m)^h=chatgpt\.com\s*$')) { throw 'Guest proxy trace failed; do not claim Codex is ready.' }
}
