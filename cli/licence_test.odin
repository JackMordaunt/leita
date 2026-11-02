package leita_cli

import "base:runtime"
import "core:crypto"
import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import jm_path "jm:path"

import "jm:http/loopback"

import "../licence"
import "../monitor"
import "../version"

// A key pair made for a test, standing in for Librium's.
@(private = "file")
Signer :: struct {
	priv: ed25519.Private_Key,
	pub:  [ed25519.PUBLIC_KEY_SIZE]byte,
}

@(private = "file")
signer :: proc() -> (s: Signer) {
	context.random_generator = crypto.random_generator()
	ok := ed25519.private_key_generate(&s.priv)
	assert(ok)
	ed25519.private_key_public_bytes(&s.priv, s.pub[:])
	return
}

// mint signs terms as a licence, in the temp allocator.
@(private = "file")
mint :: proc(s: ^Signer, terms: string) -> string {
	signed := strings.concatenate(
		{
			licence.PREFIX,
			base64.encode(transmute([]byte)terms, allocator = context.temp_allocator),
		},
		context.temp_allocator,
	)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&s.priv, transmute([]byte)signed, sig[:])
	return strings.concatenate(
		{signed, ".", base64.encode(sig[:], allocator = context.temp_allocator)},
		context.temp_allocator,
	)
}

@(private = "file")
TERMS :: #load("../licence/testdata/sample.json", string)

// A data folder for one test, and the history store in it.
@(private = "file")
data_folder :: proc(t: ^testing.T) -> (dir, kept: string) {
	err: os.Error
	dir, err = jm_path.make_directory_temp("", "leita-licence-cli-*", context.temp_allocator)
	testing.expect(t, err == nil)
	joined, _ := filepath.join({dir, "data", "history.db"}, context.temp_allocator)
	return dir, joined
}

// licence_says runs leita licence args, returning the exit code and what it said
// on standard output.
@(private = "file")
licence_says :: proc(c: Licence_Context, args: ..string) -> (int, string) {
	stdio_shared()
	defer stdio_done()
	b := strings.builder_make(context.temp_allocator)
	code := licence_dispatch(c, args, strings.to_writer(&b))
	return code, strings.to_string(b)
}

// leita licence add keeps a licence where the window keeps its own, leita
// licence shows whose it is and the paid-through date, and leita licence
// remove forgets it, after which the trial is all there is.
@(test)
a_licence_is_added_shown_and_removed :: proc(t: ^testing.T) {
	s := signer()
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	c := Licence_Context {
		kept = kept,
		key  = s.pub[:],
		now  = time.unix(1_800_000_000, 0),
	}
	beside, _ := filepath.join({dir, "data", "licence"}, context.temp_allocator)
	kept_at := licence.path_beside(kept, context.temp_allocator)
	testing.expect_value(t, kept_at, beside)
	testing.expect(t, kept_at != kept)

	code, said := licence_says(c, "add", mint(&s, TERMS))
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(
		t,
		strings.contains(
			said,
			"licensed to ada@example.com, Professional; paid through 2027-10-19T00:00:00Z",
		),
		said,
	)
	testing.expect(t, os.exists(kept_at), "it is kept beside the history store")

	code, said = licence_says(c)
	testing.expect_value(t, code, EXIT_OK)
	for want in ([]string{"ada@example.com", "Professional", "ord_1, issued 2026-10-19T12:00:00Z", "2027-10-19T00:00:00Z", "no release stamp", "runs Free"}) {
		testing.expectf(t, strings.contains(said, want), "%q is not in %q", want, said)
	}

	code, said = licence_says(c, "remove")
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, !os.exists(kept_at), "it is forgotten")
	code, said = licence_says(c)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(said, "no licence; the Pro evaluation"), said)
	code, said = licence_says(c, "remove")
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(said, "no licence is kept here"), said)
}

// The file from the receipt is taken as well as the line it holds; anything
// else, a licence key or a licence another key signed, is refused and nothing
// is kept.
@(test)
a_licence_file_is_added_and_what_is_not_a_licence_refused :: proc(t: ^testing.T) {
	s, other := signer(), signer()
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	c := Licence_Context {
		kept = kept,
		key  = s.pub[:],
		now  = time.unix(1_800_000_000, 0),
	}
	kept_at := licence.path_beside(kept, context.temp_allocator)

	for offered in ([]string{"polar_cl_0a1b2c3d", mint(&other, TERMS), "leita1.e30=.AAAA"}) {
		code, _ := licence_says(c, "add", offered)
		testing.expectf(t, code == EXIT_ERROR, "%s was taken", offered)
	}
	testing.expect(t, !os.exists(kept_at), "nothing is kept")
	code, _ := licence_says(c, "add")
	testing.expect_value(t, code, EXIT_ERROR)
	code, _ = licence_says(c, "add", "a", "b")
	testing.expect_value(t, code, EXIT_ERROR)
	code, _ = licence_says(c, "show")
	testing.expect_value(t, code, EXIT_ERROR)

	file := fmt.tprintf("%s/leita-licence.txt", dir)
	testing.expect(t, os.write_entire_file(file, fmt.tprintf("%s\n", mint(&s, TERMS))) == nil)
	code, _ = licence_says(c, "add", file)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, os.exists(kept_at), "the file's licence is kept")
}

// LEITA_LICENCE holds a licence for one run in place of the one kept, for the
// report and the monitor alike, and leita licence says it is in use; one that
// does not check is said, and the run goes on without it.
@(test)
leita_licence_holds_a_licence_for_one_run :: proc(t: ^testing.T) {
	s := signer()
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	began := time.unix(1_800_000_000, 0)
	month := time.time_add(began, 31 * licence.DAY)
	line := mint(&s, TERMS)

	licensee, unlocked, problem := monitor.licence_beside(kept, "", began, s.pub[:])
	testing.expect(t, unlocked && licensee == "", "the trial begins")
	licensee, unlocked, problem = monitor.licence_beside(kept, "", month, s.pub[:])
	testing.expect(t, !unlocked, "a month on, it is over")

	licensee, unlocked, problem = monitor.licence_beside(kept, line, month, s.pub[:])
	testing.expect_value(t, licensee, "ada@example.com")
	testing.expect_value(t, problem, "")
	// This build has no release stamp, so the line does not grant Pro once the
	// evaluation is over. The paid-through cutoff is what the gate asks.
	testing.expect(t, !unlocked, "an unstamped build stays Free after the evaluation")
	beside, _ := filepath.join({dir, "data", "licence"}, context.temp_allocator)
	testing.expect_value(t, licence.path_beside(kept, context.temp_allocator), beside)
	testing.expect(t, !os.exists(beside), "and keeps nothing")

	licensee, unlocked, problem = monitor.licence_beside(kept, "leita1.x.y", month, s.pub[:])
	testing.expect(t, !unlocked && licensee == "", "a bad one unlocks nothing")
	testing.expect(t, strings.contains(problem, "LEITA_LICENCE holds no licence"), problem)

	code, said := licence_says({kept = kept, given = line, key = s.pub[:], now = month})
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(said, "LEITA_LICENCE, for this run"), said)
}

VECTOR_1  :: #load("../licence/testdata/throwaway/vector-1.line", string)
THROW_PUB :: #load("../licence/testdata/throwaway/ed25519.public.hex", string)

// A published line is kept and says who it is for and the paid-through date.
// This build has no release stamp, so Pro stays off.
@(test)
a_line_names_its_paid_through_date :: proc(t: ^testing.T) {
	raw, ok := hex.decode(transmute([]byte)strings.trim_space(THROW_PUB), context.temp_allocator)
	testing.expect(t, ok && len(raw) == ed25519.PUBLIC_KEY_SIZE)
	key: [ed25519.PUBLIC_KEY_SIZE]byte
	copy(key[:], raw)
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	c := Licence_Context {
		kept = kept,
		key  = key[:],
		now  = time.unix(1_800_000_000, 0),
	}
	code, said := licence_says(c, "add", strings.trim_space(VECTOR_1))
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(said, "ada@example.com"), said)
	testing.expect(t, strings.contains(said, "Personal"), said)
	testing.expect(t, strings.contains(said, "paid through 2027-10-19T00:00:00Z"), said)
	testing.expect(t, !strings.contains(said, "does not expire"), said)

	code, said = licence_says(c)
	testing.expect_value(t, code, EXIT_OK)
	for want in ([]string{"ada@example.com", "Personal", "2027-10-19T00:00:00Z", "no release stamp", "runs Free"}) {
		testing.expectf(t, strings.contains(said, want), "%q is not in %q", want, said)
	}
}

// Capture diagnostics as well as stdout, holding the shared CLI stream lock
// alone so another test cannot put a message in this command's result.
@(private = "file")
activation_says :: proc(
	t: ^testing.T,
	c: Licence_Context,
	args: ..string,
) -> (
	code: int,
	out, problem: string,
) {
	sync.rw_mutex_lock(&stdio_rw)
	defer sync.rw_mutex_unlock(&stdio_rw)
	dir, err := jm_path.make_directory_temp(
		"",
		"leita-activation-output-*",
		context.temp_allocator,
	)
	if !testing.expect(t, err == nil) {
		return EXIT_ERROR, "", "capture failed"
	}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/stderr", dir)
	f, ferr := os.create(path)
	if !testing.expect(t, ferr == nil) {
		return EXIT_ERROR, "", "capture failed"
	}
	saved := os.stderr
	os.stderr = f
	b := strings.builder_make(context.temp_allocator)
	code = licence_dispatch(c, args, strings.to_writer(&b))
	os.stderr = saved
	os.close(f)
	text, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	return code, strings.to_string(b), string(text)
}

@(private = "file")
ACTIVATION_KEY :: "LEITA-quoted\"key\\value"

@(private = "file")
Activation_Shop :: struct {
	line, bad_line: string,
	bad_request:    b32,
}

// A local shop checks the actual POST, JSON escaping, identity and absence
// of extra credentials. Each path supplies one protocol outcome.
@(private = "file")
answer_cli_activation :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	shop := (^Activation_Shop)(conn.server.user)
	Ask :: struct {
		key: string `json:"key"`,
	}
	want, _ := json.marshal(Ask{ACTIVATION_KEY}, allocator = context.temp_allocator)
	if req.method != "POST" ||
	   req.body != string(want) ||
	   !strings.contains(req.head, "Content-Type: application/json\r\n") ||
	   !strings.contains(req.head, "Accept: application/json\r\n") ||
	   !strings.contains(req.head, "User-Agent: leita/" + version.VERSION + "\r\n") ||
	   strings.contains(req.head, "Authorization:") ||
	   strings.contains(req.head, "Cookie:") {
		sync.atomic_store(&shop.bad_request, true)
	}
	status, body := 200, ""
	switch req.path {
	case "/sold":
		Granted :: struct {
			licence: string `json:"licence"`,
		}
		raw, _ := json.marshal(Granted{shop.line}, allocator = context.temp_allocator)
		body = string(raw)
	case "/invalid-line":
		Granted :: struct {
			licence: string `json:"licence"`,
		}
		raw, _ := json.marshal(Granted{shop.bad_line}, allocator = context.temp_allocator)
		body = string(raw)
	case "/invalid-json":
		body = "<html>proxy sign-in</html>"
	case "/empty-line":
		body = `{"licence":""}`
	case "/not-an-object":
		body = `[]`
	case "/refund":
		status, body =
			404, `{"error":"unknown","message":"The order was refunded.\nPrivate detail"}`
	case "/unknown":
		status, body = 404, `{"error":"unknown"}`
	case "/unsettled":
		status, body = 409, `{"error":"unsettled"}`
	case "/held":
		status, body = 423, `{"error":"held"}`
	case "/terminal-controls":
		status, body = 400, `{"message":"Bad key \u001b]0;owned\u0007\u001b[31m"}`
	case "/reflected-key":
		Fault :: struct {
			message: string `json:"message"`,
		}
		raw, _ := json.marshal(
			Fault{"Rejected " + ACTIVATION_KEY},
			allocator = context.temp_allocator,
		)
		status, body = 400, string(raw)
	case "/server":
		status, body = 503, `{"error":"unavailable"}`
	case "/oversized":
		body = strings.repeat("x", LICENCE_ACTIVATE_BODY_MAX + 1, context.temp_allocator)
	case "/redirect":
		loopback.send(
			conn,
			"HTTP/1.1 307 Temporary Redirect\r\nLocation: /sold\r\nContent-Length: 0\r\n\r\n",
		)
		return
	case "/silent":
		loopback.hold(conn)
		return
	case "/disconnect":
		return
	}
	loopback.send(
		conn,
		fmt.tprintf(
			"HTTP/1.1 %d Fixture\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
			status,
			len(body),
			body,
		),
	)
}

@(test)
a_shop_key_is_exchanged_and_the_verified_licence_and_receipt_are_kept :: proc(t: ^testing.T) {
	s := signer()
	shop := Activation_Shop {
		line = mint(&s, TERMS),
	}
	srv, up := loopback.start(answer_cli_activation, &shop, runtime.heap_allocator())
	if !testing.expect(t, up) {return}
	defer loopback.stop(srv)
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	c := Licence_Context {
		kept         = kept,
		key          = s.pub[:],
		activate_url = loopback.url(srv, "/sold"),
	}
	code, out, problem := activation_says(t, c, "activate", ACTIVATION_KEY)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect_value(t, problem, "")
	testing.expect(
		t,
		strings.contains(out, "added the licence: licensed to ada@example.com, Professional"),
		out,
	)
	testing.expect(t, !strings.contains(out, ACTIVATION_KEY))
	path := licence.path_beside(kept, context.temp_allocator)
	line, read_err := licence.read(path)
	testing.expect_value(t, read_err, licence.Error.None)
	testing.expect_value(t, strings.trim_space(line), shop.line)
	receipt, found := licence.read_receipt(path)
	testing.expect(t, found)
	testing.expect_value(t, receipt, ACTIVATION_KEY)
	testing.expect(
		t,
		!sync.atomic_load(&shop.bad_request),
		"POST contains only the escaped key and documented headers",
	)
	code, out, problem = activation_says(t, c)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(out, "ada@example.com"))
	testing.expect(t, loopback.accepted(srv) == 1, "showing the stored line is offline")
	// Adding a line directly continues to be offline and drops a receipt it
	// did not obtain, rather than silently replacing it after key rotation.
	code, _, _ = activation_says(t, c, "add", shop.line)
	testing.expect_value(t, code, EXIT_OK)
	_, found = licence.read_receipt(path)
	testing.expect(t, !found)
	testing.expect_value(t, loopback.accepted(srv), 1)
}

@(test)
failed_activation_preserves_the_previous_licence_and_receipt :: proc(t: ^testing.T) {
	s, other := signer(), signer()
	shop := Activation_Shop {
		line     = mint(&s, TERMS),
		bad_line = mint(&other, TERMS),
	}
	srv, up := loopback.start(answer_cli_activation, &shop, runtime.heap_allocator())
	if !testing.expect(t, up) {return}
	defer loopback.stop(srv)
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	path := licence.path_beside(kept, context.temp_allocator)
	_, keep_err := licence.keep(path, shop.line, s.pub[:], context.temp_allocator)
	testing.expect_value(t, keep_err, licence.Error.None)
	testing.expect_value(t, licence.save_receipt(path, "OLD-KEY"), licence.Error.None)
	before, berr := licence.read(path)
	testing.expect_value(t, berr, licence.Error.None)
	Scenario :: struct {
		route, want: string,
	}
	scenarios := []Scenario {
		{"/invalid-line", "not a licence Librium signed"},
		{"/invalid-json", "returned no licence"},
		{"/empty-line", "returned no licence"},
		{"/not-an-object", "returned no licence"},
		{"/refund", "The order was refunded."},
		{"/unknown", "check the receipt or refund status"},
		{"/unsettled", "has not settled"},
		{"/held", "waiting for a licence decision"},
		{"/reflected-key", "[redacted]"},
		{"/terminal-controls", "Bad key"},
		{"/server", "HTTP 503"},
		{"/oversized", "larger than 64 KiB"},
		{"/redirect", "refused a redirect"},
		{"/silent", "did not answer in time"},
		{"/disconnect", "could not be reached"},
	}
	for scenario in scenarios {
		c := Licence_Context {
			kept         = kept,
			key          = s.pub[:],
			activate_url = loopback.url(srv, scenario.route),
		}
		if scenario.route == "/silent" {
			c.activate_timeout = 100 * time.Millisecond
		}
		accepted := loopback.accepted(srv)
		code, out, problem := activation_says(t, c, "activate", ACTIVATION_KEY)
		testing.expectf(t, code == EXIT_ERROR, "%s: %s", scenario.route, out)
		testing.expectf(
			t,
			strings.contains(problem, scenario.want),
			"%s: %s",
			scenario.route,
			problem,
		)
		testing.expect_value(t, out, "")
		testing.expect(t, !strings.contains(problem, ACTIVATION_KEY), problem)
		testing.expect(
			t,
			!strings.contains_rune(problem, 0x1b) && !strings.contains_rune(problem, 0x07),
			"server control bytes cannot reach the terminal",
		)
		testing.expect(
			t,
			!strings.contains(problem, "Private detail"),
			"only the server message's first line is shown",
		)
		if scenario.route == "/redirect" {
			testing.expect(
				t,
				loopback.accepted(srv) == accepted + 1,
				"no second request follows the redirect",
			)
		}
		after, aerr := licence.read(path)
		testing.expect_value(t, aerr, licence.Error.None)
		testing.expect(t, after == before, "a failed activation cannot replace the stored line")
		receipt, found := licence.read_receipt(path)
		testing.expect(t, found)
		testing.expect_value(t, receipt, "OLD-KEY")
	}
	// A valid response cannot report success if the atomic line replacement
	// fails. The previously verified licence and receipt remain available.
	staging := fmt.tprintf("%s.new", path)
	testing.expect(t, os.make_directory(staging) == nil)
	c := Licence_Context {
		kept         = kept,
		key          = s.pub[:],
		activate_url = loopback.url(srv, "/sold"),
	}
	code, out, problem := activation_says(t, c, "activate", ACTIVATION_KEY)
	testing.expect_value(t, code, EXIT_ERROR)
	testing.expect_value(t, out, "")
	testing.expect(t, strings.contains(problem, "could not be kept"), problem)
	after, aerr := licence.read(path)
	testing.expect_value(t, aerr, licence.Error.None)
	testing.expect_value(t, after, before)
	receipt, found := licence.read_receipt(path)
	testing.expect(t, found)
	testing.expect_value(t, receipt, "OLD-KEY")
	testing.expect(t, !sync.atomic_load(&shop.bad_request))
}

@(test)
activation_validates_arguments_and_help_without_sending_the_key :: proc(t: ^testing.T) {
	s := signer()
	shop := Activation_Shop {
		line = mint(&s, TERMS),
	}
	srv, up := loopback.start(answer_cli_activation, &shop, runtime.heap_allocator())
	if !testing.expect(t, up) {return}
	defer loopback.stop(srv)
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	c := Licence_Context {
		kept         = kept,
		key          = s.pub[:],
		activate_url = loopback.url(srv, "/sold"),
	}
	for key in ([]string{"", "KEY WITH SPACES", "KEY\tTAB", "KEY\nNEWLINE", strings.repeat("x", licence.RECEIPT_MAX + 1, context.temp_allocator)}) {
		code, _, problem := activation_says(t, c, "activate", key)
		testing.expect_value(t, code, EXIT_ERROR)
		testing.expect(t, strings.contains(problem, "not a shop key"), problem)
		if key != "" {testing.expect(t, !strings.contains(problem, key))}
	}
	code, _, problem := activation_says(t, c, "activate", ACTIVATION_KEY, "extra")
	testing.expect_value(t, code, EXIT_ERROR)
	testing.expect(t, !strings.contains(problem, ACTIVATION_KEY))
	help_code, out, _ := activation_says(t, c, "activate", "--help")
	testing.expect_value(t, help_code, EXIT_OK)
	testing.expect(t, strings.contains(out, "activate KEY"), out)
	testing.expect(t, strings.contains(out, "LEITA_ACTIVATE_URL"), out)
	testing.expect_value(t, loopback.accepted(srv), 0)
	testing.expect(t, !os.exists(licence.path_beside(kept, context.temp_allocator)))
}

@(test)
activation_limits_a_server_message_to_one_redacted_line :: proc(t: ^testing.T) {
	Fault :: struct {
		message: string `json:"message"`,
	}
	long := strings.repeat("x", 250, context.temp_allocator)
	body, _ := json.marshal(
		Fault{strings.concatenate({long, "\nsecond line"}, context.temp_allocator)},
		allocator = context.temp_allocator,
	)
	line, problem := licence_activation_response(400, string(body), ACTIVATION_KEY)
	testing.expect_value(t, line, "")
	testing.expect(t, strings.contains(problem, long[:200]))
	testing.expect(t, !strings.contains(problem, long[:201]))
	testing.expect(t, !strings.contains(problem, "second line"))
}
