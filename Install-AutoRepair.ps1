<#
.SYNOPSIS
    Installs (or removes) a scheduled task that automatically repairs MSIX app updates
    stuck on a packaged Windows service (Claude Desktop, Codex, ...).

.DESCRIPTION
    Registers the task "MsixStuckUpdateAutoRepair". It fires on event 9628 in
    Microsoft-Windows-AppXDeploymentServer/Operational ("PackagedServiceDEH failed to
    delete service"), which is logged exactly when an MSIX update gets stuck deleting
    its old service. The task runs Repair-StuckMsixUpdate.ps1 -Unattended, which
    releases every stuck packaged service and relaunches the affected apps.

    The script is copied to %ProgramData%\MsixStuckUpdateAutoRepair and locked down so
    only administrators can modify it: the task runs elevated and must not execute a
    file an ordinary user can edit.

    Idle cost is zero - no polling, no resident process. The event log service evaluates
    the EventID filter only for events written to that one channel.

    Also removes the task "ClaudeAutoHeal" installed by earlier versions of this repo.

.PARAMETER Uninstall
    Removes the task and %ProgramData%\MsixStuckUpdateAutoRepair.

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

$TaskName   = 'MsixStuckUpdateAutoRepair'
$InstallDir = Join-Path $env:ProgramData 'MsixStuckUpdateAutoRepair'
$Script     = Join-Path $InstallDir 'Repair-StuckMsixUpdate.ps1'
$Log        = Join-Path $InstallDir 'repair.log'

# Task and folder from earlier, Claude-only versions of this repo.
$LegacyTask = 'ClaudeAutoHeal'
$LegacyDir  = Join-Path $env:ProgramData 'ClaudeAutoHeal'
if (Get-ScheduledTask -TaskName $LegacyTask -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $LegacyTask -Confirm:$false
    Write-Host "Removed legacy scheduled task '$LegacyTask'"
}
if (Test-Path $LegacyDir) {
    Remove-Item -Recurse -Force $LegacyDir
    Write-Host "Removed legacy folder $LegacyDir"
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$TaskName' and $InstallDir" -ForegroundColor Green
    return
}

# 1) Install the script where only administrators can change it.
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'Repair-StuckMsixUpdate.ps1') $Script
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
# user's desktop session to relaunch the apps.
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Force `
    -Description 'Releases packaged services left pending delete by a stuck MSIX update (Claude Desktop, Codex, ...) and relaunches the apps. https://github.com/OF12138/Claude-Desktop-Update-Fix' `
    -Trigger $trigger -Action $action -Principal $taskPrincipal -Settings $settings | Out-Null

Write-Host "Scheduled task '$TaskName' registered (trigger: AppXDeploymentServer event 9628)." -ForegroundColor Green
Write-Host "Script: $Script"
Write-Host "Log:    $Log"
