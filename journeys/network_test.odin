package journeys

import "core:strings"
import "core:testing"
import "core:time"

import netfault "../faults/net"

/*
A person asks whether a newer leita is out on a network that is in the way: a
proxy they set with HTTPS_PROXY that refuses, a proxy that is not there, a
name no resolver answers, a captive portal's sign-in page, a release page that
fails. Each says what went wrong and exits 1, well inside the time a person
waits, and the binary is the one they ran. The update package's own tests take
every fault in turn, with a short timeout; these are the ones a person meets
through the command line's environment.
*/

// NET_BOUND is how long a check that fails may take here. Each case below fails
// at the first request, without waiting out a timeout.
NET_BOUND :: 30 * time.Second

// RELEASE_ELSEWHERE is a release page only a proxy could reach: its name
// resolves nowhere.
RELEASE_ELSEWHERE :: "https://" + netfault.UNRESOLVABLE + "/download"

// check_fails runs update --check with extra and fails unless it exits 1 within
// NET_BOUND, says each of says on standard error, and leaves the binary alone.
check_fails :: proc(
	t: ^testing.T,
	h: Home,
	what: string,
	extra: []string,
	says: ..string,
	loc := #caller_location,
) {
	before := read_file(binary())
	start := time.now()
	r := run(t, h, -1, "update", "--check", extra = extra)
	took := time.diff(start, time.now())
	testing.expectf(t, r.code == 1, "%s: exit %d\n%s%s", what, r.code, r.out, r.err, loc = loc)
	testing.expectf(t, took < NET_BOUND, "%s: took %v", what, took, loc = loc)
	for word in says {
		testing.expectf(
			t,
			strings.contains(r.err, word),
			"%s: does not say %q: %s",
			what,
			word,
			r.err,
			loc = loc,
		)
	}
	testing.expectf(t, read_file(binary()) == before, "%s: the binary changed", what, loc = loc)
}

// with is the extra environment of a run: each KEY=VALUE pair given.
with :: proc(pairs: ..string) -> []string {
	out := make([]string, len(pairs) / 2, context.temp_allocator)
	for i := 0; i + 1 < len(pairs); i += 2 {
		out[i / 2] = strings.concatenate({pairs[i], "=", pairs[i + 1]}, context.temp_allocator)
	}
	return out
}

// HTTPS_PROXY is honoured: the request goes to the proxy, asked to CONNECT to
// a host it could not have resolved itself, and the proxy's refusal, or its
// sign-in page in place of a tunnel, ends the check with a reason.
@(test)
update_check_goes_through_the_proxy_it_is_given :: proc(t: ^testing.T) {
	h := home(t, "update_proxy")
	defer leave(h)

	for fault in ([]netfault.Fault{.Status, .Portal}) {
		proxy := netfault.start(fault, status = 502)
		defer netfault.stop(proxy)
		check_fails(
			t,
			h,
			"a proxy that refuses",
			with("LEITA_RELEASE_BASE", RELEASE_ELSEWHERE, "HTTPS_PROXY", netfault.proxy(proxy)),
			"cannot fetch sha256sums.txt",
		)
		asked := false
		for head in netfault.seen(proxy) {
			asked ||= strings.has_prefix(head, "CONNECT " + netfault.UNRESOLVABLE + ":443 ")
		}
		testing.expectf(
			t,
			asked,
			"%v: the proxy was not asked to connect: %v",
			fault,
			netfault.seen(proxy),
		)
	}

	// A proxy that is not there is said as soon as the connection is refused.
	check_fails(
		t,
		h,
		"a proxy that is not there",
		with(
			"LEITA_RELEASE_BASE",
			RELEASE_ELSEWHERE,
			"HTTPS_PROXY",
			strings.trim_suffix(netfault.refused("/"), "/"),
		),
		"cannot fetch sha256sums.txt",
	)
}

// No proxy, and a name no resolver answers: the check says it could not
// resolve the host.
@(test)
update_check_says_when_the_name_does_not_resolve :: proc(t: ^testing.T) {
	h := home(t, "update_dns")
	defer leave(h)
	check_fails(
		t,
		h,
		"a name that resolves nowhere",
		with("LEITA_RELEASE_BASE", RELEASE_ELSEWHERE),
		"cannot fetch sha256sums.txt",
		netfault.UNRESOLVABLE,
	)
}

// A network that answers every page with its sign-in page, and a release page
// that fails, are said as such: neither is taken for a release, nor for one
// that is missing.
@(test)
update_check_says_a_portal_or_a_failing_page :: proc(t: ^testing.T) {
	h := home(t, "update_portal")
	defer leave(h)

	portal := netfault.start(.Portal)
	defer netfault.stop(portal)
	check_fails(
		t,
		h,
		"a captive portal",
		with("LEITA_RELEASE_BASE", netfault.base(portal)),
		"sign in",
	)

	failing := netfault.start(.Status, status = 503)
	defer netfault.stop(failing)
	check_fails(
		t,
		h,
		"a page that fails",
		with("LEITA_RELEASE_BASE", netfault.base(failing)),
		"HTTP 503",
		"try again later",
	)

	cut := netfault.start(.Truncate, body = "a release page cut short")
	defer netfault.stop(cut)
	check_fails(
		t,
		h,
		"a page cut short",
		with("LEITA_RELEASE_BASE", netfault.base(cut)),
		"sha256sums.txt",
	)
}
