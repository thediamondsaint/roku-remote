"""Network-wide Yodel Nuke orchestration; all device I/O uses the bundled Roku API."""
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import signal
import threading
import time
import urllib.parse

VIDEO_ID = '8_UnANdDqJc'
VOLUME = 25
DURATION = 25
PLAYBACK_TIMEOUT = 30


def app_state(node):
    app = node.find('app')
    if app is None:
        raise ValueError('Cannot identify the app to restore')
    app_id = app.get('id')
    location = app.get('ui-location', '')
    if location.startswith('tvinput.'):
        app_id = location
    if not app_id and (app.text or '').strip().lower() == 'roku':
        app_id = 'home'
    if not app_id:
        raise ValueError('Cannot identify the app to restore')
    return {'app': app_id, 'app_id': app.get('id'), 'app_name': app.text or 'Roku'}


def restore_device(api, snapshot):
    """Attempt every restoration component even if another one fails."""
    ip = snapshot['ip']
    errors = []

    def attempt(label, action):
        for retry in range(3):
            try:
                action()
                return
            except Exception as error:
                if retry == 2:
                    errors.append(f'{label}: {error}')
                else:
                    time.sleep(0.3)

    attempt('volume', lambda: api['set_volume'](ip, snapshot['volume']))

    def restore_mute():
        muted = api['get'](ip, '/query/audio-device').findtext('global/muted')
        if muted not in ('true', 'false'):
            raise ValueError('TV did not report its mute state')
        if (muted == 'true') != snapshot['muted']:
            api['post'](ip, '/keypress/VolumeMute')
            time.sleep(0.2)
            if api['get'](ip, '/query/audio-device').findtext('global/muted') != str(snapshot['muted']).lower():
                raise ValueError('Mute restoration not confirmed')

    attempt('mute', restore_mute)

    def restore_app():
        # Home also stops the temporary video when the original app was YouTube.
        api['post'](ip, '/keypress/Home')
        if snapshot['app'] != 'home':
            api['post'](ip, '/launch/' + urllib.parse.quote(snapshot['app'], safe=''))
        for _ in range(5):
            node = api['get'](ip, '/query/active-app')
            current = app_state(node)
            if (current['app'] == snapshot['app'] or
                    (snapshot['app'].startswith('tvinput.') and current['app_id'] == snapshot['app_id'])):
                return
            time.sleep(0.5)
        raise ValueError('Previous app/input not confirmed')

    if snapshot.get('restore_app'):
        attempt('app', restore_app)
    return errors


def yodel_device(api, ip, name, directory, cancel, emit):
    journal = directory / f'{ip}.json'
    snapshot = None
    error = None
    played = False
    try:
        if journal.exists():
            emit(name, 'error', 'Pending restoration; run roku yodel-restore first')
            return False
        info = api['get'](ip, '/query/device-info')
        if info.findtext('is-tv') != 'true':
            emit(name, 'skipped', 'Not a TV with its own volume control')
            return True
        if info.findtext('power-mode') != 'PowerOn':
            emit(name, 'skipped', 'TV is off or in standby')
            return True
        if '837' not in {app_id for app_id, _ in api['apps'](ip)}:
            emit(name, 'skipped', 'YouTube is not installed')
            return True
        original_app = app_state(api['get'](ip, '/query/active-app'))
        original_volume = api['volume'](ip)
        muted = api['get'](ip, '/query/audio-device').findtext('global/muted')
        if muted not in ('true', 'false'):
            raise ValueError('Cannot save the original mute state')
        if cancel.is_set():
            emit(name, 'skipped', 'Cancelled before any changes')
            return True
        snapshot = {'ip': ip, 'name': name, 'volume': original_volume,
                    'muted': muted == 'true', 'restore_app': False, **original_app}
        api['save_json'](str(journal), snapshot)
        emit(name, 'setting-volume', f'Saved volume {original_volume} and {original_app["app_name"]}')
        api['set_volume'](ip, VOLUME, cancel=cancel)
        if cancel.is_set():
            raise InterruptedError('Cancelled')
        if api['get'](ip, '/query/audio-device').findtext('global/muted') == 'true':
            api['post'](ip, '/keypress/VolumeMute')
            if api['get'](ip, '/query/audio-device').findtext('global/muted') != 'false':
                raise ValueError('Could not unmute the TV')
        snapshot['restore_app'] = True
        api['save_json'](str(journal), snapshot)
        params = urllib.parse.urlencode({'contentId': VIDEO_ID, 'mediaType': 'movie', 't': 10, 'startTime': 10})
        api['post'](ip, '/launch/837?' + params)
        emit(name, 'loading', 'Waiting for YouTube playback (ads may count)')
        deadline = time.monotonic() + PLAYBACK_TIMEOUT
        while time.monotonic() < deadline and not cancel.is_set():
            media = api['get'](ip, '/query/media-player')
            plugin = media.find('plugin')
            if media.get('state') == 'play' and plugin is not None and plugin.get('id') == '837':
                emit(name, 'playing', f'YouTube playback detected; {DURATION} seconds at volume {VOLUME}')
                played = not cancel.wait(DURATION)
                break
            cancel.wait(0.5)
        if not played:
            raise RuntimeError('Cancelled' if cancel.is_set() else 'YouTube playback not confirmed')
    except Exception as exc:
        error = str(exc)
    finally:
        if snapshot is not None:
            emit(name, 'restoring', 'Restoring volume, mute state, and previous app/input')
            errors = restore_device(api, snapshot)
            if errors:
                error = '; '.join(filter(None, [error, 'Restoration incomplete: ' + '; '.join(errors)]))
                error += '. Retry with roku yodel-restore'
            else:
                journal.unlink(missing_ok=True)
                emit(name, 'restored', f'Volume {snapshot["volume"]}; {snapshot["app_name"]}')
    if error:
        emit(name, 'error', error)
    return error is None


def run(api, device=None, restore=False, json_output=False):
    directory = Path(os.path.dirname(api['CACHE'])) / 'roku-yodel'
    directory.mkdir(parents=True, exist_ok=True)
    output_lock = threading.Lock()

    def emit(name, status, message):
        with output_lock:
            if json_output:
                print(json.dumps({'name': name, 'status': status, 'message': message}), flush=True)
            else:
                print(f'{name}: {message}', flush=True)

    with (directory / 'run.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            emit('Yodel Nuke', 'error', 'Another Yodel Nuke or restoration is already running')
            return 1
        cancel = threading.Event()
        previous_handlers = {sig: signal.signal(sig, lambda *_: cancel.set()) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            if restore:
                selected = api['resolve'](device) if device else None
                success = True
                for path in sorted(directory.glob('*.json')):
                    try:
                        snapshot = json.loads(path.read_text())
                        if selected and snapshot['ip'] != selected:
                            continue
                        errors = restore_device(api, snapshot)
                        if errors:
                            emit(snapshot['name'], 'error', '; '.join(errors))
                            success = False
                        else:
                            path.unlink()
                            emit(snapshot['name'], 'restored', 'Saved volume, mute state, and app restored')
                    except (OSError, ValueError, KeyError, TypeError) as error:
                        emit(path.stem, 'error', f'Cannot restore saved state: {error}')
                        success = False
                emit('Yodel Nuke', 'complete', 'Restoration finished' if success else 'Some TVs still need restoration')
                return 0 if success else 1
            if device:
                ip = api['resolve'](device)
                devices = {ip: api['load']()['devices'].get(ip, device)}
            else:
                emit('Yodel Nuke', 'scanning', 'Finding TVs on the local network')
                devices = api['discover']()['devices']
            if not devices:
                emit('Yodel Nuke', 'complete', 'No TVs found')
                return 0
            with concurrent.futures.ThreadPoolExecutor(max_workers=min(32, len(devices))) as pool:
                futures = [pool.submit(yodel_device, api, ip, name, directory, cancel, emit)
                           for ip, name in devices.items()]
                results = [future.result() for future in futures]
            success = all(results) and not cancel.is_set()
            emit('Yodel Nuke', 'complete', 'Finished; all changed TVs restored' if success else 'Finished with errors; check the TV results')
            return 0 if success else 1
        finally:
            for sig, handler in previous_handlers.items():
                signal.signal(sig, handler)
