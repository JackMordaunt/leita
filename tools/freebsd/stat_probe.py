#!/usr/bin/env python3
"""Record independent C/Python/Odin allocation and ABI facts before native tests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shlex
import subprocess
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[2]
ABI_FIELDS = ('size', 'mode_size', 'device', 'inode', 'links', 'mode', 'rdev',
              'atime', 'mtime', 'ctime', 'length', 'blocks')
STAT_FIELDS = ('device', 'inode', 'links', 'mode', 'length', 'blocks')


def parse(text):
    lines = {}
    for line in text.splitlines():
        label, *values = line.split()
        fields = ABI_FIELDS if label == 'abi' else STAT_FIELDS
        if label not in {'abi', 'lstat', 'fstatat'} or len(values) != len(fields):
            raise ValueError(f'bad stat probe record: {line!r}')
        lines[label] = dict(zip(fields, map(int, values)))
    if set(lines) != {'abi', 'lstat', 'fstatat'}:
        raise ValueError('stat probe did not emit all records')
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'FreeBSD':
        parser.error('this diagnostic requires native FreeBSD')
    binary = args.binary.resolve()
    evidence = dict(schema='leita.freebsd.stat-probe/1', platform=platform.platform(),
                    stages=[], abi_fields=ABI_FIELDS, stat_fields=STAT_FIELDS)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.output.write_text(json.dumps(evidence, indent=2) + '\n')

    def run(argv, **kwargs):
        result = subprocess.run([str(arg) for arg in argv], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
        if result.returncode:
            raise RuntimeError(f'{argv}: exit {result.returncode}: {result.stderr}')
        return result.stdout

    try:
        with tempfile.TemporaryDirectory(prefix='leita-stat-probe-') as directory:
            work = Path(directory)
            c_probe, odin_probe = work / 'c-stat', work / 'odin-stat'
            run(shlex.split(os.environ.get('CC', 'cc')) +
                ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                 ROOT / 'tools/freebsd/stat_probe.c', '-o', c_probe])
            run(shlex.split(os.environ.get('ODIN', 'odin')) +
                ['build', ROOT / 'tools/freebsd/stat_probe', '-vet', '-strict-style',
                 f'-out:{odin_probe}'])
            tree = work / 'tree'
            tree.mkdir()
            target = tree / 'random.bin'
            body = random.Random(883).randbytes(2 << 20)
            evidence['payload'] = dict(length=len(body), sha256=hashlib.sha256(body).hexdigest(),
                                       zlib_length=len(zlib.compress(body)))
            target.write_bytes(body)
            env = dict(os.environ, HOME=str(work / 'home'), XDG_DATA_HOME=str(work / 'data'),
                       XDG_CONFIG_HOME=str(work / 'config'), LEITA_LICENCE='')

            def sample(label):
                c = parse(run([c_probe, target]))
                odin = parse(run([odin_probe, target]))
                st = target.lstat()
                python = dict(zip(STAT_FIELDS, (st.st_dev, st.st_ino, st.st_nlink,
                                               st.st_mode, st.st_size, st.st_blocks)))
                report = work / f'{label}.json'
                output = run([binary, '--whole', '--no-history', '--report', report,
                              '--format', 'json', tree], env=env)
                record = dict(stage=label, c=c, odin=odin, python=python,
                              cli_totals=json.loads(report.read_text())['totals'],
                              cli_stdout=output)
                evidence['stages'].append(record)
                save()
                if c['abi'] != odin['abi']:
                    raise AssertionError('native C header layout differs from pinned Odin POSIX stat_t')
                # Allocation can change between probes before the TXG settles.
                identity = ('device', 'inode', 'links', 'mode', 'length')
                for method in ('lstat', 'fstatat'):
                    for field in identity:
                        if c[method][field] != python[field] or odin[method][field] != python[field]:
                            raise AssertionError(f'{label}: C/Python/Odin disagree on {method}.{field}')
                return record

            sample('closed')
            with target.open('rb') as file:
                os.fsync(file.fileno())
            sample('fsync')
            start = time.monotonic()
            os.sync()
            sample('sync')
            while target.stat().st_blocks * 512 < len(body):
                if time.monotonic() - start >= 10:
                    raise AssertionError('fixture allocation did not settle within 10 seconds after sync')
                time.sleep(0.01)
            evidence['settle_seconds'] = time.monotonic() - start
            settled = sample('settled')
            blocks = settled['python']['blocks']
            for source in ('c', 'odin'):
                for method in ('lstat', 'fstatat'):
                    if settled[source][method]['blocks'] != blocks:
                        raise AssertionError('settled C/Python/Odin allocation differs')
            if settled['cli_totals']['bytes'] != blocks * 512:
                raise AssertionError('settled CLI scan differs from native allocation')
            evidence['passed'] = True
            save()
            print(f'native C/Python/Odin stat ABI and settled allocation agree; evidence: {args.output}')
    except Exception as exc:
        evidence['error'] = str(exc)
        save()
        raise


if __name__ == '__main__':
    main()
