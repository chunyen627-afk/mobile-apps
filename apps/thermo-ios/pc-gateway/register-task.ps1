# Registers the gateway as a Windows scheduled task for the current user (no administrator
# rights needed): starts at logon and is started again by a 1-minute repeat whenever it is
# not running (crash, killed). MultipleInstances IgnoreNew keeps a single instance.
# Task Scheduler's own "restart on failure" only covers a failed launch, so the repeat is what
# brings back a gateway that died later.
#
#   powershell -ExecutionPolicy Bypass -File register-task.ps1 -Python <pythonw.exe>
#   Start-ScheduledTask ThermoGateway         # start now
#   Unregister-ScheduledTask ThermoGateway    # remove
param(
    [Parameter(Mandatory = $true)][string]$Python,           # full path to pythonw.exe
    [string]$Dir = $PSScriptRoot,                             # folder with thermo_gateway.py and the config
    [string]$Config = 'thermo-gateway.json',
    [string]$TaskName = 'ThermoGateway'
)
$action = New-ScheduledTaskAction -Execute $Python `
    -Argument "`"$Dir\thermo_gateway.py`" --config `"$Dir\$Config`"" -WorkingDirectory $Dir
$user = "$env:USERDOMAIN\$env:USERNAME"
$logon = New-ScheduledTaskTrigger -AtLogOn -User $user
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $repeat) `
    -Settings $settings -Principal $principal -Description 'Bluetooth thermometer gateway (thermo-ios pc-gateway)' -Force |
    Select-Object TaskName, State
