package update

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:path"

import netfault "../faults/net"

/*
An update over a network that fails, from a server on this machine that fails
on purpose (faults/net): every failure ends Failed within a bound, says what
failed, and leaves the executable as it was, with nothing beside it but the
lock.
*/

// NET_TIMEOUT is each request's limit here, in place of DEFAULT_TIMEOUT.
NET_TIMEOUT :: 1500 * time.Millisecond

// net_bound is how long an update that makes requests requests may take: each
// one its timeout, and slack for the rest.
net_bound :: proc(requests: int) -> time.Duration {
	return time.Duration(requests) * NET_TIMEOUT + 3 * time.Second
}

// Ended is how an apply ended and how long it took.
Ended :: struct {
	r:    Result,
	took: time.Duration,
}

timed_apply :: proc(cfg: Config) -> (e: Ended) {
	start := time.now()
	e.r = apply(cfg)
	e.took = time.diff(start, time.now())
	return
}

// net_config asks for f's release at base with NET_TIMEOUT. It holds f's key,
// so f must outlive it.
net_config :: proc(f: ^Fixture, base: string) -> Config {
	cfg := config(f)
	cfg.base = base
	cfg.timeout = NET_TIMEOUT
	return cfg
}

// expect_failed_untouched fails unless the apply failed within bound, with a
// message that says each of says, and left the executable and its folder as
// they were.
expect_failed_untouched :: proc(
	t: ^testing.T,
	f: ^Fixture,
	e: ^Ended,
	what: string,
	bound: time.Duration,
	says: ..string,
	loc := #caller_location,
) {
	testing.expectf(
		t,
		e.r.outcome == .Failed,
		"%s: the update ended %v (%v): %s",
		what,
		e.r.outcome,
		e.r.reason,
		message(&e.r),
		loc = loc,
	)
	said := strings.to_lower(message(&e.r), context.temp_allocator)
	testing.expectf(t, said != "", "%s: the failure says what failed", what, loc = loc)
	for word in says {
		testing.expectf(
			t,
			strings.contains(said, word),
			"%s: the failure does not say %q: %s",
			what,
			word,
			message(&e.r),
			loc = loc,
		)
	}
	testing.expectf(t, e.took < bound, "%s: took %v, past %v", what, e.took, bound, loc = loc)
	expect_untouched(t, f, what, loc)
}

// expect_untouched fails unless the executable holds the old build and its
// folder holds nothing else but the update's lock: no download, no .new, no
// .old, no part.
expect_untouched :: proc(t: ^testing.T, f: ^Fixture, what: string, loc := #caller_location) {
	testing.expectf(t, read(f.exe) == "old build", "%s: the executable changed", what, loc = loc)
	dir := filepath.dir(f.exe)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect(t, err == nil, "the folder reads", loc = loc)
	for e in entries {
		if e.name == "leita" || e.name == "leita" + LOCK_SUFFIX {
			continue
		}
		testing.expectf(t, false, "%s: %s was left beside the executable", what, e.name, loc = loc)
	}
}

// publish_routes adds a .zst and a patch from the old build to the release, so an
// apply tries all three routes.
publish_routes :: proc(t: ^testing.T, f: ^Fixture) {
	ta := context.temp_allocator
	zst := strings.concatenate({ASSET, ".zst"}, ta)
	patch := strings.concatenate({ASSET, ".", sha256("old build"), ".patch"}, ta)
	compressed := compress(t, "new build", "")
	patched := compress(t, "new build", "old build")
	testing.expect_value(t, path.write(path.join(f.release, zst, allocator = ta), compressed), nil)
	testing.expect_value(t, path.write(path.join(f.release, patch, allocator = ta), patched), nil)
	ver := "v1.1.0\n"
	write_sums(
		t,
		f,
		{
			{ASSET, sha256("new build")},
			{zst, sha256(compressed)},
			{patch, sha256(patched)},
			{"version.txt", sha256(ver)},
		},
	)
}

Net_Case :: struct {
	fault:  netfault.Fault,
	status: int,
}

// The page itself fails: the signed sums never arrive, so nothing is
// downloaded and the update stops at the first request.
@(test)
a_release_page_that_fails_stops_the_update :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 2 * time.Minute)
	cases := []Net_Case {
		{.Stall_Head, 0},
		{.Stall_Body, 0},
		{.Trickle, 0},
		{.Truncate, 0},
		{.Reset, 0},
		{.Redirect_Loop, 0},
		{.Status, 404},
		{.Status, 500},
		{.Status, 503},
		{.Portal, 0},
	}
	for c in cases {
		f := fixture(t, "old build", "new build", "v1.1.0")
		s := netfault.start(c.fault, dir = f.release, status = c.status, gap = time.Second)
		cfg := net_config(&f, netfault.base(s))
		e := timed_apply(cfg)
		what := fmt.tprintf("%v %d", c.fault, c.status)
		expect_failed_untouched(t, &f, &e, what, net_bound(2), "sha256sums.txt")
		netfault.stop(s)
		os.remove_all(f.root)
	}
}

// The signed sums arrive, then every route of the download fails: the patch,
// the .zst and the build itself. Each route is tried once, and the executable
// is never replaced by what part of one left.
@(test)
a_download_that_fails_installs_nothing :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 3 * time.Minute)
	cases := []Net_Case {
		{.Stall_Head, 0},
		{.Stall_Body, 0},
		{.Trickle, 0},
		{.Truncate, 0},
		{.Truncate_Unframed, 0},
		{.Reset, 0},
		{.Redirect_Loop, 0},
		{.Status, 404},
		{.Status, 503},
		{.Portal, 0},
	}
	for c in cases {
		f := fixture(t, "old build", "new build", "v1.1.0")
		publish_routes(t, &f)
		s := netfault.start(
			c.fault,
			dir = f.release,
			only = "/" + ASSET,
			status = c.status,
			gap = time.Second,
		)
		cfg := net_config(&f, netfault.base(s))
		e := timed_apply(cfg)
		what := fmt.tprintf("%v %d", c.fault, c.status)
		// The sums, their signature, the version, the stamp, then three routes.
		expect_failed_untouched(t, &f, &e, what, net_bound(3), ASSET)
		netfault.stop(s)
		os.remove_all(f.root)
	}
}

// What cannot be reached at all: nothing listening, a name no resolver
// answers, a server that does not speak TLS.
@(test)
a_release_page_that_cannot_be_reached_fails_with_a_reason :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	plain := netfault.start(.None, body = "")
	defer netfault.stop(plain)
	Unreached :: struct {
		base, says: string,
	}
	bases := []Unreached {
		{strings.trim_suffix(netfault.refused("/"), "/"), "connect"},
		{"https://" + netfault.UNRESOLVABLE + "/download", "resolve"},
		{strings.trim_suffix(netfault.url_tls_without_tls(plain, "/"), "/"), "did not answer"},
	}
	for u in bases {
		b := u.base
		f := fixture(t, "old build", "new build", "v1.1.0")
		cfg := net_config(&f, b)
		e := timed_apply(cfg)
		expect_failed_untouched(t, &f, &e, b, net_bound(1), "sha256sums.txt", u.says)
		testing.expectf(t, e.r.reason == .Unreachable, "%s: %v", b, e.r.reason)
		os.remove_all(f.root)
	}
}

// A certificate no one vouches for, for another host or signed by itself, is
// refused before a byte of the release is believed.
@(test)
a_release_page_with_a_bad_certificate_is_refused :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	if !netfault.openssl_found() {
		testing.expect(
			t,
			os.get_env("CI", context.temp_allocator) == "",
			"openssl is on every runner",
		)
		return
	}
	dir, _ := os.make_directory_temp("", "leita-certs-*", context.temp_allocator)
	defer os.remove_all(dir)
	certs, why, ok := netfault.make_certs(dir)
	if !testing.expect(t, ok, why) {
		return
	}
	for pair in ([][2]string{{certs.wrong_host, certs.wrong_key}, {certs.self, certs.self_key}}) {
		tls, swhy, sok := netfault.start_tls(pair[0], pair[1])
		if !testing.expect(t, sok, swhy) {
			continue
		}
		f := fixture(t, "old build", "new build", "v1.1.0")
		cfg := net_config(&f, strings.trim_suffix(netfault.tls_url(tls, "/"), "/"))
		e := timed_apply(cfg)
		expect_failed_untouched(t, &f, &e, pair[0], net_bound(1), "sha256sums.txt", "127.0.0.1")
		testing.expectf(t, e.r.reason == .Unreachable, "%s: %v", pair[0], e.r.reason)
		netfault.stop_tls(&tls)
		os.remove_all(f.root)
	}
}

// What only looks like a failure is not one: a redirect to the release is
// followed, and a page that answers slowly but steadily within the limit is
// installed from.
@(test)
a_redirect_or_a_slow_page_still_updates :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Minute)
	{
		f := fixture(t, "old build", "new build", "v1.1.0")
		defer os.remove_all(f.root)
		real := netfault.start(.None, dir = f.release)
		defer netfault.stop(real)
		hop := netfault.start(.Redirect, location = netfault.base(real))
		defer netfault.stop(hop)
		cfg := net_config(&f, netfault.base(hop))
		r := apply(cfg)
		testing.expectf(t, r.outcome == .Applied, "%v: %s", r.outcome, message(&r))
		testing.expect_value(t, read(f.exe), "new build")
	}
	{
		f := fixture(t, "old build", "new build", "v1.1.0")
		defer os.remove_all(f.root)
		slow := netfault.start(
			.Trickle,
			dir = f.release,
			only = "/" + ASSET,
			gap = 20 * time.Millisecond,
		)
		defer netfault.stop(slow)
		cfg := net_config(&f, netfault.base(slow))
		r := apply(cfg)
		testing.expectf(t, r.outcome == .Applied, "%v: %s", r.outcome, message(&r))
		testing.expect_value(t, read(f.exe), "new build")
	}
}
