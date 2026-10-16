# Windows 10 / 11

Windows needs its own implementation. `caffeinate` and `pmset` are macOS tools. Windows has an explicit AC/DC lid-close action, power schemes and Task Scheduler. A process-only sleep assertion does not by itself change lid-close behavior.

## Run

First follow [per-user setup](setup.md) in the ordinary user context. Saved network preferences do not grant elevation. The power controller still requires administrator rights on each invocation; never disable UAC. From the repository root, `cd awake`. Open **Windows PowerShell as Administrator**, using native `powershell.exe` 5.1, not WSL or PowerShell 7. On 64-bit Windows use 64-bit PowerShell; the controller rejects 32-bit PowerShell on a 64-bit OS:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\awake.ps1 -Action start -Minutes 60
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\awake.ps1 -Action status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\awake.ps1 -Action stop
```

Duration is an integer from 1 to 1440 minutes. Starting again replaces the deadline from now while preserving the original scheme, provided the temporary plan is still active and its settings verify. An externally changed plan requires `stop` first. This does not connect to a named hotspot or store Wi-Fi credentials. Connect to the network of your choice and verify connectivity separately.

## What changes and how it recovers

The controller duplicates the current power scheme. Only that temporary copy receives six settings: AC and DC lid-close action = do nothing; idle sleep timeout = never; idle hibernate timeout = never. The original scheme and its settings are untouched. Screen timeout, power-button actions, critical-battery behavior and system-wide hibernation availability are untouched.

Before any power change, it installs a SYSTEM recovery task, then durably records original/temporary scheme GUIDs, expiry and boot identity. The task invokes a protected copy of the controller from `%ProgramFiles%\AwakeSkillRecovery`, with access restricted to Administrators and SYSTEM. The user checkout is never scheduled as SYSTEM. Recovery runs at expiry, once per minute for retries, and at startup; a changed boot identity ends the session immediately. It also repairs interrupted preparation. Manual stop uses the same recovery path. A file lock serializes controllers and recovery.

Restoration selects and verifies the original scheme before removing the temporary scheme and state. A failed restore retains the state and task for retry. If you manually change plans during a session, the original pre-session plan is still restored at the end. Do not edit/delete the original plan or the recovery directory/task while active. Stop first. If recovery reports an error, run `stop` again from an elevated shell and inspect the reported error. The original GUID is also in `state.json`; an administrator can manually run `powercfg /setactive ORIGINAL_GUID`. Do not remove recovery files until the original plan is active.

The task uses battery-compatible scheduling and missed-start recovery. Windows scheduling is not a hard real-time deadline: delayed scheduling, suspended machines and clock changes can delay restoration. Reboot recovery runs when Task Scheduler starts. Removing/disabling Task Scheduler, deleting the original scheme, disk failure or administrator interference can defeat automatic recovery.

## Acceptance and limits

Configured settings do not prove that a particular laptop stays awake with its lid closed. OEM firmware, Modern Standby, corporate policies and battery/thermal protection may override behavior. Unsupported `powercfg` operations fail and trigger rollback. If Windows refuses scheme duplication or lid settings, this implementation stops rather than changing system-wide policy. It does not force sleep at expiry; it restores the previous policy, after which Windows decides when to sleep. Keep ventilation clear; do not run a hot laptop inside a bag.

This release was authored on macOS. AC/DC values are read back after configuration and included in status. Mock lifecycle tests validate logic without changing power settings. **No physical Windows laptop lid-close, battery-mode, scheduled expiry or reboot test has been completed by the author.** Windows CI checks parsing and mocked lifecycle only. On a test laptop, check a short session with lid open first, inspect both AC/DC settings with `powercfg /query`, then test lid closed on AC and battery. Verify the original scheme after expiry, manual stop and reboot before relying on unattended work.

Offline test (no elevation and no power/task mutation):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\test-awake.ps1
```

## Uninstall

Run `stop`, then `status` and confirm there is no session. Verify the pre-session scheme is active with `powercfg /getactivescheme`. Only then, in elevated PowerShell, remove the recovery task (if left over) and the dedicated directory:

```powershell
Unregister-ScheduledTask -TaskName 'AwakeSkill-Recover-v1' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'AwakeSkillRecovery') -Recurse -Force
```

Never uninstall recovery while a session or failed restoration remains. Removing the repository checkout alone does not remove installed recovery files.

## Microsoft sources

- [Powercfg command-line options](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options): duplicate, select, query and edit schemes.
- [Lid switch close action](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/power-button-and-lid-settings-lid-switch-close-action): `LIDACTION`, AC/DC and value 0.
- [Register-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/register-scheduledtask): task registration.
- [New-ScheduledTaskSettingsSet](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasksettingsset): battery and missed-start settings.
