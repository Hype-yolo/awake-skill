#!/bin/bash
# Run from this directory: sudo /bin/bash ./uninstall.sh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset ENV BASH_ENV CDPATH
umask 077
die() { echo "awake uninstall: $*" >&2; exit 1; }
[[ $(/usr/bin/uname -s) == Darwin && $(/usr/bin/id -u) == 0 ]] || die 'Run with sudo on macOS.'
HELPER=/Library/PrivilegedHelperTools/org.awake-skill
PLIST=/Library/LaunchDaemons/org.awake-skill.plist
SUDOERS=/etc/sudoers.d/awake-skill
STATE=/var/db/org.awake-skill
for file in "$HELPER" "$PLIST" "$SUDOERS"; do
  [[ ! -L "$file" ]] || die "Refusing symlink: $file"
  if [[ -e "$file" ]]; then
    [[ -f "$file" && $(/usr/bin/stat -f %u "$file") == 0 ]] || die "Unsafe file: $file"
    mode=$(/usr/bin/stat -f %Lp "$file")
    [[ $((8#$mode & 0022)) == 0 ]] || die "Writable file: $file"
  fi
done
[[ ! -L "$STATE" ]] || die 'Unsafe state directory'
if [[ -e "$STATE" ]]; then
  [[ -d "$STATE" && $(/usr/bin/stat -f '%u:%Lp' "$STATE") == '0:700' ]] || die 'Unsafe state directory'
fi
# Revoke new passwordless requests first; retain helper and watchdog if restore fails.
/bin/rm -f "$SUDOERS"
if [[ -f "$HELPER" ]]; then
  "$HELPER" stop || die 'Restore failed; helper and watchdog retained. Retry uninstall after resolving pmset failure.'
elif [[ -e "$STATE/deadline" ]]; then
  die 'Lease exists but helper is missing. Restore the helper before uninstalling.'
fi
/bin/launchctl bootout system/org.awake-skill 2>/dev/null || true
if /bin/launchctl print system/org.awake-skill >/dev/null 2>&1; then
  die 'Watchdog is still loaded; files retained. Retry uninstall.'
fi
/bin/rm -f "$HELPER" "$PLIST"
if [[ -d "$STATE" ]]; then
  /bin/rm -f "$STATE/deadline.new" "$STATE/watchdog-error.log"
  /bin/rmdir "$STATE" || die 'Unknown state files remain; inspect the state directory manually.'
fi
echo 'Uninstalled. Any sleep-disable setting not managed by awake-skill was preserved.'
