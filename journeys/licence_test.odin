package journeys

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "jm:http/loopback"

// Once the evaluation has ended a licence is what keeps Pro: it is checked, kept
// beside the data, shown, found by the next run, and forgotten when removed.
@(test)
a_licence_added_keeps_pro_until_it_is_removed :: proc(t: ^testing.T) {
	if licence_line() == "" {
		testing.fail_now(
			t,
			"no licence to add: run the journeys with just journeys, which builds the binary to take it",
		)
	}
	h := home(t, "licence")
	defer leave(h)

	end_evaluation(t, h)

	r := run(t, h, 0, "licence")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "evaluation has ended"), r.out)
	r = run(t, h, -1, "monitor", "add", h.dir)
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "need a licence"), r.out)

	// What is not a licence is refused, and nothing is kept.
	r = run(t, h, 0, "licence", "add", "leita.garbage")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.err, "not a leita licence"), r.err)
	r = run(t, h, 0, "licence")
	testing.expect(t, strings.contains(r.out, "evaluation has ended"), r.out)

	r = run(t, h, 0, "licence", "add", licence_line())
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "added the licence"), r.out)
	testing.expect(t, strings.contains(r.out, "test@leita.example"), r.out)

	r = run(t, h, 0, "licence")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "licensed   to test@leita.example"), r.out)
	testing.expect(t, strings.contains(r.out, "tier       Personal"), r.out)
	testing.expect(t, strings.contains(r.out, "paid       9999-12-31T23:59:59Z"), r.out)
	testing.expect(t, strings.contains(r.out, "pro        this release is included"), r.out)

	// Pro works again: a scheduled scan may be set up and an html report written.
	r = run(t, h, -1, "monitor", "add", h.dir)
	expect_code(t, r, 0)
	r = run(t, h, 0, "--no-history", "--report", file_in(h, "r.html"), "/Users/alex")
	expect_code(t, r, 0)
	testing.expect(t, os.exists(file_in(h, "r.html")), "the html report was not written")

	r = run(t, h, 0, "licence", "remove")
	expect_code(t, r, 0)
	r = run(t, h, 0, "licence")
	testing.expect(t, strings.contains(r.out, "evaluation has ended"), r.out)
	r = run(t, h, -1, "monitor", "add", h.dir)
	expect_code(t, r, 1)
}

// A licence held for one run through LEITA_LICENCE is used for that run and kept
// nowhere.
@(test)
a_licence_in_the_environment_serves_one_run :: proc(t: ^testing.T) {
	if licence_line() == "" {
		testing.fail_now(
			t,
			"no licence to add: run the journeys with just journeys, which builds the binary to take it",
		)
	}
	h := home(t, "licence_env")
	defer leave(h)

	end_evaluation(t, h)

	given := []string {
		strings.concatenate({"LEITA_LICENCE=", licence_line()}, context.temp_allocator),
	}
	r := run(t, h, 0, "licence", extra = given)
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "licensed   to test@leita.example"), r.out)
	r = run(t, h, -1, "monitor", "add", h.dir, extra = given)
	expect_code(t, r, 0)

	r = run(t, h, 0, "licence")
	testing.expect(t, strings.contains(r.out, "evaluation has ended"), r.out)
}

// The shop is local and signs nothing: it serves only the throwaway line
// the journey build already trusts. Production activation is never reached.
@(private = "file")
answer_journey_activation :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	line := (^string)(conn.server.user)^
	if req.method == "POST" && req.path == "/activate" && req.body == `{"key":"LEITA-SOLD"}` {
		Granted :: struct {
			licence: string `json:"licence"`,
		}
		body, _ := json.marshal(Granted{line}, allocator = context.temp_allocator)
		loopback.send(
			conn,
			fmt.tprintf(
				"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
				len(body),
				string(body),
			),
		)
	} else {
		body := `{"error":"unknown","message":"The order was refunded."}`
		loopback.send(
			conn,
			fmt.tprintf(
				"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
				len(body),
				body,
			),
		)
	}
}

// A script exchanges its shop key through LEITA_ACTIVATE_URL, then reads
// the persisted line offline on its next run. A refused replacement keeps it.
@(test)
a_shop_key_activates_from_the_cli_without_a_window :: proc(t: ^testing.T) {
	line := licence_line()
	if line == "" {
		testing.fail_now(t, "run with just journeys so the build trusts the test licence")
	}
	srv, up := loopback.start(answer_journey_activation, &line, runtime.heap_allocator())
	if !testing.expect(t, up, "the local shop started") {return}
	defer loopback.stop(srv)
	h := home(t, "licence_activate")
	defer leave(h)
	end_evaluation(t, h)
	env := []string{fmt.tprintf("LEITA_ACTIVATE_URL=%s", loopback.url(srv, "/activate"))}
	r := run(t, h, 0, "licence", "activate", "LEITA-SOLD", extra = env)
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "licensed to test@leita.example"), r.out)
	testing.expect(
		t,
		!strings.contains(r.out, "LEITA-SOLD") && !strings.contains(r.err, "LEITA-SOLD"),
	)
	kept := fmt.tprintf("%s/licence", data(h))
	receipt := fmt.tprintf("%s/licence-key", data(h))
	before, read_err := os.read_entire_file(kept, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, strings.trim_space(string(before)), line)
	key, key_err := os.read_entire_file(receipt, context.temp_allocator)
	testing.expect(t, key_err == nil)
	testing.expect_value(t, strings.trim_space(string(key)), "LEITA-SOLD")

	r = run(t, h, 0, "licence", "activate", "LEITA-REFUNDED", extra = env)
	expect_code(t, r, 1)
	testing.expect(
		t,
		strings.contains(r.err, "HTTP 404") && strings.contains(r.err, "refunded"),
		r.err,
	)
	after, after_err := os.read_entire_file(kept, context.temp_allocator)
	testing.expect(t, after_err == nil)
	testing.expect_value(t, string(after), string(before))

	// Point the optional endpoint at the refusing server. Reading a valid
	// stored licence still succeeds, and it makes no third HTTP request.
	r = run(t, h, 0, "licence", extra = env)
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "pro        this release is included"), r.out)
	testing.expect_value(t, loopback.accepted(srv), 2)
}
