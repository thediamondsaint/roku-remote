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
        self.g['REGISTRY'] = str(Path(self.temp.name) / 'prefs' / 'devices.json')
        self.g['INVENTORY_CACHE'] = str(Path(self.temp.name) / 'inventory.json')
        self.g['ssdp_discover'] = lambda: set()

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

    def test_volume_rejects_invalid_targets_before_network(self):
        for args in (['-1'], ['101'], ['25.5'], ['loud'], ['25', '30']):
            with patch.dict(self.g, resolve=lambda *a, **k: self.fail('unexpected network')), self.assertRaisesRegex(SystemExit, '0 to 100'):
                self.roku['main'](['volume'] + args)

    def test_volume_reads_global_level(self):
        import xml.etree.ElementTree as ET
        with patch.dict(self.g, get=lambda *a: ET.fromstring('<audio-device><global><volume>25</volume></global></audio-device>')):
            self.assertEqual(self.roku['volume']('192.168.1.50'), 25)

    def test_missing_or_invalid_volume_is_not_guessed(self):
        import xml.etree.ElementTree as ET
        for value in ('', 'loud', '101', '-1'):
            with patch.dict(self.g, get=lambda *a: ET.fromstring(f'<audio-device><global><volume>{value}</volume></global></audio-device>')), self.assertRaises(urllib.error.URLError):
                self.roku['volume']('192.168.1.50')

    def test_exact_volume_adjusts_both_directions_and_verifies(self):
        for readings, keys in (([23, 24, 25], ['VolumeUp'] * 2), ([27, 26, 25], ['VolumeDown'] * 2), ([25], []), ([24, 24, 25], ['VolumeUp'])):
            levels = iter(readings)
            sent = []
            with patch.dict(self.g, volume=lambda ip: next(levels), post=lambda ip, path: sent.append(path)), patch('time.sleep'):
                self.assertEqual(self.roku['set_volume']('192.168.1.50', 25), 25)
            self.assertEqual(sent, ['/keypress/' + key for key in keys])

    def test_stuck_volume_stops_after_one_key(self):
        sent = []
        with patch.dict(self.g, volume=lambda ip: 19, post=lambda ip, path: sent.append(path)), patch('time.sleep'), self.assertRaisesRegex(urllib.error.URLError, 'not confirmed'):
            self.roku['set_volume']('192.168.1.50', 25)
        self.assertEqual(sent, ['/keypress/VolumeUp'])

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

    def test_forbidden_queries_retry_authenticated_transport(self):
        error = urllib.error.HTTPError('http://tv/query/apps', 403, 'Forbidden', {}, None)
        response = {'content-data': 'PGFwcHM+PGFwcCBpZD0iMTIiPk5ldGZsaXg8L2FwcD48L2FwcHM+'}
        with patch('urllib.request.urlopen', side_effect=error), patch.dict(self.g, ecp_request=lambda ip, path: response):
            self.assertEqual(self.roku['apps']('192.168.1.50'), [('12', 'Netflix')])

    def test_forbidden_controls_retry_authenticated_transport(self):
        calls = []
        error = urllib.error.HTTPError('http://tv/keypress/PowerOn', 403, 'Forbidden', {}, None)
        with patch('urllib.request.urlopen', side_effect=error), patch.dict(self.g, ecp_request=lambda ip, path: calls.append((ip,path))):
            self.roku['post']('192.168.1.50', '/keypress/PowerOn')
        self.assertEqual(calls, [('192.168.1.50','/keypress/PowerOn')])

    def test_scan_retains_sleeping_devices_and_saved_macs(self):
        self.cache({'default': '192.168.1.51', 'devices': {'192.168.1.50': 'On TV', '192.168.1.51': 'Sleeping TV'}})
        records = {'192.168.1.51': {'name': 'Sleeping TV', 'info': {'wifi-mac': 'AA:BB:CC:DD:EE:FF'}, 'last_seen': 100}}
        self.roku['save_json'](self.g['REGISTRY'], records)
        with patch.dict(self.g, local_net=lambda: SimpleNamespace(hosts=lambda: []), probe=lambda ip: None):
            result = self.roku['discover']()
        self.assertIn('192.168.1.51', result['devices'])
        self.assertEqual(result['default'], '192.168.1.51')
        self.assertFalse(self.roku['registry']()['192.168.1.51']['reachable'])
        self.assertEqual(self.roku['registry']()['192.168.1.51']['info']['wifi-mac'], 'AA:BB:CC:DD:EE:FF')

    def test_saved_inventory_recovers_a_device_missing_from_latest_scan(self):
        report = [{'ip': '192.168.1.51', 'name': 'Sleeping TV', 'queries': {'device-info':
            {'children': [{'tag': 'wifi-mac', 'text': 'AA:BB:CC:DD:EE:FF'}]}}}]
        Path(self.g['INVENTORY_CACHE']).write_text(json.dumps(report))
        self.assertEqual(self.roku['registry']()['192.168.1.51']['info']['wifi-mac'], 'AA:BB:CC:DD:EE:FF')

    def test_identity_migration_updates_default_and_shortcuts(self):
        self.cache({'default': '192.168.1.50', 'devices': {'192.168.1.50': 'TV'}})
        self.roku['save_json'](self.g['REGISTRY'], {'192.168.1.50': {'name': 'TV', 'info': {'device-id': 'stable'}}})
        self.roku['save_json'](self.g['PREFERENCES'], {'192.168.1.50': [{'id': '12', 'name': 'Netflix'}]})
        def probe(ip):
            return (ip, 'TV', {'device-id': 'stable'}) if ip == '192.168.1.51' else None
        with patch.dict(self.g, local_net=lambda: SimpleNamespace(hosts=lambda: ['192.168.1.51']), probe=probe):
            result = self.roku['discover']()
        self.assertEqual(result['default'], '192.168.1.51')
        self.assertNotIn('192.168.1.50', result['devices'])
        self.assertIn('192.168.1.51', self.roku['preferences']())

    def test_magic_packet_is_valid_and_invalid_macs_are_rejected(self):
        packet = self.roku['wake_packet']('AA:BB:CC:DD:EE:FF')
        self.assertEqual(len(packet), 102)
        self.assertEqual(packet, b'\xff' * 6 + bytes.fromhex('AABBCCDDEEFF') * 16)
        with self.assertRaises(ValueError):
            self.roku['wake_packet']('not-a-mac')

    def test_wake_sends_broadcast_and_checks_response(self):
        self.roku['save_json'](self.g['REGISTRY'], {'192.168.1.51': {'name': 'TV', 'info': {'wifi-mac': 'AA:BB:CC:DD:EE:FF'}}})
        with patch('socket.socket') as factory, patch.dict(self.g,
                probe=lambda ip: (ip, 'TV', {'wifi-mac': 'AA:BB:CC:DD:EE:FF'})):
            self.assertTrue(self.roku['wake_device']('192.168.1.51', wait=1))
            calls = factory.return_value.__enter__.return_value.sendto.call_args_list
            self.assertEqual(len(calls), 2)
            self.assertEqual({c.args[1] for c in calls}, {('255.255.255.255', 9), ('192.168.1.255', 9)})

    def test_unanswered_wake_is_not_reported_as_success(self):
        self.roku['save_json'](self.g['REGISTRY'], {'192.168.1.51': {'name': 'TV', 'info': {'mac': 'AA:BB:CC:DD:EE:FF'}}})
        with patch('socket.socket'):
            self.assertFalse(self.roku['wake_device']('192.168.1.51', wait=0))

    def test_power_on_uses_wake_only_when_connection_fails(self):
        with patch.dict(self.g, wake_device=lambda ip: True):
            with patch.dict(self.g, post=unittest.mock.Mock(side_effect=[urllib.error.URLError('asleep'), None])):
                self.assertIn('Wake-on-LAN', self.roku['power_on']('192.168.1.51'))
                self.assertEqual(self.g['post'].call_count, 2)

    def test_offline_inventory_uses_explicitly_marked_last_known_details(self):
        self.roku['save_json'](self.g['REGISTRY'], {'192.168.1.51': {'name': 'TV', 'info': {'model-name': 'TCL'}, 'last_seen': 100}})
        with patch.dict(self.g, get=unittest.mock.Mock(side_effect=urllib.error.URLError('asleep'))):
            result = self.roku['inventory_device'](('192.168.1.51', 'TV'))
            self.assertEqual(self.g['get'].call_count, 1)
        self.assertFalse(result['reachable'])
        self.assertTrue(result['cached'])
        self.assertEqual(result['last_seen'], 100)


if __name__ == '__main__':
    unittest.main()
