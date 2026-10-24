package journeys

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import "jm:http/loopback"

// Request is one request a Receiver took: its request line and headers, and body.
Request :: struct {
	head: string,
	body: string,
}

// Receiver is a server on this machine for the command line to talk to: it
// keeps every request it is sent, and answers each with status. With a dir it
// serves the files in it, the way a release page does, and answers 404 for
// what is not there.
Receiver :: struct {
	server: ^loopback.Server,
	mutex:  sync.Mutex,
	taken:  [dynamic]Request,
	status: int,
	dir:    string,
}

// start_receiver starts a Receiver answering status. stop it with stop_receiver.
start_receiver :: proc(t: ^testing.T, status := 200, dir := "") -> ^Receiver {
	r := new(Receiver)
	r.status = status
	r.dir = dir
	r.taken = make([dynamic]Request)

	ok: bool
	r.server, ok = loopback.start(answer, r, context.allocator)
	testing.expect(t, ok, "the receiver could not start")
	return r
}

// stop_receiver stops the receiver and frees what it kept.
stop_receiver :: proc(r: ^Receiver) {
	loopback.stop(r.server)

	for q in r.taken {
		delete(q.head)
		delete(q.body)
	}
	delete(r.taken)
	free(r)
}

// address is the URL of path on the receiver.
address :: proc(r: ^Receiver, path := "/") -> string {
	return loopback.url(r.server, path)
}

// requests is a copy of what the receiver has taken so far.
requests :: proc(r: ^Receiver) -> []Request {
	sync.mutex_guard(&r.mutex)
	copied := make([]Request, len(r.taken), context.temp_allocator)
	copy(copied, r.taken[:])
	return copied
}

@(private = "file")
answer :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	r := (^Receiver)(conn.server.user)
	sync.mutex_guard(&r.mutex)
	append(&r.taken, Request{head = strings.clone(req.head), body = strings.clone(req.body)})

	if r.dir != "" {
		name := strings.trim_prefix(req.path, "/")
		bytes, err := os.read_entire_file(
			strings.concatenate({r.dir, "/", name}, context.temp_allocator),
			context.temp_allocator,
		)
		if err != nil || name == "" {
			loopback.send(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
			return
		}
		loopback.send(
			conn,
			fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n", len(bytes)),
		)
		loopback.send(conn, string(bytes))
		return
	}

	loopback.send(conn, fmt.tprintf("HTTP/1.1 %d Answer\r\nContent-Length: 0\r\n\r\n", r.status))
}
