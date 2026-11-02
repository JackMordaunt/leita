#!/usr/bin/env python3
"""Native acceptance on disposable, file-backed FreeBSD filesystems.

No existing device is accepted as input. Root creates temporary vnode md devices;
the independent oracle and Leita both run as --native-user. Required skips return
2, assertion/setup errors return 1, and complete acceptance returns 0.
"""

import argparse
import csv
import io
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time


def allocation_oracle(root, *, boundaries=(), follow=False):
    """Count lstat allocation independently of Leita, never charging directories.

    Hard-linked regular files pay once by (device, inode). Symlinks cost zero;
    directory mounts are counted but not traversed. Explicit boundaries include
    nullfs, whose st_dev may equal the parent device. Permission failures count
    as unread. Run under the same uid as Leita for the permission comparison.
    """
    root = Path(root)
    stop = {os.path.realpath(p) for p in boundaries}
    root_device = root.stat().st_dev
    seen = set()
    totals = dict(bytes=0, files=0, directories=0, unread=0)
    entries = []

    def visit(folder, ancestors):
        try:
            current = folder.stat()
            identity = (current.st_dev, current.st_ino)
            if identity in ancestors or current.st_dev != root_device:
                return
            if os.path.realpath(folder) in stop:
                return
            children = sorted(folder.iterdir(), key=lambda p: os.fsencode(p.name))
        except OSError:
            totals['unread'] += 1
            return
        for path in children:
            try:
                info = path.lstat()
            except OSError:
                totals['unread'] += 1
                continue
            item = dict(path=str(path), logical=info.st_size,
                        allocated=max(0, info.st_blocks) * 512,
                        device=info.st_dev, inode=info.st_ino, links=info.st_nlink)
            if stat.S_ISDIR(info.st_mode):
                totals['directories'] += 1
                item['kind'] = 'directory'
                entries.append(item)
                visit(path, ancestors | {identity})
            elif stat.S_ISREG(info.st_mode):
                key = (info.st_dev, info.st_ino)
                item['kind'] = 'file'
                item['charged'] = 0 if key in seen else item['allocated']
                if key not in seen:
                    totals['files'] += 1
                    totals['bytes'] += item['allocated']
                    seen.add(key)
                entries.append(item)
            else:
                totals['files'] += 1
                item['kind'] = 'symlink' if stat.S_ISLNK(info.st_mode) else 'other'
                item['charged'] = 0
                entries.append(item)
                if follow and stat.S_ISLNK(info.st_mode):
                    # Follow only directories; loops terminate by ancestor identity.
                    try:
                        if path.is_dir():
                            visit(path, ancestors | {identity})
                    except OSError:
                        totals['unread'] += 1

    visit(root, set())
    return dict(totals=totals, entries=entries)


class Skipped(Exception):
    pass


class Harness:
    def __init__(self, args):
        self.args = args
        self.output = args.workdir.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.stage = Path(tempfile.mkdtemp(prefix='leita-freebsd-native-'))
        self.stage.chmod(0o755)
        self.user = pwd.getpwnam(args.native_user)
        if self.user.pw_uid == 0:
            raise ValueError('--native-user must be unprivileged')
        self.evidence = dict(schema='leita.freebsd.fixtures/1', uname=list(platform.uname()),
                             complete=False, cases=[], commands=[], started=time.time())
        self.cleanup = []
        self.binary = self.stage / 'leita'
        shutil.copy2(args.binary.resolve(), self.binary)
        self.binary.chmod(0o755)
        self.driver = self.stage / 'fixtures.py'
        shutil.copy2(__file__, self.driver)
        self.home = self.stage / 'home'
        self.home.mkdir(mode=0o700)
        os.chown(self.home, self.user.pw_uid, self.user.pw_gid)

    def command(self, argv, *, user=False, expected=0, timeout=120):
        command = list(map(str, argv))
        if user:
            env = ['/usr/bin/env', f'HOME={self.home}',
                   f'XDG_DATA_HOME={self.home / "data"}', 'LEITA_LICENCE=',
                   'LC_ALL=C', 'LANG=C', 'LEITA_COLOR=never',
                   'PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin']
            command = ['su', '-m', self.args.native_user, '-c', shlex.join(env + command)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        self.evidence['commands'].append(dict(argv=command, exit=result.returncode,
                                               stdout=result.stdout, stderr=result.stderr))
        if expected is not None and result.returncode != expected:
            raise AssertionError(f'{argv!r}: exit {result.returncode}, expected {expected}: '
                                 f'{result.stderr[-1500:]} {result.stdout[-500:]}')
        return result

    def case(self, name, action, *, required=True):
        entry = dict(name=name, required=required)
        self.evidence['cases'].append(entry)
        try:
            entry['details'] = action()
            entry['status'] = 'pass'
        except Skipped as exc:
            entry.update(status='skip', reason=str(exc))
        except Exception as exc:
            entry.update(status='fail', reason=f'{type(exc).__name__}: {exc}')
        self.save()

    def save(self):
        self.evidence['complete'] = all(c.get('status') == 'pass' for c in self.evidence['cases']
                                        if c['required'])
        (self.output / 'evidence.json').write_text(json.dumps(self.evidence, indent=2) + '\n')

    def vnode(self, name, size):
        image = self.stage / f'{name}.img'
        with image.open('xb') as file:
            file.truncate(size)
        result = self.command(['mdconfig', '-a', '-t', 'vnode', '-f', image])
        device = result.stdout.strip()
        if not re.fullmatch(r'md[0-9]+', device):
            raise AssertionError(f'unexpected mdconfig device {device!r}')
        self.cleanup.append(['mdconfig', '-d', '-u', device[2:]])
        return '/dev/' + device

    def mount_ufs(self):
        device = self.vnode('ufs', 256 * 1024 * 1024)
        mount = self.stage / 'ufs'
        mount.mkdir()
        self.command(['newfs', '-U', device])
        self.command(['mount', '-t', 'ufs', device, mount])
        self.cleanup.append(['umount', mount])
        return mount

    def mount_zfs(self):
        if not shutil.which('zpool') or not shutil.which('zfs'):
            raise Skipped('zpool/zfs tools unavailable')
        module = self.command(['kldstat', '-q', '-m', 'zfs'], expected=None)
        if module.returncode and self.command(['kldload', 'zfs'], expected=None).returncode:
            raise Skipped('ZFS kernel module unavailable')
        device = self.vnode('zfs', 512 * 1024 * 1024)
        pool = 'leita_fixture_' + str(os.getpid())
        mount = self.stage / 'zfs'
        mount.mkdir()
        # No force flag and no supplied/physical disks: only our fresh vnode.
        self.command(['zpool', 'create', '-o', 'cachefile=none', '-O', 'atime=off',
                      '-O', 'compression=off', '-m', mount, pool, device])
        self.cleanup.append(['zpool', 'destroy', pool])
        return mount

    def prepare(self, mount):
        root = mount / 'tree'
        root.mkdir()
        (root / 'sub').mkdir()
        (root / 'denied').mkdir()
        (root / 'nullfs').mkdir()
        (root / 'plain.bin').write_bytes(b'ordinary allocation\n' * 4096)
        (root / 'sub' / 'inside.txt').write_bytes(b'inside\n' * 1024)
        (root / ('n' * 255)).write_bytes(b'long name\n' * 1024)
        with (root / 'sparse.bin').open('wb') as file:
            file.seek((1 << 30) + 17)
            file.write(b'sparse tail\n')
            file.flush()
            os.fsync(file.fileno())
        os.link(root / 'plain.bin', root / 'sub' / 'hardlink.bin')
        (root / 'file-link').symlink_to('plain.bin')
        (root / 'directory-link').symlink_to('sub', target_is_directory=True)
        (root / 'sub' / 'ancestor-loop').symlink_to('..', target_is_directory=True)
        (root / 'denied' / 'secret.bin').write_bytes(b'must remain unread' * 4096)
        outside = mount / 'outside'
        outside.mkdir()
        (outside / 'must-not-enter.bin').write_bytes(b'outside mount\n' * 16384)
        (root / 'boundary-link').symlink_to('nullfs', target_is_directory=True)
        for base, dirs, files in os.walk(mount):
            for path in [Path(base), *(Path(base) / p for p in dirs + files)]:
                os.chown(path, self.user.pw_uid, self.user.pw_gid, follow_symlinks=False)
        (root / 'denied').chmod(0)
        return root, outside

    def oracle(self, root, boundaries):
        result = self.command([sys.executable, self.driver, '--oracle-root', root,
                               *sum((['--boundary', str(p)] for p in boundaries), [])], user=True)
        return json.loads(result.stdout)

    def scan(self, root, name, *, history=False, extra=(), expected=0):
        report = self.home / f'{name}.json'
        options = [] if history else ['--no-history']
        result = self.command([self.binary, root, *options, '--report', report,
                               '--top', '100', *extra], user=True, expected=expected)
        data = json.loads(report.read_text())
        shutil.copy2(report, self.output / report.name)
        return result, data

    def filesystem_matrix(self, label, mount):
        root, outside = self.prepare(mount)
        boundary = root / 'nullfs'
        mounted = self.command(['mount', '-t', 'nullfs', outside, boundary], expected=None)
        if mounted.returncode:
            self.case(label + '.nullfs', lambda: (_ for _ in ()).throw(
                Skipped('nullfs mount unavailable: ' + mounted.stderr.strip())))
            boundaries = []
        else:
            self.cleanup.append(['umount', boundary])
            boundaries = [boundary]
            self.case(label + '.nullfs', lambda: dict(source=str(outside), target=str(boundary)))
        os.sync()
        expected = self.oracle(root, boundaries)
        result, data = self.scan(root, label + '-allocation')
        sparse = (root / 'sparse.bin').stat()
        if sparse.st_blocks * 512 >= sparse.st_size:
            raise AssertionError('fixture is not sparse on this filesystem')
        if data['totals'] != expected['totals']:
            raise AssertionError(f'{label} allocation: {data["totals"]!r} != oracle {expected["totals"]!r}')
        if data['totals']['unread'] != 1:
            raise AssertionError('permission fixture did not report exactly one unread directory')
        if not any(p['path'].endswith('/' + 'n' * 255) for p in data['largest_files']):
            raise AssertionError('255-byte filename missing from report')
        if data.get('retention') is not None:
            raise AssertionError('BSD must not claim APFS snapshot or purgeable measurements')
        capacity = os.statvfs(root)
        if not data.get('space') or data['space']['total'] != capacity.f_blocks * capacity.f_frsize:
            raise AssertionError('volume capacity differs from independent statvfs')
        csv_path = self.home / (label + '.csv')
        self.command([self.binary, root, '--no-history', '--report', csv_path], user=True)
        rows = list(csv.DictReader(io.StringIO(csv_path.read_text(encoding='utf-8-sig'))))
        total = next(r for r in rows if r['section'] == 'total')
        if int(total['bytes']) != expected['totals']['bytes']:
            raise AssertionError('CSV allocation differs from oracle')
        shutil.copy2(csv_path, self.output / csv_path.name)
        self.scan(root, label + '-threshold', extra=['--min-free', '1TB'], expected=3)
        # A clean subtree avoids unread-directory baselines obscuring fallback.
        clean = root / 'sub'
        self.scan(clean, label + '-history-1', history=True)
        second, history = self.scan(clean, label + '-history-2', history=True)
        if 'read whole: the system cannot say what changes in this place' not in second.stdout + second.stderr:
            raise AssertionError('repeat scan did not explain the FreeBSD full-read fallback')
        self.command([self.binary, 'monitor', 'add', clean, '--every', 'hourly'], user=True)
        on = self.command([self.binary, 'monitor', 'on'], user=True)
        if 'no scheduler entry was installed' not in on.stdout:
            raise AssertionError('monitor on claimed a native scheduler')
        self.command([self.binary, 'monitor', 'run', '--all'], user=True)
        self.command([self.binary, 'monitor', 'run', '--all'], user=True)
        self.command([self.binary, 'monitor', 'off'], user=True)
        return dict(oracle=expected, totals=data['totals'], space=data['space'],
                    sparse_logical=(root / 'sparse.bin').stat().st_size,
                    sparse_allocated=(root / 'sparse.bin').stat().st_blocks * 512,
                    second_history_totals=history['totals'])

    def run(self):
        try:
            self.case('ufs', lambda: self.filesystem_matrix('ufs', self.mount_ufs()))
            self.case('zfs', lambda: self.filesystem_matrix('zfs', self.mount_zfs()))
            self.case('follow-cli', lambda: (_ for _ in ()).throw(
                Skipped('CLI exposes no --follow option; native walk tests cover engine follow and loop behavior')),
                required=False)
            self.case('licence-status', lambda: dict(output=self.command(
                [self.binary, 'licence'], user=True).stdout))
        finally:
            # Unwind only resources this process created, in reverse mount order.
            cleanup_failures = []
            for argv in reversed(self.cleanup):
                result = self.command(argv, expected=None)
                if result.returncode:
                    cleanup_failures.append(dict(argv=list(map(str, argv)), stderr=result.stderr))
            if cleanup_failures:
                self.evidence['cases'].append(dict(name='cleanup', required=True,
                    status='fail', details=cleanup_failures))
            else:
                shutil.rmtree(self.stage)
            self.evidence['finished'] = time.time()
            self.save()
        cases = self.evidence['cases']
        return 1 if any(c['status'] == 'fail' for c in cases) else 0 if self.evidence['complete'] else 2


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--workdir', type=Path)
    parser.add_argument('--native-user')
    parser.add_argument('--oracle-root', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--boundary', action='append', default=[], help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.oracle_root:
        print(json.dumps(allocation_oracle(args.oracle_root, boundaries=args.boundary)))
        return 0
    if not args.binary or not args.workdir or not args.native_user:
        parser.error('--binary, --workdir and --native-user are required')
    if platform.system() != 'FreeBSD' or os.geteuid() != 0:
        parser.error('native fixtures require root in a disposable FreeBSD VM')
    return Harness(args).run()


if __name__ == '__main__':
    sys.exit(main())
