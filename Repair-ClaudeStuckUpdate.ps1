<#
.SYNOPSIS
    Recovers Claude Desktop (MSIX) from a stuck self-update without rebooting.

.DESCRIPTION
    Symptom: Claude Desktop quits on its own while idle (to install an update)
    and then refuses to start again until the machine is rebooted.

    Cause: the update has to delete the previous version's packaged Windows service,
    CoworkVMService. If any process holds an open handle to that service, the Service
    Control Manager can only mark it for deletion (DeleteFlag=1). The deployment times
    out after ~65 s (0x8007041D) and every later launch fails with 0x80070430
    ERROR_SERVICE_MARKED_FOR_DELETE. A reboot "fixes" it only because it closes every
    handle.

    This script releases the handle holders one step at a time, from least to most
    disruptive, and checks after each step whether the service is gone. As soon as it
    is, it launches Claude, which completes the pending update. The step that did it is
    written to the log so you learn which program is the culprit on your machine.

.PARAMETER IncludeDisruptive
    Also restart vmcompute/WSL (stops running WSL, Docker and Hyper-V VMs) and
    StateRepository (the Start menu may flicker).

.PARAMETER Unattended
    Used by the scheduled task: never runs the disruptive steps, never prompts.

.PARAMETER LogPath
    Log file. Defaults to repair.log next to this script.

.EXAMPLE
    PS> .\Repair-ClaudeStuckUpdate.ps1
.EXAMPLE
    PS> .\Repair-ClaudeStuckUpdate.ps1 -IncludeDisruptive
#>
[CmdletBinding()]
param(
    [switch]$IncludeDisruptive,
    [switch]$Unattended,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$ServiceName = 'CoworkVMService'
$ServiceKey  = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$Aumid       = 'Claude_pzs8sxrjxfjjc!Claude'
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'repair.log' }

# Third-party services known to hold the handle. Add yours here once repair.log has
# told you which one it is.
$KnownHolderServices = @(
    @{ Service = 'MBAMainService'; Label = 'Honor PC Manager'; Processes = @('HnPerformanceCenter', 'HnPerfPowerNexus') }
)

# ------------------------------------------------------------------------------

function Log([string]$Message, [string]$Color = 'Gray') {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    if (-not $Unattended) { Write-Host $line -ForegroundColor $Color }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Test-ServiceStuck {
    if (-not (Test-Path $ServiceKey)) { return $false }
    return ((Get-ItemProperty $ServiceKey -Name DeleteFlag -ErrorAction SilentlyContinue).DeleteFlag -eq 1)
}

function Wait-ServiceReleased([int]$Seconds = 10) {
    for ($i = 0; $i -lt $Seconds * 2; $i++) {
        if (-not (Test-ServiceStuck)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Restart-ServiceIfRunning([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc)                 { Log "  service $Name not installed, skipped"; return }
    if ($svc.Status -ne 'Running') { Log "  service $Name is $($svc.Status), skipped"; return }
    try   { Restart-Service -Name $Name -Force -ErrorAction Stop; Log "  restarted service $Name" }
    catch { Log "  could not restart $Name : $($_.Exception.Message)" 'Yellow' }
}

function Stop-ProcessesByName([string[]]$Names) {
    $found = Get-Process -Name $Names -ErrorAction SilentlyContinue
    if (-not $found) { Log "  no running process named $($Names -join ', ')"; return }
    foreach ($p in $found) {
        try   { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Log "  killed $($p.Name) (pid $($p.Id))" }
        catch { Log "  could not kill $($p.Name) (pid $($p.Id)): $($_.Exception.Message)" 'Yellow' }
    }
}

function Stop-ClaudePackageProcesses {
    $found = Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like '*\WindowsApps\Claude_*' }
    if (-not $found) { Log '  no leftover Claude package process'; return }
    foreach ($p in $found) {
        try   { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Log "  killed $($p.Name) (pid $($p.ProcessId))" }
        catch { Log "  could not kill $($p.Name) (pid $($p.ProcessId)): $($_.Exception.Message)" 'Yellow' }
    }
}

function Test-ClaudeRunning {
    [bool](Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like '*\WindowsApps\Claude_*\app\claude.exe' })
}

# ------------------------------------------------------------------------------

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell session (Run as Administrator).'
}

if (-not (Test-ServiceStuck)) {
    Log "$ServiceName is not stuck (no DeleteFlag) - nothing to do."
    return
}

Log '================ Repair-ClaudeStuckUpdate ================' 'Cyan'
Log ('installed package: {0}' -f (Get-AppxPackage -Name Claude).PackageFullName)
Log "$ServiceName has DeleteFlag=1: stuck pending delete." 'Yellow'

$steps = [System.Collections.Generic.List[hashtable]]::new()
$steps.Add(@{ Name = 'Leftover Claude package processes'; Run = { Stop-ClaudePackageProcesses } })
foreach ($h in $KnownHolderServices) {
    $steps.Add(@{ Name = "$($h.Label): restart service $($h.Service)"; Arg = $h.Service
                  Run  = { param($a) Restart-ServiceIfRunning $a } })
    if ($h.Processes) {
        $steps.Add(@{ Name = "$($h.Label): kill $($h.Processes -join ', ')"; Arg = $h.Processes
                      Run  = { param($a) Stop-ProcessesByName $a } })
    }
}
if (-not $Unattended) {
    $steps.Add(@{ Name = 'Service management tools (Task Manager, services.msc, Process Explorer)'
                  Run  = { Stop-ProcessesByName @('Taskmgr', 'mmc', 'procexp', 'procexp64', 'SystemInformer', 'ProcessHacker') } })
}
$steps.Add(@{ Name = 'AppX deployment service (AppXSvc)'; Run = { Restart-ServiceIfRunning 'AppXSvc' } })
$steps.Add(@{ Name = 'WMI (Winmgmt)';                     Run = { Restart-ServiceIfRunning 'Winmgmt' } })
if ($IncludeDisruptive -and -not $Unattended) {
    $steps.Add(@{ Name = 'Host Compute Service + WSL [stops running VMs]'; Run = { Restart-ServiceIfRunning 'WSLService'; Restart-ServiceIfRunning 'vmcompute' } })
    $steps.Add(@{ Name = 'State Repository [Start menu may flicker]';      Run = { Restart-ServiceIfRunning 'StateRepository' } })
}

$releasedBy = $null
foreach ($step in $steps) {
    Log "STEP: $($step.Name)" 'Cyan'
    & $step.Run $step.Arg
    if (Wait-ServiceReleased) { $releasedBy = $step.Name; break }
    Log '  -> still stuck'
}

if (-not $releasedBy) {
    Log 'None of the steps released the service.' 'Red'
    if (-not $IncludeDisruptive -and -not $Unattended) { Log 'Try again with -IncludeDisruptive, or reboot.' 'Yellow' }
    else                                               { Log 'A reboot is required this time.' 'Yellow' }
    return
}
Log "RELEASED BY: $releasedBy" 'Green'

# Launching Claude retries the pending package registration and completes the update.
Log 'Launching Claude to complete the pending update ...' 'Cyan'
if (-not (Test-ClaudeRunning)) {
    Start-Process explorer.exe "shell:AppsFolder\$Aumid"
    for ($i = 0; $i -lt 60 -and -not (Test-ClaudeRunning); $i++) { Start-Sleep -Seconds 2 }
}
Log ('installed package now: {0}' -f (Get-AppxPackage -Name Claude).PackageFullName)
if (Test-ClaudeRunning) { Log 'Claude is running.' 'Green' }
else                    { Log 'Claude did not start within 2 minutes; check the AppXDeploymentServer event log.' 'Red' }
