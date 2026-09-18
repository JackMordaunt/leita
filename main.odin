/*
sonar: find out what is using the disk.

Usage:
	sonar [drive-or-image]        default C:

Reads the volume's MFT directly and prints the largest files and directories. Reading
a live volume needs an elevated prompt.
*/
package main

import "core:debug/trace"
import "core:fmt"
import "core:os"
import "core:time"

// Only referenced inside `when ODIN_DEBUG`; @(require) keeps release builds from
// rejecting the import as unused.
@(require) import "debug"
import "ntfs"

TOP_N :: 20

main :: proc() {
	os.exit(debug_main())
}

// Deferred cleanup must run before os.exit, so the debug wiring lives one frame down.
debug_main :: proc() -> int {
	// Assertion failures print a call chain in every build; symbols need -debug.
	context.assertion_failure_proc = trace.assertion_failure_proc
	when ODIN_DEBUG {
		da: debug.Allocator
		debug.init(&da, context.allocator)
		defer debug.destroy(&da)
		defer debug.report(&da)
		context.allocator = debug.allocator(&da)
	}
	return run()
}

run :: proc() -> int {
	defer free_all(context.temp_allocator)

	target := "C:"
	if len(os.args) > 1 {
		target = os.args[1]
	}
	if target == "-h" || target == "--help" || target == "/?" {
		fmt.println("usage: sonar [drive-or-image]   (default C:)")
		return 0
	}

	fmt.printfln("sonar: reading MFT of %s", target)
	start := time.tick_now()
	m, err := ntfs.read_mft(target)
	if err != nil {
		#partial switch err {
		case .Access_Denied:
			fmt.eprintln("error: access denied. Reading a raw volume needs an administrator prompt.")
		case .Not_Ntfs:
			fmt.eprintln("error: not an NTFS volume")
		case .Open_Failed:
			fmt.eprintfln("error: could not open %s", target)
		case:
			fmt.eprintfln("error: %v", err)
		}
		return 1
	}
	defer ntfs.mft_destroy(&m)
	elapsed := time.tick_since(start)

	prefix := ""
	if len(target) <= 3 {
		prefix = fmt.tprintf("%c:", target[0])
	}

	print_summary(&m, elapsed)
	print_largest_files(&m, prefix)
	print_largest_directories(&m, prefix)
	return 0
}

print_summary :: proc(m: ^ntfs.Mft, elapsed: time.Duration) {
	files: u64
	allocated: u64
	for e in m.entries {
		if .In_Use not_in e.flags {
			continue
		}
		allocated += e.allocated
		if .Directory not_in e.flags {
			files += 1
		}
	}
	volume_bytes := m.boot.total_sectors * u64(m.boot.bytes_per_sector)
	fmt.println()
	fmt.printfln("volume     %s, %d B clusters, %d B records", human(volume_bytes), m.boot.bytes_per_cluster, m.boot.record_size)
	fmt.printfln("mft        %d slots, %d records, %d unreadable, read in %.0f ms", m.stats.records, m.stats.records_read, m.stats.records_bad, time.duration_milliseconds(elapsed))
	fmt.printfln("in use     %d files, %d directories, %d extra hard links", files, m.stats.directories, len(m.links))
	fmt.printfln("attributed %s summed from every file run list", human(allocated))

	/*
	$Bitmap counts allocated clusters without consulting a single file, so comparing it
	against the sum above checks the run list decoding. The two should agree closely;
	a wide gap means clusters are allocated that no file claims, which is a parsing bug
	rather than missing disk space.
	*/
	on_disk := m.stats.allocated_clusters * u64(m.boot.bytes_per_cluster)
	if on_disk > 0 {
		fmt.printfln("on disk    %s marked allocated in $Bitmap", human(on_disk))
		if on_disk >= allocated {
			gap := on_disk - allocated
			fmt.printfln("unclaimed  %s (%.2f%%) allocated but charged to no file", human(gap), 100 * f64(gap) / f64(on_disk))
		} else {
			fmt.printfln("overcount  %s more attributed than $Bitmap reports allocated", human(allocated - on_disk))
		}
	}
	if m.stats.resident_files > 0 {
		fmt.printfln("resident   %d files hold %s inside their MFT records, charged to $MFT", m.stats.resident_files, human(m.stats.resident_bytes))
	}
}

Sized :: struct {
	bytes:  u64,
	record: u32,
}

// Keep the N largest candidates in descending order without sorting the whole table.
// Most candidates fail the first comparison, so the scan stays linear.
@(private = "file")
top_n :: proc(top: []Sized, count: ^int, cand: Sized) {
	if count^ == len(top) && cand.bytes <= top[len(top) - 1].bytes {
		return
	}
	i := count^ if count^ < len(top) else len(top) - 1
	for i > 0 && top[i - 1].bytes < cand.bytes {
		top[i] = top[i - 1]
		i -= 1
	}
	top[i] = cand
	if count^ < len(top) {
		count^ += 1
	}
}

print_largest_files :: proc(m: ^ntfs.Mft, prefix: string) {
	top: [TOP_N]Sized
	count := 0
	for e, i in m.entries {
		if .In_Use not_in e.flags || .Directory in e.flags || e.allocated == 0 {
			continue
		}
		top_n(top[:], &count, Sized{bytes = e.allocated, record = u32(i)})
	}
	fmt.println()
	fmt.printfln("largest files (%d)", count)
	for s in top[:count] {
		fmt.printfln("  %10s  %s%s", human(s.bytes), prefix, ntfs.mft_path(m, s.record, context.temp_allocator))
	}
}

/*
Directory sizes are the point of the tool. Each entry's allocation is credited to
every ancestor by walking parent references; average depth is under ten, so this is a
single cheap pass even on millions of records. Entries whose parent chain is broken
(deleted directory, stale reference) stop at the last valid ancestor.
*/
print_largest_directories :: proc(m: ^ntfs.Mft, prefix: string) {
	totals := make([]u64, len(m.entries))
	defer delete(totals)

	for e, i in m.entries {
		if .In_Use not_in e.flags || e.name == "" {
			continue
		}
		if .Directory in e.flags {
			totals[i] += e.allocated
		}
		cur := e
		for depth := 0; depth < 64; depth += 1 {
			if !ntfs.entry_parent_valid(m, cur) {
				break
			}
			totals[cur.parent] += e.allocated
			if cur.parent == ntfs.RECORD_ROOT {
				break
			}
			cur = m.entries[cur.parent]
		}
	}

	top: [TOP_N]Sized
	count := 0
	for e, i in m.entries {
		if .In_Use not_in e.flags || .Directory not_in e.flags || totals[i] == 0 {
			continue
		}
		top_n(top[:], &count, Sized{bytes = totals[i], record = u32(i)})
	}
	fmt.println()
	fmt.printfln("largest directories (%d)", count)
	for s in top[:count] {
		fmt.printfln("  %10s  %s%s", human(s.bytes), prefix, ntfs.mft_path(m, s.record, context.temp_allocator))
	}
}

human :: proc(n: u64) -> string {
	units := [?]string{"B", "KiB", "MiB", "GiB", "TiB"}
	v := f64(n)
	i := 0
	for v >= 1024 && i < len(units) - 1 {
		v /= 1024
		i += 1
	}
	if i == 0 {
		return fmt.tprintf("%d B", n)
	}
	return fmt.tprintf("%.1f %s", v, units[i])
}
