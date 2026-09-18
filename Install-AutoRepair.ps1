<#
.SYNOPSIS
    Installs (or removes) a scheduled task that repairs a stuck Claude Desktop update
    automatically.

.DESCRIPTION
    Registers the task "ClaudeAutoHeal". It fires on event 9628 in
    Microsoft-Windows-AppXDeploymentServer/Operational ("PackagedServiceDEH failed to
    delete service"), which is logged exactly when a Claude update gets stuck on
    CoworkVMService. The task runs Repair-ClaudeStuckUpdate.ps1 -Unattended, which
    releases the service and relaunches Claude.

    The script is copied to %ProgramData%\ClaudeAutoHeal and locked down so only
    administrators can modify it: the task runs elevated and must not execute a file an
    ordinary user can edit.

    Idle cost is zero - no polling, no resident process. The event log service evaluates
    the EventID filter only for events written to that one channel.

.PARAMETER Uninstall
    Removes the task and %ProgramData%\ClaudeAutoHeal.

.EXAMPLE
    PS> .\Install-AutoRepair.ps1
.EXAMPLE
    PS> .\Install-AutoRepair.ps1 -Uninstall
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell session (Run as Administrator).'
}

$TaskName   = 'ClaudeAutoHeal'
$InstallDir = Join-Path $env:ProgramData 'ClaudeAutoHeal'
$Script     = Join-Path $InstallDir 'Repair-ClaudeStuckUpdate.ps1'
$Log        = Join-Path $InstallDir 'heal.log'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$TaskName' and $InstallDir" -ForegroundColor Green
    return
}

# 1) Install the script where only administrators can change it.
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'Repair-ClaudeStuckUpdate.ps1') $Script
# SYSTEM and Administrators: full control. Users: read/execute.
& icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

# 2) Trigger: AppXDeploymentServer event 9628.
$subscription = @'
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-AppXDeploymentServer/Operational">
    <Select Path="Microsoft-Windows-AppXDeploymentServer/Operational">*[System[(EventID=9628)]]</Select>
  </Query>
</QueryList>
'@
$triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
$trigger.Subscription = $subscription
$trigger.Enabled      = $true

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" -Unattended -LogPath `"$Log`""

# Runs as the logged-on user, elevated: admin rights to restart services, and the
# user's desktop session to relaunch Claude.
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Force `
    -Description 'Releases CoworkVMService when a Claude Desktop update gets stuck deleting it, then relaunches Claude. https://github.com/OF12138/Claude-Desktop-Update-Fix' `
    -Trigger $trigger -Action $action -Principal $taskPrincipal -Settings $settings | Out-Null

# Files from earlier revisions of this installer.
Remove-Item -Force (Join-Path $InstallDir 'Invoke-ClaudeAutoHeal.ps1') -ErrorAction SilentlyContinue

Write-Host "Scheduled task '$TaskName' registered (trigger: AppXDeploymentServer event 9628)." -ForegroundColor Green
Write-Host "Script: $Script"
Write-Host "Log:    $Log"
