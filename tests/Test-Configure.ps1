# Requires -Version 5.1
# Uses synthetic identities and Mihomo -t only; never starts a proxy or changes system settings.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CorePath,
    [Parameter(Mandatory=$true)][string]$GeodataDirectory
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('guest-config-test-' + [Guid]::NewGuid().ToString('N'))
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    foreach ($case in @('wireguard-only','https','invalid-https')) {
        $package = Join-Path $testRoot $case
        foreach ($dir in @($package, "$package/scripts", "$package/bin", "$package/state")) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Copy-Item "$repo/windows/Configure-GuestProxy.ps1" $package
        Copy-Item "$repo/windows/scripts/Common.ps1" "$package/scripts"
        Copy-Item -LiteralPath $CorePath -Destination "$package/bin/mihomo.exe"
        foreach ($file in @('Country.mmdb','geosite.dat')) { Copy-Item -LiteralPath (Join-Path $GeodataDirectory $file) -Destination $package }
        @{ core = @{ sha256 = (Get-FileHash -LiteralPath $CorePath -Algorithm SHA256).Hash } } | ConvertTo-Json -Depth 4 | Set-Content "$package/PROVENANCE.json" -Encoding UTF8
        $key = [Convert]::ToBase64String([byte[]](1..32))
        @{ server='203.0.113.10'; port=51820; address='10.77.0.10/32'; privateKey=$key; publicKey=$key; presharedKey=$key; mtu=1280 } | ConvertTo-Json | Set-Content "$package/guest-credentials.json" -Encoding UTF8
        @{ ComputerName=$env:COMPUTERNAME; GeneratedUtc=[DateTime]::UtcNow.ToString('o'); Candidates=@(); RuleSources=@() } | ConvertTo-Json | Set-Content "$package/state/local-proxy-report.json" -Encoding UTF8
        if ($case -ne 'wireguard-only') {
            $uuid = '11111111-1111-4111-8111-111111111111'
            if ($case -eq 'invalid-https') { $uuid = 'REPLACE_WITH_DEVICE_UUID' }
            @{ server='203.0.113.20'; port=443; uuid=$uuid; servername='your-tunnel.example.com'; path='/test' } | ConvertTo-Json | Set-Content "$package/https-credentials.json" -Encoding UTF8
        }
        if ($case -eq 'invalid-https') {
            $rejected = $false
            try { & "$package/Configure-GuestProxy.ps1" } catch { if ($_.Exception.Message -like 'HTTPS uuid*') { $rejected=$true } else { throw } }
            Assert $rejected 'Placeholder UUID was accepted.'
            Assert (!(Test-Path "$package/state/config.json")) 'Invalid HTTPS credentials produced a configuration.'
        } else {
            & "$package/Configure-GuestProxy.ps1"
            $config = Get-Content "$package/state/config.json" -Raw | ConvertFrom-Json
            $group = $config.'proxy-groups'[0]
            $route = 'AUTO'
            if ($case -eq 'https') {
                $route = 'AzureHTTPS'
                Assert (($group.proxies -join ',') -eq 'AzureHTTPS,AzureGuest') 'HTTPS fallback order is incorrect.'
                $node = $config.proxies | Where-Object name -eq 'AzureHTTPS'
                Assert ($node.tls -and $node.network -eq 'ws' -and $node.'ws-opts'.headers.Host -eq $node.servername) 'HTTPS TLS/WebSocket settings are incorrect.'
            } else { Assert (($group.proxies -join ',') -eq 'AzureGuest') 'WireGuard-only behavior changed.' }
            Assert (@($config.dns.nameserver).Count -eq 2) 'Expected two separate DoH endpoints.'
            Assert ($config.dns.nameserver[0] -eq ('https://1.1.1.1/dns-query#' + $route)) 'Wrong default DNS route.'
            Assert ($config.dns.'nameserver-policy'.'+.openai.com'[1] -eq ('https://1.0.0.1/dns-query#' + $route)) 'OpenAI DNS policy is incorrect.'
            Assert ($config.dns.listen -eq '127.0.0.1:0' -and !$config.tun.enable) 'Guest unexpectedly enabled system DNS or TUN.'
        }
        Write-Output ('PASS: ' + $case)
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or !(Split-Path -Leaf $resolved).StartsWith('guest-config-test-')) { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
