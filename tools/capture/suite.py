#!/usr/bin/env python3
"""Capture current Leita views and a verified, disposable growth scenario."""
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


def export(path, include=False, frames=None):
    steps = ['-click', 'Settings', '-click', 'Export', '-advance', '20',
             '-click', path.suffix[1:].upper()]
    if include:
        steps += ['-click', 'Include Reclaim candidates']
    if frames:
        steps += ['-frames', frames / '06-export-dialog-', '60']
    steps += ['-click', 'Export', '-advance', '5', '-pick', str(path),
              '-await-file', str(path)]
    if frames:
        steps += ['-frames', frames / '07-report-saved-', '60']
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
    root = fixture_root / theme / 'example-project'
    root.mkdir(parents=True)
    (root / 'CMakeLists.txt').write_text('project(example)\n')
    payload(root / 'source' / 'assets.bin', 2 << 20, 1)
    payload(root / 'docs' / 'reference.bin', 1 << 20, 2)
    expected_before = allocated(root)
    reports = fixture_root / theme / 'reports'
    reports.mkdir()
    before, after = reports / 'before.json', reports / 'after.json'
    ready, resume = base / 'ready', base / 'resume'
    frame_dir = base / 'frames'
    if frames:
        frame_dir.mkdir()
    def shot(name, count=60):
        return ['-frames', frame_dir / name, str(count)] if frames else []
    rescan = ['-key', 'Shortcut+R', *shot('03-rescan-'), '-await', 'Done'] if frames else ['-rescan']
    args = [binary, root, data, theme, *shot('00-scan-', 30),
            '-await', 'Done', '-advance', '30', '-png', base / 'before.png',
            *shot('01-before-'), *export(before, include=True),
            '-signal', ready, '-await-file', resume, *shot('02-build-added-', 30),
            *rescan, '-advance', '30',
            '-click', 'Change', '-advance', '30', '-png', base / 'growth.png',
            *shot('04-growth-'), '-click', 'Reclaim', '-advance', '30',
            '-png', base / 'reclaim.png', *shot('05-reclaim-'),
            *export(after, frames=frame_dir if frames else None), *export(reports / 'report.html')]
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
            if process.wait(timeout=180) != 0:
                raise RuntimeError(f'fixture capture failed; see {base / "capture.log"}')
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait()
    for path in (before, after, reports / 'report.html'):
        shutil.copy2(path, base / path.name)
    if frames:
        encode(frame_dir, base / 'demo.mp4')
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
    return result


def encode(frames, output):
    run(['ffmpeg', '-nostdin', '-v', 'error', '-framerate', '30', '-pattern_type', 'glob',
         '-i', frames / '*.png', '-c:v', 'libx264', '-preset', 'fast',
         '-crf', '20', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', output])


def synthetic(binary, out, frames):
    for theme in ('light', 'dark'):
        base = out / theme
        base.mkdir()
        data = base / 'data'
        data.mkdir()
        env = dict(os.environ, XDG_DATA_HOME=str(data), LEITA_SYNTHETIC='0')
        run([binary, '/', data, theme, '-await', 'Done'], env=env)
        env['LEITA_SYNTHETIC'] = '7'
        steps = ['-await', 'Done', '-advance', '60']
        sequence = [('sunburst', 'Sunburst', 'Folder'), ('treemap', 'Treemap', 'Folder'),
                    ('icicle', 'Icicle', 'Folder'), ('change', 'Treemap', 'Change'),
                    ('reclaim', 'Reclaim', None)]
        if frames:
            (base / 'frames').mkdir()
        for number, (name, mode, colour) in enumerate(sequence):
            steps += ['-click', mode]
            if colour:
                steps += ['-click', colour]
            steps += ['-advance', '30', '-png', base / f'{name}.png']
            if frames:
                steps += ['-frames', base / 'frames' / f'{number:02}-{name}-', str(frames)]
        steps += export(base / 'report.json', include=True) + export(base / 'report.html')
        run([binary, '/', data, theme, *steps], env=env)
        if frames:
            encode(base / 'frames', base / 'demo.mp4')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='new output directory; existing directories are refused')
    parser.add_argument('--binary', type=Path, default=ROOT / 'build' / 'capture')
    parser.add_argument('--fixture-root', type=Path, required=True,
                        help='new directory on tmpfs, e.g. /tmp/leita-example-<id>')
    parser.add_argument('--jm-revision', required=True, help='exact jm revision used to build the driver')
    parser.add_argument('--frames', type=int, default=60, help='frames per scene at 30 fps; 0 for stills')
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
    files = {}
    for path in sorted(args.output.rglob('*')):
        if path.is_file() and 'data' not in path.relative_to(args.output).parts:
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
                    fixture_video=dict(fps=30, frames=420 if args.frames else 0, seconds=14 if args.frames else 0,
                                       scenes=['scan', 'before', 'build-added', 'rescan', 'growth', 'reclaim', 'export-dialog', 'report-saved']),
                    hero=dict(fps=30, frames_per_scene=args.frames,
                              scenes=['sunburst', 'treemap', 'icicle', 'change', 'reclaim']),
                    fixture=validation, sha256=files)
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(args.output / 'manifest.json')


if __name__ == '__main__':
    main()
