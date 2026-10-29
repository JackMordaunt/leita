package leita_settings

import "core:strings"

import "jm:sqlite3"
import "../schema"

/*
Webhooks, a paid feature: the person's own servers the monitor tells of each
alert, each with the secret its deliveries are signed with, and whether they
may carry folder paths. Off until one is added. Each delivery waits in a queue
here until the server takes it, so a machine that is offline when an alert
fires delivers it on a later run (package webhook).
*/

// Webhook is one server alerts are sent to, and how the last delivery to it
// went: when one was last taken, 0 for never, and why the last failed, "" when
// it did not.
Webhook :: struct {
	id:           i64,
	url:          string,
	secret:       string, // hex, the HMAC-SHA256 key
	paths:        bool, // deliveries may carry folder paths
	added:        i64, // Unix seconds
	last_sent:    i64,
	last_problem: string,
}

// Delivery is one body waiting for its webhook to take it: the event it tells
// of, when it was made, how many times it was tried, when it is next due, and
// why the last try failed.
Delivery :: struct {
	id:       i64,
	hook:     i64,
	event:    string,
	body:     string,
	created:  i64, // Unix seconds
	attempts: int,
	next_at:  i64, // Unix seconds
	problem:  string,
}

@(private)
WEBHOOK_SCHEMA :: `
	CREATE TABLE IF NOT EXISTS webhook(
		id INTEGER PRIMARY KEY,
		url TEXT NOT NULL UNIQUE,
		secret TEXT NOT NULL,
		paths INTEGER NOT NULL,
		added INTEGER NOT NULL,
		last_sent INTEGER NOT NULL DEFAULT 0,
		last_problem TEXT NOT NULL DEFAULT '');
	CREATE TABLE IF NOT EXISTS delivery(
		id INTEGER PRIMARY KEY,
		hook INTEGER NOT NULL,
		event TEXT NOT NULL,
		body TEXT NOT NULL,
		created INTEGER NOT NULL,
		attempts INTEGER NOT NULL DEFAULT 0,
		next_at INTEGER NOT NULL,
		problem TEXT NOT NULL DEFAULT '');
	CREATE INDEX IF NOT EXISTS delivery_due ON delivery(next_at);`

/*
hook_add keeps a webhook to url, signed with secret, and returns its id. One
already there for url keeps its secret, so the server need not be told a new
one, and takes paths.
*/
hook_add :: proc(
	st: ^Store,
	url, secret: string,
	paths: bool,
	added: i64,
) -> (
	id: i64,
	err: sqlite3.Error,
) {
	if blocked := write_allowed(st); blocked != nil { return {}, blocked }
	sqlite3.exec_args(
		st.db,
		`INSERT INTO webhook(url, secret, paths, added) VALUES (?, ?, ?, ?)
			ON CONFLICT(url) DO UPDATE SET paths = excluded.paths`,
		url,
		secret,
		paths,
		added,
	) or_return
	rows := sqlite3.query(
		st.db,
		"SELECT id FROM webhook WHERE url = ?",
		url,
		allocator = context.temp_allocator,
	) or_return
	if sqlite3.next(&rows) {
		id = sqlite3.integer(rows, 0)
	}
	sqlite3.finish(&rows) or_return
	return
}

// hook_remove forgets the webhook to url and what waits for it, and says
// whether there was one.
hook_remove :: proc(st: ^Store, url: string) -> (found: bool, err: sqlite3.Error) {
	if blocked := write_allowed(st); blocked != nil { return {}, blocked }
	sqlite3.exec_args(
		st.db,
		"DELETE FROM delivery WHERE hook IN (SELECT id FROM webhook WHERE url = ?)",
		url,
	) or_return
	sqlite3.exec_args(st.db, "DELETE FROM webhook WHERE url = ?", url) or_return
	return sqlite3.changes(st.db) > 0, nil
}

// hooks is every webhook, in the order they were added, in allocator.
hooks :: proc(st: ^Store, allocator := context.allocator) -> (out: []Webhook, err: sqlite3.Error) {
	if st.read_only && st.legacy {
		exists := schema.table_exists(st.db, "webhook") or_return
		if !exists { return nil, nil }
	}

	rows := sqlite3.query(
		st.db,
		`SELECT id, url, secret, paths, added, last_sent, last_problem
			FROM webhook ORDER BY added, id`,
		allocator = context.temp_allocator,
	) or_return
	found := make([dynamic]Webhook, allocator)
	for sqlite3.next(&rows) {
		append(
			&found,
			Webhook {
				id = sqlite3.integer(rows, 0),
				url = strings.clone(sqlite3.text(rows, 1), allocator),
				secret = strings.clone(sqlite3.text(rows, 2), allocator),
				paths = sqlite3.boolean(rows, 3),
				added = sqlite3.integer(rows, 4),
				last_sent = sqlite3.integer(rows, 5),
				last_problem = strings.clone(sqlite3.text(rows, 6), allocator),
			},
		)
	}
	if err = sqlite3.finish(&rows); err != nil {
		hooks_destroy(found[:], allocator)
		return nil, err
	}
	return found[:], nil
}

// hooks_destroy frees what hooks returned.
hooks_destroy :: proc(hs: []Webhook, allocator := context.allocator) {
	for h in hs {
		delete(h.url, allocator)
		delete(h.secret, allocator)
		delete(h.last_problem, allocator)
	}
	delete(hs, allocator)
}

// note_delivery keeps how the last delivery to webhook id went: taken at sent,
// or refused for problem, which leaves when one was last taken as it was.
note_delivery :: proc(st: ^Store, id: i64, sent: i64, problem: string) -> sqlite3.Error {
	write_allowed(st) or_return
	if problem == "" {
		return sqlite3.exec_args(
			st.db,
			"UPDATE webhook SET last_sent = ?, last_problem = '' WHERE id = ?",
			sent,
			id,
		)
	}
	return sqlite3.exec_args(
		st.db,
		"UPDATE webhook SET last_problem = ? WHERE id = ?",
		problem,
		id,
	)
}

// enqueue keeps body, telling of event, for webhook hook to take, due now, and
// returns its id.
enqueue :: proc(
	st: ^Store,
	hook: i64,
	event, body: string,
	now: i64,
) -> (
	id: i64,
	err: sqlite3.Error,
) {
	if blocked := write_allowed(st); blocked != nil { return {}, blocked }
	sqlite3.exec_args(
		st.db,
		"INSERT INTO delivery(hook, event, body, created, next_at) VALUES (?, ?, ?, ?, ?)",
		hook,
		event,
		body,
		now,
		now,
	) or_return
	return sqlite3.last_id(st.db), nil
}

// due is every delivery due by now, oldest first, of webhook hook or of every
// webhook for 0, in allocator.
due :: proc(
	st: ^Store,
	now: i64,
	hook: i64 = 0,
	allocator := context.allocator,
) -> (
	out: []Delivery,
	err: sqlite3.Error,
) {
	if st.read_only && st.legacy {
		exists := schema.table_exists(st.db, "delivery") or_return
		if !exists { return nil, nil }
	}

	rows := sqlite3.query(
		st.db,
		`SELECT id, hook, event, body, created, attempts, next_at, problem FROM delivery
			WHERE next_at <= ? AND (? = 0 OR hook = ?) ORDER BY created, id`,
		now,
		hook,
		hook,
		allocator = context.temp_allocator,
	) or_return
	found := make([dynamic]Delivery, allocator)
	for sqlite3.next(&rows) {
		append(
			&found,
			Delivery {
				id = sqlite3.integer(rows, 0),
				hook = sqlite3.integer(rows, 1),
				event = strings.clone(sqlite3.text(rows, 2), allocator),
				body = strings.clone(sqlite3.text(rows, 3), allocator),
				created = sqlite3.integer(rows, 4),
				attempts = int(sqlite3.integer(rows, 5)),
				next_at = sqlite3.integer(rows, 6),
				problem = strings.clone(sqlite3.text(rows, 7), allocator),
			},
		)
	}
	if err = sqlite3.finish(&rows); err != nil {
		deliveries_destroy(found[:], allocator)
		return nil, err
	}
	return found[:], nil
}

// deliveries_destroy frees what due returned.
deliveries_destroy :: proc(ds: []Delivery, allocator := context.allocator) {
	for d in ds {
		delete(d.event, allocator)
		delete(d.body, allocator)
		delete(d.problem, allocator)
	}
	delete(ds, allocator)
}

// forget_delivery forgets delivery id, taken or given up on.
forget_delivery :: proc(st: ^Store, id: i64) -> sqlite3.Error {
	write_allowed(st) or_return
	return sqlite3.exec_args(st.db, "DELETE FROM delivery WHERE id = ?", id)
}

// retry keeps that delivery id was tried attempts times, last failing for
// problem, and is next due at next_at.
retry :: proc(st: ^Store, id: i64, attempts: int, next_at: i64, problem: string) -> sqlite3.Error {
	write_allowed(st) or_return
	return sqlite3.exec_args(
		st.db,
		"UPDATE delivery SET attempts = ?, next_at = ?, problem = ? WHERE id = ?",
		i64(attempts),
		next_at,
		problem,
		id,
	)
}

// waiting is how many deliveries wait for webhook hook.
waiting :: proc(st: ^Store, hook: i64) -> int {
	rows, err := sqlite3.query(
		st.db,
		"SELECT count(*) FROM delivery WHERE hook = ?",
		hook,
		allocator = context.temp_allocator,
	)
	if err != nil {
		return 0
	}
	defer sqlite3.finish(&rows)
	return int(sqlite3.integer(rows, 0)) if sqlite3.next(&rows) else 0
}
