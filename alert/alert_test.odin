package sonar_alert

import "base:runtime"

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:http/loopback"

import "../history"

GIB :: u64(1) << 30

// snaps is a snapshot every hour, newest first, of a disk of total bytes with
// used[i] in use i hours before the newest.
@(private)
snaps :: proc(total: u64, used: ..u64) -> []history.Snapshot {
	out := make([]history.Snapshot, len(used), context.temp_allocator)
	for u, i in used {
		out[i] = {
			id    = i64(len(used) - i),
			taken = 1_000_000 - i64(i) * 3600,
			disk  = {total, total - u},
		}
	}
	return out
}

@(test)
a_disk_filling_steadily_is_forecast_full :: proc(t: ^testing.T) {
	// 10 GiB an hour onto a disk with 100 GiB left: ten hours.
	days, ok := forecast(snaps(1000 * GIB, 900 * GIB, 890 * GIB, 880 * GIB, 870 * GIB))
	testing.expect(t, ok, "a rising line forecasts")
	testing.expectf(t, math.abs(days - 10.0 / 24) < 1e-9, "full in %v days", days)

	// Past full already, the line says now.
	days, ok = forecast(snaps(100 * GIB, 100 * GIB, 99 * GIB, 98 * GIB))
	testing.expect(t, ok)
	testing.expect_value(t, days, 0)
}

@(test)
a_disk_flat_or_emptying_has_no_forecast :: proc(t: ^testing.T) {
	_, flat := forecast(snaps(1000 * GIB, 500 * GIB, 500 * GIB, 500 * GIB))
	testing.expect(t, !flat, "flat")
	_, falling := forecast(snaps(1000 * GIB, 400 * GIB, 450 * GIB, 500 * GIB))
	testing.expect(t, !falling, "falling")
	_, rising := forecast(snaps(1000 * GIB, 500 * GIB, 499 * GIB, 498 * GIB))
	testing.expect(t, rising, "a rising line over as many points does")
}

@(test)
a_forecast_needs_enough_points_over_enough_time :: proc(t: ^testing.T) {
	_, two := forecast(snaps(1000 * GIB, 900 * GIB, 800 * GIB))
	testing.expect(t, !two, "two points are too few")

	short := snaps(1000 * GIB, 900 * GIB, 800 * GIB, 700 * GIB)
	for &s, i in short {
		s.taken = 1_000_000 - i64(i) * 60
	}
	_, minutes := forecast(short)
	testing.expect(t, !minutes, "three minutes is too short a span")

	// A snapshot from before the disk was kept is passed over, not read as empty.
	gap := snaps(1000 * GIB, 900 * GIB, 890 * GIB, 0, 870 * GIB, 860 * GIB)
	gap[2].disk = {}
	days, ok := forecast(gap)
	testing.expect(t, ok)
	testing.expectf(t, math.abs(days - 10.0 / 24) < 1e-9, "full in %v days", days)
}

@(test)
only_the_newest_snapshots_draw_the_line :: proc(t: ^testing.T) {
	// Ten newest filling 1 GiB an hour; anything older, emptying fast, is ignored.
	used := make([dynamic]u64, context.temp_allocator)
	for i in 0 ..< FORECAST_MOST {
		append(&used, (500 - u64(i)) * GIB)
	}
	for i in 0 ..< 20 {
		append(&used, u64(i) * GIB)
	}
	days, ok := forecast(snaps(1000 * GIB, ..used[:]))
	testing.expect(t, ok)
	testing.expectf(t, math.abs(days - 500.0 / 24) < 1e-6, "full in %v days", days)
}

@(test)
alerts_fire_on_their_own_rules :: proc(t: ^testing.T) {
	disk := history.Disk{100 * GIB, 5 * GIB}
	testing.expect_value(t, evaluate({}, {disk, 1.0}), Alerts{})
	testing.expect_value(t, evaluate({free_below = 10}, {disk, nil}), Alerts{.Low_Free})
	testing.expect_value(t, evaluate({free_below = 5}, {disk, nil}), Alerts{})
	testing.expect_value(t, evaluate({full_within = 7}, {disk, 3.0}), Alerts{.Filling})
	testing.expect_value(t, evaluate({full_within = 7}, {disk, 8.0}), Alerts{})
	testing.expect_value(t, evaluate({full_within = 7}, {disk, nil}), Alerts{})
	testing.expect_value(t, evaluate({10, 7}, {disk, 0.0}), Alerts{.Low_Free, .Filling})
	testing.expect_value(t, evaluate({free_below = 10}, {{}, nil}), Alerts{})
}

@(test)
a_report_reads_as_json_with_null_for_no_forecast :: proc(t: ^testing.T) {
	taken := time.unix(1_790_000_000, 0)
	disk := history.Disk{100 * GIB, 5 * GIB}
	r := report("box", "/srv", taken, {disk, nil}, {.Low_Free})
	data, ok := body(r)
	testing.expect(t, ok)

	v, err := json.parse_string(data, parse_integers = true, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	o := v.(json.Object)
	testing.expect_value(t, o["host"].(json.String), "box")
	testing.expect_value(t, o["target"].(json.String), "/srv")
	testing.expect_value(t, o["free"].(json.Integer), i64(5 * GIB))
	testing.expect_value(t, o["total"].(json.Integer), i64(100 * GIB))
	testing.expect_value(t, o["forecast_days"].(json.Null), nil)
	testing.expect_value(t, o["alerts"].(json.Array)[0].(json.String), "low_free")
	testing.expect_value(t, o["taken"].(json.String), "2026-09-21T14:13:20Z")
	text := o["text"].(json.String)
	testing.expectf(t, strings.contains(text, "/srv has 5.0% free"), "text %q", text)

	r = report("box", "/srv", taken, {disk, 2.4}, {.Filling})
	data, _ = body(r)
	v, _ = json.parse_string(data, allocator = context.temp_allocator)
	days := v.(json.Object)["forecast_days"]
	f, is_float := days.(json.Float)
	testing.expectf(t, is_float && f == 2.4, "forecast_days %v", days)
	testing.expect(t, strings.contains(r.text, "full in 2 days"), r.text)
}

// Listener is a test webhook: how it answers, and what it was sent.
@(private)
Listener :: struct {
	mutex:  sync.Mutex,
	body:   string,
	head:   string,
	status: string, // how to answer
}

@(private)
listen :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	h := (^Listener)(conn.server.user)
	sync.guard(&h.mutex)
	h.body = strings.clone(req.body, runtime.heap_allocator())
	h.head = strings.clone(req.head, runtime.heap_allocator())
	if h.status == "hold" {
		sync.mutex_unlock(&h.mutex)
		loopback.hold(conn)
		sync.mutex_lock(&h.mutex)
		return
	}
	buf: [128]byte
	loopback.send(conn, fmt.bprintf(buf[:], "HTTP/1.1 %s\r\nContent-Length: 0\r\n\r\n", h.status))
}

@(test)
a_report_is_posted_to_the_webhook :: proc(t: ^testing.T) {
	heard := Listener {
		status = "200 OK",
	}
	srv, ok := loopback.start(listen, &heard, runtime.heap_allocator())
	testing.expect(t, ok)
	defer {
		loopback.stop(srv)
		delete(heard.body, runtime.heap_allocator())
		delete(heard.head, runtime.heap_allocator())
	}

	r := report("box", "/srv", time.unix(0, 0), {{100, 5}, nil}, {.Low_Free})
	testing.expect_value(t, deliver(loopback.url(srv, "/hook"), r), "")
	sync.guard(&heard.mutex)
	want, _ := body(r)
	testing.expect_value(t, heard.body, want)
	testing.expect(t, strings.contains(heard.head, "POST /hook"), heard.head)
	testing.expect(
		t,
		strings.contains(
			strings.to_lower(heard.head, context.temp_allocator),
			"content-type: application/json",
		),
		heard.head,
	)
}

@(test)
a_webhook_that_refuses_or_hangs_is_reported :: proc(t: ^testing.T) {
	heard := Listener {
		status = "500 Oops",
	}
	srv, ok := loopback.start(listen, &heard, runtime.heap_allocator())
	testing.expect(t, ok)
	defer {
		loopback.stop(srv)
		delete(heard.body, runtime.heap_allocator())
		delete(heard.head, runtime.heap_allocator())
	}
	r := report("box", "/srv", time.unix(0, 0), {{100, 5}, nil}, {.Low_Free})
	testing.expect_value(t, deliver(loopback.url(srv, "/hook"), r), "HTTP 500")

	sync.lock(&heard.mutex)
	heard.status = "hold"
	delete(heard.body, runtime.heap_allocator())
	delete(heard.head, runtime.heap_allocator())
	heard.body, heard.head = "", ""
	sync.unlock(&heard.mutex)
	testing.expect_value(
		t,
		deliver(loopback.url(srv, "/hook"), r, 200 * time.Millisecond),
		"Timed_Out",
	)
}
