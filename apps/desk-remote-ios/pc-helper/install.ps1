# Installs the desk remote helper for the current user (no administrator rights needed):
#  1. writes %LOCALAPPDATA%\DeskRemote\config.json with a new random token, unless it exists;
#  2. registers a logon task "DeskRemoteHelper" that runs the helper hidden in this user's
#     interactive session (limited rights), and starts it now.
# The token stays in config.json (readable only by this user); it is never printed here.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -BindIp <ZeroTier address> -Network <CIDR>
param(
  [Parameter(Mandatory = $true)][string]$BindIp,
  [Parameter(Mandatory = $true)][string]$Network,
  [int]$Port = 18790,
  [string]$PcName = $env:COMPUTERNAME,
  [string]$Python = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$helper = Join-Path $here 'desk_remote_helper.py'
$folder = Join-Path $env:LOCALAPPDATA 'DeskRemote'
$config = Join-Path $folder 'config.json'
New-Item -ItemType Directory -Force -Path $folder | Out-Null

if (-not $Python) {
  $Python = (Get-Command pythonw.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  if (-not $Python) { throw 'pythonw.exe not found; pass -Python <path to pythonw.exe>' }
}

if (Test-Path $config) {
  Write-Output "Keeping the existing $config"
} else {
  $bytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  $cfg = [ordered]@{ pc_name = $PcName; bind_ip = $BindIp; port = $Port; allowed_networks = @($Network); token = $token }
  $json = $cfg | ConvertTo-Json -Depth 4
  [IO.File]::WriteAllText($config, $json, (New-Object Text.UTF8Encoding $false))
  # Only this user (and SYSTEM) may read the token.
  icacls $config /inheritance:r /grant:r "$($env:USERNAME):(R,W)" "SYSTEM:(F)" | Out-Null
  Write-Output "Wrote $config with a new token (open it on this PC to copy the token to the phone)."
}

$action = New-ScheduledTaskAction -Execute $Python -Argument "`"$helper`" --config `"$config`"" -WorkingDirectory $here
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'DeskRemoteHelper' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'DeskRemoteHelper'
Write-Output 'Registered and started the logon task DeskRemoteHelper.'
