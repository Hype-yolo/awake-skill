# macOS backend

This backend uses a narrowly privileged, root-owned helper and a launchd watchdog. A session accepts **1–1440 integer minutes**. Starting again replaces the deadline. The watchdog checks every 15 seconds, so normal expiry may take approximately 15 extra seconds; OS scheduling or command failures can delay recovery further. Closing the agent does not stop the watchdog. At boot, an old session is restored rather than resumed.

## Installation and commands

From the checked-out repository root, inspect the scripts, then run:

```sh
sudo /bin/bash awake/scripts/macos/install.sh
sudo -n /Library/PrivilegedHelperTools/org.awake-skill start 120
sudo -n /Library/PrivilegedHelperTools/org.awake-skill status
sudo -n /Library/PrivilegedHelperTools/org.awake-skill stop
```

Installation requires local administrator authentication. Never ask an agent to collect an administrator password. The installer derives the account from `SUDO_USER` and accepts only a conservative lowercase short-name syntax. It grants that account only this helper's start, stop, and status operations. The helper validates argument count and a decimal integer range; arbitrary commands and watchdog invocation are not allowed by the rule. There is no general passwordless sudo grant. Running the installer directly from a root shell is rejected.

The public helper uses `org.awake-skill`, independent of private/custom installations. The underlying power setting is still global: **do not run multiple sleep controllers simultaneously**. The helper refuses to start when sleep is already disabled without its own lease. Stop and uninstall preserve an unmanaged disabled-sleep setting. Installation also refuses to adopt an existing unmanaged disabled-sleep setting. Restore the other tool's setting through its owner first, if desired.

A fresh installation starts no session and changes no power setting. Existing managed sessions retain their deadline during an upgrade. Existing installed files and power-state output are backed up to a root-only temporary directory announced by the installer. Updating an installation replaces the sudoers account with the invoking account.

The helper writes its root-only lease before changing power settings. Failed enabling leaves the expiry safeguard armed. Failed restoration retains the lease so the watchdog can retry. Corrupt lease content is treated as expired. The timer uses system wall-clock time; changing the clock can shorten or extend its apparent duration. The lease directory is `/var/db/org.awake-skill`.

## What is actually controlled

`pmset -a disablesleep 1` and `SleepDisabled` inspection are empirical macOS behavior, **not a documented public Apple guarantee for closed-lid operation**. Compatibility can change across macOS releases and hardware. This backend requires checking the actual setting after every start/stop. It does not claim that an ordinary `caffeinate` assertion alone overrides the lid-close policy.

After start, verify all of:

```sh
sudo -n /Library/PrivilegedHelperTools/org.awake-skill status
pmset -g
launchctl print system/org.awake-skill
```

Expect `managed=1`, `enabled=1`, a deadline matching the requested duration, and a loaded watchdog. After stop, expect `managed=0` and `enabled=0` for a session owned by this tool. If the output reports `enabled=1 managed=0`, another owner has disabled sleep; report that state accurately.

These checks verify configuration and watchdog loading, not physical lid behavior. Test a short session on the actual laptop before relying on closed-lid operation. The public package has not undergone an actual lid-close test. Restoring the setting permits normal sleep policy; it does not force sleep or cancel assertions held by other applications. Keep the computer ventilated. No hotspot, network, display, or user-specific preference is configured by this backend.

## Uninstall

```sh
sudo /bin/bash awake/scripts/macos/uninstall.sh
```

Uninstall revokes new passwordless requests, stops a managed session, unloads the watchdog, and removes this package's installed files. If restore fails, it keeps the helper and watchdog for recovery and reports failure. Unmanaged sleep-disable settings are left intact. Unknown state-directory files are not recursively deleted. Do not start another session concurrently with uninstall.

## Offline validation

```sh
bash -n awake/scripts/macos/install.sh
bash -n awake/scripts/macos/uninstall.sh
sh -n awake/scripts/macos/root-helper.sh
python3 awake/scripts/macos/test-helper.py
```

The Python suite patches a temporary helper copy with mock clocks, power commands, root identity, launchd and file metadata. It never invokes real pmset or sudo. It covers deadline replacement, minimum/maximum duration, invalid arguments, expiry, reboot recovery, failure retries, malformed state, stale locks, unmanaged settings, missing watchdog, and the installer checksum. These tests do not validate a real privileged installation, launchd scheduling, physical lid behavior, or uninstall end to end.
