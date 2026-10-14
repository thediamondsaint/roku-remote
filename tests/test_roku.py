import contextlib
import io
import json
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error


class RokuTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.roku = runpy.run_path(str(Path(__file__).parents[1] / 'bin/roku'))
        self.g = self.roku['main'].__globals__
        self.g['PREFERENCES'] = str(Path(self.temp.name) / 'prefs' / 'shortcuts.json')
        self.g['CACHE'] = str(Path(self.temp.name) / 'roku.json')

    def cache(self, value):
        Path(self.g['CACHE']).write_text(json.dumps(value))

    def test_invalid_cache_shapes_recover(self):
        for value in ({}, [], None, {'devices': []}, {'devices': {'ip': None}}):
            self.cache(value)
            self.assertEqual(self.roku['load']()['devices'], {})

    def test_explicit_ip_bypasses_discovery(self):
        with patch.dict(self.g, discover=lambda: self.fail('unexpected discovery')):
            self.assertEqual(self.roku['resolve']('192.168.1.50'), '192.168.1.50')

    def test_invalid_ip_reports_error(self):
        with self.assertRaisesRegex(SystemExit, 'invalid IPv4'):
            self.roku['resolve']('999.1.1.1')

    def test_empty_scan_preserves_default(self):
        self.cache({'default': '192.168.1.50', 'devices': {}})
        with patch.dict(self.g, local_net=lambda: SimpleNamespace(hosts=lambda: [])):
            self.assertEqual(self.roku['discover']()['default'], '192.168.1.50')
        self.assertEqual(self.roku['load']()['default'], '192.168.1.50')

    def test_saved_default_bypasses_discovery(self):
        self.cache({'default': '192.168.1.50', 'devices': {}})
        with patch.dict(self.g, discover=lambda: self.fail('unexpected discovery')):
            self.assertEqual(self.roku['resolve'](None), '192.168.1.50')

    def test_offline_info_preserves_picker(self):
        self.cache({'default': '192.168.1.50', 'devices': {'192.168.1.50': 'Living Room', '192.168.1.51': 'Bedroom'}})
        def offline(*args):
            raise urllib.error.URLError('offline')
        output = io.StringIO()
        with patch.dict(self.g, get=offline), contextlib.redirect_stdout(output):
            self.roku['main'](['info'])
        result = json.loads(output.getvalue())
        self.assertTrue(result['unreachable'])
        self.assertEqual(len(result['devices']), 2)

    def test_atomic_save_leaves_no_temporary_files(self):
        data = {'default': None, 'devices': {}}
        self.roku['save'](data)
        self.assertEqual(self.roku['load'](), data)
        self.assertEqual(len(list(Path(self.temp.name).iterdir())), 1)

    def test_empty_launch_is_rejected_before_network(self):
        with self.assertRaisesRegex(SystemExit, 'requires an app'):
            self.roku['main'](['launch'])

    def test_shortcuts_are_saved_per_tv_without_network(self):
        selected = [{"id": str(i), "name": f"App {i}"} for i in range(4)]
        with patch.dict(self.g, discover=lambda: self.fail("unexpected discovery")), contextlib.redirect_stdout(io.StringIO()):
            self.roku['main'](['-d', '192.168.1.50', 'shortcuts', json.dumps(selected)])
            self.roku['main'](['-d', '192.168.1.51', 'shortcuts', json.dumps(list(reversed(selected)))])
        self.assertEqual(self.roku['preferences']()['192.168.1.50'], selected)
        self.assertEqual(self.roku['preferences']()['192.168.1.51'], list(reversed(selected)))

    def test_invalid_shortcuts_do_not_write_preferences(self):
        for value in ([], [{"id": "1", "name": "Netflix"}] * 3, [None] * 4):
            with self.assertRaises(SystemExit):
                self.roku['main'](['-d', '192.168.1.50', 'shortcuts', json.dumps(value)])
        self.assertFalse(Path(self.g['PREFERENCES']).exists())

    def test_inventory_keeps_fields_and_continues_after_forbidden(self):
        import xml.etree.ElementTree as ET
        def query(ip, path):
            if path == "/query/apps":
                raise urllib.error.HTTPError(path, 403, "Forbidden", {}, None)
            return ET.fromstring('<root state="play"><item id="1">One</item><item id="2">Two</item></root>')
        with patch.dict(self.g, get=query, post=lambda *a: self.fail("inventory must not send controls")):
            report = self.roku['inventory_device'](('192.168.1.50', 'Living'))
        self.assertIn('apps', report['errors'])
        self.assertIn('media-player', report['queries'])
        self.assertEqual(report['queries']['device-info']['attributes']['state'], 'play')
        self.assertEqual(len(report['queries']['device-info']['children']), 2)

    def test_inventory_single_ip_does_not_scan(self):
        with patch.dict(self.g, discover=lambda: self.fail("unexpected scan"),
                        inventory_device=lambda device: {"ip": device[0]}):
            self.assertEqual(self.roku['inventory']('192.168.1.50'), [{"ip": '192.168.1.50'}])


if __name__ == '__main__':
    unittest.main()
