# Allocation correctness fixtures

This runner measures an existing Leita CLI on small, fresh fixtures. It complements
`tools/fsbench` and the website's existing `benchmarks/benchmark.py`; it does not
measure speed or change the CI performance baseline.

Use Python 3.11 or newer on macOS or Linux, and a built Leita CLI:

```sh
just cli speed
python3 tools/truth/runner.py \
  --leita build/speed/leita \
  --workspace build/truth-first-run \
  --source-revision "$(git rev-parse HEAD)" > build/truth-first-run.stdout.json
cat build/truth-first-run/table.md
python3 -m unittest discover -s tools/truth -p 'test_*.py' -v
```

`--source-revision` is an operator declaration about the supplied binary. It must
name the source actually used to build that executable, which may differ from
the checkout running the harness. The result also retains the executable's SHA256
before and after measurement and its own reported version. A matching version
string alone does not prove source identity. An existing binary from another
checkout can be measured without supplying a source revision; its source then
remains unknown.

The workspace must not exist; its parent must already exist. An existing file,
directory or symlink, including a dangling symlink, is refused. Each invocation
needs a different workspace. The runner creates no mounts, deletes no fixtures,
uses no `sudo`, and does not change system services. Fixtures, raw command output,
`results.json` and `table.md` remain under that private workspace. Remove only a
workspace you have reviewed and no longer need. No cleanup command runs as part
of the measurement.

Leita runs with `--whole --no-history --color never --report - --format json`.
Its home/XDG directories are isolated outside the measured targets, inherited
`LEITA_*` settings are removed, and commands are passed as argument arrays. The
runner's stdout is one JSON document; child stderr is retained inside it rather
than mixed into that stream. Invalid configuration is an argparse error on
stderr with exit 2. A comparable mismatch or failed command/fixture run exits 1.
Unknown/skipped measurements do not fail by themselves, and must not be presented
as passing proof.

## What the fixtures establish

- **Dense:** seeded incompressible bytes around block boundaries, including empty
  files. File lengths do not stand in for allocation.
- **Sparse:** a hole-only file and a file with separated writes. Each file records
  whether its measured allocation is actually less than its length; a filesystem
  that allocates the full length has not demonstrated sparse storage for that
  file merely because `truncate` or `seek` was called.
- **Hard links:** one file named in different subdirectories and at the root,
  plus an independent file. The oracle counts each regular-file
  `(st_dev, st_ino)` identity once within a target.
- **Odd names:** spaces, newlines, tabs, a leading dash, Unicode and bidirectional
  text. JSON escapes preserve the names; no shell parses them.
- **Symlinks:** file, loop, dangling and outside-target directory links. The oracle
  uses `lstat`, never follows them, and verifies only the target tree.
- **Unread:** a directory owned by the run is made inaccessible. The process must
  actually receive permission denial; privileged processes that can still list
  it produce a skipped permission test. Visible bytes and the unread count are
  checked, but the scan remains explicitly partial. Access to the owned directory
  is restored after measurement so the retained workspace is inspectable.

Mount-boundary and shared/reflink/compression cases are explicit skipped rows.
The runner cannot create a physical-allocation oracle by looking at `st_blocks`
or successfully copying a file. Native disposable-volume tests remain in
`tools/btrfs-fixture`, the native filesystem tests and platform-specific CI.
This slice does not establish Windows, WizTree or TreeSize correctness.

## Accounting and verdicts

The independent Python oracle records native `lstat` fields and content hashes,
and takes snapshots before and after the Leita/du commands. A changed fixture
has `coverage: "mutated"` and unknown comparison results, rather than a fabricated
stable correctness verdict. Scan coverage is `complete`, `partial`,
`not-completed`, `mutated`, or `not-run`; a complete scan can still fail a
correctness comparison.

On these regular-file fixtures, Leita charges unique regular-file allocation and
charges directory/symlink entries zero. Non-followed symlinks still contribute
file entries to the report count. Directory count excludes the target itself;
permission-denied directories are counted and separately reported as unread.
The contract is derived from the current walker/report implementation and is
checked independently against actual native metadata.

`du -sk` is run once per target with exactly one operand, preserving its default
within-target hard-link deduplication. GNU and BSD `du -k` report KiB. The exact
reconciliation is:

```text
Leita bytes = sum(st_blocks * 512 for unique regular-file identities)
du KiB = ceil((regular + directory + symlink allocated bytes) / 1024)
```

The second equation includes the target directory's own allocation. It does not
round every file independently. `BLOCK_SIZE`, `BLOCKSIZE`, `DU_BLOCK_SIZE` and
`POSIXLY_CORRECT` are cleared. Failed/partial `du` output is retained and marked
unknown, even if it printed a number. No tolerance is used to hide a difference.

Allocation equality is checked only on an identified filesystem with established
plain-file semantics, known allocation/identity metadata, and a Leita report
whose `logical` and `scan_order` flags are both false. Unknown filesystem type,
unknown identity, Btrfs sharing semantics, logical fallback or scan-order
estimation produce an unknown allocation comparison. Entry counts can still be
compared when identity is established. Unsupported feature operations are
explicit skips; unexpected fixture/command failures remain failures.

`results.json` uses schema `leita.truth/1` and retains seed, Python/OS/effective UID,
filesystem probe commands and raw output, executable and runner hashes,
operator-declared source revision, all Leita/du commands and output, full stat
snapshots and individual expected/actual verdicts. BSD `du` may have no version
flag; that failed version probe is recorded alongside its executable hash and
OS identity, not invented as a version.

Apparent regular bytes, charged allocations, directory/symlink allocations and
whole-volume free space are different quantities. The report stores
`unique_physical_bytes` and `deletion_savings_bytes` as null: this runner does not
measure either. It makes no claim that deleting any path returns its charged
size, or that candidate results certify a published release.
