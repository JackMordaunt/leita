package leita_app

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"

import "jm:http"
import "jm:stream"

import "../../licence"
import "../../settings"
import "../../version"
import "../command"
import "../msg"
import "../query"

/*
The licence, on the desk. The one in use is kept in a file beside the history
store and read once, at init; a licence the window offers is checked, and only
one that holds replaces it and is kept.

The window offers one of three things: the licence line itself, a file holding
one, or the licence key the shop's receipt gives. A key is the one thing leita
ever sends. It goes to ACTIVATE_URL, and again only when a stored line no
longer verifies. The body this client accepts is the JSON object
licence/FORMAT.md's Activation section names, {"licence":"<line>"}. The line
is then checked here, offline, against the public keys leita was built with.
The request runs on an HTTP client of its own, started on the first key; its
answer comes back to the desk through a port as Activated, so the desk goes
on answering while it waits.

A licence kept that no longer verifies is left on disk. When the receipt key
was kept beside it, leita exchanges that key once. A line that verifies
replaces the stored one. No network, or a 404, leaves this copy Free and says
so, and the previous line stays for a later build.
*/

// ACTIVATE_URL is where a licence key is exchanged for its licence, unless
// LEITA_ACTIVATE_URL names another, as for the shop's sandbox. The variable
// replaces the whole URL, including the path.
ACTIVATE_URL :: "https://mordaunt.dev/leita/activate"

// ACTIVATE_ENV names the variable that replaces ACTIVATE_URL.
ACTIVATE_ENV :: "LEITA_ACTIVATE_URL"

// activate_endpoint is where a key is exchanged: explicit, else ACTIVATE_ENV,
// else ACTIVATE_URL. explicit is what the caller was given, and it wins so a
// test or an embed can point one run at a server without touching the
// environment of the others.
activate_endpoint :: proc(explicit: string) -> string {
	if explicit != "" {
		return explicit
	}
	if env := os.get_env(ACTIVATE_ENV, context.temp_allocator); env != "" {
		return env
	}
	return ACTIVATE_URL
}

// ACTIVATE_TIMEOUT is how long a key's exchange may take before leita gives up.
ACTIVATE_TIMEOUT :: 30 * time.Second

// KEY_MAX is the longest licence key leita sends. Polar's keys are a prefix
// and a UUID, about 40 characters (polar.sh/docs, license keys benefit).
KEY_MAX :: licence.RECEIPT_MAX

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
// against key; key nil means the keys leita was built with. Keys are exchanged
// at activate_url, "" for LEITA_ACTIVATE_URL or else ACTIVATE_URL. A stored
// line that fails its signature, with a receipt key beside it, is marked to be
// exchanged once licence_refresh_pending runs, after the answer port exists.
licence_open :: proc(d: ^Desk, path: string, key: []byte, activate_url: string) {
	d.licence_path = strings.clone(path)
	d.activate_url = strings.clone(activate_endpoint(activate_url))
	d.first_use = licence.first_use(
		licence.path_beside(path, context.temp_allocator, licence.FIRST_USE),
		settings.trial_ledger(d.settings),
		time.now(),
	)
	if key != nil {
		d.licence_key = key
	}
	if path == "" {
		return
	}
	text, err := licence.read(path)
	if err != .None {
		return
	}
	if l, cerr := verify_line(d, text); cerr == .None {
		d.licence = l
		d.licensed = true
		return
	} else if cerr != .Signature {
		return
	}
	receipt, ok := licence.read_receipt(path)
	if !ok {
		return
	}
	d.renew_key = strings.clone(receipt)
}

// licence_refresh_pending exchanges the receipt key licence_open set aside,
// once. The answer port has to exist already: the client's thread sends
// through it.
licence_refresh_pending :: proc(d: ^Desk) {
	key := d.renew_key
	if key == "" {
		return
	}
	d.renew_key = ""
	d.refreshing = true
	activate(d, key)
	delete(key)
	if !d.activating {
		d.refreshing = false
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
	delete(d.licence_renewal)
	delete(d.renew_key)
	delete(d.receipt_pending)
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
			licence_settle(d, licence_problem(d, err))
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

// verify_line checks text against the key the caller passed, or the set this
// build was made with when it passed none.
@(private = "file")
verify_line :: proc(
	d: ^Desk,
	text: string,
	allocator := context.allocator,
) -> (
	licence.Licence,
	licence.Error,
) {
	if d.licence_key != nil {
		return licence.check(text, d.licence_key, allocator)
	}
	return licence.check_built(text, allocator)
}

// take checks text as a licence, and uses and keeps it if it holds. receipt,
// when set, is the licence key that fetched it and is kept beside the line;
// otherwise a receipt left by an older activation is removed, so it cannot
// exchange itself later and replace this line.
@(private = "file")
take :: proc(d: ^Desk, text: string, receipt := "") {
	l, err := verify_line(d, text)
	// Without a data folder to keep it in, it holds for this session only.
	if err == .None && d.licence_path != "" {
		err = licence.save(d.licence_path, text)
		if err == .None {
			if receipt != "" {
				err = licence.save_receipt(d.licence_path, receipt)
			} else {
				err = licence.forget_receipt(d.licence_path)
			}
		}
	}
	if err != .None {
		licence.destroy(&l)
		licence_settle(d, licence_problem(d, err))
		return
	}
	licence.destroy(&d.licence)
	d.licence = l
	d.licensed = true
	delete(d.licence_renewal)
	d.licence_renewal = ""
	licence_settle(d, "")
}

// licence_problem says why a licence was not taken, in the heap.
@(private = "file")
licence_problem :: proc(d: ^Desk, err: licence.Error) -> string {
	return strings.clone(say(d, LICENCE_ERRORS[err], version.PRODUCT))
}

// licence_settle ends an offer, with why it was not taken, "" when it was. problem is
// owned from here.
@(private = "file")
licence_settle :: proc(d: ^Desk, problem: string) {
	delete(d.licence_problem)
	d.licence_problem = problem
	d.licence_offered += 1
}

// activate sends key to be exchanged for its licence. The key is remembered
// until the answer arrives, so a line that verifies is stored beside it.
@(private = "file")
activate :: proc(d: ^Desk, key: string) {
	if key == "" || len(key) > KEY_MAX || strings.index_any(key, " \t\r\n") >= 0 {
		refuse_activation(d, say(d, .Not_A_Key), d.refreshing)
		return
	}
	delete(d.receipt_pending)
	d.receipt_pending = strings.clone(key)
	if d.client == nil {
		client, err := http.start()
		if err != .None {
			// Linux opens libcurl at run time, so a system without it
			// still runs the window; only this request needs it.
			why := msg.Msg.No_Curl if err == .No_Library else msg.Msg.Cannot_Connect
			drop_pending(d)
			refuse_activation(d, say(d, why, version.PRODUCT), d.refreshing)
			return
		}
		d.client = client
	}
	Ask :: struct {
		key: string `json:"key"`,
	}
	body, _ := json.marshal(Ask{key}, allocator = context.temp_allocator)
	headers := [?]string{"Content-Type: application/json", "Accept: application/json"}
	req := http.Request {
		method     = "POST",
		url        = d.activate_url,
		headers    = headers[:],
		body       = string(body),
		timeout    = d.activate_timeout if d.activate_timeout > 0 else ACTIVATE_TIMEOUT,
		max_body   = 64 * 1024,
		user_agent = "leita/" + version.VERSION,
	}
	if _, err := http.submit(d.client, req, activated, d.activations); err != .None {
		drop_pending(d)
		refuse_activation(d, say(d, .Cannot_Connect, version.PRODUCT), d.refreshing)
		return
	}
	d.activating = true
}

// drop_pending forgets the key of an exchange that never left the machine.
@(private = "file")
drop_pending :: proc(d: ^Desk) {
	delete(d.receipt_pending)
	d.receipt_pending = ""
}

// refuse_activation records why an exchange granted nothing. why is not
// owned. A refresh says so on the banner and leaves the stored line alone; an
// offer the window made is the dialog's problem.
@(private = "file")
refuse_activation :: proc(d: ^Desk, why: string, refreshing: bool) {
	if refreshing {
		delete(d.licence_renewal)
		d.licence_renewal = strings.clone(why)
		delete(d.licence_problem)
		d.licence_problem = strings.clone(why)
		return
	}
	licence_settle(d, strings.clone(why))
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
// One answer ends the exchange. A refresh that fails leaves the stored line
// where it is.
take_activation :: proc(d: ^Desk, a: ^Activated) {
	refreshing := d.refreshing
	d.refreshing = false
	d.activating = false
	receipt := d.receipt_pending
	d.receipt_pending = ""
	defer delete(receipt)
	body := strings.trim_space(command.text_of(&a.body))
	switch {
	case a.err == .Timed_Out:
		refuse_activation(d, say(d, .Server_Slow), refreshing)
	case a.err != .None:
		refuse_activation(d, say(d, .Server_Unreachable, version.PRODUCT), refreshing)
	case a.status == 200 && a.whole:
		// licence/FORMAT.md, Activation: a 200 body is {"licence":"<line>"}.
		// The line is then checked offline. Any other body grants nothing.
		Granted :: struct {
			licence: string `json:"licence"`,
		}
		granted: Granted
		jerr := json.unmarshal(transmute([]byte)body, &granted, allocator = context.temp_allocator)
		if jerr != nil || granted.licence == "" {
			refuse_activation(d, say(d, .Server_Busy), refreshing)
			return
		}
		take(d, granted.licence, receipt)
		if refreshing && !d.licensed && d.licence_problem != "" {
			delete(d.licence_renewal)
			d.licence_renewal = strings.clone(d.licence_problem)
		}
	case a.status >= 400 && a.status < 500:
		// licence/FORMAT.md, Activation: a 4xx body may carry an optional message.
		Fault :: struct {
			message: string `json:"message"`,
		}
		fault: Fault
		line := ""
		if json.unmarshal(transmute([]byte)body, &fault, allocator = context.temp_allocator) ==
		   nil {
			line = fault.message
		}
		if i := strings.index_any(line, "\r\n"); i >= 0 {
			line = line[:i]
		}
		if line == "" {
			line = say(d, .Key_Refused)
		}
		refuse_activation(d, line[:min(len(line), MESSAGE_MAX)], refreshing)
	case:
		refuse_activation(d, say(d, .Server_Busy), refreshing)
	}
}

licence_answer :: proc(d: ^Desk) -> query.Licence_Result {
	now := time.now()
	grant := licence.Licence{}
	if d.licensed {
		grant = d.licence
	}
	r := query.Licence_Result {
		licensed   = d.licensed,
		activating = d.activating,
		offered    = d.licence_offered,
		unlocked   = licence.entitled_to_pro(grant, d.first_use, now),
		trial_left = licence.days_left(d.first_use, now),
		problem    = d.licence_problem,
		renewal    = d.licence_renewal,
	}
	if d.licensed {
		r.licensee = d.licence.licensee
		r.tier = say(d, TIER_TITLES[d.licence.tier])
		r.order = d.licence.order
		r.issued = d.licence.issued
		// The paid-through date names which releases this line covers. It
		// is not an expiry of the installed build, and a failed renewal is
		// a different sentence (renewal).
		r.paid_through = d.licence.paid_through
		if at, ok := licence.this_release(); ok {
			r.release_at = at
			r.build_covered = licence.pro_for_this_build(d.licence)
		}
	}
	return r
}
