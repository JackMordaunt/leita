#!/usr/bin/env python3
"""Capture current Leita views and a verified, disposable growth scenario.

Licence and update flows are tools/capture/lifecycle.py. This script does not
activate a licence or talk to a release server. A recording types with -type
and draws that text on the next hold.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def run(argv, **kwargs):
    subprocess.run([str(x) for x in argv], check=True, **kwargs)


def export(path, include=False):
    steps = ['-click', 'Settings', '-click', 'Export', '-advance', '20',
             '-click', path.suffix[1:].upper()]
    if include:
        steps += ['-click', 'Include Reclaim candidates']
    steps += ['-click', 'Export', '-advance', '5', '-pick', str(path),
              '-await-file', str(path)]
    return steps + ['-advance', '600']


def payload(path, size, seed):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('wb') as file:
        rng = random.Random(seed)
        for _ in range(size // 65536):
            file.write(rng.randbytes(65536))
        file.flush()
        os.fsync(file.fileno())


def allocated(root):
    # Compare the report with the generated files' sum of st_blocks * 512.
    return sum(p.stat().st_blocks * 512 for p in root.rglob('*'))


def wait_file(path, process):
    deadline = time.monotonic() + 120
    while not path.exists():
        if process.poll() is not None:
            raise RuntimeError(f'capture exited {process.returncode} before {path}')
        if time.monotonic() > deadline:
            raise TimeoutError(path)
        time.sleep(.05)


def fixture(binary, out, fixture_root, theme, frames):
    base = out / 'fixture' / theme
    base.mkdir(parents=True)
    data = base / 'data'
    data.mkdir()
    root = fixture_root / 'example-project'
    root.mkdir(parents=True)
    (root / 'CMakeLists.txt').write_text('project(example)\n')
    payload(root / 'source' / 'assets.bin', 2 << 20, 1)
    payload(root / 'docs' / 'reference.bin', 1 << 20, 2)
    expected_before = allocated(root)
    reports = fixture_root / theme / 'reports'
    reports.mkdir(parents=True)
    before, after = reports / 'before.json', reports / 'after.json'
    ready, resume = base / 'ready', base / 'resume'
    frame_dir = base / 'frames'
    if frames:
        frame_dir.mkdir()
    env = dict(os.environ)
    env.pop('LEITA_SYNTHETIC', None)
    env['XDG_DATA_HOME'] = str(data)
    # Record the before report independently; the filmed host keeps its own history.
    baseline_data = base / 'baseline-data'
    baseline_data.mkdir()
    run([binary, root, baseline_data, theme, '-await', 'Done', *export(before, include=True)], env=env)
    if frames:
        args = [binary, root, data, theme, '-await', 'Done', '-advance', '30',
                '-movie', frame_dir / 'frame-', '-hold', '45',
                '-tap', 'Settings', '-tap', 'Rescan',
                '-hold', '60', '-await', 'Done', '-png', base / 'before.png',
                '-signal', ready, '-await-file', resume,
                '-cue', 'Example build files added: 8 MiB build output + 1 MiB source growth',
                '-hold', '90', '-cue', '',
                '-tap', 'Settings', '-tap', 'Rescan',
                '-hold', '60', '-await', 'Done',
                '-tap', 'Change', '-hold', '84',
                '-png', base / 'growth.png',
                '-tap', 'Reclaim', '-hold', '96',
                '-png', base / 'reclaim.png',
                '-tap', 'Settings', '-tap', 'Export', '-tap', 'HTML',
                '-tap', 'Include Reclaim candidates', '-hold', '60', '-tap', 'Export',
                '-pick', reports / 'report.html', '-hold', '93', '-await-file', reports / 'report.html',
                '-end-movie', '-advance', '600', *export(after)]
    else:
        args = [binary, root, data, theme, '-await', 'Done', '-advance', '30',
                '-png', base / 'before.png', '-signal', ready, '-await-file', resume,
                '-rescan', '-advance', '30', '-click', 'Change', '-advance', '30',
                '-png', base / 'growth.png', '-click', 'Reclaim', '-advance', '30',
                '-png', base / 'reclaim.png', *export(after, include=True), *export(reports / 'report.html')]
    env = dict(os.environ)
    env.pop('LEITA_SYNTHETIC', None)
    env['XDG_DATA_HOME'] = str(data)
    with (base / 'capture.log').open('w') as log:
        process = subprocess.Popen([str(x) for x in args], env=env, stdout=log, stderr=log)
        try:
            wait_file(ready, process)
            # External build output appears while the same application stays open.
            (root / 'build').mkdir()
            (root / 'build' / 'CMakeCache.txt').write_text('CMAKE_PROJECT_NAME:STATIC=example\n')
            payload(root / 'build' / 'example.o', 8 << 20, 3)
            payload(root / 'source' / 'assets.bin', 3 << 20, 1)
            expected_after = allocated(root)
            expected_build = allocated(root / 'build')
            resume.write_text('rescan\n')
            if process.wait(timeout=300) != 0:
                raise RuntimeError(f'fixture capture failed; see {base / "capture.log"}')
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait()
    for path in (before, after, reports / 'report.html'):
        shutil.copy2(path, base / path.name)
    if frames:
        encode(frame_dir, base / 'demo.mp4')
        storyboard(base)
    first, second = json.loads(before.read_text()), json.loads(after.read_text())
    assert first['schema'] == second['schema'] == 'leita.report/1'
    assert first['compared'] is None
    assert first['totals']['bytes'] == expected_before, (first['totals'], expected_before)
    assert second['totals']['bytes'] == expected_after, (second['totals'], expected_after)
    assert second['compared']['bytes'] == expected_before
    assert first['totals']['files'] == 3 and second['totals']['files'] == 5
    assert first['totals']['unread'] == second['totals']['unread'] == 0
    assert not any(g['category'] == 'build_output' for g in first['reclaim']['groups'])
    group = next(g for g in second['reclaim']['groups'] if g['category'] == 'build_output')
    assert group['bytes'] == expected_build
    assert any(item['path'] == str(root / 'build') for item in group['items'])
    grown = next(f for f in second['largest_files'] if f['path'].endswith('/source/assets.bin'))
    assert grown['bytes_before'] == 2 << 20 and grown['change'] == 1 << 20
    result = dict(before_bytes=expected_before, after_bytes=expected_after,
                  growth_bytes=expected_after - expected_before, build_output_bytes=expected_build,
                  grown_file_change_bytes=grown['change'], validated=True,
                  mechanism='real app host, UI Rescan and Export; generated fixture files only')
    (base / 'validation.json').write_text(json.dumps(result, indent=2) + '\n')
    if theme == 'light':
        # Keep the completed light fixture beside its reports.
        root.rename(reports.parent / root.name)
    return result


def encode(frames, output):
    run(['ffmpeg', '-nostdin', '-v', 'error', '-framerate', '30', '-pattern_type', 'glob',
         '-i', frames / '*.png', '-c:v', 'libx264', '-preset', 'slow',
         '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', output])


def synthetic(binary, out, frames):
    for theme in ('light', 'dark'):
        base = out / theme
        base.mkdir()
        data = base / 'data'
        data.mkdir()
        env = dict(os.environ, XDG_DATA_HOME=str(data), LEITA_SYNTHETIC='0')
        run([binary, '/', data, theme, '-await', 'Done'], env=env)
        env['LEITA_SYNTHETIC'] = '7'
        steps = []
        if frames:
            (base / 'frames').mkdir()
            steps += ['-stream', '-movie', base / 'frames' / 'frame-', '-hold', '45']
            for index, mode in enumerate(('Sunburst', 'Treemap', 'Icicle')):
                if index:
                    steps += ['-tap', mode, '-hold', str((0, 45, 54)[index])]
                steps += ['-chart', 'Users', '-hold', str((75, 66, 81)[index]),
                          '-at', '/Users', '-tap', '/',
                          '-hold', str((30, 39, 45)[index]), '-at', '/']
            steps += ['-await', 'Done', '-end-movie']
        steps += ['-await', 'Done', '-advance', '60']
        for name, mode, colour in [('sunburst', 'Sunburst', 'Folder'),
                                  ('treemap', 'Treemap', 'Folder'), ('icicle', 'Icicle', 'Folder'),
                                  ('change', 'Treemap', 'Change'), ('reclaim', 'Reclaim', None)]:
            steps += ['-click', mode]
            if colour:
                steps += ['-click', colour]
            steps += ['-advance', '30', '-png', base / f'{name}.png']
        steps += export(base / 'report.json', include=True) + export(base / 'report.html')
        with (base / 'capture.log').open('w') as log:
            run([binary, '/', data, theme, *steps], env=env, stdout=log, stderr=log)
        if frames:
            encode(base / 'frames', base / 'demo.mp4')
            storyboard(base)


def storyboard(base):
    events = []
    count = 0
    progress = []
    navigation = []
    for line in (base / 'capture.log').read_text().splitlines():
        fields = line.split('\t')
        if fields[0] == 'ACTION':
            events.append(dict(frame=int(fields[1]), seconds=int(fields[1]) / 30,
                               action=fields[2], target=[float(fields[3]), float(fields[4])],
                               travel_frames=int(fields[5]), hover_frames=int(fields[6]),
                               press_frames=int(fields[7]), release_frames=int(fields[8])))
        elif fields[0] == 'NAVIGATION':
            navigation.append(dict(frame=int(fields[1]), view=fields[2], node=int(fields[3]), path=fields[4], state=fields[5]))
        elif fields[0] == 'CUE':
            events.append(dict(frame=int(fields[1]), seconds=int(fields[1]) / 30, cue=fields[2]))
        elif fields[0] == 'PROGRESS':
            progress.append(dict(frame=int(fields[1]), nodes=int(fields[2]), bytes=int(fields[3]), state=fields[4], scan_seconds=float(fields[5])))
        elif fields[0] == 'FRAMES':
            count = int(fields[1])
    assert count == len(list((base / 'frames').glob('*.png')))
    result = dict(fps=30, encoding=dict(codec='libx264', preset='slow', crf=18, pixel_format='yuv420p'), frames=count, seconds=count / 30, events=events,
                  pointer='macOS-style black arrow, thin white outline and subtle shadow',
                  pointer_motion='direct shallow curves; distance-paced travel and varied deterministic pauses; no parking moves',
                  source='continuous real app frames with dispatched pointer Move, Press and Release events')
    if progress:
        result['progress'] = progress
        result['navigation'] = navigation
        assert [(n['view'], n['path']) for n in navigation] == [(view, path) for view in ('Sunburst', 'Treemap', 'Icicle') for path in ('/Users', '/')], 'chart navigation differs'
        assert all(n['state'] == 'Scanning' for n in navigation if n['path'] == '/Users')
        assert all(n['node'] != 0 for n in navigation if n['path'] == '/Users')
        assert all(n['node'] == 0 for n in navigation if n['path'] == '/')
        assert all(abs(p['scan_seconds'] - min(p['frame'] / 30, 24)) < .11 for p in progress), 'scan display clock differs from movie clock'
        switches = [(event['action'], event['frame'] + event['travel_frames'] +
                     event['hover_frames'] + event['press_frames'])
                    for event in events if event.get('action') in ('Treemap', 'Icicle')]
        intervals = [('Sunburst', 0), *switches, ('Done', 720)]
        for (name, start), (_, stop) in zip(intervals, intervals[1:]):
            end = stop - 1
            samples = [p for p in progress if start <= p['frame'] <= end]
            assert len({p['nodes'] for p in samples}) > 10, f'{name} did not visibly scan'
            assert all(p['state'] == 'Scanning' for p in samples), f'{name} finished prematurely'
            assert samples[-1]['bytes'] > samples[0]['bytes']
    (base / 'storyboard.json').write_text(json.dumps(result, indent=2) + '\n')
    return result



def storyboard_difference(light, dark, path='$'):
    if type(light) is not type(dark):
        return f'{path}: light={light!r}, dark={dark!r}'
    if isinstance(light, dict):
        for key in sorted(light.keys() | dark.keys()):
            if key not in light or key not in dark:
                return f'{path}.{key}: missing from {"light" if key not in light else "dark"}'
            difference = storyboard_difference(light[key], dark[key], f'{path}.{key}')
            if difference:
                return difference
    elif isinstance(light, list):
        if len(light) != len(dark):
            return f'{path}.length: light={len(light)}, dark={len(dark)}'
        for index, (left, right) in enumerate(zip(light, dark)):
            difference = storyboard_difference(left, right, f'{path}[{index}]')
            if difference:
                return difference
    elif light != dark:
        return f'{path}: light={light!r}, dark={dark!r}'
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='new output directory; existing directories are refused')
    parser.add_argument('--binary', type=Path, default=ROOT / 'build' / 'capture')
    parser.add_argument('--fixture-root', type=Path, required=True,
                        help='new directory on tmpfs, e.g. /tmp/leita-example-<id>')
    parser.add_argument('--jm-revision', required=True, help='exact jm revision used to build the driver')
    parser.add_argument('--frames', type=int, default=60, help='enable fixed 30 fps interaction timelines when positive; 0 for stills')
    parser.add_argument('--fixture-only', action='store_true')
    args = parser.parse_args()
    if args.frames < 0:
        parser.error('--frames must be nonnegative')
    if args.output.exists() or args.fixture_root.exists():
        parser.error('output and fixture root must both be new; nothing is overwritten')
    # This fixture validates tmpfs only; refuse other filesystems.
    fs = subprocess.check_output(['stat', '-f', '-c', '%T', args.fixture_root.parent], text=True).strip()
    if fs != 'tmpfs' or str(args.fixture_root.resolve()).startswith('/dev/'):
        parser.error('--fixture-root must have an existing parent on tmpfs outside /dev (Reclaim protects /dev)')
    args.output = args.output.resolve()
    args.fixture_root = args.fixture_root.resolve()
    args.output.mkdir(parents=True)
    validation = {}
    for theme in ('light', 'dark'):
        validation[theme] = fixture(args.binary.resolve(), args.output, args.fixture_root, theme, args.frames > 0)
    if not args.fixture_only:
        synthetic(args.binary.resolve(), args.output, args.frames)
    if args.frames:
        pairs = [args.output / 'fixture'] + ([] if args.fixture_only else [args.output])
        for pair in pairs:
            difference = storyboard_difference(json.loads((pair / 'light/storyboard.json').read_text()),
                                               json.loads((pair / 'dark/storyboard.json').read_text()))
            assert difference is None, f'theme choreography differs in {pair}: {difference}'
    files = {}
    for path in sorted(args.output.rglob('*')):
        if path.is_file() and not any(part in ('data', 'baseline-data') for part in path.relative_to(args.output).parts):
            files[str(path.relative_to(args.output))] = hashlib.sha256(path.read_bytes()).hexdigest()
    application_revision = subprocess.check_output(
        ['git', 'log', '-1', '--format=%H', '--', '.', ':(exclude)tools/capture'], cwd=ROOT, text=True).strip()
    capture_revision = subprocess.check_output(
        ['git', 'log', '-1', '--format=%H', '--', 'tools/capture'], cwd=ROOT, text=True).strip() or None
    capture_sources = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in sorted((ROOT / 'tools' / 'capture').iterdir()) if p.is_file()}
    manifest = dict(source=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    application_revision=application_revision, capture_revision=capture_revision,
                    capture_source_sha256=capture_sources,
                    source_status=subprocess.check_output(['git', 'status', '--short'], cwd=ROOT, text=True),
                    jm_revision=args.jm_revision,
                    binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                    geometry=dict(logical=[1280, 820], density=2, pixels=[2560, 1640]),
                    fixture_video=json.loads((args.output / 'fixture/light/storyboard.json').read_text()) if args.frames else None,
                    hero=json.loads((args.output / 'light/storyboard.json').read_text()) if args.frames and not args.fixture_only else None,
                    fixture=validation, sha256=files)
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(args.output / 'manifest.json')


if __name__ == '__main__':
    main()
