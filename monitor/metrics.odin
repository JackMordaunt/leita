package leita_monitor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

import "jm:sqlite3"

import "../faults"
import "../history"
import "../report"
import "../scan"
import "../settings"
import "../survey"

// These settings are opt-in. A missing destination makes the existing monitor
// do no metrics work. The versioned cache preserves measurements of places not
// due this run; its timestamps are never replaced with the publication time.
METRICS_PATH_KEY :: "monitor_metrics_path"
@(private)
METRICS_STATE_KEY       :: "monitor_metrics_state"
METRICS_WATCH_LIMIT     :: 64
METRICS_DIRECTORY_LIMIT :: 10
METRICS_LABEL_LIMIT     :: 1024 // bytes after reversible path encoding; never truncate
@(private)
METRICS_BYTE_LIMIT :: 2 * 1024 * 1024

@(private)
Metrics_Directory :: struct {
	path:  string,
	bytes: u64,
}

@(private)
Metrics_Sample :: struct {
	place:                                 string, // reversibly encoded label, not a raw filename
	run_id:                                i64,
	watch_added:                           i64,
	attempt:                               i64,
	last_success:                          i64,
	success:                               bool,
	measured:                              bool,
	seconds:                               f64,
	bytes, files, directories, unread:     u64,
	capacity_known:                        bool,
	disk_total, disk_free:                 u64,
	synthetic:                             bool,
	accounting_known, logical, scan_order: bool,
	folders:                               []Metrics_Directory,
	omitted:                               int,
}

@(private)
Metrics_State :: struct {
	version: int,
	samples: []Metrics_Sample,
}

// Configure the destination and reset retained samples together. A new path
// must not carry detailed state from a previous export configuration.
metrics_configure :: proc(st: ^settings.Store, path: string) -> (problem: string) {
	if err := sqlite3.exec(st.db, "BEGIN IMMEDIATE"); err != nil {return history.describe(err)}
	committed := false
	defer if !committed {_ = sqlite3.exec(st.db, "ROLLBACK")}
	previous, read_problem := metrics_setting(st, METRICS_PATH_KEY)
	if read_problem != "" {return read_problem}
	if err := settings.set(st, METRICS_PATH_KEY, path); err != nil {return history.describe(err)}
	if path == "" || path != previous {
		if err := settings.set(st, METRICS_STATE_KEY, "");
		   err != nil {return history.describe(err)}
	}
	if err := sqlite3.exec(st.db, "COMMIT"); err != nil {return history.describe(err)}
	committed = true
	return ""
}

// metrics_setting differs from a preference lookup: a failed read must not
// silently turn configured output off or replace a corrupt cache with defaults.
metrics_setting :: proc(st: ^settings.Store, key: string) -> (value, problem: string) {
	rows, err := sqlite3.query(
		st.db,
		"SELECT value FROM setting WHERE key = ?",
		key,
		allocator = context.temp_allocator,
	)
	if err != nil {return "", history.describe(err)}
	if sqlite3.next(&rows) {value = strings.clone(sqlite3.text(rows, 0), context.temp_allocator)}
	if err = sqlite3.finish(&rows); err != nil {return "", history.describe(err)}
	return
}

// metrics_label preserves valid Unicode and Prometheus-escapable newlines.
// Percent signs, other controls and invalid UTF-8 bytes are percent encoded;
// literal "%FF" and a filename containing byte FF remain distinct labels.
@(private)
metrics_label :: proc(path: string) -> (label: string, ok: bool) {
	if len(path) > METRICS_LABEL_LIMIT {return "", false}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(path); {
		c := path[i]
		_, n := utf8.decode_rune(path[i:])
		if c == '%' || c < 32 && c != '\n' || c == 127 || c >= 128 && n == 1 {
			hex := "0123456789ABCDEF"
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[c >> 4])
			strings.write_byte(&b, hex[c & 15])
			i += 1
		} else {
			strings.write_string(&b, path[i:i + n])
			i += n
		}
		if len(b.buf) > METRICS_LABEL_LIMIT {return "", false}
	}
	return strings.to_string(b), true
}

// Cache labels must already have passed path encoding. A newline is legal
// because metrics_quote escapes it; other raw controls are not exposition.
@(private)
metrics_valid_label :: proc(label: string) -> bool {
	if len(label) == 0 ||
	   len(label) > METRICS_LABEL_LIMIT ||
	   !utf8.valid_string(label) {return false}
	for c in transmute([]u8)label {
		if c < 32 && c != '\n' || c == 127 {return false}
	}
	return true
}

@(private)
metrics_find :: proc(samples: []Metrics_Sample, place: string) -> int {
	for s, i in samples {if s.place == place {return i}}
	return -1
}

@(private)
metrics_prepare :: proc(
	st: ^settings.Store,
	watches: []settings.Watch,
) -> (
	state: Metrics_State,
	problem: string,
) {
	raw: string
	raw, problem = metrics_setting(st, METRICS_STATE_KEY)
	if problem != "" {return {}, problem}
	previous: Metrics_State
	if raw != "" {
		if len(raw) > METRICS_BYTE_LIMIT {return {}, "metrics cache exceeds its byte limit"}
		if json.unmarshal_string(raw, &previous, allocator = context.temp_allocator) != nil {
			return {}, "metrics cache is invalid JSON; existing output was retained"
		}
		if previous.version !=
		   1 {return {}, "metrics cache has an unsupported version; existing output was retained"}
		if len(previous.samples) >
		   METRICS_WATCH_LIMIT {return {}, "metrics cache exceeds its watch limit"}
		for s, i in previous.samples {
			if !metrics_valid_label(s.place) ||
			   len(s.folders) > METRICS_DIRECTORY_LIMIT ||
			   s.run_id < 0 ||
			   s.attempt < 0 ||
			   s.last_success < 0 ||
			   s.seconds < 0 ||
			   math.is_nan(s.seconds) ||
			   math.is_inf(s.seconds) ||
			   s.omitted < 0 ||
			   s.measured && !s.success ||
			   s.capacity_known && (s.disk_total == 0 || s.disk_free > s.disk_total) ||
			   metrics_find(previous.samples[:i], s.place) >= 0 {
				return {}, "metrics cache has invalid measurements"
			}
			for f, j in s.folders {
				for before in s.folders[:j] {
					if before.path ==
					   f.path {return {}, "metrics cache has duplicate directory labels"}
				}
				if !metrics_valid_label(f.path) {
					return {}, "metrics cache has an invalid directory label"
				}
			}
		}
	}
	selected := make([dynamic]Metrics_Sample, 0, METRICS_WATCH_LIMIT, context.temp_allocator)
	for watch in watches {
		if len(selected) == METRICS_WATCH_LIMIT {break}
		label, ok := metrics_label(watch.place)
		if !ok {continue}
		s := Metrics_Sample {
			place       = label,
			watch_added = watch.added,
		}
		if i := metrics_find(previous.samples, label);
		   i >= 0 && previous.samples[i].watch_added == watch.added {s = previous.samples[i]}
		append(&selected, s)
	}
	return {version = 1, samples = selected[:]}, ""
}

// Scheduling orders by scan time. Metrics inspect insertion order instead,
// so a clock rollback cannot replace a newer attempt with an older-time row.
@(private)
metrics_last_record :: proc(
	st: ^settings.Store,
	place: string,
) -> (
	r: settings.Run,
	found: bool,
	last_success: i64,
	problem: string,
) {
	rows, err := sqlite3.query(
		st.db,
		`SELECT id, started, seconds, bytes, problem,
			(SELECT started FROM run WHERE place = ? AND problem = '' ORDER BY id DESC LIMIT 1)
			FROM run WHERE place = ? ORDER BY id DESC LIMIT 1`,
		place,
		place,
		allocator = context.temp_allocator,
	)
	if err != nil {return {}, false, 0, history.describe(err)}
	found = sqlite3.next(&rows)
	if found {
		r.id, r.started = sqlite3.integer(rows, 0), sqlite3.integer(rows, 1)
		r.seconds = sqlite3.real(rows, 2)
		r.bytes = u64(sqlite3.integer(rows, 3))
		r.problem = strings.clone(sqlite3.text(rows, 4), context.temp_allocator)
		last_success = sqlite3.integer(rows, 5)
	}
	if err = sqlite3.finish(&rows); err != nil {return {}, false, 0, history.describe(err)}
	return
}

// A run made while metrics were disabled has no retained detailed measurement.
// Never attach older quantities to a different row sharing the same second.
@(private)
metrics_observe_record :: proc(
	s: ^Metrics_Sample,
	r: settings.Run,
	found: bool,
	successful := i64(0),
) {
	if found &&
	   s.run_id == r.id &&
	   s.attempt == r.started &&
	   s.success == (r.problem == "") &&
	   (!s.measured || s.bytes == r.bytes && s.seconds == r.seconds) {return}
	place, added := s.place, s.watch_added
	if !found {
		s^ = {
			place       = place,
			watch_added = added,
		}
		return
	}
	last_success := successful
	if last_success == 0 && r.problem == "" {last_success = r.started}
	s^ = {
		place        = place,
		watch_added  = added,
		run_id       = r.id,
		attempt      = r.started,
		last_success = last_success,
		success      = r.problem == "",
	}
}

@(private)
metrics_finish :: proc(
	s: ^Metrics_Sample,
	r: settings.Run,
	measurement: Metrics_Sample,
	recorded: bool,
) {
	place, added, last_success := s.place, s.watch_added, s.last_success
	if r.problem == "" && recorded {
		s^ = measurement
		s.place, s.watch_added, s.run_id = place, added, r.id
		s.attempt, s.last_success = r.started, r.started
		s.success = true
	} else {
		s^ = {
			place        = place,
			watch_added  = added,
			run_id       = r.id,
			attempt      = r.started,
			last_success = last_success,
		}
	}
}

// The report owns the counting/accounting rules. Only ranking the at-most-two
// levels of directories is specific to this bounded export; totals can overlap
// between a parent and child, and must not be summed as independent space.
@(private)
metrics_measurement :: proc(r: ^report.Report, s: ^Place_Scan) -> (m: Metrics_Sample) {
	m.measured = true
	m.seconds = time.duration_seconds(r.duration)
	m.bytes, m.files, m.directories, m.unread = r.bytes, r.files, r.directories, r.unread
	m.synthetic = r.engine == .Synthetic
	if a, known := r.accounting.?; known {
		m.accounting_known, m.logical, m.scan_order = true, a.logical, a.scan_order
	}
	if sp, known := r.space.?; known && sp.total > 0 && sp.free <= sp.total {
		m.capacity_known = true
		m.disk_total, m.disk_free = sp.total, sp.free
	}
	ranked: [METRICS_DIRECTORY_LIMIT]Metrics_Directory
	count, candidates := 0, 0
	offer :: proc(
		s: ^Place_Scan,
		node: u32,
		ranked: []Metrics_Directory,
		count, candidates: ^int,
	) {
		bytes := survey.total(&s.roll, node)
		if bytes == 0 {return}
		candidates^ += 1
		if count^ == len(ranked) && bytes < ranked[count^ - 1].bytes {return}
		label, ok := metrics_label(scan.path(&s.tree, node, context.temp_allocator))
		if !ok {return}
		at := 0
		for at < count^ &&
		    (ranked[at].bytes > bytes ||
				    ranked[at].bytes == bytes && ranked[at].path < label) {at += 1}
		if at == len(ranked) {return}
		count^ = min(count^ + 1, len(ranked))
		for i := count^ - 1; i > at; i -= 1 {ranked[i] = ranked[i - 1]}
		ranked[at] = {label, bytes}
	}
	first := survey.children(&s.roll, s.top)
	for one, ok := survey.next_child(&first); ok; one, ok = survey.next_child(&first) {
		if .Directory not_in scan.node_flags(scan.node(&s.tree, one)) {continue}
		offer(s, one, ranked[:], &count, &candidates)
		second := survey.children(&s.roll, one)
		for two, has_two := survey.next_child(&second);
		    has_two;
		    two, has_two = survey.next_child(&second) {
			if .Directory in
			   scan.node_flags(
				   scan.node(&s.tree, two),
			   ) {offer(s, two, ranked[:], &count, &candidates)}
		}
	}
	m.folders = make([]Metrics_Directory, count, context.temp_allocator)
	copy(m.folders, ranked[:count])
	m.omitted = candidates - count
	return
}

@(private)
metrics_quote :: proc(b: ^strings.Builder, label: string) {
	strings.write_byte(b, '"')
	for c in transmute([]u8)label {
		switch c {
		case '\\':
			strings.write_string(b, `\\`)
		case '"':
			strings.write_string(b, `\"`)
		case '\n':
			strings.write_string(b, `\n`)
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

@(private)
metrics_line :: proc(b: ^strings.Builder, name, place: string, value: $T, path := "") {
	strings.write_string(b, name)
	if place != "" {
		strings.write_string(b, "{place=")
		metrics_quote(b, place)
		if path != "" {
			strings.write_string(b, ",path=")
			metrics_quote(b, path)
		}
		strings.write_byte(b, '}')
	}
	fmt.sbprintfln(b, " %v", value)
}

@(private)
metrics_render :: proc(state: Metrics_State, watches: int, now: i64) -> (text, problem: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"# Leita scheduled-scan gauges; path labels are explicitly enabled local output.\n",
	)
	for metric in ([][2]string{{"leita_metrics_generated_timestamp_seconds", "Unix seconds this textfile was generated; not the scan measurement time."}, {"leita_metrics_watches", "Number of configured watched places."}, {"leita_metrics_watches_omitted", "Watched places omitted by watch or label limits."}, {"leita_monitor_last_attempt_timestamp_seconds", "Unix seconds the last recorded attempt began; zero means never attempted."}, {"leita_monitor_last_success_timestamp_seconds", "Unix seconds the last successful scan and history save began; zero means none known."}, {"leita_monitor_scan_success", "Whether the last attempt scanned and saved history successfully; unread directories may still exist."}, {"leita_monitor_scan_measurement_known", "Whether quantities were captured for the last successful attempt."}, {"leita_monitor_scan_complete", "Whether the captured scan has no unread directories; not a promise that every filesystem feature is measurable."}, {"leita_monitor_scan_duration_seconds", "Elapsed seconds of the captured scan."}, {"leita_monitor_scan_charged_bytes", "Charged scan size; can include logical fallback or scan-order estimates as the accounting flags indicate; not deletion savings."}, {"leita_monitor_scan_files", "Files counted by the captured scan."}, {"leita_monitor_scan_directories", "Directories below the target counted by the captured scan."}, {"leita_monitor_scan_unread_directories", "Directories the captured scan could not read completely."}, {"leita_monitor_scan_accounting_known", "Whether accounting precision flags are known for the captured scan."}, {"leita_monitor_scan_logical", "Whether charged bytes include logical fallback instead of native allocation."}, {"leita_monitor_scan_order", "Whether charged accounting is a scan-order estimate."}, {"leita_monitor_scan_synthetic", "Whether the captured scan used the made-up demonstration filesystem."}, {"leita_monitor_volume_capacity_known", "Whether volume total and free counters were obtained for the captured scan."}, {"leita_monitor_volume_total_bytes", "Volume total capacity in bytes; can repeat across places on the same volume."}, {"leita_monitor_volume_free_bytes", "Volume free bytes; not space reclaimable from this place."}, {"leita_monitor_directory_charged_bytes", "Charged allocation of one of the largest directories at depth one or two; parent and child totals overlap."}, {"leita_monitor_directories_omitted", "Nonempty directories at depth one or two omitted by ranking or label limits."}}) {
		fmt.sbprintfln(&b, "# HELP %s %s", metric[0], metric[1])
		fmt.sbprintfln(&b, "# TYPE %s gauge", metric[0])
	}
	metrics_line(&b, "leita_metrics_generated_timestamp_seconds", "", now)
	metrics_line(&b, "leita_metrics_watches", "", watches)
	metrics_line(&b, "leita_metrics_watches_omitted", "", watches - len(state.samples))
	for s in state.samples {
		p := s.place
		metrics_line(&b, "leita_monitor_last_attempt_timestamp_seconds", p, s.attempt)
		metrics_line(&b, "leita_monitor_last_success_timestamp_seconds", p, s.last_success)
		metrics_line(&b, "leita_monitor_scan_success", p, int(s.success))
		metrics_line(&b, "leita_monitor_scan_measurement_known", p, int(s.measured))
		metrics_line(&b, "leita_monitor_scan_complete", p, int(s.measured && s.unread == 0))
		metrics_line(
			&b,
			"leita_monitor_volume_capacity_known",
			p,
			int(s.measured && s.capacity_known),
		)
		if !s.measured {continue}
		metrics_line(&b, "leita_monitor_scan_duration_seconds", p, s.seconds)
		metrics_line(&b, "leita_monitor_scan_charged_bytes", p, s.bytes)
		metrics_line(&b, "leita_monitor_scan_files", p, s.files)
		metrics_line(&b, "leita_monitor_scan_directories", p, s.directories)
		metrics_line(&b, "leita_monitor_scan_unread_directories", p, s.unread)
		metrics_line(&b, "leita_monitor_scan_synthetic", p, int(s.synthetic))
		metrics_line(&b, "leita_monitor_scan_accounting_known", p, int(s.accounting_known))
		metrics_line(&b, "leita_monitor_scan_logical", p, int(s.logical))
		metrics_line(&b, "leita_monitor_scan_order", p, int(s.scan_order))
		metrics_line(&b, "leita_monitor_directories_omitted", p, s.omitted)
		if s.capacity_known {
			metrics_line(&b, "leita_monitor_volume_total_bytes", p, s.disk_total)
			metrics_line(&b, "leita_monitor_volume_free_bytes", p, s.disk_free)
		}
		for f in s.folders {metrics_line(&b, "leita_monitor_directory_charged_bytes", p, f.bytes, f.path)}
		if len(b.buf) > METRICS_BYTE_LIMIT {return "", "metrics output exceeds its byte limit"}
	}
	// The text format groups each family's HELP, TYPE and samples together.
	// Sort only this bounded output; the scan itself is never sorted here.
	lines := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(strings.to_string(b), context.temp_allocator) {
		if len(line) > 0 &&
		   (!strings.has_prefix(line, "#") ||
				   strings.has_prefix(line, "# HELP ") ||
				   strings.has_prefix(line, "# TYPE ")) {
			append(&lines, line)
		}
	}
	slice.sort_by(
		lines[:],
		proc(a, b: string) -> bool {
			metric_name :: proc(line: string) -> string {
				rest := line[7:] if strings.has_prefix(line, "#") else line
				end := strings.index_any(rest, " {\t")
				return rest[:end] if end >= 0 else rest
			}
			an, bn := metric_name(a), metric_name(b)
			if an != bn {return an < bn}
			// Lexical order puts HELP before TYPE; both precede the samples.
			return a < b
		},
	)
	ordered := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&ordered,
		"# Leita scheduled-scan gauges; path labels are explicitly enabled local output.\n",
	)
	for line in lines {strings.write_string(&ordered, line); strings.write_byte(&ordered, '\n')}
	return strings.to_string(ordered), ""
}

@(private)
metrics_stage_counter: u64

// A fresh exclusive sibling prevents staging collisions and symlink following.
// Nothing touches the destination until the complete stage is synced/closed.
@(private)
metrics_write :: proc(path, text: string) -> string {
	serial := sync.atomic_add(&metrics_stage_counter, 1)
	stage := fmt.tprintf("%s.partial-%d-%d", path, os.get_pid(), serial)
	f, err := faults.open(stage, {.Write, .Create, .Excl}, os.Permissions_Read_All + {.Write_User})
	if err != nil {return fmt.tprintf("cannot create metrics stage: %v", err)}
	problem := ""
	bytes := transmute([]u8)text
	for len(bytes) > 0 {
		n, e := faults.write(f, bytes)
		if e != nil || n <= 0 {
			problem = fmt.tprintf("cannot write metrics stage: %v", e)
			break
		}
		bytes = bytes[n:]
	}
	if problem == "" && faults.sync(f) != nil {problem = "cannot sync metrics stage"}
	if err = os.close(f);
	   err != nil && problem == "" {problem = fmt.tprintf("cannot close metrics stage: %v", err)}
	if problem == "" && faults.rename(stage, path) != nil {problem = "cannot replace metrics file"}
	if problem != "" {_ = faults.remove(stage)}
	return problem
}

@(private)
metrics_publish :: proc(
	st: ^settings.Store,
	path: string,
	state: Metrics_State,
	watches: int,
	now: i64,
) -> string {
	text, problem := metrics_render(state, watches, now)
	if problem != "" {return problem}
	raw, err := json.marshal(state, allocator = context.temp_allocator)
	if err != nil || len(raw) > METRICS_BYTE_LIMIT {return "cannot encode bounded metrics cache"}
	if err := settings.set(st, METRICS_STATE_KEY, string(raw)); err != nil {
		return fmt.tprintf("cannot keep metrics measurements: %s", history.describe(err))
	}
	return metrics_write(path, text)
}
