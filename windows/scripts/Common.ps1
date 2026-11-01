Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Load exported PS 5.1 module functions into this script scope, rather than
# relying on auto-loading from a short-lived helper function scope.
Import-Module Microsoft.PowerShell.Utility -Scope Local
Import-Module NetTCPIP -Scope Local
$script:PackageRoot = Split-Path -Parent $PSScriptRoot
$script:StateRoot = Join-Path $script:PackageRoot 'state'
function Ensure-StateDirectory {
    if (!(Test-Path -LiteralPath $script:StateRoot)) { New-Item -ItemType Directory -Path $script:StateRoot | Out-Null }
}
function Write-JsonFile($Value, [string]$Path) {
    $text = $Value | ConvertTo-Json -Depth 40
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}
function Read-JsonFile([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function New-RandomSecret {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [Convert]::ToBase64String($bytes)
}
function Protect-PrivateFile([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    $name = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($name, 'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('SYSTEM', 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-Listeners {
    @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
}
function Find-FreePort([int]$First, [int[]]$Reserved = @()) {
    for ($candidate = $First; $candidate -lt ($First + 100); $candidate++) {
        if ($Reserved -contains $candidate) { continue }
        $probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $candidate)
        try { $probe.Start(); return $candidate } catch { } finally { $probe.Stop() }
    }
    throw "No free local port near $First."
}
function Get-CorePath {
    if (![Environment]::Is64BitOperatingSystem) { throw 'This package contains an AMD64 Windows core and requires 64-bit Windows.' }
    $processor = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($processor -and [int]$processor.Architecture -ne 9) { throw 'This package core is Windows AMD64. Obtain the correct official core and update its provenance for ARM64 or other architectures.' }
    $paths = @((Join-Path $script:PackageRoot 'bin/mihomo.exe'))
    if (${env:ProgramFiles}) { $paths += (Join-Path ${env:ProgramFiles} 'Clash Verge/verge-mihomo.exe') }
    if (${env:LOCALAPPDATA}) { $paths += (Join-Path ${env:LOCALAPPDATA} 'Programs/Clash Verge/verge-mihomo.exe') }
    $command = Get-Command mihomo.exe -ErrorAction SilentlyContinue
    if ($command) { $paths += $command.Source }
    $running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('mihomo.exe', 'verge-mihomo.exe', 'clash-meta.exe') }
    foreach ($item in $running) { if ($item.ExecutablePath) { $paths += $item.ExecutablePath } }
    foreach ($path in ($paths | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $resolved = (Resolve-Path -LiteralPath $path).Path
            $packaged = [IO.Path]::GetFullPath((Join-Path $script:PackageRoot 'bin/mihomo.exe'))
            if ($resolved -eq $packaged) {
                $manifestPath = Join-Path $script:PackageRoot 'PROVENANCE.json'
                if (!(Test-Path -LiteralPath $manifestPath)) { throw 'Packaged core has no provenance manifest. Verify its official source before use.' }
                $manifest = Read-JsonFile $manifestPath
                $expectedHash = [string](Get-PropertyValue $manifest.core 'sha256' '')
                if (!$expectedHash -or (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Packaged Mihomo hash does not match PROVENANCE.json. Do not execute it; verify or replace it from the official source.' }
            }
            return $resolved
        }
    }
    throw 'No Mihomo core found. Ask the deploying Codex to verify the official core and place it in bin/mihomo.exe.'
}
function Get-CurlPath {
    $command = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (!$command) { throw 'Windows curl.exe is required for real HTTPS proxy checks.' }
    $command.Source
}
function Test-HttpsProxy([string]$Uri) {
    $curl = Get-CurlPath
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $curl
    $startInfo.Arguments = '--silent --show-error --head --output NUL --write-out "%{http_code}" --proxy "' + $Uri + '" --connect-timeout 3 --max-time 6 https://chatgpt.com/robots.txt'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $text = $process.StandardOutput.ReadToEnd()
        # Curl's detailed error can contain local data; keep only its exit code.
        $null = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally { $process.Dispose() }
    [pscustomobject]@{ Healthy = ($exitCode -eq 0 -and $text.Trim() -eq '200'); HttpStatus = $(if ($text.Trim() -match '^\d{3}$') { $text.Trim() } else { '' }); ExitCode = $exitCode; TestUrl = 'https://chatgpt.com/robots.txt'; TlsVerification = 'enabled' }
}
function Get-ProxyDescription([string]$Value, [string]$Origin) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $uri = $null
    if ($Value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $Value = 'http://' + $Value }
    if (![Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return }
    if ($uri.Scheme -notin @('http', 'https', 'socks5', 'socks5h')) { return }
    $localNames = @('localhost', '127.0.0.1', '::1')
    if ($localNames -notcontains $uri.Host.Trim('[', ']')) { return }
    if ($uri.UserInfo) {
        return [pscustomobject]@{ Uri = ''; Host = $uri.Host; Port = $uri.Port; Origin = $Origin; CredentialsPresent = $true }
    }
    $scheme = $uri.Scheme
    if ($scheme -eq 'socks5') { $scheme = 'socks5h' }
    [pscustomobject]@{ Uri = ($scheme + '://127.0.0.1:' + $uri.Port); Host = '127.0.0.1'; Port = $uri.Port; Origin = $Origin; CredentialsPresent = $false }
}
function Get-RuleSourceCandidates {
    $paths = @()
    if ($env:APPDATA) {
        $paths += (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml')
        $paths += (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev/config.yaml')
        $paths += (Join-Path $env:APPDATA 'clash-verge/clash-verge.yaml')
    }
    if ($env:USERPROFILE) { $paths += (Join-Path $env:USERPROFILE '.config/clash/config.yaml') }
    @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
}
function Read-SafeLocalRules([string]$Path) {
    $content = [IO.File]::ReadAllText($Path)
    if ($content.TrimStart().StartsWith('{')) {
        $obj = $content | ConvertFrom-Json
        return @(Get-PropertyValue $obj 'rules' @())
    }
    $inside = $false
    $rules = New-Object Collections.Generic.List[string]
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^rules\s*:\s*(?:#.*)?$') { $inside = $true; continue }
        if (!$inside) { continue }
        if ($line -match '^\S' -and $line -notmatch '^-\s') { break }
        if ($line -match '^\s*-\s+(.+?)\s*$') {
            $rule = $Matches[1].Trim()
            if (($rule.StartsWith("'") -and $rule.EndsWith("'")) -or ($rule.StartsWith('"') -and $rule.EndsWith('"'))) { $rule = $rule.Substring(1, $rule.Length - 2) }
            $rule = ($rule -replace '\s+#.*$', '').Trim()
            if ($rule) { $rules.Add($rule) }
        }
    }
    @($rules.ToArray())
}
function Invoke-GuestApi([string]$Path, [string]$Method = 'GET', $Body = $null, [int]$TimeoutSec = 8) {
    $config = Read-JsonFile (Join-Path $script:StateRoot 'config.json')
    $runtime = Read-JsonFile (Join-Path $script:StateRoot 'deployment.json')
    $request = [Net.HttpWebRequest]::Create('http://127.0.0.1:' + $runtime.ApiPort + $Path)
    $request.Proxy = $null
    $request.Method = $Method
    $request.Timeout = $TimeoutSec * 1000
    $request.Headers['Authorization'] = 'Bearer ' + $config.secret
    if ($null -ne $Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 40 -Compress))
        $request.ContentType = 'application/json'
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
    if ($text) { $text | ConvertFrom-Json }
}
