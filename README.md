# MSIX Update Fix for Claude Desktop, Codex and other apps

Fixes Windows desktop apps distributed as **MSIX packages that include their own
Windows service** when their self-update gets stuck, and a reboot is the only thing that
brings them back. Confirmed with:

| App | Packaged service |
|---|---|
| Claude Desktop (Anthropic) | `CoworkVMService` |
| Codex (OpenAI) | `CodexSandboxService.OpenAI.Codex` |

The fix is generic: it handles any MSIX packaged service stuck in this state.

- `Repair-StuckMsixUpdate.ps1` gets the app updated and running again within seconds,
  with no reboot.
- `Install-AutoRepair.ps1` installs a scheduled task that runs the repair automatically
  every time this happens.

---

## Symptom

One of these, and a reboot fixes both:

- **Claude Desktop** closes by itself while you are idle. After that, clicking its icon
  does nothing: no window opens and no error is shown.
- **Codex** restarts to install an update, but no window comes back. If you start it
  by hand it opens, but it is still the old version and the update never completes.

In both cases the same thing happens again a few days later, with the next update.

## What is actually going on

The diagnosis below uses Claude Desktop. Codex produced exactly the same event sequence,
with the same 65-second gap.

### 1. The app quits to update itself

Claude Desktop installs updates silently. After downloading one, it waits until you are
idle, then quits so that Windows can swap the package. From
`%LOCALAPPDATA%\Claude\logs\main.log`:

```
[updater] Update downloaded and ready to install { releaseName: 'Claude 2.2553.0' }
[stealth-update] Triggering stealth update after idle timeout
beforeQuitForUpdate handler fired, going down for update
```

### 2. The update fails deleting the old Windows service

Both apps ship a Windows service inside the MSIX package. An update has to delete the
old version's service before it can register the new one. From
`Microsoft-Windows-AppXDeploymentServer/Operational`:

```
09:26:43.679  9650  Successfully terminated service ... CoworkVMService
09:26:43.936  9622  PackagedServiceDEH EvaluateRequest completed successfully
                    <- 65 seconds of nothing ->
09:27:48.945  9628  PackagedServiceDEH failed to delete service CoworkVMService
09:27:48.954   306  error 0x8007041D: ... the service did not respond to the start or
                    control request in a timely fashion
09:27:48.958   300  error 0x80073CF6: Cannot register the Claude_pzs8sxrjxfjjc package
```

The service had already stopped by then. What Windows spent 65 seconds waiting for was
the service entry itself to disappear.

### 3. The service is left "marked for deletion"

The Windows Service Control Manager cannot delete a service while any process still
holds an open handle to it. Instead it marks the service for deletion, and the service
disappears only when the last handle is closed:

```
HKLM\SYSTEM\CurrentControlSet\Services\CoworkVMService
    DeleteFlag    REG_DWORD    0x1
```

From then on, every launch of the app makes Windows retry the pending update first, and
every retry fails straight away:

```
404  AppX Deployment operation failed for package Claude_2.2553.0.0_x64__pzs8sxrjxfjjc
     with error 0x80073CF9 ... unknown error 0x80070430 in determining which apps need
     to be closed.
```

`0x80070430` is `ERROR_SERVICE_MARKED_FOR_DELETE`. Claude Desktop then does not start
at all. Codex starts, but only on the old version.

### 4. Why a reboot fixes it

A reboot closes every handle. The service is deleted during boot, and the next launch
completes the update.

### 5. Who holds the handle

On the machine this was diagnosed on it was **Honor PC Manager** (荣耀电脑管家), more
precisely one of its performance-management processes, **`HnPerformanceCenter` or
`HnPerfPowerNexus`**:

- For Claude, restarting its main service `MBAMainService` released the handle. That
  restart also restarted both `HnPerf*` processes.
- For Codex, restarting `MBAMainService` did **not** help. This time the `HnPerf*`
  processes were not restarted, because they are supervised by a separate watchdog,
  `MBAProcessWatcher.exe`, which kept running. Killing the two `HnPerf*` processes
  released the handle immediately, and the watchdog started them again in the same
  second.

Two unrelated apps from two vendors failing the same way points at the machine, not at
either app.

Why a system utility would do this is an inference, because the software is closed
source. Tools that watch services typically use `NotifyServiceStatusChange`, which keeps
a handle open to every service being monitored. The API documentation says that when the
caller receives `SERVICE_NOTIFY_DELETE_PENDING` it must close that handle, or the service
cannot be deleted. A monitor that misses this blocks the deletion until it is restarted.
Packaged services are reinstalled on every app update, and they are often auto-start
`LocalSystem` services, which makes them exactly the kind of service that security,
optimiser and performance tools watch.

**On your machine the culprit may be different.** The repair script tries the likely
holders one by one and logs which step worked (see below).

Windows provides no supported way to list which processes hold a Service Control Manager
handle. These are RPC context handles inside `services.exe`, so neither Process Explorer
nor `handle.exe` shows them. Releasing candidates one at a time and watching `DeleteFlag`
is the practical way to find the holder.

### Check whether you are affected

```powershell
Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Services | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.DeleteFlag -eq 1 -and $p.PackageFullName) { "$($_.PSChildName)  ->  $($p.PackageFullName)" }
}
```

Any output means a packaged service is stuck and that app's update cannot complete.

---

## Requirements

- Windows 10 / 11
- An elevated PowerShell session

## Fix it now

Open PowerShell with **Run as administrator**:

```powershell
git clone https://github.com/OF12138/Claude-Desktop-Update-Fix.git
cd Claude-Desktop-Update-Fix
powershell -ExecutionPolicy Bypass -File .\Repair-StuckMsixUpdate.ps1
```

The script finds every packaged service with `DeleteFlag=1`. If there are none, it says
so and exits without changing anything. Otherwise it tries these steps in order, from
least to most disruptive, and after each step checks whether all the stuck services are
gone:

| # | Step |
|---|------|
| 1 | Kill leftover processes from the affected packages |
| 2 | Honor PC Manager: kill `HnPerformanceCenter`, `HnPerfPowerNexus` (restarted by its watchdog at once) |
| 3 | Honor PC Manager: restart `MBAMainService` (skipped if not installed) |
| 4 | Close Task Manager, `services.msc`, Process Explorer (manual runs only) |
| 5 | Restart `AppXSvc` |
| 6 | Restart WMI (`Winmgmt`) |
| 7 | `-IncludeDisruptive` only: restart WSL + `vmcompute` (stops running WSL/Docker/Hyper-V VMs) |
| 8 | `-IncludeDisruptive` only: restart `StateRepository` (Start menu may flicker) |

When the services are gone, the script completes each pending update itself:

1. It looks up the version the update was trying to install. Event 855 in the deployment
   log records every attempt as `<old package> is updating to <new package>`.
2. It registers that already-downloaded package with
   `Add-AppxPackage -Register -MainPackage <new package> -ForceApplicationShutdown`.
   This step matters. Claude retries the registration by itself when it is launched,
   but Codex only registers from its own updater. Launching Codex after the release
   merely starts the old version again, and the update never completes.
3. It launches the app, using the `AppUserModelId` recorded in the service's registry
   key or the package manifest, and waits until the new version is running.

Everything goes to `repair.log`, including a `RELEASED BY` line that names the culprit.
From the Codex incident:

```
STUCK: CodexSandboxService.OpenAI.Codex  (package OpenAI.Codex_26.915.3509.0_x64__2p2nqsd0c76g0)
STEP: Leftover processes from the affected packages
  no leftover process from the affected packages
  -> still stuck
STEP: Honor PC Manager: restart service MBAMainService
  restarted service MBAMainService
  -> still stuck
STEP: Honor PC Manager: kill HnPerformanceCenter, HnPerfPowerNexus
  killed HnPerformanceCenter (pid 7048)
  killed HnPerfPowerNexus (pid 21060)
RELEASED BY: Honor PC Manager: kill HnPerformanceCenter, HnPerfPowerNexus
```

The step order shown there is from before the `HnPerf*` step was moved to the front. In
that run the update was then completed by registering
`OpenAI.Codex_26.915.4065.0_x64__2p2nqsd0c76g0` as described above.

If none of the steps works, run it again with `-IncludeDisruptive`, or reboot.

### If your culprit is something else

When `repair.log` points at a different program, add it to `$KnownHolderServices` at
the top of the script. Its steps then run early, and the scheduled task uses them too.

```powershell
$KnownHolderServices = @(
    @{ Service = 'MBAMainService'; Label = 'Honor PC Manager'; Processes = @('HnPerformanceCenter', 'HnPerfPowerNexus') }
    @{ Service = 'SomeOtherSvc';   Label = 'Some Other Tool';  Processes = @() }
)
```

## Fix it automatically from now on

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-AutoRepair.ps1
```

This registers a scheduled task named `MsixStuckUpdateAutoRepair`. It is triggered by
event **9628** in `Microsoft-Windows-AppXDeploymentServer/Operational`, which Windows
logs exactly when an MSIX update fails to delete a packaged service, whichever app it
belongs to. The task runs `Repair-StuckMsixUpdate.ps1 -Unattended`. That releases the
service using only the non-disruptive steps and relaunches the app. After an automatic
update you get the app back within about two minutes, without doing anything.

- Script location: `%ProgramData%\MsixStuckUpdateAutoRepair\`. It is locked so that
  only administrators can modify it, because the task runs elevated.
- Log: `%ProgramData%\MsixStuckUpdateAutoRepair\repair.log`
- Remove: `.\Install-AutoRepair.ps1 -Uninstall`
- Upgrading from the earlier Claude-only version: just run the installer. It removes the
  old `ClaudeAutoHeal` task and folder.

### Does the task cost anything?

- **When nothing is happening: nothing.** An event-triggered task does not poll and has
  no resident process. The Windows Event Log service tests the `EventID=9628` filter only
  against events written to that one channel. That is a single integer comparison per
  event, and on the test machine the channel received about 900 events a day, almost all
  in the few seconds around app installs.
- **How often it fires:** only on a stuck update. On the test machine event 9628
  appeared three times in total: twice for Claude, once for Codex.
- **When it fires:** it scans the service keys in the registry and exits immediately if
  nothing is stuck. Otherwise it spends up to about a minute waiting for the handle to
  be released, checking every 0.5 seconds, and then up to 2 minutes per app waiting for
  it to update and start. The CPU is essentially idle during these waits.

### Does it affect Honor PC Manager?

Only when it fires. The first thing it does is kill `HnPerformanceCenter` and
`HnPerfPowerNexus`. Honor's watchdog `MBAProcessWatcher.exe` starts them again within
the same second, so performance management pauses for about a second. The script
restarts `MBAMainService` only if that was not enough, and that restart also takes
about a second. Honor PC Manager's other processes (tray UI, cloud service, update
service) are never touched. Afterwards Honor PC Manager runs normally, and so do the
repaired apps. None of them depend on each other.

## Related

- Claude Desktop before 2.9939.2.0 shipped a 24x24 taskbar icon that looked blurry on a
  high-DPI display; 2.9939.2.0 fixed that and changed the artwork from a transparent
  star glyph to an opaque rounded square. Either way, every update resets the icon. See
  [ClaudeDesktopIconFix](https://github.com/OF12138/ClaudeDesktopIconFix), which writes
  the artwork of your choice and can re-apply it automatically after every update.
- Claude Cowork and `vm_bundles` junctions: `cowork-svc` runs as `LocalSystem` and
  deliberately refuses to follow junctions, symlinks and hard links
  (`vm_bundles is a symlink or junction, refusing to open` in `main.log`). This is to
  stop a user-level process from redirecting its SYSTEM-level writes. Moving
  `vm_bundles` to another drive with a junction therefore disables Cowork. This is
  unrelated to the update problem.

## Disclaimer

This is an unofficial community fix. It is not affiliated with or endorsed by Anthropic,
OpenAI or Honor. Use at your own risk.

## License

[MIT](LICENSE)
