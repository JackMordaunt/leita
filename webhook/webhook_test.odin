package leita_webhook

import "base:runtime"

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:http/loopback"

import "../alert"
import "../report"
import "../settings"

@(test)
a_body_is_signed_with_its_timestamp :: proc(t: ^testing.T) {
	// Python's hmac.new(b"k3y", b'1700000000.{"a":1}', hashlib.sha256).
	testing.expect_value(
		t,
		sign("k3y", 1_700_000_000, `{"a":1}`),
		"sha256=fd5a70e965043f7df6309c2c3b5ff5a8ffa99b1f5175e9a311459e73c4634d4a",
	)
	testing.expect(
		t,
		sign("k3y", 1_700_000_001, `{"a":1}`) != sign("k3y", 1_700_000_000, `{"a":1}`),
	)
	a, b := make_secret(context.temp_allocator), make_secret(context.temp_allocator)
	testing.expect_value(t, len(a), 2 * SECRET_BYTES)
	testing.expect(t, a != b, "each secret is new")
}

@(test)
only_https_is_sent_to_but_this_machine :: proc(t: ^testing.T) {
	testing.expect_value(t, check_url("https://hooks.example.com/leita"), URL_Problem.None)
	testing.expect_value(t, check_url("HTTPS://example.com:8443/x?y=1"), URL_Problem.None)
	testing.expect_value(t, check_url("http://127.0.0.1:9000/hook"), URL_Problem.None)
	testing.expect_value(t, check_url("http://localhost/hook"), URL_Problem.None)
	testing.expect_value(t, check_url("http://[::1]:9000/hook"), URL_Problem.None)
	testing.expect_value(t, check_url("http://example.com/hook"), URL_Problem.Not_Https)
	testing.expect_value(t, check_url("http://127.0.0.1.example.com/"), URL_Problem.Not_Https)
	testing.expect_value(t, check_url("ftp://example.com/"), URL_Problem.Not_Https)
	testing.expect_value(t, check_url("https://"), URL_Problem.No_Host)
	testing.expect_value(t, check_url("hooks.example.com"), URL_Problem.Not_Https)
}

@(test)
each_try_waits_twice_as_long_up_to_a_day :: proc(t: ^testing.T) {
	testing.expect_value(t, backoff(1), 5 * 60)
	testing.expect_value(t, backoff(2), 10 * 60)
	testing.expect_value(t, backoff(3), 20 * 60)
	testing.expect_value(t, backoff(30), 24 * 60 * 60)
	testing.expect_value(t, fate_of(204), Fate.Taken)
	testing.expect_value(t, fate_of(503), Fate.Later)
	testing.expect_value(t, fate_of(429), Fate.Later)
	testing.expect_value(t, fate_of(0), Fate.Later)
	testing.expect_value(t, fate_of(404), Fate.Refused)
	testing.expect_value(t, fate_of(301), Fate.Refused)
}

// Receiver is a webhook's server on this machine: it answers each POST with
// the next of answers, the last again once they run out, and keeps what it was
// sent and whether its signature held.
@(private = "file")
Receiver :: struct {
	mutex:   sync.Mutex,
	secret:  string,
	answers: []int,
	got:     [dynamic]Received,
}

@(private = "file")
Received :: struct {
	event:  string,
	body:   string,
	signed: bool, // the signature is the body's, under the secret, at its timestamp
}

@(private = "file")
receive :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	r := (^Receiver)(conn.server.user)
	header :: proc(head, name: string) -> string {
		rest := head
		for line in strings.split_lines_iterator(&rest) {
			if len(line) > len(name) + 1 &&
			   strings.equal_fold(line[:len(name)], name) &&
			   line[len(name)] == ':' {
				return strings.trim_space(line[len(name) + 1:])
			}
		}
		return ""
	}
	stamp, _ := strconv.parse_i64(header(req.head, "X-Leita-Timestamp"))
	signature := header(req.head, "X-Leita-Signature")
	tag, _ := hex.decode(
		transmute([]byte)strings.trim_prefix(signature, "sha256="),
		context.temp_allocator,
	)
	signed := fmt.tprintf("%d.%s", stamp, req.body)
	got := Received {
		event  = strings.clone(header(req.head, "X-Leita-Event"), runtime.heap_allocator()),
		body   = strings.clone(req.body, runtime.heap_allocator()),
		signed = hmac.verify(
			hash.Algorithm.SHA256,
			tag,
			transmute([]byte)signed,
			transmute([]byte)r.secret,
		),
	}
	status: int
	{
		sync.guard(&r.mutex)
		append(&r.got, got)
		status = r.answers[min(len(r.got), len(r.answers)) - 1]
	}
	loopback.send(conn, fmt.tprintf("HTTP/1.1 %d Answer\r\nContent-Length: 0\r\n\r\n", status))
}

@(private = "file")
receiver_destroy :: proc(r: ^Receiver) {
	for g in r.got {
		delete(g.event, runtime.heap_allocator())
		delete(g.body, runtime.heap_allocator())
	}
	delete(r.got)
}

@(private = "file")
received :: proc(r: ^Receiver) -> int {
	sync.guard(&r.mutex)
	return len(r.got)
}

// A delivery the server cannot take now waits and is tried again, signed
// afresh, until it is taken; the store keeps how the last went.
@(test)
a_delivery_waits_for_a_server_that_is_down :: proc(t: ^testing.T) {
	r := Receiver {
		secret  = "s3cret",
		answers = {503, 200},
		got     = make([dynamic]Received, runtime.heap_allocator()),
	}
	defer receiver_destroy(&r)
	srv, ok := loopback.start(receive, &r, runtime.heap_allocator())
	testing.expect(t, ok)
	defer loopback.stop(srv)

	st: settings.Store
	testing.expect(t, settings.open(&st, ":memory:") == nil)
	defer settings.close(&st)
	now := i64(1_800_000_000)
	id, _ := settings.hook_add(&st, loopback.url(srv, "/leita"), r.secret, false, now)
	e := Event {
		event  = TEST,
		raised = time.unix(now, 0),
		text   = "a test",
	}
	testing.expect_value(t, tell(&st, e, "", "", now), "")

	tally, problem := deliver(&st, now, post)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, tally, Tally{later = 1})
	waiting, _ := settings.due(&st, now + backoff(1), allocator = context.temp_allocator)
	testing.expect_value(t, len(waiting), 1)
	testing.expect_value(t, waiting[0].attempts, 1)
	testing.expect_value(t, waiting[0].next_at, now + 5 * 60)
	testing.expect_value(t, waiting[0].problem, "HTTP 503")

	tally, _ = deliver(&st, now + 60, post)
	testing.expect_value(t, tally, Tally{}) // not due yet
	tally, _ = deliver(&st, now + 5 * 60, post)
	testing.expect_value(t, tally, Tally{taken = 1})
	testing.expect_value(t, settings.waiting(&st, id), 0)
	hooks, _ := settings.hooks(&st, context.temp_allocator)
	testing.expect_value(t, hooks[0].last_sent, now + 5 * 60)
	testing.expect_value(t, hooks[0].last_problem, "")

	testing.expect_value(t, received(&r), 2)
	for g in r.got {
		testing.expect(t, g.signed, "signed with the webhook's secret")
		testing.expect_value(t, g.event, "test")
		var: json.Value
		testing.expect(
			t,
			json.unmarshal_string(g.body, &var, allocator = context.temp_allocator) == nil,
			g.body,
		)
	}
}

// A server that refuses a delivery is not asked again; nor is one that has
// not taken it for a week.
@(test)
a_refused_or_old_delivery_is_dropped :: proc(t: ^testing.T) {
	r := Receiver {
		secret  = "s3cret",
		answers = {400},
		got     = make([dynamic]Received, runtime.heap_allocator()),
	}
	defer receiver_destroy(&r)
	srv, ok := loopback.start(receive, &r, runtime.heap_allocator())
	testing.expect(t, ok)
	defer loopback.stop(srv)

	st: settings.Store
	testing.expect(t, settings.open(&st, ":memory:") == nil)
	defer settings.close(&st)
	now := i64(1_800_000_000)
	_, _ = settings.hook_add(&st, loopback.url(srv, "/leita"), r.secret, false, now)
	testing.expect_value(t, tell(&st, {event = TEST}, "", "", now), "")
	tally, _ := deliver(&st, now, post)
	testing.expect_value(t, tally, Tally{dropped = 1})
	hooks, _ := settings.hooks(&st, context.temp_allocator)
	testing.expect_value(t, hooks[0].last_problem, "HTTP 400")

	// Nobody listens at all: kept for later, until a week has passed.
	st2: settings.Store
	testing.expect(t, settings.open(&st2, ":memory:") == nil)
	defer settings.close(&st2)
	_, _ = settings.hook_add(&st2, "http://127.0.0.1:1/nobody", "x", false, now)
	_ = tell(&st2, {event = TEST}, "", "", now)
	tally, _ = deliver(&st2, now, post)
	testing.expect_value(t, tally, Tally{later = 1})
	tally, _ = deliver(&st2, now + GIVE_UP, post)
	testing.expect_value(t, tally, Tally{dropped = 1})
}

// The summary names the place, but its largest directories and files only for
// a webhook that may carry folder paths.
@(test)
folder_paths_go_only_where_the_person_allowed :: proc(t: ^testing.T) {
	r := report.Report {
		target              = "/srv/data",
		bytes               = 10 << 30,
		largest_directories = {{path = "/srv/data/secret-project", bytes = 9 << 30}},
		largest_files       = {{path = "/srv/data/secret-project/plans.pdf", bytes = 1 << 30}},
	}
	with := summary(&r, true)
	without := summary(&r, false)
	testing.expect(t, strings.contains(with, "secret-project"), with)
	testing.expect(t, !strings.contains(without, "secret-project"), without)
	testing.expect(t, strings.contains(without, "/srv/data"), "the place is named")

	st: settings.Store
	testing.expect(t, settings.open(&st, ":memory:") == nil)
	defer settings.close(&st)
	open_id, _ := settings.hook_add(&st, "https://a.example/", "x", true, 1)
	closed_id, _ := settings.hook_add(&st, "https://b.example/", "y", false, 1)
	e := Event {
		event = alert.CONDITION_KEYS[.Warn_Used],
		place = "/srv/data",
		text = "The disk under /srv/data is 91.0% used, past the warning at 80%.",
		measure = {kind = .Warn_Used, used_percent = 91, limit = 80},
	}
	testing.expect_value(t, tell(&st, e, with, without, 1), "")
	open_q, _ := settings.due(&st, 1, open_id, context.temp_allocator)
	closed_q, _ := settings.due(&st, 1, closed_id, context.temp_allocator)
	testing.expect(t, strings.contains(open_q[0].body, "plans.pdf"))
	testing.expect(t, !strings.contains(closed_q[0].body, "plans.pdf"))
	for body in ([]string{open_q[0].body, closed_q[0].body}) {
		parsed: struct {
			schema:  string,
			event:   string,
			place:   string,
			measure: struct {
				used_percent: f64,
				limit:        f64,
			},
			summary: struct {
				schema: string,
			},
		}
		testing.expect(
			t,
			json.unmarshal_string(body, &parsed, allocator = context.temp_allocator) == nil,
			body,
		)
		testing.expect_value(t, parsed.schema, SCHEMA)
		testing.expect_value(t, parsed.event, "warn_used")
		testing.expect_value(t, parsed.place, "/srv/data")
		testing.expect_value(t, parsed.measure.used_percent, 91)
		testing.expect_value(t, parsed.summary.schema, report.SCHEMA)
	}
}
