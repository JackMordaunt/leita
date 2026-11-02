import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('freebsd_fixtures', Path(__file__).with_name('fixtures.py'))
fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixtures)


class AllocationOracleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_sparse_hardlinks_and_symlinks_have_independent_allocation(self):
        file = self.root / 'plain'
        file.write_bytes(b'x' * 16384)
        os.link(file, self.root / 'hardlink')
        with (self.root / 'sparse').open('wb') as out:
            out.seek(16 * 1024 * 1024)
            out.write(b'end')
        (self.root / 'link').symlink_to('plain')
        (self.root / 'empty').mkdir()
        answer = fixtures.allocation_oracle(self.root)
        expected = file.stat().st_blocks * 512 + (self.root / 'sparse').stat().st_blocks * 512
        self.assertEqual(answer['totals'], dict(bytes=expected, files=3, directories=1, unread=0))
        self.assertLess(expected, (self.root / 'sparse').stat().st_size)
        self.assertEqual(sum(e.get('charged', 0) for e in answer['entries']), expected)

    def test_boundary_is_not_traversed_even_on_same_device(self):
        boundary = self.root / 'mounted'
        boundary.mkdir()
        (boundary / 'inaccessible-mount-data').write_bytes(b'x' * 65536)
        self.assertEqual(boundary.stat().st_dev, self.root.stat().st_dev)
        answer = fixtures.allocation_oracle(self.root, boundaries=[boundary])
        self.assertEqual(answer['totals'], dict(bytes=0, files=0, directories=1, unread=0))

    def test_permission_failure_is_reported_and_not_treated_as_empty(self):
        denied = self.root / 'denied'
        denied.mkdir()
        (denied / 'secret').write_bytes(b'not measured')
        original = Path.iterdir

        def refuse(path):
            if path == denied:
                raise PermissionError('fixture')
            return original(path)

        with patch.object(Path, 'iterdir', refuse):
            answer = fixtures.allocation_oracle(self.root)
        self.assertEqual(answer['totals'], dict(bytes=0, files=0, directories=1, unread=1))

    def test_followed_ancestor_loop_terminates_without_duplicate_charges(self):
        sub = self.root / 'sub'
        sub.mkdir()
        (sub / 'value').write_bytes(b'value' * 4096)
        (sub / 'up').symlink_to('..', target_is_directory=True)
        answer = fixtures.allocation_oracle(self.root, follow=True)
        self.assertEqual(answer['totals']['bytes'], (sub / 'value').stat().st_blocks * 512)
        self.assertEqual(answer['totals']['files'], 2)

    def test_long_names_and_oracle_cli_are_json_serializable(self):
        long = self.root / ('n' * 255)
        long.write_bytes(b'long filename')
        result = subprocess.run([sys.executable, str(Path(fixtures.__file__)), '--oracle-root',
                                 str(self.root)], check=True, capture_output=True, text=True)
        answer = json.loads(result.stdout)
        self.assertEqual(answer['entries'][0]['path'], str(long))
        self.assertEqual(answer['totals']['files'], 1)


class EvidenceTest(unittest.TestCase):
    def test_pending_or_skipped_required_cases_do_not_claim_complete_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            harness = object.__new__(fixtures.Harness)
            harness.output = Path(directory)
            harness.evidence = dict(cases=[dict(name='pending', required=True)])
            harness.save()
            self.assertFalse(harness.evidence['complete'])
            harness.evidence['cases'][0]['status'] = 'skip'
            harness.save()
            self.assertFalse(harness.evidence['complete'])
            harness.evidence['cases'][0]['status'] = 'pass'
            harness.evidence['cases'].append(dict(name='optional', required=False, status='skip'))
            harness.save()
            self.assertTrue(harness.evidence['complete'])


if __name__ == '__main__':
    unittest.main()
