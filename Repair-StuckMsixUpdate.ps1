<#
.SYNOPSIS
    Recovers MSIX apps (Claude Desktop, Codex, ...) whose self-update got stuck on a
    packaged Windows service, without rebooting.

.DESCRIPTION
    Symptom: an MSIX app that ships its own Windows service quits to install an update
    and then either does not come back, or starts on the old version and never finishes
    updating. A reboot fixes it.

    Cause: the update has to delete the previous version's packaged service. If any
    process holds an open handle to that service, the Service Control Manager can only
    mark it for deletion (DeleteFlag=1). The deployment times out after ~65 s
    (0x8007041D, event 9628) and every later attempt fails with 0x80070430
    ERROR_SERVICE_MARKED_FOR_DELETE.

    This script finds every packaged service stuck with DeleteFlag=1, releases the
    handle holders one step at a time (least disruptive first) until all of them are
    gone, then relaunches each affected app so it completes the pending update. The
    step that did it is written to the log, so you learn which program is the culprit
    on your machine.

.PARAMETER IncludeDisruptive
    Also restart vmcompute/WSL (stops running WSL, Docker and Hyper-V VMs) and
    StateRepository (the Start menu may flicker).

.PARAMETER Unattended
    Used by the scheduled task: never runs the disruptive steps, no console output.

.PARAMETER LogPath
    Log file. Defaults to repair.log next to this script.

.EXAMPLE
    PS> .\Repair-StuckMsixUpdate.ps1
.EXAMPLE
    PS> .\Repair-StuckMsixUpdate.ps1 -IncludeDisruptive
#>
[CmdletBinding()]
param(
    [switch]$IncludeDisruptive,
    [switch]$Unattended,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$ServicesRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'repair.log' }

# Third-party services known to hold the handle. Add yours here once the log has told
# you which one it is.
$KnownHolderServices = @(
    # Holder confirmed as HnPerformanceCenter / HnPerfPowerNexus; MBAProcessWatcher restarts them within a second.
    @{ Service = 'MBAMainService'; Label = 'Honor PC Manager'; Processes = @('HnPerformanceCenter', 'HnPerfPowerNexus') }
)

# ------------------------------------------------------------------------------

function Log([string]$Message, [string]$Color = 'Gray') {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    if (-not $Unattended) { Write-Host $line -ForegroundColor $Color }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Get-StuckPackagedServices {
    # Packaged (MSIX) services left behind with DeleteFlag=1.
    foreach ($key in Get-ChildItem $ServicesRoot -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        if ($p.DeleteFlag -ne 1 -or -not $p.PackageFullName) { continue }

        # PackageFullName = Name_Version_Arch_ResourceId_PublisherId
        $parts = $p.PackageFullName -split '_'
        [pscustomobject]@{
            Service         = $key.PSChildName
            PackageFullName = $p.PackageFullName
            PackageName     = $parts[0]
            OldVersion      = $parts[1]
            FamilyName      = '{0}_{1}' -f $parts[0], $parts[-1]
            Aumid           = $p.AppUserModelId
        }
    }
}

function Wait-AllReleased([string[]]$Services, [int]$Seconds = 10) {
    for ($i = 0; $i -lt $Seconds * 2; $i++) {
        $left = @($Services | Where-Object {
            (Get-ItemProperty (Join-Path $ServicesRoot $_) -Name DeleteFlag -ErrorAction SilentlyContinue).DeleteFlag -eq 1 })
        if ($left.Count -eq 0) { return $true }
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

function Get-PackageProcesses([string]$PackageName) {
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "*\WindowsApps\$($PackageName)_*" }
}

function Stop-PackageProcesses([string[]]$PackageNames) {
    $found = @(foreach ($n in $PackageNames) { Get-PackageProcesses $n })
    if (-not $found) { Log '  no leftover process from the affected packages'; return }
    foreach ($p in $found) {
        try   { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Log "  killed $($p.Name) (pid $($p.ProcessId))" }
        catch { Log "  could not kill $($p.Name) (pid $($p.ProcessId)): $($_.Exception.Message)" 'Yellow' }
    }
}

function Get-InstalledVersion([string]$PackageName) {
    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { [string]$pkg.Version }
}

function Get-PendingTargetPackage([string]$OldFullName) {
    # Event 855 records every update attempt as "<old full name> is updating to <new full name>".
    $pattern = [regex]::Escape($OldFullName) + ' is updating to (\S+?)\.?(\s|$)'
    $events = Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' `
        -FilterXPath '*[System[(EventID=855)]]' -MaxEvents 500 -ErrorAction SilentlyContinue
    foreach ($e in $events) {   # newest first
        $m = [regex]::Match($e.Message, $pattern)
        if ($m.Success) { return $m.Groups[1].Value }
    }
}

function Get-LaunchAumid($Stuck) {
    if ($Stuck.Aumid) { return $Stuck.Aumid }
    $pkg = Get-AppxPackage -Name $Stuck.PackageName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { return $null }
    $appId = @(($pkg | Get-AppxPackageManifest).Package.Applications.Application)[0].Id
    if ($appId) { '{0}!{1}' -f $pkg.PackageFamilyName, $appId }
}

# ------------------------------------------------------------------------------

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell session (Run as Administrator).'
}

$stuck = @(Get-StuckPackagedServices)
if ($stuck.Count -eq 0) {
    Log 'No packaged service is stuck pending delete - nothing to do.'
    return
}

Log '================ Repair-StuckMsixUpdate ================' 'Cyan'
foreach ($s in $stuck) {
    Log ("STUCK: {0}  (package {1})" -f $s.Service, $s.PackageFullName) 'Yellow'
}
$serviceNames = @($stuck.Service)
$packageNames = @($stuck.PackageName | Select-Object -Unique)

$steps = [System.Collections.Generic.List[hashtable]]::new()
$steps.Add(@{ Name = 'Leftover processes from the affected packages'; Arg = $packageNames
              Run  = { param($a) Stop-PackageProcesses $a } })
foreach ($h in $KnownHolderServices) {
    # Killing the helper processes first: the vendor's watchdog restarts them at once,
    # which is less disruptive than restarting the whole service.
    if ($h.Processes) {
        $steps.Add(@{ Name = "$($h.Label): kill $($h.Processes -join ', ')"; Arg = $h.Processes
                      Run  = { param($a) Stop-ProcessesByName $a } })
    }
    $steps.Add(@{ Name = "$($h.Label): restart service $($h.Service)"; Arg = $h.Service
                  Run  = { param($a) Restart-ServiceIfRunning $a } })
}
if (-not $Unattended) {
    $steps.Add(@{ Name = 'Service management tools (Task Manager, services.msc, Process Explorer)'
                  Arg  = @('Taskmgr', 'mmc', 'procexp', 'procexp64', 'SystemInformer', 'ProcessHacker')
                  Run  = { param($a) Stop-ProcessesByName $a } })
}
$steps.Add(@{ Name = 'AppX deployment service (AppXSvc)'; Arg = 'AppXSvc'; Run = { param($a) Restart-ServiceIfRunning $a } })
$steps.Add(@{ Name = 'WMI (Winmgmt)';                     Arg = 'Winmgmt'; Run = { param($a) Restart-ServiceIfRunning $a } })
if ($IncludeDisruptive -and -not $Unattended) {
    $steps.Add(@{ Name = 'Host Compute Service + WSL [stops running VMs]'; Arg = @('WSLService', 'vmcompute')
                  Run  = { param($a) foreach ($n in $a) { Restart-ServiceIfRunning $n } } })
    $steps.Add(@{ Name = 'State Repository [Start menu may flicker]'; Arg = 'StateRepository'
                  Run  = { param($a) Restart-ServiceIfRunning $a } })
}

$releasedBy = $null
foreach ($step in $steps) {
    Log "STEP: $($step.Name)" 'Cyan'
    & $step.Run $step.Arg
    if (Wait-AllReleased $serviceNames) { $releasedBy = $step.Name; break }
    Log '  -> still stuck'
}

if (-not $releasedBy) {
    Log 'None of the steps released the service(s).' 'Red'
    if (-not $IncludeDisruptive -and -not $Unattended) { Log 'Try again with -IncludeDisruptive, or reboot.' 'Yellow' }
    else                                               { Log 'A reboot is required this time.' 'Yellow' }
    return
}
Log "RELEASED BY: $releasedBy" 'Green'

foreach ($s in $stuck) {
    # Complete the pending update by registering the already-staged new version.
    # Some apps (Claude) also retry this themselves on launch; others (Codex) only do it
    # from their own updater, so launching alone would just start the old version.
    $target = Get-PendingTargetPackage $s.PackageFullName
    if ($target -and $target -ne (Get-AppxPackage -Name $s.PackageName | Select-Object -First 1).PackageFullName) {
        Log "Registering pending update $target ..." 'Cyan'
        try   { Add-AppxPackage -Register -MainPackage $target -ForceApplicationShutdown -ErrorAction Stop; Log '  registered' 'Green' }
        catch { Log "  register failed: $($_.Exception.Message)" 'Yellow' }
    } else {
        Log "  no pending update found for $($s.PackageFullName) in the deployment log"
    }

    $aumid = Get-LaunchAumid $s
    if (-not $aumid) { Log "  cannot determine how to launch $($s.PackageName); start it manually" 'Yellow'; continue }

    Log "Launching $aumid ..." 'Cyan'
    if (-not (Get-PackageProcesses $s.PackageName)) { Start-Process explorer.exe "shell:AppsFolder\$aumid" }

    for ($i = 0; $i -lt 60; $i++) {
        if ((Get-InstalledVersion $s.PackageName) -ne $s.OldVersion -and (Get-PackageProcesses $s.PackageName)) { break }
        Start-Sleep -Seconds 2
    }
    $now = Get-InstalledVersion $s.PackageName
    if ($now -ne $s.OldVersion) { Log ("  {0}: {1} -> {2}" -f $s.PackageName, $s.OldVersion, $now) 'Green' }
    else                        { Log ("  {0}: still {1} after 2 minutes; check the AppXDeploymentServer event log" -f $s.PackageName, $now) 'Red' }
    if (Get-PackageProcesses $s.PackageName) { Log "  $($s.PackageName) is running." 'Green' }
}
