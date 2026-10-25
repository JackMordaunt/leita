package netfault

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:http"

// TIMEOUT is the whole-request limit each test asks with, and BOUND how long
// past it an answer may come: none of these may wait on the network for ever.
TIMEOUT :: 2 * time.Second
BOUND   :: TIMEOUT + 3 * time.Second

BODY :: `{"licence":"leita.a-line-long-enough-to-cut-in-half"}`

// Outcome is how one request ended, and how long it took.
Outcome :: struct {
	res:  http.Response,
	err:  http.Error,
	took: time.Duration,
	said: string,
}

@(private = "file", thread_local)
said_last: string

get :: proc(url: string) -> (g: Outcome) {
	start := time.now()
	g.res, g.err = http.get(url, {
			timeout = TIMEOUT,
			on_error = proc(msg: string) {said_last = strings.clone(msg, context.temp_allocator)},
		}, context.temp_allocator)
	g.took = time.diff(start, time.now())
	g.said = said_last
	return
}

expect_failed :: proc(t: ^testing.T, g: Outcome, want: http.Error, loc := #caller_location) {
	testing.expectf(
		t,
		g.err == want,
		"the request ended %v (%s), want %v",
		g.err,
		g.said,
		want,
		loc = loc,
	)
	testing.expectf(t, g.took < BOUND, "the request took %v, past %v", g.took, BOUND, loc = loc)
}

@(test)
each_fault_ends_the_request_within_its_timeout :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	Case :: struct {
		fault: Fault,
		want:  http.Error,
	}
	cases := []Case {
		{.Stall_Head, .Timed_Out},
		{.Stall_Body, .Timed_Out},
		{.Truncate, .Transfer_Failed},
		{.Reset, .Transfer_Failed},
		{.Redirect_Loop, .Transfer_Failed},
	}
	for c in cases {
		s := start(c.fault, body = BODY, gap = time.Second)
		testing.expect(t, s != nil, "the server starts")
		g := get(url(s, "/activate"))
		expect_failed(t, g, c.want)
		testing.expectf(t, accepted(s) >= 1, "%v: the server was asked", c.fault)
		stop(s)
	}
}

@(test)
a_trickle_finishes_slowly_or_times_out :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	slow := start(.Trickle, body = "abc", gap = 100 * time.Millisecond)
	defer stop(slow)
	g := get(url(slow, "/"))
	testing.expect_value(t, g.err, http.Error.None)
	testing.expect_value(t, g.res.body, "abc")

	stuck := start(.Trickle, body = BODY, gap = time.Second)
	defer stop(stuck)
	expect_failed(t, get(url(stuck, "/")), .Timed_Out)
}

@(test)
a_short_body_with_no_length_looks_whole :: proc(t: ^testing.T) {
	s := start(.Truncate_Unframed, body = BODY)
	defer stop(s)
	g := get(url(s, "/"))
	testing.expect_value(t, g.err, http.Error.None)
	testing.expect_value(t, g.res.body, BODY[:len(BODY) / 2])
}

@(test)
statuses_portals_and_redirects_answer :: proc(t: ^testing.T) {
	for status in ([]int{404, 429, 500, 502, 503}) {
		s := start(.Status, status = status)
		g := get(url(s, "/"))
		testing.expect_value(t, g.err, http.Error.None)
		testing.expect_value(t, g.res.status, status)
		testing.expect(t, !g.res.ok)
		testing.expect_value(
			t,
			g.res.body,
			strings.concatenate(
				{`{"message":"the server answered `, fmt.tprint(status), `"}`},
				context.temp_allocator,
			),
		)
		stop(s)
	}

	portal := start(.Portal)
	defer stop(portal)
	g := get(url(portal, "/sha256sums.txt"))
	testing.expect_value(t, g.res.status, 200)
	testing.expect(t, strings.contains(g.res.body, "<html>"), g.res.body)

	good := start(.None, body = BODY)
	defer stop(good)
	hop := start(.Redirect, location = base(good))
	defer stop(hop)
	g = get(url(hop, "/activate"))
	testing.expect_value(t, g.err, http.Error.None)
	testing.expect_value(t, g.res.body, BODY)
}

@(test)
only_the_named_path_is_broken :: proc(t: ^testing.T) {
	dir, _ := os.make_directory_temp("", "leita-netfault-*", context.temp_allocator)
	defer os.remove_all(dir)
	testing.expect(
		t,
		os.write_entire_file(strings.concatenate({dir, "/a"}, context.temp_allocator), "whole") ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file(strings.concatenate({dir, "/b"}, context.temp_allocator), "broken") ==
		nil,
	)
	s := start(.Truncate, dir = dir, only = "/b")
	defer stop(s)
	testing.expect_value(t, get(url(s, "/a")).res.body, "whole")
	expect_failed(t, get(url(s, "/b")), .Transfer_Failed)
	testing.expect_value(t, get(url(s, "/c")).res.status, 404)
	heads := seen(s)
	testing.expect_value(t, len(heads), 3)
	testing.expect(t, strings.has_prefix(heads[0], "GET /a "), heads[0])
}

//review:ignore test-no-assertion expect_failed asserts the error and the bound
@(test)
nothing_answers_a_refused_port_or_an_invalid_name :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	expect_failed(t, get(refused("/")), .Transfer_Failed)
	expect_failed(t, get("http://" + UNRESOLVABLE + "/"), .Transfer_Failed)
}

// The plain server waits for a request head that a TLS hello never ends, so
// the handshake waits too, until the timeout.
//review:ignore test-no-assertion expect_failed asserts the error and the bound
@(test)
a_server_that_does_not_speak_tls_ends_at_the_timeout :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	s := start(.None, body = BODY)
	defer stop(s)
	expect_failed(t, get(url_tls_without_tls(s, "/")), .Timed_Out)
}

// in_ci says whether this runs on a CI runner, where a missing tool is a
// failure rather than a test left out.
in_ci :: proc() -> bool {
	return os.get_env("CI", context.temp_allocator) != ""
}

@(test)
a_certificate_no_one_vouches_for_is_refused :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	if !openssl_found() {
		testing.expect(t, !in_ci(), "openssl is on every runner")
		return
	}
	dir, _ := os.make_directory_temp("", "leita-certs-*", context.temp_allocator)
	defer os.remove_all(dir)
	certs, why, ok := make_certs(dir)
	if !testing.expect(t, ok, why) {
		return
	}
	for pair in ([][2]string{{certs.wrong_host, certs.wrong_key}, {certs.self, certs.self_key}}) {
		tls, swhy, sok := start_tls(pair[0], pair[1])
		if !testing.expect(t, sok, swhy) {
			continue
		}
		g := get(tls_url(tls, "/"))
		expect_failed(t, g, .Transfer_Failed)
		stop_tls(&tls)
	}
}
