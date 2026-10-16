#!/bin/sh
# Installed root-owned; no caller-controlled paths or configuration are read.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL
unset ENV BASH_ENV CDPATH
umask 077
STATE=/var/db/org.awake-skill
PMSET=/usr/bin/pmset
DATE=/bin/date
SYSCTL=/usr/sbin/sysctl
STAT=/usr/bin/stat
ID=/usr/bin/id
LAUNCHCTL=/bin/launchctl

fail() { echo "awake: $*" >&2; exit 1; }
[ "$("$ID" -u)" = 0 ] || fail 'root privileges required'
case "${1-}" in
  start)
    [ "$#" = 2 ] || fail 'usage: start <1..1440 minutes>'
    case "$2" in ''|*[!0-9]*|0*) fail 'minutes must be an integer from 1 to 1440';; esac
    [ "${#2}" -le 4 ] && [ "$2" -le 1440 ] || fail 'minutes out of range'
    "$LAUNCHCTL" print system/org.awake-skill >/dev/null 2>&1 || fail 'watchdog not loaded; run installer first'
    ;;
  stop|status|watchdog) [ "$#" = 1 ] || fail 'unexpected arguments';;
  *) fail 'allowed commands: start, stop, status, watchdog';;
esac
[ ! -L "$STATE" ] || fail 'state directory is a symlink'
if [ ! -e "$STATE" ]; then /bin/mkdir -m 700 "$STATE"; fi
[ -d "$STATE" ] && [ "$("$STAT" -f '%u:%Lp' "$STATE")" = '0:700' ] || fail 'unsafe state directory'
now=$("$DATE" +%s)
boot=$("$SYSCTL" -n kern.boottime | /usr/bin/awk '{print $4}' | /usr/bin/tr -d ',')
case "$now:$boot" in *[!0-9:]*|:*|*:) fail 'cannot read clock or boot time';; esac

# Serialize manual commands and launchd. Recover a lock left by a killed process.
tries=0
until /bin/mkdir "$STATE/lock" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -le 10 ] || fail 'controller busy; retry shortly'
  if [ "$("$STAT" -f %m "$STATE/lock")" -lt "$boot" ]; then
    /bin/rm -f "$STATE/lock/pid"
    /bin/rmdir "$STATE/lock" 2>/dev/null || :
    continue
  fi
  if [ -f "$STATE/lock/pid" ] && [ ! -L "$STATE/lock/pid" ]; then
    lock_record=$(/bin/cat "$STATE/lock/pid")
    owner=${lock_record%%|*}
    owner_birth=${lock_record#*|}
    case "$owner" in ''|*[!0-9]*) :;; *)
      actual_birth=$(/bin/ps -p "$owner" -o lstart= 2>/dev/null || :)
      if ! kill -0 "$owner" 2>/dev/null || [ "$actual_birth" != "$owner_birth" ]; then
        /bin/rm -f "$STATE/lock/pid"
        /bin/rmdir "$STATE/lock" 2>/dev/null || :
      fi;;
    esac
  elif [ ! -e "$STATE/lock/pid" ]; then
    lock_age=$(( $("$DATE" +%s) - $("$STAT" -f %m "$STATE/lock") ))
    if [ "$lock_age" -gt 30 ]; then /bin/rmdir "$STATE/lock" 2>/dev/null || :; fi
  fi
  /bin/sleep 1
done
printf '%s|%s\n' "$$" "$(/bin/ps -p $$ -o lstart=)" > "$STATE/lock/pid"
cleanup() { /bin/rm -f "$STATE/lock/pid"; /bin/rmdir "$STATE/lock" 2>/dev/null || :; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

now=$("$DATE" +%s)
deadline=0
saved_boot=0
managed=0
if [ -e "$STATE/deadline" ] || [ -L "$STATE/deadline" ]; then
  [ -f "$STATE/deadline" ] && [ ! -L "$STATE/deadline" ] || fail 'unsafe deadline file'
  record=$(/bin/cat "$STATE/deadline")
  case "$record" in *' '*) :;; *) record='0 0';; esac
  saved_boot=${record%% *}
  deadline=${record#* }
  case "$saved_boot:$deadline" in *[!0-9:]*|:*|*:) saved_boot=0; deadline=0;; esac
  # Corruption is treated as expired; watchdog will restore normal sleep.
  [ "${#saved_boot}" -le 11 ] && [ "${#deadline}" -le 11 ] || { saved_boot=0; deadline=0; }
  managed=1
fi
enabled() {
  settings=$("$PMSET" -g) || fail 'cannot read power settings'
  value=$(printf '%s\n' "$settings" | /usr/bin/awk 'BEGIN {v=0} $1 == "SleepDisabled" {v=$2} END {print v}')
  case "$value" in 0|1) echo "$value";; *) fail 'cannot verify SleepDisabled';; esac
}
restore() {
  "$PMSET" -a disablesleep 0 || fail 'could not restore sleep; watchdog will retry'
  [ "$(enabled)" = 0 ] || fail 'sleep restoration did not take effect; watchdog will retry'
  /bin/rm -f "$STATE/deadline"
  managed=0; deadline=0
}
report() {
  remaining=0
  if [ "$managed" = 1 ] && [ "$saved_boot" = "$boot" ] && [ "$deadline" -gt "$now" ]; then
    remaining=$((deadline - now))
  fi
  current_enabled=$(enabled) || fail 'cannot report current power setting'
  echo "enabled=$current_enabled deadline=$deadline remaining_seconds=$remaining managed=$managed"
}
case "$1" in
  start)
    current_enabled=$(enabled) || fail 'cannot read current power setting'
    if [ "$managed" = 0 ] && [ "$current_enabled" = 1 ]; then
      fail 'sleep already disabled outside awake-skill; refusing to take ownership'
    fi
    deadline=$((now + $2 * 60))
    saved_boot=$boot
    # Atomic deadline is committed before disabling sleep. A failed pmset still
    # leaves a bounded lease for the watchdog to clean up safely.
    printf '%s %s\n' "$boot" "$deadline" > "$STATE/deadline.new"
    /bin/mv -f "$STATE/deadline.new" "$STATE/deadline"
    managed=1
    "$PMSET" -a disablesleep 1 || fail 'could not enable; expiry safeguard remains armed'
    [ "$(enabled)" = 1 ] || fail 'enable did not take effect; expiry safeguard remains armed'
    report;;
  stop)
    if [ "$managed" = 1 ]; then restore; fi
    report;;
  status) report;;
  watchdog)
    if [ "$managed" = 1 ]; then
      if [ "$saved_boot" != "$boot" ] || [ "$deadline" -le "$now" ]; then restore; fi
    fi;;
esac
