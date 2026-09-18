# Claude Desktop Update Fix

Fixes the **MSIX build of Claude Desktop** on Windows when it quits by itself and then
refuses to start again until you reboot.

- `Repair-ClaudeStuckUpdate.ps1` gets Claude running again in a few seconds, with no reboot.
- `Install-AutoRepair.ps1` sets up a scheduled task that does this for you every time it happens.

---

## Symptom

- Claude Desktop is open and idle. At some point it closes on its own.
- Clicking the Claude icon, the Start menu entry or the taskbar pin does nothing. No
  window appears and no error is shown.
- Rebooting fixes it, and Claude comes back with a newer version.
- A few days later it happens again.

## What is actually going on

### 1. The "crash" is a silent self-update

Claude Desktop installs updates in the background. After downloading one, it waits
until you are idle, then quits so that Windows can swap the package. From
`%LOCALAPPDATA%\Claude\logs\main.log`:

```
[updater] Update downloaded and ready to install { releaseName: 'Claude 2.2553.0' }
...
[stealth-update] Triggering stealth update after idle timeout
beforeQuitForUpdate handler fired, going down for update
```

### 2. The update fails deleting the old Windows service

The MSIX package contains a Windows service, `CoworkVMService` (`cowork-svc.exe`,
which runs the Cowork virtual machine). An update has to delete the old version's
service before it can register the new one. From
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

The Windows Service Control Manager cannot delete a service while any process
still holds an open handle to it. Instead it marks the service for deletion, and the
service disappears only when the last handle is closed:

```
HKLM\SYSTEM\CurrentControlSet\Services\CoworkVMService
    DeleteFlag    REG_DWORD    0x1
```

From that point on, every launch of Claude makes Windows retry the pending update first,
and every retry fails straight away:

```
404  AppX Deployment operation failed for package Claude_2.2553.0.0_x64__pzs8sxrjxfjjc
     with error 0x80073CF9 ... unknown error 0x80070430 in determining which apps need
     to be closed.
```

`0x80070430` is `ERROR_SERVICE_MARKED_FOR_DELETE`. Claude never gets started.

### 4. Why a reboot fixes it

A reboot closes every handle. The service is deleted during boot, and the next launch
completes the update. On the machine this was diagnosed on, the pattern was:
update stuck at 14:26, reboot at 22:49, new service installed at 22:50.

### 5. Who holds the handle

On the machine this was diagnosed on it was **Honor PC Manager** (荣耀电脑管家, service
`MBAMainService`, together with its `HnPerformanceCenter` / `HnPerfPowerNexus` processes).
Restarting that service released the handle immediately. Five seconds later Claude had
updated and was running.

Why a system utility would do this is an inference, because the software is closed
source. Tools that watch services typically use `NotifyServiceStatusChange`, which keeps
a handle open to every service being monitored. The API documentation says that when the
caller receives `SERVICE_NOTIFY_DELETE_PENDING` it must close that handle, or the service
cannot be deleted. A monitor that misses this blocks the deletion until it is restarted.
`CoworkVMService` is an auto-start `LocalSystem` service that gets reinstalled on every
Claude update, which makes it exactly the kind of service security, optimiser and
performance tools watch.

**On your machine the culprit may be different.** The repair script tries the likely
holders one by one and logs which step worked (see below).

Windows provides no supported way to list which processes hold a Service Control Manager
handle. These are RPC context handles inside `services.exe`, so neither Process Explorer
nor `handle.exe` shows them. Releasing candidates one at a time and watching `DeleteFlag`
is the practical way to find the holder.

---

## Requirements

- Windows 10 / 11 with the **MSIX** build of Claude Desktop
  (`Get-AppxPackage -Name Claude` returns a package)
- An elevated PowerShell session

## Fix it now

Open PowerShell with **Run as administrator**:

```powershell
git clone https://github.com/OF12138/Claude-Desktop-Update-Fix.git
cd Claude-Desktop-Update-Fix
powershell -ExecutionPolicy Bypass -File .\Repair-ClaudeStuckUpdate.ps1
```

If `CoworkVMService` has no `DeleteFlag`, the script says so and exits without changing
anything. Otherwise it tries these steps in order, from least to most disruptive. After
each step it checks whether the service is gone:

| # | Step |
|---|------|
| 1 | Kill leftover processes from the Claude package |
| 2 | Honor PC Manager: restart `MBAMainService` (skipped if not installed) |
| 3 | Honor PC Manager: kill `HnPerformanceCenter`, `HnPerfPowerNexus` |
| 4 | Close Task Manager, `services.msc`, Process Explorer (manual runs only) |
| 5 | Restart `AppXSvc` |
| 6 | Restart WMI (`Winmgmt`) |
| 7 | `-IncludeDisruptive` only: restart WSL + `vmcompute` (stops running WSL/Docker/Hyper-V VMs) |
| 8 | `-IncludeDisruptive` only: restart `StateRepository` (Start menu may flicker) |

When the service is gone, the script launches Claude, which completes the pending update.
Everything is written to `repair.log`, including the line that tells you who the
culprit was:

```
STEP: Honor PC Manager: restart service MBAMainService
  restarted service MBAMainService
RELEASED BY: Honor PC Manager: restart service MBAMainService
installed package now: Claude_2.2553.0.0_x64__pzs8sxrjxfjjc
Claude is running.
```

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

This registers a scheduled task named `ClaudeAutoHeal`. It is triggered by event
**9628** in `Microsoft-Windows-AppXDeploymentServer/Operational`, which is logged exactly
when a Claude update fails to delete `CoworkVMService`. The task runs
`Repair-ClaudeStuckUpdate.ps1 -Unattended`. That releases the service using only the
non-disruptive steps and relaunches Claude. After an automatic update you get Claude
back within about two minutes, without doing anything.

- Script location: `%ProgramData%\ClaudeAutoHeal\`. It is locked so that only
  administrators can modify it, because the task runs elevated.
- Log: `%ProgramData%\ClaudeAutoHeal\heal.log`
- Remove: `.\Install-AutoRepair.ps1 -Uninstall`

### Does the task cost anything?

- **When nothing is happening: nothing.** An event-triggered task does not poll and has
  no resident process. The Windows Event Log service tests the `EventID=9628` filter only
  against events written to that one channel. That is a single integer comparison per
  event, and on the test machine the channel received about 900 events a day, almost all
  in the few seconds around app installs.
- **How often it fires:** only on a stuck Claude update. Event 9628 appeared exactly
  twice in the test machine's log, once per incident.
- **When it fires:** it reads one registry value and exits immediately if nothing is
  stuck. Otherwise it spends up to about 45 seconds waiting for the handle to be
  released, checking every 0.5 seconds, and then up to 2 minutes waiting for Claude to
  start. The CPU is essentially idle during these waits.

### Does it affect Honor PC Manager?

Only when it fires. `MBAMainService` is restarted and brings its helper processes back
by itself within about a second. Its other processes (tray UI, cloud service, update
service) are not touched. Afterwards Honor PC Manager runs normally, and so does Claude.
The two programs do not depend on each other.

## Related

- The update also resets Claude's low-resolution taskbar icon. See
  [ClaudeDesktopIconFix](https://github.com/OF12138/ClaudeDesktopIconFix), which can
  re-apply its fix automatically after every update.
- If you moved `vm_bundles` to another drive with a junction: `cowork-svc` runs as
  `LocalSystem` and deliberately refuses to follow junctions
  (`vm_bundles is a symlink or junction, refusing to open` in `main.log`). Cowork will
  not start that way. This is unrelated to the update problem.

## Disclaimer

This is an unofficial community fix. It is not affiliated with or endorsed by Anthropic
or Honor. Use at your own risk.

## License

[MIT](LICENSE)
