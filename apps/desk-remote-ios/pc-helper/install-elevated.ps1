# One-time setup of the elevated companion. Run it yourself in an administrator PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-elevated.ps1
# It:
#  1. copies desk_remote_elevated.ps1 into %ProgramData%\DeskRemote\bin, a folder only
#     Administrators and SYSTEM can change (the elevated task never runs a user-writable file);
#  2. creates %ProgramData%\DeskRemote\elevated.json (admin-only) with a new approval key and a
#     submit token, unless it exists;
#  3. writes the submit token (not the key) to %LOCALAPPDATA%\DeskRemote\elevate-submit.json for
#     this user, so the helper and the elevate command can reach the companion;
#  4. adds the "elevate" command (a small elevate.cmd in %LOCALAPPDATA%\Microsoft\WindowsApps);
#  5. registers the logon task "DeskRemoteElevated" (highest privileges, this user, interactive)
#     and starts it;
#  6. shows the approval key once, to type into the phone (the PC's edit form, admin approval key).
# It does not change UAC or any other security setting. Run it again to update the companion;
# the key is kept. Delete elevated.json and run again to make a new key.
param([string]$Python = '')
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this in an administrator PowerShell (right-click PowerShell > Run as administrator).'
}
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Join-Path $env:ProgramData 'DeskRemote'
$bin = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
# Administrators and SYSTEM only, for the folder and everything in it.
icacls $root /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
Copy-Item -Force (Join-Path $here 'desk_remote_elevated.ps1') (Join-Path $bin 'desk_remote_elevated.ps1')

$config = Join-Path $root 'elevated.json'
function Random-Hex([int]$n) {
  $bytes = New-Object byte[] $n
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}
$fresh = -not (Test-Path $config)
if ($fresh) {
  $cfg = [ordered]@{ port = 18799; elevate_key = (Random-Hex 32); submit_token = (Random-Hex 24) }
  [IO.File]::WriteAllText($config, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}
$cfg = [IO.File]::ReadAllText($config) | ConvertFrom-Json

$userDir = Join-Path $env:LOCALAPPDATA 'DeskRemote'
New-Item -ItemType Directory -Force -Path $userDir | Out-Null
$submit = Join-Path $userDir 'elevate-submit.json'
$submitCfg = [ordered]@{ port = [int]$cfg.port; submit_token = "$($cfg.submit_token)" }
[IO.File]::WriteAllText($submit, ($submitCfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
# The signed-in account, not $env:USERDOMAIN: over SSH that is WORKGROUP, which is no account.
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls $submit /inheritance:r /grant:r "$($user):(R,W)" '*S-1-5-18:(F)' | Out-Null

if (-not $Python) { $Python = (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if ($Python) {
  $apps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
  $cmd = "@`"$Python`" `"$(Join-Path $here 'elevate.py')`" %*`r`n"
  [IO.File]::WriteAllText((Join-Path $apps 'elevate.cmd'), $cmd, (New-Object Text.ASCIIEncoding))
  # Git Bash does not find .cmd files by their bare name, and cmd.exe would re-parse quotes and
  # pipes; this wrapper hands the arguments to Python unchanged.
  $sh = "#!/bin/sh`nexec `"$($Python -replace '\\', '/')`" `"$((Join-Path $here 'elevate.py') -replace '\\', '/')`" `"`$@`"`n"
  [IO.File]::WriteAllText((Join-Path $apps 'elevate'), $sh, (New-Object Text.ASCIIEncoding))
} else {
  Write-Output 'python.exe not found: the elevate command was not added (pass -Python <path to python.exe>).'
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $bin 'desk_remote_elevated.ps1')`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'DeskRemoteElevated' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Stop-ScheduledTask -TaskName 'DeskRemoteElevated' -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName 'DeskRemoteElevated'
Write-Output 'Registered and started the logon task DeskRemoteElevated (highest privileges).'
Write-Output 'Restart the desk remote helper so it picks up elevate-submit.json.'
Write-Output ''
if ($fresh) { Write-Output 'New approval key. Type it into the phone (DeskRemote > edit this PC > admin approval key):' }
else { Write-Output 'Approval key (unchanged). It is only needed again on a new phone:' }
Write-Output "  $($cfg.elevate_key)"
Write-Output 'Keep it only on the phone; the helper and the AI never need it.'
