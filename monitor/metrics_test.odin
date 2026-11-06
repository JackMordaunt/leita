package leita_monitor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import jm_path "jm:path"

import "../faults"
import "../report"
import "../settings"

@(test)
metrics_labels_escape_without_collapsing_path_identities :: proc(t: ^testing.T) {
	label, ok := metrics_label("/tmp/a\"\\\nb%FF\xff")
	testing.expect(t, ok)
	b := strings.builder_make(context.temp_allocator)
	metrics_quote(&b, label)
	testing.expect_value(t, strings.to_string(b), "\"/tmp/a\\\"\\\\\\nb%25FF%FF\"")
	literal, _ := metrics_label("/tmp/%FF")
	invalid, _ := metrics_label("/tmp/\xff")
	testing.expect(
		t,
		literal != invalid,
		"an invalid byte and its percent spelling must stay distinct",
	)
	_, ok = metrics_label(strings.repeat("x", METRICS_LABEL_LIMIT + 1, context.temp_allocator))
	testing.expect(t, !ok, "overlong labels are omitted, never truncated")
	_, ok = metrics_label(strings.repeat("%", METRICS_LABEL_LIMIT, context.temp_allocator))
	testing.expect(t, !ok, "the encoded length is bounded too")
}

@(test)
metrics_state_keeps_not_due_measurements_and_prunes_removed_places :: proc(t: ^testing.T) {
	st: settings.Store
	testing.expect_value(t, settings.open(&st, ":memory:"), nil)
	defer settings.close(&st)
	old := Metrics_State {
		version = 1,
		samples = {
			{
				place = "/keep",
				attempt = 100,
				last_success = 100,
				success = true,
				measured = true,
				bytes = 42,
			},
			{place = "/removed", attempt = 100},
		},
	}
	raw, _ := json.marshal(old, allocator = context.temp_allocator)
	testing.expect_value(t, settings.set(&st, METRICS_STATE_KEY, string(raw)), nil)
	watches := make([]settings.Watch, METRICS_WATCH_LIMIT + 2, context.temp_allocator)
	watches[0].place = "/keep"
	for i in 1 ..< len(watches) {watches[i].place = fmt.tprintf("/place/%d", i)}
	state, problem := metrics_prepare(&st, watches)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(state.samples), METRICS_WATCH_LIMIT)
	testing.expect_value(t, state.samples[0].attempt, i64(100))
	testing.expect_value(t, state.samples[0].bytes, u64(42))
	testing.expect_value(t, metrics_find(state.samples, "/removed"), -1)
	text, _ := metrics_render(state, len(watches), 500)
	testing.expect(t, strings.contains(text, "leita_metrics_watches_omitted 2\n"), text)
	testing.expect(
		t,
		strings.contains(
			text,
			"leita_monitor_last_attempt_timestamp_seconds{place=\"/keep\"} 100\n",
		),
		text,
	)
	testing.expect(
		t,
		strings.contains(text, "leita_metrics_generated_timestamp_seconds 500\n"),
		text,
	)
	metrics_observe_record(&state.samples[0], {started = 200}, true)
	testing.expect(
		t,
		!state.samples[0].measured,
		"a newer run without captured details must not inherit old quantities",
	)
	testing.expect_value(t, state.samples[0].last_success, i64(200))
}

@(test)
metrics_corrupt_or_newer_state_is_explicit_and_preserved :: proc(t: ^testing.T) {
	st: settings.Store
	testing.expect_value(t, settings.open(&st, ":memory:"), nil)
	defer settings.close(&st)
	for raw in ([]string{"{", `{"version":2,"samples":[]}`}) {
		testing.expect_value(t, settings.set(&st, METRICS_STATE_KEY, raw), nil)
		_, problem := metrics_prepare(&st, nil)
		testing.expect(t, problem != "", "unsupported state must not silently become a new cache")
		kept, _ := metrics_setting(&st, METRICS_STATE_KEY)
		testing.expect_value(t, kept, raw)
	}
}

@(test)
metrics_partial_unknown_and_failed_attempts_are_distinct :: proc(t: ^testing.T) {
	m := Metrics_Sample {
		place        = "/partial",
		attempt      = 100,
		last_success = 100,
		success      = true,
		measured     = true,
		bytes        = 123,
		unread       = 2,
	}
	text, problem := metrics_render({version = 1, samples = {m}}, 1, 100)
	testing.expect_value(t, problem, "")
	testing.expect(
		t,
		strings.contains(text, "leita_monitor_scan_success{place=\"/partial\"} 1\n"),
		text,
	)
	testing.expect(
		t,
		strings.contains(text, "leita_monitor_scan_complete{place=\"/partial\"} 0\n"),
		text,
	)
	testing.expect(
		t,
		strings.contains(text, "leita_monitor_scan_unread_directories{place=\"/partial\"} 2\n"),
		text,
	)
	testing.expect(
		t,
		strings.contains(text, "leita_monitor_volume_capacity_known{place=\"/partial\"} 0\n"),
		text,
	)
	testing.expect(
		t,
		!strings.contains(text, "leita_monitor_volume_free_bytes{place="),
		"unknown capacity is absent, not zero",
	)
	metrics_finish(&m, {started = 200, problem = "cannot read"}, {}, true)
	text, _ = metrics_render({version = 1, samples = {m}}, 1, 200)
	testing.expect(
		t,
		strings.contains(text, "leita_monitor_scan_success{place=\"/partial\"} 0\n"),
		text,
	)
	testing.expect(
		t,
		strings.contains(
			text,
			"leita_monitor_last_success_timestamp_seconds{place=\"/partial\"} 100\n",
		),
		text,
	)
	testing.expect(
		t,
		!strings.contains(text, "leita_monitor_scan_charged_bytes{place="),
		"a failed attempt must not publish the prior measurement as current",
	)
}

@(test)
metrics_atomic_failures_keep_the_previous_file_and_remove_stages :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp("", "leita-metrics-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/leita.prom", dir)
	testing.expect_value(t, metrics_write(path, "old_metric 1\n"), "")
	for op in ([]faults.Op{.Open, .Write, .Sync, .Rename}) {
		faults.arm({op = op, fault = .No_Space, path = "leita.prom.partial-"})
		problem := metrics_write(path, "new_metric 2\n")
		faults.disarm()
		testing.expect(t, problem != "", "the caller must see the failure")
		testing.expect_value(t, faults.hits(), 1)
		raw, read_err := os.read_entire_file(path, context.temp_allocator)
		testing.expect_value(t, read_err, nil)
		testing.expect_value(t, string(raw), "old_metric 1\n")
		files, walk_err := jm_path.walk(dir, context.temp_allocator)
		testing.expect_value(t, walk_err, nil)
		testing.expect_value(t, len(files), 1)
	}
	faults.arm({op = .Write, fault = .Short, path = "leita.prom.partial-"})
	testing.expect(t, metrics_write(path, "short write must not replace old output\n") != "")
	faults.disarm()
	raw, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(raw), "old_metric 1\n")
	testing.expect_value(t, metrics_write(path, "recovered_metric 3\n"), "")
	raw, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(raw), "recovered_metric 3\n")
}

@(test)
metrics_cache_rejects_duplicate_series_controls_and_impossible_capacity :: proc(t: ^testing.T) {
	st: settings.Store
	testing.expect_value(t, settings.open(&st, ":memory:"), nil)
	defer settings.close(&st)
	for bad in ([]Metrics_Sample{{place = "/x\x00"}, {place = "/x", folders = {{path = "/a"}, {path = "/a"}}}, {place = "/x", folders = {{path = "/a\r"}}}, {place = "/x", capacity_known = true, disk_total = 0}, {place = "/x", capacity_known = true, disk_total = 10, disk_free = 11}}) {
		raw, _ := json.marshal(
			Metrics_State{version = 1, samples = {bad}},
			allocator = context.temp_allocator,
		)
		testing.expect_value(t, settings.set(&st, METRICS_STATE_KEY, string(raw)), nil)
		_, problem := metrics_prepare(&st, nil)
		testing.expect(t, problem != "", "malformed cached data must not become exposition")
	}
	scan: Place_Scan
	for space in ([]report.Space{{0, 0}, {10, 11}}) {
		r := report.Report {
			space = space,
		}
		m := metrics_measurement(&r, &scan)
		testing.expect(
			t,
			!m.capacity_known,
			"unknown capacity must not be published as an empty or overfull volume",
		)
	}
	r := report.Report {
		space = report.Space{10, 4},
	}
	m := metrics_measurement(&r, &scan)
	testing.expect(t, m.capacity_known)
	testing.expect_value(t, m.disk_free, u64(4))
}

@(test)
metrics_run_identity_is_distinct_from_its_second :: proc(t: ^testing.T) {
	m := Metrics_Sample {
		place        = "/x",
		run_id       = 1,
		attempt      = 100,
		last_success = 100,
		success      = true,
		measured     = true,
		bytes        = 42,
	}
	metrics_observe_record(&m, {id = 2, started = 100, problem = "failed"}, true, 100)
	testing.expect(t, !m.measured && !m.success)
	testing.expect_value(t, m.run_id, i64(2))
	m = {
		place        = "/x",
		run_id       = 1,
		attempt      = 100,
		last_success = 100,
		success      = true,
		measured     = true,
		bytes        = 42,
	}
	metrics_observe_record(&m, {id = 2, started = 100, bytes = 99}, true, 100)
	testing.expect(t, !m.measured && m.success)
	testing.expect_value(t, m.bytes, u64(0))
	st: settings.Store
	testing.expect_value(t, settings.open(&st, ":memory:"), nil)
	defer settings.close(&st)
	_, _ = settings.record(&st, {place = "/x", started = 1000})
	newest_id, _ := settings.record(&st, {place = "/x", started = 900})
	latest, found, _, problem := metrics_last_record(&st, "/x")
	testing.expect_value(t, problem, "")
	testing.expect(t, found)
	testing.expect_value(t, latest.id, newest_id)
	testing.expect_value(t, latest.started, i64(900))
	scheduled, _ := settings.last_run(&st, "/x", context.temp_allocator)
	testing.expect_value(t, scheduled.started, i64(1000))
}

@(test)
metrics_groups_each_family_before_the_next :: proc(t: ^testing.T) {
	text, problem := metrics_render(
		{
			version = 1,
			samples = {
				{place = "/a", success = true, measured = true, bytes = 11},
				{place = "/b", success = true, measured = true, bytes = 22},
			},
		},
		2,
		100,
	)
	testing.expect_value(t, problem, "")
	testing.expect(
		t,
		strings.contains(
			text,
			"leita_monitor_scan_charged_bytes{place=\"/a\"} 11\n" +
			"leita_monitor_scan_charged_bytes{place=\"/b\"} 22\n",
		),
		"family samples must be contiguous",
	)
}
