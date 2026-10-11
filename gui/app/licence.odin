package leita_app

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"

import "jm:http"
import "jm:stream"

import "../../licence"
import "../../version"
import "../command"
import "../query"

/*
The licence, on the desk. The one in use is kept in a file beside the history
store and read once, at init; a licence the window offers is checked, and only
one that holds replaces it and is kept.

The window offers one of three things: the licence line itself, a file holding
one, or the licence key the shop's receipt gives. A key is the one thing leita
ever sends: it goes once, to ACTIVATE_URL, which answers with the licence line
that key bought, and from then on the licence is checked here, offline, against
the public key leita was built with. The request runs on an HTTP client of its
own, started on the first key; its answer comes back to the desk through a port
as Activated, so the desk goes on answering while it waits.

A licence kept that no longer checks, as after a build with another key, is
left on disk but not used, so a later build can still read it.
*/

// ACTIVATE_URL is where a licence key is exchanged for its licence, unless
// LEITA_ACTIVATE_URL names another, as for the shop's sandbox.
ACTIVATE_URL :: "https://mordaunt.dev/leita/activate"

// ACTIVATE_TIMEOUT is how long a key's exchange may take before leita gives up.
ACTIVATE_TIMEOUT :: 30 * time.Second

// KEY_MAX is the longest licence key leita sends. Polar's keys are a prefix
// and a UUID, about 40 characters (polar.sh/docs, license keys benefit).
KEY_MAX :: 128

// MESSAGE_MAX is the most of a refusal's text the window is shown.
MESSAGE_MAX :: 200

// Activated is how a key's exchange ended, as the client's thread hands it to
// the desk: by value, since the client frees its response once it has.
Activated :: struct {
	err:    http.Error,
	status: int,
	body:   command.Text, // the licence, or why not; cut short past MAX_PATH
	whole:  bool, // body was not cut short
}

// licence_open reads the licence kept at path, if there is one that checks
// against key; key nil means the one leita was built with. Keys are exchanged
// at activate_url, "" for LEITA_ACTIVATE_URL or else ACTIVATE_URL.
licence_open :: proc(d: ^Desk, path: string, key: []byte, activate_url: string) {
	d.licence_path = strings.clone(path)
	url := activate_url
	if url == "" {
		url = os.get_env("LEITA_ACTIVATE_URL", context.temp_allocator)
	}
	d.activate_url = strings.clone(url if url != "" else ACTIVATE_URL)
	if key != nil {
		d.licence_key = key
	} else if built, ok := licence.public_key(); ok {
		copy(d.licence_built[:], built[:])
		d.licence_key = d.licence_built[:]
	}
	if path == "" {
		return
	}
	text, err := licence.read(path)
	if err != .None {
		return
	}
	if l, cerr := licence.check(text, d.licence_key); cerr == .None {
		d.licence = l
		d.licensed = true
	}
}

// licence_stop stops the client, so no answer comes after: while the port it
// answers through is still there.
licence_stop :: proc(d: ^Desk) {
	if d.client != nil {
		http.shutdown(d.client)
		d.client = nil
	}
}

licence_close :: proc(d: ^Desk) {
	licence.destroy(&d.licence)
	delete(d.licence_path)
	delete(d.activate_url)
	delete(d.licence_problem)
}

// add_licence takes the licence c offers, or sends the key it offers to be
// exchanged for one.
add_licence :: proc(d: ^Desk, c: ^command.Add_Licence) {
	if d.activating {
		return
	}
	text := command.text_of(&c.text)
	if c.file {
		read, err := licence.read(text)
		if err != .None {
			licence_settle(d, strings.concatenate({"The licence ", licence.describe(err), "."}))
			return
		}
		take(d, read)
		return
	}
	text = strings.trim_space(text)
	if strings.has_prefix(text, "leita") && strings.contains_rune(text, '.') {
		take(d, text)
		return
	}
	activate(d, text)
}

// take checks text as a licence, and uses and keeps it if it holds.
@(private = "file")
take :: proc(d: ^Desk, text: string) {
	l, err := licence.check(text, d.licence_key)
	// Without a data folder to keep it in, it holds for this session only.
	if err == .None && d.licence_path != "" {
		err = licence.save(d.licence_path, text)
	}
	if err != .None {
		licence.destroy(&l)
		licence_settle(d, strings.concatenate({"The licence ", licence.describe(err), "."}))
		return
	}
	licence.destroy(&d.licence)
	d.licence = l
	d.licensed = true
	licence_settle(d, "")
}

// licence_settle ends an offer, with why it was not taken, "" when it was. problem is
// owned from here.
@(private = "file")
licence_settle :: proc(d: ^Desk, problem: string) {
	delete(d.licence_problem)
	d.licence_problem = problem
	d.licence_offered += 1
}

// activate sends key to be exchanged for its licence.
@(private = "file")
activate :: proc(d: ^Desk, key: string) {
	if key == "" || len(key) > KEY_MAX || strings.index_any(key, " \t\r\n") >= 0 {
		licence_settle(
			d,
			strings.clone(
				"That is not a licence key: paste the key from your receipt, or a licence beginning leita1.",
			),
		)
		return
	}
	if d.client == nil {
		client, err := http.start()
		if err != .None {
			licence_settle(
				d,
				strings.clone("leita could not start a connection to fetch the licence."),
			)
			return
		}
		d.client = client
	}
	Ask :: struct {
		key: string `json:"key"`,
	}
	body, _ := json.marshal(Ask{key}, allocator = context.temp_allocator)
	headers := [?]string{"Content-Type: application/json", "Accept: text/plain"}
	req := http.Request {
		method     = "POST",
		url        = d.activate_url,
		headers    = headers[:],
		body       = string(body),
		timeout    = ACTIVATE_TIMEOUT,
		max_body   = 64 * 1024,
		user_agent = "leita/" + version.VERSION,
	}
	if _, err := http.submit(d.client, req, activated, d.activations); err != .None {
		licence_settle(
			d,
			strings.clone("leita could not start a connection to fetch the licence."),
		)
		return
	}
	d.activating = true
}

// activated runs on the client's thread: it copies the result out and hands
// it to the desk.
@(private = "file")
activated :: proc(r: http.Result, user: rawptr) {
	port := (^stream.Port(Activated))(user)
	a := Activated {
		err    = r.err,
		status = r.response.status,
		body   = command.text_make(r.response.body),
		whole  = len(r.response.body) <= command.MAX_PATH,
	}
	stream.port_send(port^, a)
}

// take_activation is the desk's half: the licence the key bought, or why not.
take_activation :: proc(d: ^Desk, a: ^Activated) {
	d.activating = false
	body := strings.trim_space(command.text_of(&a.body))
	switch {
	case a.err == .Timed_Out:
		licence_settle(d, strings.clone("The licence server did not answer in time; try again."))
	case a.err != .None:
		licence_settle(
			d,
			strings.clone(
				"leita could not reach the licence server. Check the connection, or open the licence file from your receipt instead.",
			),
		)
	case a.status >= 200 && a.status < 300 && a.whole:
		take(d, body)
	case a.status >= 400 && a.status < 500:
		// The server says why: a key it does not know, or one refunded.
		line := body
		if i := strings.index_any(line, "\r\n"); i >= 0 {
			line = line[:i]
		}
		if line == "" {
			line = "The licence key was not accepted."
		}
		licence_settle(d, strings.clone(line[:min(len(line), MESSAGE_MAX)]))
	case:
		licence_settle(
			d,
			strings.clone("The licence server could not answer just now; try again later."),
		)
	}
}

licence_answer :: proc(d: ^Desk) -> query.Licence_Result {
	r := query.Licence_Result {
		licensed   = d.licensed,
		activating = d.activating,
		offered    = d.licence_offered,
		problem    = d.licence_problem,
	}
	if d.licensed {
		r.licensee = d.licence.licensee
		r.tier = licence.TIER_TITLES[d.licence.tier]
		r.order = d.licence.order
		r.issued = d.licence.issued
	}
	return r
}
