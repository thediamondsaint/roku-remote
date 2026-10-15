import contextlib
import io
import json
from pathlib import Path
import runpy
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import xml.etree.ElementTree as ET


class InstantTimer:
    def __init__(self, cancelled=False):
        self.cancelled = cancelled
        self.waits = []

    def is_set(self):
        return self.cancelled

    def wait(self, seconds):
        self.waits.append(seconds)
        return self.cancelled


class YodelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.module = runpy.run_path(str(Path(__file__).parents[1] / 'bin/roku_yodel.py'))
        self.g = self.module['run'].__globals__
        self.ip = '192.0.2.1'
        self.volume = 17
        self.muted = True
        self.app = '41468'
        self.playing = True
        self.is_tv = True
        self.power = 'PowerOn'
        self.sent = []
        self.events = []
        self.api = {
            'CACHE': str(self.directory / 'roku.json'),
            'get': self.get, 'post': self.post, 'volume': lambda ip: self.volume,
            'set_volume': self.set_volume, 'apps': lambda ip: [('837', 'YouTube')],
            'save_json': lambda path, data: Path(path).write_text(json.dumps(data)),
        }

    def get(self, ip, path):
        if path == '/query/device-info':
            return ET.fromstring(f'<device-info><is-tv>{str(self.is_tv).lower()}</is-tv><power-mode>{self.power}</power-mode></device-info>')
        if path == '/query/audio-device':
            return ET.fromstring(f'<audio-device><global><volume>{self.volume}</volume><muted>{str(self.muted).lower()}</muted></global></audio-device>')
        if path == '/query/active-app':
            if self.app == 'home':
                return ET.fromstring('<active-app><app>Roku</app></active-app>')
            return ET.fromstring(f'<active-app><app id="{self.app}">App</app></active-app>')
        if path == '/query/media-player':
            return ET.fromstring('<player state="play"><plugin id="837"/></player>' if self.playing else '<player state="close"/>')
        self.fail(path)

    def post(self, ip, path):
        self.sent.append((ip, path))
        if path == '/keypress/Home':
            self.app = 'home'
        elif path == '/keypress/VolumeMute':
            self.muted = not self.muted
        elif path.startswith('/launch/'):
            self.app = path.split('/launch/')[1].split('?')[0]

    def set_volume(self, ip, target, cancel=None):
        # Many TVs unmute on volume changes. Restoration must undo this too.
        if self.volume != target:
            self.muted = False
        self.volume = target
        return target

    def emit(self, *args):
        self.events.append(args)

    def device(self, timer=None):
        with patch('time.sleep'):
            return self.module['yodel_device'](self.api, self.ip, 'Test TV', self.directory, timer or InstantTimer(), self.emit)

    def test_playback_waits_25_seconds_and_restores_volume_mute_and_app(self):
        timer = InstantTimer()
        self.assertTrue(self.device(timer))
        self.assertEqual(timer.waits, [25])
        self.assertEqual((self.volume, self.muted, self.app), (17, True, '41468'))
        launch = next(path for _, path in self.sent if '?' in path)
        self.assertIn('contentId=8_UnANdDqJc', launch)
        self.assertIn('t=10', launch)
        self.assertFalse((self.directory / f'{self.ip}.json').exists())
        self.assertIn('restored', [e[1] for e in self.events])

    def test_home_without_an_app_id_is_restored(self):
        self.app = 'home'
        self.assertTrue(self.device())
        self.assertEqual(self.app, 'home')

    def test_muted_tv_already_at_25_is_unmuted_and_then_restored(self):
        self.volume = 25
        self.assertTrue(self.device())
        self.assertEqual(self.volume, 25)
        self.assertTrue(self.muted)
        self.assertEqual(self.sent.count((self.ip, '/keypress/VolumeMute')), 2)

    def test_original_youtube_video_is_stopped_before_reopening_youtube(self):
        self.app = '837'
        self.assertTrue(self.device())
        self.assertIn((self.ip, '/keypress/Home'), self.sent)
        self.assertEqual(self.sent[-1], (self.ip, '/launch/837'))

    def test_tv_input_location_is_used_instead_of_generic_live_tv_app(self):
        node = ET.fromstring('<active-app><app id="779845" ui-location="tvinput.dtv">Live TV Input</app></active-app>')
        self.assertEqual(self.module['app_state'](node)['app'], 'tvinput.dtv')

    def test_offline_tv_is_reported_without_controls(self):
        self.api['get'] = lambda *args: (_ for _ in ()).throw(urllib.error.URLError('offline'))
        self.assertFalse(self.device())
        self.assertEqual(self.sent, [])
        self.assertIn('offline', self.events[-1][2])

    def test_players_standby_tvs_and_missing_youtube_are_skipped(self):
        for kind in ('player', 'standby', 'no-youtube'):
            with self.subTest(kind=kind):
                self.is_tv = kind != 'player'
                self.power = 'Ready' if kind == 'standby' else 'PowerOn'
                self.api['apps'] = lambda ip: [] if kind == 'no-youtube' else [('837', 'YouTube')]
                self.assertTrue(self.device())
                self.assertEqual(self.events[-1][1], 'skipped')
                self.assertEqual(self.sent, [])
                self.assertEqual(self.volume, 17)

    def test_unknown_previous_app_never_changes_the_tv(self):
        original_get = self.api['get']
        self.api['get'] = lambda ip, path: ET.fromstring('<active-app/>') if path.endswith('active-app') else original_get(ip, path)
        self.assertFalse(self.device())
        self.assertEqual(self.volume, 17)
        self.assertEqual(self.sent, [])

    def test_volume_failure_restores_without_launching_video(self):
        calls = []
        def change(ip, target, cancel=None):
            calls.append(target)
            if target == 25:
                self.volume = 20
                raise RuntimeError('stuck')
            return self.set_volume(ip, target)
        self.api['set_volume'] = change
        self.assertFalse(self.device())
        self.assertEqual(calls, [25, 17])
        self.assertEqual(self.volume, 17)
        self.assertFalse(any('/launch/' in path for _, path in self.sent))

    def test_launch_failure_still_restores(self):
        original_post = self.api['post']
        def launch(ip, path):
            if '?' in path:
                raise RuntimeError('launch refused')
            original_post(ip, path)
        self.api['post'] = launch
        self.assertFalse(self.device())
        self.assertEqual((self.volume, self.app), (17, '41468'))
        self.assertEqual(self.events[-1][1], 'error')

    def test_playback_timeout_does_not_claim_success(self):
        self.playing = False
        with patch.dict(self.g, PLAYBACK_TIMEOUT=0):
            self.assertFalse(self.device())
        self.assertEqual((self.volume, self.app), (17, '41468'))
        self.assertIn('not confirmed', self.events[-1][2])

    def test_cancellation_during_playback_restores(self):
        timer = InstantTimer()
        timer.wait = lambda seconds: setattr(timer, 'cancelled', True) or True
        self.assertFalse(self.device(timer))
        self.assertEqual((self.volume, self.app), (17, '41468'))
        self.assertIn('Cancelled', self.events[-1][2])

    def test_cancelled_before_changes_sends_no_controls(self):
        self.assertTrue(self.device(InstantTimer(cancelled=True)))
        self.assertEqual(self.sent, [])
        self.assertEqual(self.volume, 17)

    def test_failed_restore_keeps_journal_and_restores_other_components(self):
        original_set = self.api['set_volume']
        def change(ip, target, cancel=None):
            if target == 17:
                raise RuntimeError('TV lost volume control')
            return original_set(ip, target, cancel)
        self.api['set_volume'] = change
        self.assertFalse(self.device())
        self.assertEqual(self.app, '41468')
        self.assertTrue(self.muted)
        self.assertTrue((self.directory / f'{self.ip}.json').exists())
        self.assertIn('yodel-restore', self.events[-1][2])
        # A new run must never replace a pending snapshot.
        before = list(self.sent)
        self.assertFalse(self.device())
        self.assertEqual(self.sent, before)

    def test_recovery_command_restores_saved_journal(self):
        directory = self.directory / 'roku-yodel'
        directory.mkdir()
        path = directory / f'{self.ip}.json'
        path.write_text(json.dumps({'ip': self.ip, 'name': 'Test TV', 'volume': 12, 'muted': False,
                                    'app': 'home', 'app_id': None, 'app_name': 'Roku', 'restore_app': True}))
        with patch('time.sleep'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.module['run'](self.api, restore=True), 0)
        self.assertEqual((self.volume, self.muted, self.app), (12, False, 'home'))
        self.assertFalse(path.exists())

    def test_all_network_devices_are_dispatched_concurrently_without_default_selection(self):
        devices = {'192.0.2.1': 'One', '192.0.2.2': 'Two'}
        self.api['discover'] = lambda: {'devices': devices}
        self.api['resolve'] = lambda *a: self.fail('must not select default')
        barrier = threading.Barrier(2)
        seen = []
        def worker(api, ip, name, directory, cancel, emit):
            barrier.wait(timeout=2)
            seen.append(ip)
            return ip != '192.0.2.2'
        output = io.StringIO()
        with patch.dict(self.g, yodel_device=worker), contextlib.redirect_stdout(output):
            self.assertEqual(self.module['run'](self.api, json_output=True), 1)
        self.assertEqual(set(seen), set(devices))
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(events[-1]['status'], 'complete')
        self.assertIn('errors', events[-1]['message'])

    def test_duplicate_runs_are_blocked_before_discovery(self):
        import fcntl
        directory = self.directory / 'roku-yodel'
        directory.mkdir()
        with (directory / 'run.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(self.module['run'](self.api), 1)
        self.assertIn('already running', output.getvalue())


if __name__ == '__main__':
    unittest.main()
