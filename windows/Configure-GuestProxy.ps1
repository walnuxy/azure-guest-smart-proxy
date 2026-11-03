# Requires -Version 5.1
[CmdletBinding()]
param([string]$RuleSourcePath = '')
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
Ensure-StateDirectory
$listenerStatePath = Join-Path $script:StateRoot 'listener.json'
if (Test-Path -LiteralPath $listenerStatePath) {
    $trackedListener = Read-JsonFile $listenerStatePath
    $trackedProcess = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $trackedListener.ListenerPid) -ErrorAction SilentlyContinue
    if ($trackedProcess -and $trackedProcess.ExecutablePath -eq $trackedListener.CorePath -and $trackedProcess.CommandLine.Contains($trackedListener.ConfigPath)) { throw 'Stop this package instance before regenerating its configuration.' }
}
$reportPath = Join-Path $script:StateRoot 'local-proxy-report.json'
if (!(Test-Path -LiteralPath $reportPath)) { throw 'Run Inspect-LocalProxy.ps1 on THIS computer before configuring.' }
$report = Read-JsonFile $reportPath
if ($report.ComputerName -ne $env:COMPUTERNAME -or ([DateTime]::UtcNow - [DateTime]::Parse($report.GeneratedUtc).ToUniversalTime()).TotalMinutes -gt 30) { throw 'Inspection is stale or belongs to another computer. Run Inspect-LocalProxy.ps1 again.' }
$credentialPath = Join-Path $PSScriptRoot 'guest-credentials.json'
if (!(Test-Path -LiteralPath $credentialPath)) { throw 'Missing guest-credentials.json. Do not substitute the administrator SSH key or the owner VPN configuration.' }
$guest = Read-JsonFile $credentialPath
foreach ($field in @('server','port','address','privateKey','publicKey','presharedKey')) {
    if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $guest $field ''))) { throw ('Missing guest credential field: ' + $field) }
}
foreach ($field in @('privateKey','publicKey','presharedKey')) {
    try { $key = [Convert]::FromBase64String($guest.$field) } catch { throw ('Invalid guest key encoding: ' + $field) }
    if ($key.Length -ne 32) { throw ('Invalid guest key length: ' + $field) }
}
$core = Get-CorePath
$mixedPort = Find-FreePort 17890
$apiPort = Find-FreePort 19090 @($mixedPort)
$proxies = New-Object Collections.Generic.List[object]
$azure = [ordered]@{ name = 'AzureGuest'; type = 'wireguard'; server = $guest.server; port = [int]$guest.port; ip = ([string]$guest.address).Split('/')[0]; 'private-key' = $guest.privateKey; 'public-key' = $guest.publicKey; 'pre-shared-key' = $guest.presharedKey; 'allowed-ips' = @('0.0.0.0/0'); 'persistent-keepalive' = 25; udp = $true; mtu = [int](Get-PropertyValue $guest 'mtu' 1280); 'remote-dns-resolve' = $true; dns = @('tcp://1.1.1.1:53','tcp://8.8.8.8:53') }
$azure['ip-stack'] = [ordered]@{ mode = 'mips'; 'congestion-controller' = 'bbr3' }
$proxies.Add($azure)
$names = New-Object Collections.Generic.List[string]
$names.Add('AzureGuest')
# Optional HTTPS identity is issued separately for each device.
$httpsPath = Join-Path $PSScriptRoot 'https-credentials.json'
$dnsRoute = 'AUTO'
if (Test-Path -LiteralPath $httpsPath) {
    $https = Read-JsonFile $httpsPath
    foreach ($field in @('server','port','uuid','servername','path')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $https $field ''))) { throw ('Missing HTTPS credential field: ' + $field) }
    }
    $identity = [Guid]::Empty
    if (![Guid]::TryParse([string]$https.uuid, [ref]$identity) -or $identity -eq [Guid]::Empty) { throw 'HTTPS uuid must be an issued, nonzero UUID.' }
    if ([int]$https.port -lt 1 -or [int]$https.port -gt 65535) { throw 'Invalid HTTPS port.' }
    if (!([string]$https.path).StartsWith('/')) { throw 'HTTPS WebSocket path must start with /.' }
    $proxies.Add([ordered]@{ name = 'AzureHTTPS'; type = 'vless'; server = [string]$https.server; port = [int]$https.port; uuid = [string]$https.uuid; tls = $true; servername = [string]$https.servername; network = 'ws'; 'ws-opts' = @{ path = [string]$https.path; headers = @{ Host = [string]$https.servername } }; udp = $true })
    $names.Insert(0, 'AzureHTTPS')
    $dnsRoute = 'AzureHTTPS'
    Protect-PrivateFile $httpsPath
}
$usedPorts = @()
$fallbacks = @()
foreach ($candidate in @($report.Candidates | Where-Object Healthy)) {
    if ($candidate.Port -eq $mixedPort -or $usedPorts -contains $candidate.Port) { continue }
    # Re-test immediately before use; a listener that was healthy at inspection
    # may have disappeared or changed in the intervening minutes.
    $health = Test-HttpsProxy $candidate.Uri
    if (!$health.Healthy) { continue }
    $uri = [Uri]$candidate.Uri
    $name = 'LocalBackup-' + ($usedPorts.Count + 1)
    $type = 'http'
    if ($uri.Scheme.StartsWith('socks')) { $type = 'socks5' }
    $proxy = [ordered]@{ name = $name; type = $type; server = '127.0.0.1'; port = [int]$candidate.Port }
    if ($uri.Scheme -eq 'https') { $proxy.tls = $true }
    $proxies.Add($proxy); $names.Add($name); $usedPorts += [int]$candidate.Port
    $fallbacks += [pscustomobject]@{ Name = $name; Uri = $candidate.Uri; ProcessName = $candidate.ProcessName }
    if ($usedPorts.Count -ge 4) { break }
}
if (!$RuleSourcePath) {
    $best = @($report.RuleSources | Sort-Object RuleCount -Descending) | Select-Object -First 1
    if ($best -and $best.RuleCount -gt 0) { $RuleSourcePath = $best.Path }
}
$rules = New-Object Collections.Generic.List[string]
foreach ($domain in @('chatgpt.com','openai.com','oaistatic.com','oaiusercontent.com')) { $rules.Add('DOMAIN-SUFFIX,' + $domain + ',AUTO') }
$sourceCount = 0; $keptCount = 0; $skippedCount = 0
if ($RuleSourcePath) {
    if (!(Test-Path -LiteralPath $RuleSourcePath -PathType Leaf)) { throw 'Selected local rule source does not exist.' }
    foreach ($rule in @(Read-SafeLocalRules $RuleSourcePath)) {
        $sourceCount++
        $parts = $rule.Split(',')
        if ($parts.Length -lt 2) { $skippedCount++; continue }
        if ($parts[0] -eq 'MATCH' -or $rule -match '^IP-CIDR,0\.0\.0\.0/0,' -or $rule -match '^IP-CIDR6,::/0,') { continue }
        if ($parts[0] -notin @('DOMAIN','DOMAIN-SUFFIX','DOMAIN-KEYWORD','DOMAIN-REGEX','IP-CIDR','IP-CIDR6','GEOIP','GEOSITE','DST-PORT','NETWORK','PROCESS-NAME','PROCESS-PATH')) { $skippedCount++; continue }
        $target = $parts.Length - 1
        if ($parts[$target] -eq 'no-resolve') { $target-- }
        if ($parts[$target] -notin @('DIRECT','REJECT','REJECT-DROP')) { $parts[$target] = 'AUTO' }
        $rules.Add(($parts -join ',')); $keptCount++
    }
}
foreach ($rule in @('DOMAIN-SUFFIX,local,DIRECT','IP-CIDR,127.0.0.0/8,DIRECT,no-resolve','IP-CIDR,10.0.0.0/8,DIRECT,no-resolve','IP-CIDR,172.16.0.0/12,DIRECT,no-resolve','IP-CIDR,192.168.0.0/16,DIRECT,no-resolve','GEOSITE,cn,DIRECT','GEOIP,CN,DIRECT','MATCH,AUTO')) { $rules.Add($rule) }
foreach ($file in @('Country.mmdb','geosite.dat')) {
    $dataPath = Join-Path (Join-Path $PSScriptRoot 'data') $file
    if (!(Test-Path -LiteralPath $dataPath)) { $dataPath = Join-Path $PSScriptRoot $file }
    if (!(Test-Path -LiteralPath $dataPath)) { throw ('Missing public geodata: ' + $file + '. Ask the deploying Codex to verify and supply it before proceeding.') }
    Copy-Item -LiteralPath $dataPath -Destination (Join-Path $script:StateRoot $file) -Force
}
$cnDns = @('https://dns.alidns.com/dns-query#DIRECT','https://doh.pub/dns-query#DIRECT')
$proxyDns = @(('https://1.1.1.1/dns-query#' + $dnsRoute), ('https://1.0.0.1/dns-query#' + $dnsRoute))
$dnsPolicy = @{ 'geosite:cn' = $cnDns }
foreach ($domain in @('chatgpt.com','openai.com','oaistatic.com','oaiusercontent.com')) { $dnsPolicy['+.' + $domain] = $proxyDns }
$config = [ordered]@{ 'mixed-port' = $mixedPort; 'allow-lan' = $false; 'bind-address' = '127.0.0.1'; mode = 'rule'; 'log-level' = 'info'; ipv6 = $false; 'external-controller' = ('127.0.0.1:' + $apiPort); secret = (New-RandomSecret); tun = @{ enable = $false }; 'geodata-mode' = $false; dns = @{ enable = $true; listen = '127.0.0.1:0'; ipv6 = $false; 'enhanced-mode' = 'redir-host'; 'default-nameserver' = @('223.5.5.5','119.29.29.29'); nameserver = $proxyDns; 'nameserver-policy' = $dnsPolicy; 'proxy-server-nameserver' = $cnDns; 'direct-nameserver' = $cnDns }; proxies = @($proxies.ToArray()); 'proxy-groups' = @(@{ name = 'AUTO'; type = 'fallback'; proxies = @($names.ToArray()); url = 'https://chatgpt.com/robots.txt'; 'expected-status' = 200; interval = 30; timeout = 5000; lazy = $false }); rules = @($rules.ToArray()) }
$configPath = Join-Path $script:StateRoot 'config.json'
if (Test-Path -LiteralPath $configPath) { Copy-Item -LiteralPath $configPath -Destination ($configPath + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
Write-JsonFile $config $configPath
Protect-PrivateFile $configPath
Protect-PrivateFile $credentialPath
# Configuration validation can initialize local geodata, but cannot start
# listeners, TUN, a Windows service or change any system proxy settings.
& $core -t -d $script:StateRoot -f $configPath
if ($LASTEXITCODE -ne 0) { throw 'Mihomo rejected the generated configuration. Do not start or integrate it.' }
$deployment = [ordered]@{ SchemaVersion = 1; GeneratedUtc = [DateTime]::UtcNow.ToString('o'); ComputerName = $env:COMPUTERNAME; CorePath = $core; CoreSha256 = (Get-GuestFileHash -LiteralPath $core -Algorithm SHA256).Hash; MixedPort = $mixedPort; ApiPort = $apiPort; Fallbacks = $fallbacks; RuleSource = $RuleSourcePath; SourceRuleCount = $sourceCount; MigratedRuleCount = $keptCount; SkippedRuleCount = $skippedCount; TotalRuleCount = $rules.Count; TunEnabled = $false; SystemProxyModified = $false }
Write-JsonFile $deployment (Join-Path $script:StateRoot 'deployment.json')
Write-Output ('Validated guest configuration. HTTP/SOCKS entry: 127.0.0.1:' + $mixedPort)
Write-Output ('Healthy local backups: ' + $fallbacks.Count + '; migrated local rules: ' + $keptCount + '; unsupported rules skipped: ' + $skippedCount)
Write-Output 'Configuration is not started or integrated. No existing proxy, subscription, system settings or Codex files were changed.'
