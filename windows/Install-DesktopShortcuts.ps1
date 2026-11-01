#Requires -Version 5.1
[CmdletBinding()]
param([string]$Destination='')
if (!$Destination) { $Destination=[Environment]::GetFolderPath('Desktop') }
if (!(Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination | Out-Null }
$shell=New-Object -ComObject WScript.Shell
$items=@(@('AzureGuest-Start','Start-GuestProxy.ps1'),@('AzureGuest-Stop','Stop-GuestProxy.ps1'),@('AzureGuest-Check','Test-GuestDeployment.ps1'))
foreach ($item in $items) {
    $path=Join-Path $Destination ($item[0]+'.lnk');$script=Join-Path $PSScriptRoot $item[1];$link=$shell.CreateShortcut($path)
    if ((Test-Path -LiteralPath $path) -and !$link.Arguments.Contains($script)) { throw 'Shortcut name belongs to another deployment.' }
    $link.TargetPath=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $link.Arguments='-NoProfile -ExecutionPolicy RemoteSigned -NoExit -File "'+$script+'"'
    if ($item[1] -eq 'Test-GuestDeployment.ps1') { $link.Arguments += ' -TestHttps' }
    $link.WorkingDirectory=$PSScriptRoot;$link.Save()
}
Write-Output 'Current-user Start/Stop/Check shortcuts created. Their paths were generated on this computer.'
