#!/bin/bash
# Run from this directory: sudo /bin/bash ./install.sh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset ENV BASH_ENV CDPATH
umask 077
[[ $(/usr/bin/id -u) == 0 ]] || { echo 'Run this installer with sudo.' >&2; exit 1; }
[[ $(/usr/bin/uname -s) == Darwin ]] || { echo 'macOS only.' >&2; exit 1; }
USER_NAME=${SUDO_USER:-}
[[ $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ && $USER_NAME != root ]] || { echo 'Run sudo from a regular account with a safe short username.' >&2; exit 1; }
USER_UID=$(/usr/bin/id -u "$USER_NAME")
[[ $USER_UID != 0 ]] || exit 1
SOURCE_DIR=$(cd "$(dirname "$0")" && /bin/pwd -P)
HELPER=/Library/PrivilegedHelperTools/org.awake-skill
PLIST=/Library/LaunchDaemons/org.awake-skill.plist
SUDOERS=/etc/sudoers.d/awake-skill
STATE=/var/db/org.awake-skill
# Updated alongside root-helper.sh; rejects a replaced or partially edited source.
EXPECTED_HELPER_SHA=565d9c15e04574c6301452f3940c372f580163fd2c0e8bd298a30c6d51f118b1
die() { echo "awake install: $*" >&2; exit 1; }
safe_dir() {
  [[ -d "$1" && ! -L "$1" ]] || die "Unsafe directory: $1"
  local owner mode
  owner=$(/usr/bin/stat -f %u "$1")
  mode=$(/usr/bin/stat -f %Lp "$1")
  [[ $owner == 0 && $((8#$mode & 0022)) == 0 ]] || die "Directory must be root-owned and not writable by group/others: $1"
}

[[ -f "$SOURCE_DIR/root-helper.sh" && ! -L "$SOURCE_DIR/root-helper.sh" ]] || die 'Missing or symlinked helper source'
SOURCE_OWNER=$(/usr/bin/stat -f %u "$SOURCE_DIR/root-helper.sh")
SOURCE_MODE=$(/usr/bin/stat -f %Lp "$SOURCE_DIR/root-helper.sh")
[[ $SOURCE_OWNER == 0 || $SOURCE_OWNER == "$(/usr/bin/id -u "$USER_NAME")" ]] || die 'Unexpected source owner'
[[ $((8#$SOURCE_MODE & 0022)) == 0 ]] || die 'Source is writable by group or others'
for dir in /Library /Library/PrivilegedHelperTools /Library/LaunchDaemons /private/etc /private/var /private/var/db; do safe_dir "$dir"; done
[[ -d /etc/sudoers.d ]] || /bin/mkdir -m 755 /etc/sudoers.d
safe_dir /etc/sudoers.d
[[ ! -L "$STATE" ]] || die 'State directory is a symlink'
if [[ -e "$STATE" ]]; then
  safe_dir "$STATE"
  [[ $(/usr/bin/stat -f %Lp "$STATE") == 700 ]] || die 'State directory must have mode 700'
fi
for file in "$HELPER" "$PLIST" "$SUDOERS"; do
  [[ ! -L "$file" ]] || die "Refusing symlink target: $file"
  [[ ! -e "$file" || -f "$file" ]] || die "Not a regular file: $file"
done
# Never adopt another application's or administrator's sleep setting.
POWER_SETTINGS=$(/usr/bin/pmset -g) || die 'Cannot inspect power settings'
DISABLED=$(printf '%s\n' "$POWER_SETTINGS" | /usr/bin/awk 'BEGIN {v=0} $1=="SleepDisabled" {v=$2} END {print v}')
[[ $DISABLED == 0 || $DISABLED == 1 ]] || die 'Unknown SleepDisabled state'
if [[ $DISABLED == 1 ]]; then
  [[ -f "$HELPER" && $(/usr/bin/stat -f %u "$HELPER") == 0 && -f "$STATE/deadline" ]] || die 'Sleep is disabled outside awake-skill; leave that setting under its existing owner.'
fi
STAGE=$(/usr/bin/mktemp -d /private/var/tmp/org.awake-skill.install.XXXXXX)
trap '/bin/rm -rf "$STAGE"' EXIT
/bin/cp "$SOURCE_DIR/root-helper.sh" "$STAGE/helper"
ACTUAL_SHA=$(/usr/bin/shasum -a 256 "$STAGE/helper" | /usr/bin/awk '{print $1}')
[[ $ACTUAL_SHA == "$EXPECTED_HELPER_SHA" ]] || die 'Helper checksum mismatch; installation stopped'
/bin/sh -n "$STAGE/helper"
cat > "$STAGE/daemon.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>org.awake-skill</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/org.awake-skill</string><string>watchdog</string></array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>15</integer>
<key>ProcessType</key><string>Background</string>
<key>StandardErrorPath</key><string>/var/db/org.awake-skill/watchdog-error.log</string>
</dict></plist>
PLIST_EOF
/usr/bin/plutil -lint "$STAGE/daemon.plist"
printf '%s ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/org.awake-skill start *, /Library/PrivilegedHelperTools/org.awake-skill stop, /Library/PrivilegedHelperTools/org.awake-skill status\n' "$USER_NAME" > "$STAGE/sudoers"
/usr/sbin/visudo -cf "$STAGE/sudoers"
# sudoers.d must actually be included; do not silently claim passwordless setup.
/usr/bin/grep -Eq '^[[:space:]]*([@#]includedir)[[:space:]]+/private/etc/sudoers.d|^[[:space:]]*([@#]includedir)[[:space:]]+/etc/sudoers.d' /etc/sudoers || die 'sudoers does not include /etc/sudoers.d'
BACKUP=$(/usr/bin/mktemp -d /private/var/tmp/org.awake-skill.backup.XXXXXX)
[[ ! -e "$HELPER" ]] || /bin/cp -p "$HELPER" "$BACKUP/helper.previous"
[[ ! -e "$PLIST" ]] || /bin/cp -p "$PLIST" "$BACKUP/daemon.previous.plist"
[[ ! -e "$SUDOERS" ]] || /bin/cp -p "$SUDOERS" "$BACKUP/sudoers.previous"
if [[ -e "$STATE/deadline" ]]; then /bin/cp -p "$STATE/deadline" "$BACKUP/deadline"; fi
/usr/bin/pmset -g > "$BACKUP/pmset-before.txt"
echo "Backup: $BACKUP"
/usr/bin/install -o root -g wheel -m 755 "$STAGE/helper" "$HELPER"
/usr/bin/install -o root -g wheel -m 644 "$STAGE/daemon.plist" "$PLIST"
/usr/bin/install -o root -g wheel -m 440 "$STAGE/sudoers" "$SUDOERS"
if ! /usr/sbin/visudo -c; then
  /bin/rm -f "$SUDOERS"
  [[ ! -e "$BACKUP/sudoers.previous" ]] || /bin/cp -p "$BACKUP/sudoers.previous" "$SUDOERS"
  die 'Global sudoers check failed; new rule removed'
fi
/bin/mkdir -p "$STATE"
/usr/sbin/chown root:wheel "$STATE"
/bin/chmod 700 "$STATE"
/bin/launchctl bootout system/org.awake-skill 2>/dev/null || true
if ! /bin/launchctl bootstrap system "$PLIST"; then
  if ! "$HELPER" stop; then
    die 'Watchdog could not start and sleep restoration failed. Run sudo /Library/PrivilegedHelperTools/org.awake-skill stop to recover.'
  fi
  die 'Watchdog could not start; any managed session was stopped. Installation is incomplete.'
fi
/bin/launchctl print system/org.awake-skill >/dev/null
/usr/bin/sudo -n -u "$USER_NAME" /usr/bin/sudo -n "$HELPER" status
echo 'Installed. Start: sudo -n /Library/PrivilegedHelperTools/org.awake-skill start 120'
echo 'Stop: sudo -n /Library/PrivilegedHelperTools/org.awake-skill stop'
