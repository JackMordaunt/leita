package journeys

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"

// header is the value of the named header in a request head, "" when it has none.
header :: proc(head, name: string) -> string {
	for line in strings.split_lines(head, context.temp_allocator) {
		key, _, value := strings.partition(line, ":")
		if strings.equal_fold(key, name) {
			return strings.trim_space(value)
		}
	}
	return ""
}

// is_null is whether key of o is JSON null.
is_null :: proc(o: json.Object, key: string) -> bool {
	_, null := o[key].(json.Null)
	return null
}

// secret_in is the secret the run printed for the webhook it added.
secret_in :: proc(out: string) -> string {
	_, _, secret := strings.partition(out, "X-Leita-Signature on each request: ")
	return strings.trim_space(secret)
}

// A person adds a webhook, is given its secret, sends a test, sees it taken, and
// removes it. The server receives a signed JSON body it can check.
@(test)
a_webhook_takes_a_signed_test :: proc(t: ^testing.T) {
	h := home(t, "webhook")
	defer leave(h)

	server := start_receiver(t)
	defer stop_receiver(server)

	url := address(server, "/alerts")

	r := run(t, h, -1, "monitor", "webhook", "list")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "nothing is sent anywhere"), r.out)

	r = run(t, h, -1, "monitor", "webhook", "add", url)
	expect_code(t, r, 0)
	testing.expect(
		t,
		strings.contains(r.out, fmt.tprintf("sending each new alert to %s", url)),
		r.out,
	)
	secret := secret_in(r.out)
	testing.expectf(t, len(secret) == 64, "the secret is 64 hex characters: %q", secret)

	r = run(t, h, -1, "monitor", "webhook", "list")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, url), r.out)
	testing.expect(t, strings.contains(r.out, fmt.tprintf("secret %s", secret)), r.out)
	testing.expect(t, strings.contains(r.out, "nothing delivered yet"), r.out)
	testing.expect_value(t, len(requests(server)), 0)

	r = run(t, h, -1, "monitor", "webhook", "test", url)
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, fmt.tprintf("%s took the test", url)), r.out)

	taken := requests(server)
	if !testing.expect_value(t, len(taken), 1) {
		return
	}
	head, body := taken[0].head, taken[0].body
	testing.expect(t, strings.has_prefix(head, "POST /alerts "), head)
	testing.expect_value(t, header(head, "Content-Type"), "application/json")
	testing.expect_value(t, header(head, "X-Leita-Event"), "test")
	testing.expect(t, header(head, "X-Leita-Delivery") != "", head)
	testing.expect(t, strings.has_prefix(header(head, "User-Agent"), "leita/"), head)

	// The signature is the HMAC-SHA256 of "<timestamp>.<body>" under the secret,
	// which is all a receiver needs to know the body came from this leita, now.
	stamp := header(head, "X-Leita-Timestamp")
	seconds, stamped := strconv.parse_i64(stamp)
	testing.expectf(
		t,
		stamped && seconds > 1_700_000_000,
		"the timestamp is Unix seconds: %q",
		stamp,
	)
	signed := fmt.tprintf("%s.%s", stamp, body)
	tag: [32]byte
	hmac.sum(hash.Algorithm.SHA256, tag[:], transmute([]byte)signed, transmute([]byte)secret)
	want := fmt.tprintf("sha256=%s", hex.encode(tag[:], context.temp_allocator))
	testing.expect_value(t, header(head, "X-Leita-Signature"), want)

	event := report(t, body)
	testing.expect_value(t, text(event, "schema"), "leita.event/1")
	testing.expect_value(t, text(event, "event"), "test")
	testing.expect(t, text(event, "raised") != "", body)
	testing.expect(t, text(event, "text") != "", body)
	testing.expect(t, is_null(event, "place"), "a test names no place")
	testing.expect(t, is_null(event, "problem"), "a test has no problem")
	testing.expect(t, is_null(event, "summary"), "a test carries no scan")
	// A test measures nothing, and each measure says so with a 0.
	for key in ([]string{"used_percent", "free", "total", "days", "grew", "limit"}) {
		value := member(event, "measure")[key]
		zero := false
		#partial switch n in value {
		case json.Integer:
			zero = n == 0
		case json.Float:
			zero = n == 0
		}
		testing.expectf(t, zero, "measure %s is 0: %s", key, body)
	}

	// Once taken, the list says when, and the webhook goes.
	r = run(t, h, -1, "monitor", "webhook", "list")
	testing.expect(t, strings.contains(r.out, "last delivered"), r.out)
	r = run(t, h, -1, "monitor", "webhook", "remove", url)
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "no longer sending to"), r.out)
	r = run(t, h, -1, "monitor", "webhook", "list")
	testing.expect(t, strings.contains(r.out, "nothing is sent anywhere"), r.out)
	r = run(t, h, -1, "monitor", "webhook", "remove", url)
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "no webhook to"), r.out)
	r = run(t, h, -1, "monitor", "webhook", "test")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "no webhook to test"), r.out)
	testing.expect_value(t, len(requests(server)), 1)
}

// A server that will not take a test is told apart from one that is down: one is
// dropped, the other is tried again, and the list says why the last try failed.
@(test)
a_webhook_that_does_not_take_the_test_says_why :: proc(t: ^testing.T) {
	h := home(t, "webhook_refused")
	defer leave(h)

	refusing := start_receiver(t, 410)
	defer stop_receiver(refusing)

	busy := start_receiver(t, 503)
	defer stop_receiver(busy)

	for server in ([]^Receiver{refusing, busy}) {
		r := run(t, h, -1, "monitor", "webhook", "add", address(server, "/hook"))
		expect_code(t, r, 0)
	}

	r := run(t, h, -1, "monitor", "webhook", "test", address(refusing, "/hook"))
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "did not take the test: HTTP 410"), r.out)
	testing.expect(t, !strings.contains(r.out, "tried again"), r.out)

	r = run(t, h, -1, "monitor", "webhook", "test", address(busy, "/hook"))
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "did not take the test: HTTP 503"), r.out)
	testing.expect(t, strings.contains(r.out, "tried again on later runs"), r.out)

	r = run(t, h, -1, "monitor", "webhook", "list")
	testing.expect(t, strings.contains(r.out, "last try failed: HTTP 410"), r.out)
	testing.expect(t, strings.contains(r.out, "last try failed: HTTP 503"), r.out)
	testing.expect(t, strings.contains(r.out, "1 waiting to be taken"), r.out)
}

// Only https may be sent to, or http to this machine; and a webhook is a Pro
// feature to add, though one already added can always be listed and removed.
@(test)
a_webhook_is_refused_where_it_must_be :: proc(t: ^testing.T) {
	h := home(t, "webhook_refused_urls")
	defer leave(h)

	r := run(t, h, -1, "monitor", "webhook", "add", "http://example.com/hook")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "is not https"), r.out)
	r = run(t, h, -1, "monitor", "webhook", "add", "https://")
	expect_code(t, r, 1)
	r = run(t, h, -1, "monitor", "webhook", "list")
	testing.expect(t, strings.contains(r.out, "nothing is sent anywhere"), r.out)

	r = run(t, h, -1, "monitor", "webhook", "add", "https://example.com/hook", "--paths")
	expect_code(t, r, 0)
	r = run(t, h, -1, "monitor", "webhook", "list")
	testing.expect(t, strings.contains(r.out, "(folder paths included)"), r.out)

	end_evaluation(t, h)
	r = run(t, h, -1, "monitor", "webhook", "add", "https://example.com/other")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "need a licence"), r.out)
	r = run(t, h, -1, "monitor", "webhook", "test")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "need a licence"), r.out)
	r = run(t, h, -1, "monitor", "webhook", "list")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "https://example.com/hook"), r.out)
	r = run(t, h, -1, "monitor", "webhook", "remove", "https://example.com/hook")
	expect_code(t, r, 0)
}
