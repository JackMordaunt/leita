/*
Package webhook tells the person's own server of each alert a scheduled scan
raises, a paid feature that is off until they add one. It is the one place
leita sends anything on its own, and only where it is told to:

	- Only to https, so the alert and the scan summary cross no network in the
	  clear; plain http is taken only to this machine (127.0.0.1, ::1,
	  localhost), for a receiver beside leita. Redirects are not followed.
	- Signed: each POST carries X-Leita-Timestamp, the Unix seconds it was
	  signed at, and X-Leita-Signature, sha256= and the hex HMAC-SHA256 of the
	  timestamp, a full stop and the body, keyed with the webhook's secret, so
	  the server can tell leita sent it and refuse one replayed later.
	- The body is the event (SCHEMA, event.odin) with the scan summary in the
	  report schema (report/SCHEMA.md), its folder paths left out unless the
	  person opted in.
	- Kept until taken: each delivery waits in settings.db and is tried again
	  with backoff (deliver.odin), so a machine offline when an alert fires
	  delivers it on a later run.
*/
package leita_webhook

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:strings"

import "core:crypto"

// SECRET_BYTES is how many random bytes a webhook's secret is made of.
SECRET_BYTES :: 32

// make_secret is a new secret for a webhook, SECRET_BYTES from the system's
// random source as hex, in allocator.
make_secret :: proc(allocator := context.allocator) -> string {
	raw: [SECRET_BYTES]byte
	crypto.rand_bytes(raw[:])
	return string(hex.encode(raw[:], allocator))
}

/*
sign is the signature a POST of body signed at timestamp carries: sha256= and
the hex HMAC-SHA256 of the timestamp in decimal, ".", and the body, keyed with
secret's bytes as written. In the temp allocator.
*/
sign :: proc(secret: string, timestamp: i64, body: string) -> string {
	signed := fmt.tprintf("%d.%s", timestamp, body)
	tag: [32]byte
	hmac.sum(hash.Algorithm.SHA256, tag[:], transmute([]byte)signed, transmute([]byte)secret)
	return strings.concatenate(
		{"sha256=", string(hex.encode(tag[:], context.temp_allocator))},
		context.temp_allocator,
	)
}

// URL_Problem is why a URL is not one a webhook may be sent to.
URL_Problem :: enum u8 {
	None,
	Not_Https, // neither https, nor http to this machine
	No_Host,
}

/*
check_url says whether url is one a webhook may be sent to: https to any host,
or http only to this machine, which is all a receiver beside leita needs.
*/
check_url :: proc(url: string) -> URL_Problem {
	scheme, host, _, _, _ := net.split_url(url, context.temp_allocator)
	name := host
	if strings.has_prefix(name, "[") {
		if end := strings.index_byte(name, ']'); end > 0 {
			name = name[1:end]
		}
	} else if colon := strings.last_index_byte(name, ':'); colon >= 0 {
		name = name[:colon]
	}
	switch {
	case name == "":
		return .No_Host
	case strings.equal_fold(scheme, "https"):
		return .None
	case strings.equal_fold(scheme, "http") &&
	     (name == "127.0.0.1" || name == "::1" || strings.equal_fold(name, "localhost")):
		return .None
	}
	return .Not_Https
}
