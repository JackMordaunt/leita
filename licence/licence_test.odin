package leita_licence

import "core:crypto"
import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// Signer is a key pair made for a test, standing in for Librium's.
Signer :: struct {
	priv: ed25519.Private_Key,
	pub:  [ed25519.PUBLIC_KEY_SIZE]byte,
}

signer :: proc() -> (s: Signer) {
	context.random_generator = crypto.random_generator()
	ok := ed25519.private_key_generate(&s.priv)
	assert(ok)
	ed25519.private_key_public_bytes(&s.priv, s.pub[:])
	return
}

// mint signs terms in the format check reads, in the temp allocator.
mint :: proc(s: ^Signer, terms: string) -> string {
	signed := strings.concatenate(
		{PREFIX, base64.encode(transmute([]byte)terms, allocator = context.temp_allocator)},
		context.temp_allocator,
	)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&s.priv, transmute([]byte)signed, sig[:])
	return strings.concatenate(
		{signed, ".", base64.encode(sig[:], allocator = context.temp_allocator)},
		context.temp_allocator,
	)
}

TERMS :: `{"licensee": "Acme Ltd", "tier": "office", "order": "ord_1", "issued": "2026-10-11"}`

@(test)
a_signed_licence_reads_back_its_terms :: proc(t: ^testing.T) {
	s := signer()
	l, err := check(
		strings.concatenate({"  ", mint(&s, TERMS), "\n"}, context.temp_allocator),
		s.pub[:],
	)
	defer destroy(&l)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, l.licensee, "Acme Ltd")
	testing.expect_value(t, l.tier, Tier.Office)
	testing.expect_value(t, l.order, "ord_1")
	testing.expect_value(t, l.issued, "2026-10-11")
}

@(test)
another_key_does_not_vouch_for_a_licence :: proc(t: ^testing.T) {
	s, other := signer(), signer()
	_, err := check(mint(&s, TERMS), other.pub[:])
	testing.expect_value(t, err, Error.Signature)
}

@(test)
changed_terms_break_the_signature :: proc(t: ^testing.T) {
	s := signer()
	text := mint(&s, TERMS)
	// Swap in other terms, keeping the signature of the first.
	sig := text[strings.last_index_byte(text, '.'):]
	forged := strings.concatenate(
		{
			PREFIX,
			base64.encode(
				transmute([]byte)string(
					`{"licensee": "Acme Ltd", "tier": "multi_site", "order": "ord_1"}`,
				),
				allocator = context.temp_allocator,
			),
			sig,
		},
		context.temp_allocator,
	)
	_, err := check(forged, s.pub[:])
	testing.expect_value(t, err, Error.Signature)
}

@(test)
what_is_not_a_licence_says_so :: proc(t: ^testing.T) {
	s := signer()
	cases := []struct {
		text: string,
		want: Error,
	} {
		{"", .Malformed},
		{"hello", .Malformed},
		{"leita1.", .Malformed},
		{"leita1.abc", .Malformed},
		{"leita1..", .Malformed},
		{"leita1.a.b.c", .Malformed},
		{"leita1.e30=.not-base64!", .Malformed},
		{"leita1.e30=.AAAA", .Malformed},
		{"leita2.e30=.AAAA", .Version},
	}
	for c in cases {
		_, err := check(c.text, s.pub[:])
		testing.expectf(t, err == c.want, "%q: %v, want %v", c.text, err, c.want)
	}
}

@(test)
signed_terms_must_name_a_licensee_tier_and_order :: proc(t: ^testing.T) {
	s := signer()
	for terms in ([]string{`{"tier": "office", "order": "ord_1"}`, `{"licensee": " ", "tier": "office", "order": "ord_1"}`, `{"licensee": "Acme", "tier": "galaxy", "order": "ord_1"}`, `{"licensee": "Acme", "tier": "office"}`, `not json`}) {
		_, err := check(mint(&s, terms), s.pub[:])
		testing.expectf(t, err == .Terms, "%s: %v", terms, err)
	}
}

@(test)
no_key_checks_no_licence :: proc(t: ^testing.T) {
	s := signer()
	_, err := check(mint(&s, TERMS), nil)
	testing.expect_value(t, err, Error.No_Key)
}

@(test)
a_saved_licence_reads_back :: proc(t: ^testing.T) {
	s := signer()
	dir, derr := os.make_directory_temp("", "leita-licence-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	kept, _ := filepath.join({dir, "data", "history.db"}, context.temp_allocator)
	path := path_beside(kept, context.temp_allocator)

	text := mint(&s, TERMS)
	testing.expect_value(t, save(path, text), Error.None)
	got, err := read(path)
	testing.expect_value(t, err, Error.None)
	l, cerr := check(got, s.pub[:])
	defer destroy(&l)
	testing.expect_value(t, cerr, Error.None)
	testing.expect_value(t, l.licensee, "Acme Ltd")

	_, gone := read(path_beside(kept, context.temp_allocator)[:len(path) - 1])
	testing.expect_value(t, gone, Error.Unreadable)
	testing.expect_value(t, path_beside(""), "")
}

@(test)
first_use_is_remembered_from_the_first_time_it_is_asked :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "leita-first-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "data", "first-use"}, context.temp_allocator)

	first := first_use(path)
	testing.expect(t, os.exists(path), "it is written the first time")
	testing.expect_value(t, time.to_unix_seconds(first_use(path)), time.to_unix_seconds(first))

	testing.expect(t, os.write_entire_file(path, "1000\n") == nil)
	testing.expect_value(t, time.to_unix_seconds(first_use(path)), 1000)
	testing.expect(t, time.since(first_use("")) < time.Minute, "nowhere to keep it is now")
}
