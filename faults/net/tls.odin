package netfault

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

/*
The certificate faults. make_certs makes, in a folder of the test's, a
certificate authority of its own and two certificates no client trusts: one
the authority signed for another host (elsewhere.invalid), and one that signed
itself for 127.0.0.1. start_tls serves one of them with openssl s_server on
127.0.0.1, so a client that asks https://127.0.0.1:<port>/ is shown a
certificate it must refuse: for the wrong host, by an issuer it has never
heard of, or both.

Nothing is installed or trusted anywhere: the authority's key is made at test
time, lives in the test's folder, and is removed with it. TLS itself comes from
the openssl command. openssl_found says whether this machine has one, and a
test that needs it fails on a runner (CI set) without it rather than passing
by leaving the certificates out.
*/

// Certs are the files make_certs wrote.
Certs :: struct {
	dir:        string,
	ca:         string,
	wrong_host: string, // signed by ca, for elsewhere.invalid
	wrong_key:  string,
	self:       string, // signed by itself, for 127.0.0.1
	self_key:   string,
}

// WRONG_HOST is the one name wrong_host is for.
WRONG_HOST :: "elsewhere.invalid"

@(private)
CONFIG :: `[req]
distinguished_name = dn
prompt = no
[dn]
CN = leita test authority
[authority]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
[wrong]
basicConstraints = CA:FALSE
subjectAltName = DNS:elsewhere.invalid
[self]
basicConstraints = CA:FALSE
subjectAltName = IP:127.0.0.1
`

// openssl is the command run for TLS: LEITA_OPENSSL, else openssl on PATH, in
// allocator.
openssl :: proc(allocator := context.temp_allocator) -> string {
	if p := os.get_env("LEITA_OPENSSL", allocator); p != "" {
		return p
	}
	return "openssl"
}

// openssl_found says whether the openssl command runs here.
openssl_found :: proc() -> bool {
	_, ok := run_openssl("", "version")
	return ok
}

// make_certs writes the authority and both certificates into dir, which must
// exist, and says why not when it could not. The paths are in allocator.
make_certs :: proc(
	dir: string,
	allocator := context.temp_allocator,
) -> (
	c: Certs,
	why: string,
	ok: bool,
) {
	context.allocator = allocator
	at :: proc(dir, name: string) -> string {
		return strings.concatenate({dir, "/", name})
	}
	c = {
		dir        = dir,
		ca         = at(dir, "ca.pem"),
		wrong_host = at(dir, "wrong.pem"),
		wrong_key  = at(dir, "wrong.key"),
		self       = at(dir, "self.pem"),
		self_key   = at(dir, "self.key"),
	}
	config := at(dir, "openssl.cnf")
	if os.write_entire_file(config, CONFIG) != nil {
		return c, "could not write the openssl configuration", false
	}
	steps := [][]string {
		{
			"req",
			"-x509",
			"-config",
			config,
			"-extensions",
			"authority",
			"-newkey",
			"rsa:2048",
			"-nodes",
			"-keyout",
			at(dir, "ca.key"),
			"-out",
			c.ca,
			"-days",
			"2",
			"-subj",
			"/CN=leita test authority",
		},
		{
			"req",
			"-new",
			"-config",
			config,
			"-newkey",
			"rsa:2048",
			"-nodes",
			"-keyout",
			c.wrong_key,
			"-out",
			at(dir, "wrong.csr"),
			"-subj",
			"/CN=" + WRONG_HOST,
		},
		{
			"x509",
			"-req",
			"-in",
			at(dir, "wrong.csr"),
			"-CA",
			c.ca,
			"-CAkey",
			at(dir, "ca.key"),
			"-set_serial",
			"2",
			"-days",
			"2",
			"-extfile",
			config,
			"-extensions",
			"wrong",
			"-out",
			c.wrong_host,
		},
		{
			"req",
			"-x509",
			"-config",
			config,
			"-extensions",
			"self",
			"-newkey",
			"rsa:2048",
			"-nodes",
			"-keyout",
			c.self_key,
			"-out",
			c.self,
			"-days",
			"2",
			"-subj",
			"/CN=127.0.0.1",
		},
	}
	for step in steps {
		if said, ran := run_openssl(dir, ..step, allocator = allocator); !ran {
			return c, fmt.aprintf("openssl %s: %s", step[0], said), false
		}
	}
	return c, "", true
}

// Tls is an openssl s_server on 127.0.0.1.
Tls :: struct {
	process: os.Process,
	port:    int,
}

/*
start_tls serves cert and its key over TLS on 127.0.0.1, and answers HTTP
with s_server's status page, which no test reaches: every client here refuses
the certificate first. It waits until the server takes connections. stop it
with stop_tls. why, when it could not, is in allocator.
*/
start_tls :: proc(
	cert, key: string,
	allocator := context.temp_allocator,
) -> (
	tls: Tls,
	why: string,
	ok: bool,
) {
	// OpenSSL's s_server takes -accept host:port. If the openssl on PATH will
	// not listen that way, the port alone is tried, which listens on every
	// address for as long as the test runs.
	for form in 0 ..< 2 {
		tls.port = free_port()
		buf: [32]byte
		accept := fmt.bprintf(buf[:], "127.0.0.1:%d" if form == 0 else "%d", tls.port)
		command := []string {
			openssl(allocator),
			"s_server",
			"-accept",
			accept,
			"-cert",
			cert,
			"-key",
			key,
			"-www",
			"-quiet",
		}
		p, err := os.process_start({command = command})
		if err != nil {
			return tls,
				fmt.aprintf("could not start openssl s_server: %v", err, allocator = allocator),
				false
		}
		tls.process = p
		deadline := time.time_add(time.now(), 10 * time.Second)
		for time.diff(time.now(), deadline) > 0 {
			if state, werr := os.process_wait(p, 0); werr == nil && state.exited {
				break
			}
			if sock, derr := net.dial_tcp(net.Endpoint{net.IP4_Loopback, tls.port}); derr == nil {
				net.close(sock)
				return tls, "", true
			}
			time.sleep(20 * time.Millisecond)
		}
		stop_tls(&tls)
	}
	return tls, "openssl s_server did not take connections on 127.0.0.1", false
}

// tls_url is the https URL of path on tls, which a client asks to be shown
// its certificate, in allocator.
tls_url :: proc(tls: Tls, path := "/", allocator := context.temp_allocator) -> string {
	return fmt.aprintf("https://127.0.0.1:%d%s", tls.port, path, allocator = allocator)
}

// stop_tls ends the server.
stop_tls :: proc(tls: ^Tls) {
	if tls.process == {} {
		return
	}
	_ = os.process_kill(tls.process)
	_, _ = os.process_wait(tls.process, 5 * time.Second)
	tls.process = {}
}

// free_port is a port on 127.0.0.1 nothing listened on a moment ago.
@(private)
free_port :: proc() -> int {
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		return 0
	}
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	return bound.port
}

// run_openssl runs openssl with args in dir and says whether it exited 0, with
// what it wrote to its error stream, in allocator.
@(private)
run_openssl :: proc(
	dir: string,
	args: ..string,
	allocator := context.temp_allocator,
) -> (
	said: string,
	ok: bool,
) {
	context.allocator = allocator
	command := make([dynamic]string)
	append(&command, openssl(allocator))
	append(&command, ..args)
	state, _, stderr, err := os.process_exec({working_dir = dir, command = command[:]}, allocator)
	if err != nil {
		return fmt.aprintf("%v", err), false
	}
	return strings.trim_space(string(stderr)), state.exited && state.exit_code == 0
}
