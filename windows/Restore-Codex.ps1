#Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
$recordPath = Join-Path $script:StateRoot 'codex-integration.json'
if (!(Test-Path -LiteralPath $recordPath)) { throw 'No tracked Codex integration exists for this package.' }
$record = Read-JsonFile $recordPath
$expected = [string](Get-PropertyValue $record 'AppliedEnvHash' '')
if (!$expected -or !(Test-Path -LiteralPath $record.EnvPath -PathType Leaf)) { throw 'Tracked applied .env or its hash is unavailable. Stop and manually review/merge the local backup; no files were changed.' }
if ((Get-GuestFileHash -LiteralPath $record.EnvPath -Algorithm SHA256).Hash -ne $expected) { throw 'Codex .env was edited after guest integration. Stop and manually merge the backup; no subsequent user changes were overwritten.' }
if ($record.Backup) {
    if (!(Test-Path -LiteralPath $record.Backup -PathType Leaf)) { throw 'Original .env backup is missing. No files were changed.' }
    $backupHash = [string](Get-PropertyValue $record 'BackupSha256' '')
    if (!$backupHash -or (Get-GuestFileHash -LiteralPath $record.Backup -Algorithm SHA256).Hash -ne $backupHash) { throw 'Backup integrity differs from the recorded original. Review it manually; no files were changed.' }
    Copy-Item -LiteralPath $record.Backup -Destination $record.EnvPath -Force
    Protect-PrivateFile $record.EnvPath
    Write-Output 'Original Codex .env restored from its verified backup.'
} else {
    Remove-Item -LiteralPath $record.EnvPath
    Write-Output 'Package-created Codex .env removed after its applied hash was verified.'
}
Write-JsonFile ([ordered]@{ RestoredUtc = [DateTime]::UtcNow.ToString('o'); EnvPath = $record.EnvPath; HadOriginalBackup = [bool]$record.Backup }) (Join-Path $script:StateRoot 'last-codex-restore.json')
Remove-Item -LiteralPath $recordPath
Write-Output 'No running Codex process was terminated. Restart the client to use its restored environment.'
