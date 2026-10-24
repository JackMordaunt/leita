package leita_history

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../kstat"

/*
baseline_path is where a scan of place keeps its whole tree between runs, for
survey.Fill.baseline: a file named for place's FNV-1a hash in a baselines folder
beside the store at store (default_path), "" when store is "". A baseline is not
history, which keeps only entries of at least KEPT_MIN, and is replaced on every
run rather than added to. In allocator.
*/
baseline_path :: proc(store, place: string, allocator := context.allocator) -> string {
	if store == "" {
		return ""
	}
	name := fmt.tprintf("%016x.tree", hash.fnv64a(transmute([]u8)place))
	path, _ := filepath.join({filepath.dir(store), "baselines", name}, allocator)
	return path
}

/*
BASELINE_KEPT is how long a baseline no scan has rewritten is kept. Every scan of a
place with history on rewrites its baseline, so only places no longer scanned grow
old. One older than this is seldom updated from: Linux reads a place whole once its
last whole read is older than changes.STALE_AFTER, 7 days, and on macOS a month of a
busy volume's events can pass changes.REPLAY_MOST, whose doc puts a busy day's replay
near the cost of a whole read. Kept, each would hold disk for nothing: a home
directory's of 2.57 million entries was 99 MB (README, 2026-10-13).
*/
BASELINE_KEPT :: 30 * 24 * time.Hour

/*
STAGE_KEPT is how long a temporary file a baseline save wrote is kept: one older was
left by a save that was stopped, killed or out of space before its rename, and each
is as large as the baseline. A save writes its file in one go, 125 ms for 2.1 million
nodes (survey.baseline_save). Should a save be suspended for longer between its write
and its rename, its file pruned, the rename fails and the baseline is not kept: the
next scan of the place reads it whole, as it does after any save that failed.
*/
STAGE_KEPT :: time.Hour

/*
prune_baselines deletes each file in the baselines folder beside the store at store
last written more than BASELINE_KEPT before now, and each temporary file a stopped
save left among them (".new") last written more than STAGE_KEPT before. A file that
cannot be read or deleted is left for the next prune.
*/
prune_baselines :: proc(store: string, now: time.Time) {
	dir, join_err := filepath.join({filepath.dir(store), "baselines"}, context.temp_allocator)
	if join_err != nil {
		return
	}
	files, read_err := kstat.read_directory(dir, context.temp_allocator)
	if read_err != nil {
		return
	}
	for f in files {
		if f.type != .Regular {
			continue
		}
		kept := STAGE_KEPT if strings.has_suffix(f.name, ".new") else BASELINE_KEPT
		if time.diff(f.modification_time, now) > kept {
			_ = os.remove(f.fullpath)
		}
	}
}
