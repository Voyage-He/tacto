#!/usr/bin/env python3
"""Run real AVPlayer/audio_service transitions, without attaching a debugger."""
import argparse
import base64
from datetime import datetime
import json
from pathlib import Path
import subprocess
import tempfile
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator', help='UDID of a booted iOS simulator')
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    fixture = project / 'tool/fixtures/background_tone.m4a'
    flutter = project / '.fvm/flutter_sdk/bin/flutter'
    with tempfile.TemporaryDirectory(prefix='tacto-native-probe-') as temp:
        defines = Path(temp) / 'defines.json'
        defines.write_text(json.dumps({
            'TACTO_PROBE_AUDIO': base64.b64encode(fixture.read_bytes()).decode()
        }))
        if not args.skip_build:
            run(str(flutter), 'build', 'ios', '--simulator', '--debug', '--no-pub',
                '--target', 'tool/background_playback_probe.dart',
                '--dart-define-from-file=' + str(defines), cwd=project)
    app = project / 'build/ios/iphonesimulator/Runner.app'
    bundle = output('plutil', '-extract', 'CFBundleIdentifier', 'raw',
                    str(app / 'Info.plist'))
    subprocess.run(['xcrun', 'simctl', 'terminate', args.simulator, bundle],
                   capture_output=True)
    run('xcrun', 'simctl', 'install', args.simulator, str(app))
    root = Path(output('xcrun', 'simctl', 'get_app_container', args.simulator,
                       bundle, 'data'))
    trace = root / 'Library/Application Support/native-playback-probe/trace.jsonl'
    prior = trace.stat().st_mtime_ns if trace.exists() else 0
    run('xcrun', 'simctl', 'launch', args.simulator, bundle,
        '--enable-software-rendering', '--enable-impeller=false')
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if (trace.exists() and trace.stat().st_mtime_ns != prior
                and '"event":"started"' in trace.read_text()):
            break
        time.sleep(.1)
    else:
        raise RuntimeError('Probe did not start playback: ' + str(trace))
    run('xcrun', 'simctl', 'launch', args.simulator, 'com.apple.Preferences')
    print('Actual audio is now playing in the background.', flush=True)
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        rows = [json.loads(line) for line in trace.read_text().splitlines()]
        if any(row['event'] == 'systemState' and
               row['detail']['processing'] == 'completed' for row in rows):
            break
        time.sleep(.25)
    else:
        raise RuntimeError('Background queue stalled. Trace: ' + str(trace))
    errors = [row for row in rows if row['event'] == 'flutterError']
    assert not errors, errors
    ends = [row for row in rows if row['event'] == 'nativeComplete']
    ids = ['native-probe-1', 'native-probe-2', 'native-probe-3']
    assert [row['detail'] for row in ends] == ids, ends
    assert all(row['lifecycle'] == 'paused' for row in ends), ends
    started_at = next(row['at'] for row in rows if row['event'] == 'started')
    first_end_seconds = (datetime.fromisoformat(ends[0]['at']) -
                         datetime.fromisoformat(started_at)).total_seconds()
    assert first_end_seconds >= 40, first_end_seconds
    leases = [row['detail'] for row in rows if row['event'] == 'nativeLease']
    assert len(leases) == 3 and all(
        item['active'] and item['origin'] == 'track-tail' and
        item['applicationState'] == 2
        for item in leases), leases
    playing = [row['detail'] for row in rows if row['event'] == 'nowPlaying']
    assert [item['title'] for item in playing] == ids, playing
    assert all(item['nextEnabled'] for item in playing), playing
    ready = {row['detail']: row['at'] for row in rows
             if row['event'] == 'networkReady'}
    assert ready['audio native-probe-2'] < ends[0]['at'], ready
    assert ready['audio native-probe-3'] < ends[1]['at'], ready
    saved_trace = project / '.buildlog/ios-background-playback.jsonl'
    saved_trace.parent.mkdir(exist_ok=True)
    saved_trace.write_text(trace.read_text())
    print(json.dumps({
        'firstCompletionAfterSeconds': round(first_end_seconds, 1),
        'passed': True, 'nativeCompletions': len(ends),
        'nativeLeasesBeforeDart': len(leases),
        'nowPlayingTitles': [item['title'] for item in playing],
        'nextAudioPreparedBeforeCompletion': True, 'trace': str(saved_trace)
    }, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
