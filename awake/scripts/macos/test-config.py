import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('config', Path(__file__).with_name('config.py'))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'nested' / 'config.json'

    def test_missing_has_no_side_effect(self):
        self.assertEqual(config.read(self.path), {'state': 'missing'})
        self.assertFalse(self.path.parent.exists())

    def test_unicode_and_shell_characters_round_trip(self):
        name = '手机 $(touch x) `id`'
        config.save(self.path, 'hotspot', name)
        self.assertEqual(config.read(self.path)['network']['ssid'], name)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_reconfigure_and_existing_mode(self):
        config.save(self.path, 'hotspot', 'Phone')
        config.save(self.path, 'existing', None)
        self.assertEqual(config.read(self.path)['network'], {'mode': 'existing', 'ssid': None})
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_invalid_input_preserves_file(self):
        config.save(self.path, 'existing', None)
        before = self.path.read_bytes()
        for mode, ssid in [('hotspot', ''), ('hotspot', ' '), ('hotspot', '中'*11), ('hotspot', 'a\nb'), ('hotspot', None), ('existing', 'Phone')]:
            with self.subTest(mode=mode, ssid=ssid), self.assertRaises(ValueError):
                config.save(self.path, mode, ssid)
            self.assertEqual(self.path.read_bytes(), before)

    def test_corrupt_or_new_schema_is_not_overwritten(self):
        self.path.parent.mkdir()
        for contents in ['broken', json.dumps({'version': 2, 'platform': 'macos', 'network': {'mode': 'existing', 'ssid': None}})]:
            self.path.write_text(contents)
            with self.assertRaises(ValueError):
                config.save(self.path, 'existing', None)
            self.assertEqual(self.path.read_text(), contents)

    def test_symlink_refused(self):
        target = Path(self.tmp.name) / 'target'
        target.write_text('keep')
        self.path.parent.mkdir()
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            config.save(self.path, 'existing', None)
        self.assertEqual(target.read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
