/*
Package netfault is a server on this machine that answers the way a broken
network does, so a test can point leita's requests at it and see what a person
would: a connection refused, a server that stalls before its headers or half
way through its body, one that trickles a byte at a time, a body cut short or
reset, a redirect and a redirect loop, a 4xx or 5xx, and the HTML page a
captive portal answers every request with. Nothing here reaches past
127.0.0.1, and nothing waits on the network outside the machine.

	srv := netfault.start(.Stall_Head)
	defer netfault.stop(srv)
	url := netfault.url(srv, "/sha256sums.txt")

A server with a dir serves its files, as a release page does, and one with a
body answers every request with it; the fault replaces that answer. With only
set, the fault is put on the paths that begin with it and every other path is
served whole, so a test can break the download alone, its patch and its .zst
too, and leave the signed sums be.

The same server stands in for an HTTP proxy: a client told HTTPS_PROXY asks it
CONNECT host:443, which seen keeps, and the fault is its answer to that.

tls.odin starts a TLS server with a certificate made at test time, for the
certificate faults, and url_tls_without_tls is the plain server asked over
https.
*/
package netfault

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import "jm:http/loopback"

// Fault is how the server answers a request it puts a fault on.
Fault :: enum {
	// Serve what is asked, whole.
	None,
	// Read the request and say nothing, until stop.
	Stall_Head,
	// Send the head and half the body, then nothing, until stop.
	Stall_Body,
	// Send the head, then the body a byte at a time, gap apart.
	Trickle,
	// Promise the whole body by Content-Length, send half, and close.
	Truncate,
	// Send half the body with no length, ended by the close: a short body that
	// looks whole to a client that does not know its length.
	Truncate_Unframed,
	// Send the head and half the body, then reset the connection.
	Reset,
	// 302 to the path asked, on the server at location.
	Redirect,
	// 302 to the path asked, for ever.
	Redirect_Loop,
	// Answer status, with body as a JSON message.
	Status,
	// 200 with the HTML a captive portal sends in place of every page.
	Portal,
}

// PORTAL_PAGE is what a captive portal answers in place of any page asked.
PORTAL_PAGE :: `<!doctype html>
<html><head><title>Sign in to Guest Wi-Fi</title></head>
<body><h1>Welcome</h1><p>Accept the terms to use this network.</p>
<form method="post" action="/login"><button>Accept</button></form></body></html>
`

// GAP is how far apart a trickle sends its bytes unless the server is given one.
GAP :: 50 * time.Millisecond

// Server is a loopback server with a fault. Read its fields only through the
// procedures here: each connection runs on a thread of its own.
Server :: struct {
	allocator: runtime.Allocator,
	srv:       ^loopback.Server, // loopback.stop frees it, in stop
	fault:     Fault,
	only:      string,
	dir:       string,
	body:      string,
	status:    int,
	location:  string,
	gap:       time.Duration,
	mutex:     sync.Mutex,
	seen:      [dynamic]string,
}

/*
start starts a server with fault on every path, or on those only begins. dir is a
folder whose files it serves, 404 for what is not there; body, when dir is
empty, is what it answers every request with, 200 and JSON. status is the
answer of a Status fault, and location the base, with no trailing slash,
a Redirect sends each path to. allocator holds the server and what it keeps
until stop; every connection's thread uses it, so it must be thread-safe, as
the heap is and a test's tracking allocator is not; none is the heap. stop
it with stop.
*/
start :: proc(
	fault: Fault,
	dir := "",
	body := "",
	only := "",
	status := 503,
	location := "",
	gap := GAP,
	allocator: runtime.Allocator = {},
) -> ^Server {
	a := allocator if allocator.procedure != nil else runtime.heap_allocator()
	s := new(Server, a)
	s.allocator = a
	s.fault = fault
	s.dir = strings.clone(dir, a)
	s.body = strings.clone(body, a)
	s.only = strings.clone(only, a)
	s.status = status
	s.location = strings.clone(location, a)
	s.gap = gap
	s.seen = make([dynamic]string, a)
	ok: bool
	s.srv, ok = loopback.start(answer, s, a)
	if !ok {
		free_server(s)
		return nil
	}
	return s
}

// stop ends every connection still held open, waits for each, and frees s.
stop :: proc(s: ^Server) {
	if s == nil {
		return
	}
	loopback.stop(s.srv)
	free_server(s)
}

@(private)
free_server :: proc(s: ^Server) {
	a := s.allocator
	for h in s.seen {
		delete(h, a)
	}
	delete(s.seen)
	delete(s.dir, a)
	delete(s.body, a)
	delete(s.only, a)
	delete(s.location, a)
	free(s, a)
}

// url is http://127.0.0.1:<port><path> on s, in allocator.
url :: proc(s: ^Server, path := "/", allocator := context.temp_allocator) -> string {
	return loopback.url(s.srv, path, allocator)
}

// base is s's URL with no trailing slash, as a release base is given, in
// allocator.
base :: proc(s: ^Server, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("http://127.0.0.1:%d", s.srv.port, allocator = allocator)
}

// proxy is s as an HTTP proxy address, http://127.0.0.1:<port>, in allocator.
proxy :: proc(s: ^Server, allocator := context.temp_allocator) -> string {
	return base(s, allocator)
}

// url_tls_without_tls is path on s asked over https, which s does not speak,
// in allocator.
url_tls_without_tls :: proc(
	s: ^Server,
	path := "/",
	allocator := context.temp_allocator,
) -> string {
	return fmt.aprintf("https://127.0.0.1:%d%s", s.srv.port, path, allocator = allocator)
}

// seen is the request line and headers of each request s has taken, oldest
// first, in allocator.
seen :: proc(s: ^Server, allocator := context.temp_allocator) -> []string {
	sync.mutex_guard(&s.mutex)
	out := make([]string, len(s.seen), allocator)
	for h, i in s.seen {
		out[i] = strings.clone(h, allocator)
	}
	return out
}

// accepted is how many connections s has taken.
accepted :: proc(s: ^Server) -> int {
	return loopback.accepted(s.srv)
}

/*
refused is a URL with path on 127.0.0.1 at a port nothing listens on, so a
connection to it is refused at once: a port that was bound and let go. Another
test may bind it again in between, which a refusal test then sees as an
answer it did not want; the window is the few instructions until it dials.
*/
refused :: proc(path := "/", allocator := context.temp_allocator) -> string {
	port := 1
	if listener, err := net.listen_tcp({net.IP4_Loopback, 0}); err == nil {
		bound, _ := net.bound_endpoint(listener)
		port = bound.port
		net.close(listener)
	}
	return fmt.aprintf("http://127.0.0.1:%d%s", port, path, allocator = allocator)
}

// UNRESOLVABLE is a host no resolver answers: .invalid is reserved for that
// (RFC 6761 §6.4), so a lookup fails without a server anywhere being asked
// for a name that exists.
UNRESOLVABLE :: "leita-release.invalid"

// answer is loopback's Handler, whose signature takes no allocator: what it
// keeps goes to the server's, which outlives the connection, and what it sends
// is built in the connection thread's temp allocator.
//review:ignore odin-allocator-contract a loopback.Handler cannot take an allocator; it names the two it uses above
@(private)
answer :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	s := (^Server)(conn.server.user)
	{
		sync.mutex_guard(&s.mutex)
		append(&s.seen, strings.clone(req.head, s.allocator))
	}
	whole := whole_answer(s, req)
	fault := s.fault
	if !strings.has_prefix(req.path, s.only) {
		fault = .None
	}
	head_of :: proc(status: int, kind: string, length: int) -> string {
		if length < 0 {
			return fmt.tprintf(
				"HTTP/1.1 %d %s\r\nContent-Type: %s\r\n\r\n",
				status,
				reason(status),
				kind,
			)
		}
		return fmt.tprintf(
			"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n",
			status,
			reason(status),
			kind,
			length,
		)
	}
	half := whole.body[:len(whole.body) / 2]
	switch fault {
	case .None:
		loopback.send(conn, head_of(whole.status, whole.kind, len(whole.body)))
		loopback.send(conn, whole.body)
	case .Stall_Head:
		loopback.hold(conn)
	case .Stall_Body:
		loopback.send(conn, head_of(whole.status, whole.kind, len(whole.body)))
		loopback.send(conn, half)
		loopback.hold(conn)
	case .Trickle:
		loopback.send(conn, head_of(whole.status, whole.kind, len(whole.body)))
		for i in 0 ..< len(whole.body) {
			if !loopback.pause(conn, s.gap) || !loopback.send(conn, whole.body[i:i + 1]) {
				return
			}
		}
	case .Truncate:
		loopback.send(conn, head_of(whole.status, whole.kind, len(whole.body)))
		loopback.send(conn, half)
	case .Truncate_Unframed:
		loopback.send(conn, head_of(whole.status, whole.kind, -1))
		loopback.send(conn, half)
	case .Reset:
		loopback.send(conn, head_of(whole.status, whole.kind, len(whole.body)))
		loopback.send(conn, half)
		// Let the half reach the client before the reset throws away what
		// the kernel has not yet sent.
		loopback.pause(conn, 50 * time.Millisecond)
		reset_on_close(conn.socket)
	case .Redirect:
		loopback.send(
			conn,
			fmt.tprintf(
				"HTTP/1.1 302 Found\r\nLocation: %s%s\r\nContent-Length: 0\r\n\r\n",
				s.location,
				req.path,
			),
		)
	case .Redirect_Loop:
		loopback.send(
			conn,
			fmt.tprintf(
				"HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\n\r\n",
				req.path,
			),
		)
	case .Status:
		message := fmt.tprintf("%s%d%s", `{"message":"the server answered `, s.status, `"}`)
		loopback.send(conn, head_of(s.status, "application/json", len(message)))
		loopback.send(conn, message)
	case .Portal:
		loopback.send(conn, head_of(200, "text/html; charset=utf-8", len(PORTAL_PAGE)))
		loopback.send(conn, PORTAL_PAGE)
	}
}

@(private)
Answer :: struct {
	status: int,
	kind:   string,
	body:   string,
}

// whole_answer is what s answers req with when nothing is wrong, a file's
// bytes in allocator.
@(private)
whole_answer :: proc(
	s: ^Server,
	req: loopback.Request,
	allocator := context.temp_allocator,
) -> Answer {
	if s.dir == "" {
		return {200, "application/json", s.body}
	}
	name := strings.trim_prefix(req.path, "/")
	if q := strings.index_byte(name, '?'); q >= 0 {
		name = name[:q]
	}
	if name == "" || strings.contains(name, "..") {
		return {404, "text/plain", ""}
	}
	data, err := os.read_entire_file(strings.concatenate({s.dir, "/", name}, allocator), allocator)
	if err != nil {
		return {404, "text/plain", ""}
	}
	return {200, "application/octet-stream", string(data)}
}

@(private)
reason :: proc(status: int) -> string {
	switch status {
	case 200:
		return "OK"
	case 302:
		return "Found"
	case 400:
		return "Bad Request"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 407:
		return "Proxy Authentication Required"
	case 429:
		return "Too Many Requests"
	case 500:
		return "Internal Server Error"
	case 502:
		return "Bad Gateway"
	case 503:
		return "Service Unavailable"
	}
	return "Answer"
}
