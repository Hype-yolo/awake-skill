#!/usr/bin/env python3
"""Offline behavior tests. Patch a temporary copy; never invoke real pmset/sudo."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).with_name("root-helper.sh")

class HelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awake-test-")
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.clock = self.root / "clock"
        self.boot = self.root / "boot"
        self.enabled = self.root / "enabled"
        self.failure = self.root / "failure"
        self.clock.write_text("2000000000")
        self.boot.write_text("1999990000")
        self.enabled.write_text("0")
        mock = self.root / "mock.py"
        mock.write_text(f'''#!/usr/bin/env python3
import pathlib, sys
r=pathlib.Path({str(self.root)!r})
tool=pathlib.Path(sys.argv[0]).name
a=sys.argv[1:]
if tool == 'id': print('0')
elif tool == 'launchctl':
    sys.exit(1 if (r/'daemon-missing').exists() else 0)
elif tool == 'stat': print('0:700' if a[1] == '%u:%Lp' else '1999999999')
elif tool == 'date': print((r/'clock').read_text())
elif tool == 'sysctl': print('{{ sec = '+(r/'boot').read_text()+', usec = 0 }}')
elif tool == 'pmset':
    if a == ['-g']:
        if (r/'failure').exists() and (r/'failure').read_text() == 'read': sys.exit(7)
        v=(r/'enabled').read_text()
        print('ordinary power settings' if v == 'default' else ' SleepDisabled '+v)
    else:
        assert a[:2] == ['-a', 'disablesleep']
        if (r/'failure').exists() and (r/'failure').read_text() == a[2]: sys.exit(7)
        (r/'enabled').write_text(a[2])
''')
        mock.chmod(0o755)
        code = SOURCE.read_text().replace("STATE=/var/db/org.awake-skill", f"STATE='{self.state}'")
        for key, original, name in [
            ("PMSET", "/usr/bin/pmset", "pmset"), ("DATE", "/bin/date", "date"),
            ("SYSCTL", "/usr/sbin/sysctl", "sysctl"), ("STAT", "/usr/bin/stat", "stat"),
            ("ID", "/usr/bin/id", "id"), ("LAUNCHCTL", "/bin/launchctl", "launchctl")]:
            target = self.root / name
            target.symlink_to(mock)
            code = code.replace(f"{key}={original}", f"{key}='{target}'")
        self.helper = self.root / "helper.sh"
        self.helper.write_text(code)

    def tearDown(self): self.temp.cleanup()
    def run_helper(self, *args, ok=True):
        p = subprocess.run(["/bin/sh", str(self.helper), *args], capture_output=True, text=True)
        if ok: self.assertEqual(p.returncode, 0, p.stderr)
        else: self.assertNotEqual(p.returncode, 0, p.stdout)
        return p.stdout
    def test_start_replace_and_stop(self):
        self.assertIn("remaining_seconds=120", self.run_helper("start", "2"))
        self.assertIn("remaining_seconds=86400", self.run_helper("start", "1440"))
        self.assertIn("enabled=0", self.run_helper("stop"))
        self.assertFalse((self.state / "deadline").exists())
    def test_expiry(self):
        self.run_helper("start", "1")
        self.clock.write_text("2000000059")
        self.run_helper("watchdog")
        self.assertEqual(self.enabled.read_text(), "1")
        self.clock.write_text("2000000060")
        self.run_helper("watchdog")
        self.assertEqual(self.enabled.read_text(), "0")
    def test_reboot(self):
        self.run_helper("start", "1440")
        self.boot.write_text("2000000001")
        self.run_helper("watchdog")
        self.assertEqual(self.enabled.read_text(), "0")
    def test_invalid_inputs(self):
        for args in [(), ("start",), ("start", "0"), ("start", "-1"), ("start", "01"),
                     ("start", "1441"), ("start", "1.5"), ("start", "1; id"),
                     ("start", "1", "extra"), ("stop", "extra"), ("watchdog", "x"), ("unknown",)]:
            with self.subTest(args=args): self.run_helper(*args, ok=False)
        self.assertFalse(self.state.exists())
    def test_enable_failure_keeps_timer(self):
        self.failure.write_text("1")
        self.run_helper("start", "1", ok=False)
        self.assertTrue((self.state / "deadline").exists())
        self.clock.write_text("2000000060")
        self.run_helper("watchdog")
        self.assertFalse((self.state / "deadline").exists())
    def test_restore_failure_retries(self):
        self.run_helper("start", "1")
        self.clock.write_text("2000000060")
        self.failure.write_text("0")
        self.run_helper("watchdog", ok=False)
        self.assertTrue((self.state / "deadline").exists())
        self.failure.unlink()
        self.run_helper("watchdog")
        self.assertEqual(self.enabled.read_text(), "0")
    def test_corrupt_state_restores(self):
        self.run_helper("start", "1")
        (self.state / "deadline").write_text("corrupt")
        self.run_helper("watchdog")
        self.assertEqual(self.enabled.read_text(), "0")
    def test_no_lease_does_not_change_external_setting(self):
        self.enabled.write_text("1")
        self.run_helper("watchdog")
        self.assertEqual(self.enabled.read_text(), "1")
        self.assertIn("managed=0", self.run_helper("status"))
    def test_start_refuses_unmanaged_disable(self):
        self.enabled.write_text("1")
        self.run_helper("start", "10", ok=False)
        self.assertEqual(self.enabled.read_text(), "1")
        self.assertFalse((self.state / "deadline").exists())
    def test_stop_preserves_unmanaged_disable(self):
        self.enabled.write_text("1")
        self.assertIn("managed=0", self.run_helper("stop"))
        self.assertEqual(self.enabled.read_text(), "1")
    def test_stop_without_lease_does_not_write_setting(self):
        self.failure.write_text("0")
        self.assertIn("enabled=0", self.run_helper("stop"))
    def test_default_missing_sleep_disabled_is_zero(self):
        self.enabled.write_text("default")
        self.assertIn("enabled=0", self.run_helper("status"))
    def test_failed_pmset_read_is_failure(self):
        self.failure.write_text("read")
        self.run_helper("status", ok=False)
    def test_start_refuses_without_watchdog(self):
        (self.root / 'daemon-missing').touch()
        self.run_helper('start', '120', ok=False)
        self.assertFalse(self.state.exists())
        self.assertEqual(self.enabled.read_text(), '0')
    def test_stale_process_lock_recovers(self):
        self.run_helper("start", "1")
        (self.state / 'lock').mkdir()
        (self.state / 'lock' / 'pid').write_text('99999999')
        self.run_helper('stop')
        self.assertEqual(self.enabled.read_text(), '0')
    def test_prior_boot_lock_recovers_even_if_pid_exists(self):
        self.run_helper('start', '1')
        (self.state / 'lock').mkdir()
        (self.state / 'lock' / 'pid').write_text(str(os.getpid()))
        self.boot.write_text('2000000001')
        self.run_helper('watchdog')
        self.assertEqual(self.enabled.read_text(), '0')
    def test_same_boot_reused_pid_recovers(self):
        self.run_helper('start', '1')
        (self.state / 'lock').mkdir()
        (self.state / 'lock' / 'pid').write_text(str(os.getpid()) + '|stale-process-birth')
        self.run_helper('stop')
        self.assertEqual(self.enabled.read_text(), '0')
    def test_symlink_state_rejected(self):
        target = self.root / "elsewhere"
        target.mkdir()
        self.state.symlink_to(target)
        self.run_helper("start", "1", ok=False)
    def test_installer_hash_matches(self):
        digest = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
        self.assertIn("EXPECTED_HELPER_SHA=" + digest, SOURCE.with_name("install.sh").read_text())

if __name__ == "__main__": unittest.main(verbosity=2)
