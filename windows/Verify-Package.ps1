#Requires -Version 5.1
[CmdletBinding()]
param([switch]$VerifyOnly)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -Scope Local
$packageRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\','/')
$rootPrefix = $packageRoot + [IO.Path]::DirectorySeparatorChar
$manifestPath = Join-Path $packageRoot 'SHA256SUMS.txt'
if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Missing SHA256SUMS.txt; no files were executed or unblocked.' }
function Get-Sha256([string]$Path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}
function Assert-NoReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Package contains a reparse point; resolve the package location before verifying.' }
        if ($item.FullName.TrimEnd('\','/') -eq $packageRoot) { return }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
    throw 'Could not establish package containment.'
}
$seen = @{}
$verified = New-Object Collections.Generic.List[object]
foreach ($line in [IO.File]::ReadAllLines($manifestPath, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -notmatch '^([0-9a-fA-F]{64}) {2}(.+)$') { throw 'Malformed checksum manifest line; no files were unblocked.' }
    $expected = $Matches[1].ToLowerInvariant()
    $relative = $Matches[2]
    if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or @($relative -split '[\\/]' | Where-Object { $_ -eq '..' }).Count) { throw 'Checksum path is not a safe package-relative path.' }
    $path = [IO.Path]::GetFullPath((Join-Path $packageRoot $relative))
    if (!$path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or $path -eq $manifestPath) { throw 'Checksum path escapes the package or refers to the manifest itself.' }
    if ($seen.ContainsKey($path)) { throw 'Duplicate checksum path; manifest is ambiguous.' }
    $seen[$path] = $true
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Missing package file: ' + $relative) }
    Assert-NoReparsePoint $path
    if ((Get-Sha256 $path) -ne $expected) { throw ('Checksum mismatch: ' + $relative + '. No files were unblocked.') }
    $verified.Add([pscustomobject]@{ Path = $path; Sha256 = $expected })
}
if (!$verified.Count) { throw 'Checksum manifest is empty.' }
Write-Output ('Verified ' + $verified.Count + ' package files against SHA256SUMS.txt.')
if ($VerifyOnly) { Write-Output 'Verify-only mode; no download markers changed.'; return }
$count = 0
foreach ($file in $verified) {
    if ([IO.Path]::GetExtension($file.Path) -ne '.ps1') { continue }
    if ((Get-Sha256 $file.Path) -ne $file.Sha256) { throw 'A verified script changed before unblocking; stopped.' }
    Unblock-File -LiteralPath $file.Path
    $count++
}
Write-Output ('Removed download markers only from ' + $count + ' checksum-verified package scripts. Persistent execution policy was not changed.')
