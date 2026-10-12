package leita_webhook

import "core:fmt"
import "core:time"

import "jm:http"

import "../settings"
import "../version"

/*
Delivering what waits in the queue (settings.due): each due delivery is signed
afresh and posted to its webhook. A 2xx takes it. A server that is down or
busy, or no answer at all, leaves it for later, each try waiting twice as long
as the last, from RETRY_FIRST to RETRY_MOST, and the monitor tries what is due
on each run; one still not taken after GIVE_UP is dropped. Any other answer is
the server refusing it, which trying again will not change, so it is dropped
at once. Each webhook keeps how its last delivery went, for the window to say.
*/

// TIMEOUT is how long one POST may take.
TIMEOUT :: 15 * time.Second

// RETRY_FIRST and RETRY_MOST are the shortest and longest waits, in seconds,
// before a delivery is tried again; GIVE_UP how old one is dropped at.
RETRY_FIRST :: 5 * 60
RETRY_MOST  :: 24 * 60 * 60
GIVE_UP     :: 7 * 24 * 60 * 60

// Poster posts body to url with headers, and says what status the server
// answered, or why there was no answer.
Poster :: #type proc(
	url: string,
	headers: []string,
	body: string,
	user: rawptr,
) -> (
	status: int,
	problem: string,
)

// post posts for real, through jm:http, following no redirect.
post :: proc(
	url: string,
	headers: []string,
	body: string,
	_: rawptr,
) -> (
	status: int,
	problem: string,
) {
	res, err := http.request(
		"POST",
		url,
		{
			headers = headers,
			body = body,
			timeout = TIMEOUT,
			no_follow = true,
			user_agent = "leita/" + version.VERSION,
		},
		context.temp_allocator,
	)
	#partial switch err {
	case .None:
		return res.status, ""
	case .Timed_Out:
		return 0, "no answer in time"
	}
	return 0, "could not reach the server"
}

// Fate is what became of one try.
Fate :: enum u8 {
	Taken,
	Later, // down, busy or unreachable: try again
	Refused, // the server will not take it: trying again will not change that
}

// fate_of is what a server's status means for a delivery.
fate_of :: proc(status: int) -> Fate {
	switch status {
	case 200 ..= 299:
		return .Taken
	case 0, 408, 425, 429, 500 ..= 599:
		return .Later
	}
	return .Refused
}

/*
attempt posts d to url, signed with secret at now, and says what became of it
and, unless it was taken, why, in the temp allocator.
*/
attempt :: proc(
	url, secret: string,
	d: settings.Delivery,
	now: i64,
	poster: Poster,
	user: rawptr,
) -> (
	fate: Fate,
	problem: string,
) {
	headers := []string {
		"Content-Type: application/json",
		fmt.tprintf("X-Leita-Event: %s", d.event),
		fmt.tprintf("X-Leita-Delivery: %d", d.id),
		fmt.tprintf("X-Leita-Timestamp: %d", now),
		fmt.tprintf("X-Leita-Signature: %s", sign(secret, now, d.body)),
	}
	status, why := poster(url, headers, d.body, user)
	fate = fate_of(status)
	switch {
	case fate == .Taken:
		return
	case status == 0:
		problem = why
	case status >= 300 && status < 400:
		problem = fmt.tprintf(
			"HTTP %d: the server sent it elsewhere; give the URL it ends at",
			status,
		)
	case:
		problem = fmt.tprintf("HTTP %d", status)
	}
	return
}

// backoff is how long, in seconds, a delivery tried attempts times waits
// before its next try.
backoff :: proc(attempts: int) -> i64 {
	wait := i64(RETRY_FIRST)
	for _ in 1 ..< attempts {
		wait *= 2
		if wait >= RETRY_MOST {
			return RETRY_MOST
		}
	}
	return wait
}

// Tally is what one round of delivering came to.
Tally :: struct {
	taken, later, dropped: int,
}

/*
deliver tries each delivery due at now, of webhook hook or of every webhook for
0, through poster, and keeps what became of each. A store that cannot be read
or written is said in problem, and stops the round.
*/
deliver :: proc(
	st: ^settings.Store,
	now: i64,
	poster: Poster,
	user: rawptr = nil,
	hook: i64 = 0,
) -> (
	tally: Tally,
	problem: string,
) {
	hooks, herr := settings.hooks(st, context.temp_allocator)
	if herr != nil {
		return tally, "cannot read the webhooks"
	}
	queue, qerr := settings.due(st, now, hook, context.temp_allocator)
	if qerr != nil {
		return tally, "cannot read the deliveries waiting"
	}
	for d in queue {
		h, found := hook_of(hooks, d.hook)
		if !found || check_url(h.url) != .None {
			settings.forget_delivery(st, d.id)
			tally.dropped += 1
			continue
		}
		fate, why := attempt(h.url, h.secret, d, now, poster, user)
		switch {
		case fate == .Taken:
			settings.forget_delivery(st, d.id)
			settings.note_delivery(st, h.id, now, "")
			tally.taken += 1
		case fate == .Refused || now - d.created >= GIVE_UP:
			settings.forget_delivery(st, d.id)
			settings.note_delivery(st, h.id, now, why)
			tally.dropped += 1
		case:
			attempts := d.attempts + 1
			if err := settings.retry(st, d.id, attempts, now + backoff(attempts), why);
			   err != nil {
				return tally, "cannot keep a delivery to try again"
			}
			settings.note_delivery(st, h.id, now, why)
			tally.later += 1
		}
	}
	return
}

// hook_of is the webhook of hooks with id, and whether there is one.
@(private)
hook_of :: proc(hooks: []settings.Webhook, id: i64) -> (settings.Webhook, bool) {
	for h in hooks {
		if h.id == id {
			return h, true
		}
	}
	return {}, false
}

// tell queues e for every webhook, each its own body, folder paths in it only
// for one that may carry them, and says why not when it could not.
tell :: proc(
	st: ^settings.Store,
	e: Event,
	with_paths, without_paths: string,
	now: i64,
) -> string {
	hooks, err := settings.hooks(st, context.temp_allocator)
	if err != nil {
		return "cannot read the webhooks"
	}
	for h in hooks {
		e := e
		e.summary = with_paths if h.paths else without_paths
		if _, qerr := settings.enqueue(st, h.id, e.event, body(e), now); qerr != nil {
			return "cannot queue a delivery"
		}
	}
	return ""
}

// TEST_TEXT is what a test delivery says, for the person reading it on the
// other end.
TEST_TEXT :: "A test from leita: this webhook is set up, and alerts will arrive here."

// queue_test queues a test delivery for webhook hook, and says why not when it
// could not.
queue_test :: proc(st: ^settings.Store, hook: i64, now: i64) -> string {
	e := Event {
		event  = TEST,
		raised = time.unix(now, 0),
		host   = host_name(),
		text   = TEST_TEXT,
	}
	if _, err := settings.enqueue(st, hook, TEST, body(e), now); err != nil {
		return "cannot queue a delivery"
	}
	return ""
}
