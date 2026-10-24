package leita_licence

import "core:crypto"
import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../faults"

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

TERMS :: #load("testdata/sample.json", string)

@(test)
a_signed_licence_reads_back_its_terms :: proc(t: ^testing.T) {
	s := signer()
	l, err := check(
		strings.concatenate({"  ", mint(&s, TERMS), "\n"}, context.temp_allocator),
		s.pub[:],
	)
	defer destroy(&l)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, l.licensee, "ada@example.com")
	testing.expect_value(t, l.tier, Tier.Professional)
	testing.expect_value(t, l.order, "ord_1")
	testing.expect_value(t, l.issued, "2026-10-19T12:00:00Z")
	testing.expect_value(t, l.format, Format.Annual)
	testing.expect_value(t, l.paid_through, "2027-10-19T00:00:00Z")
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
					`{"v":1,"id":"ord_9","email":"ada@example.com","scope":"professional","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`,
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
		{"leita.", .Malformed},
		{"leita.abc", .Malformed},
		{"leita..", .Malformed},
		{"leita.a.b.c", .Malformed},
		{"leita.e30=.not-base64!", .Malformed},
		{"leita.e30=.AAAA", .Malformed},
		{"leita1.e30=.AAAA", .Version},
		{"leita2.e30=.AAAA", .Version},
		{"leita3.e30=.AAAA", .Version},
	}
	for c in cases {
		_, err := check(c.text, s.pub[:])
		testing.expectf(t, err == c.want, "%q: %v, want %v", c.text, err, c.want)
	}
}

@(test)
signed_terms_must_name_a_licensee_tier_and_order :: proc(t: ^testing.T) {
	s := signer()
	for terms in ([]string{`{"v":1,"email":"ada@example.com","scope":"professional","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`, `{"v":1,"id":"ord_1","email":"not-an-email","scope":"professional","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`, `{"v":1,"id":"ord_1","email":"ada@example.com","scope":"office","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`, `not json`}) {
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
	testing.expect_value(t, l.licensee, "ada@example.com")

	_, gone := read(path_beside(kept, context.temp_allocator)[:len(path) - 1])
	testing.expect_value(t, gone, Error.Unreadable)
	testing.expect_value(t, path_beside(""), "")
}

// SAMPLE is a licence the private half of the key this build was made with
// signed, as just check-licence gives it: -define:LEITA_LICENCE_SAMPLE=<licence>.
SAMPLE :: #config(LEITA_LICENCE_SAMPLE, "")

// A build with a key set takes the licences any key in it signed, as a release
// must; a build without one, as just test makes, has no key to check them with.
// A malformed set is refused whole, the same as none.
@(test)
the_key_built_in_checks_what_it_signed :: proc(t: ^testing.T) {
	keys, ok := parse_key_set(KEY)
	defer if ok {
		delete(keys)
	}
	if !ok {
		_, lone := public_key()
		testing.expect(t, !lone, "a build without a well-formed set has no single key")
		return
	}
	testing.expect(t, SAMPLE != "", "a build with a key is given a licence one of them signed")
	l, err := check_keys(SAMPLE, keys[:], context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, l.licensee != "", "it names whose it is")
	if len(keys) == 1 {
		one, single := public_key()
		testing.expect(t, single)
		testing.expect(t, one == keys[0])
	}
}

// Either key in a set verifies the line it signed. A third key's line does
// not, and a signature that holds with bad terms is not offered to the other key.
@(test)
either_key_of_a_set_verifies_its_line :: proc(t: ^testing.T) {
	a, b, c := signer(), signer(), signer()
	keys := [][ed25519.PUBLIC_KEY_SIZE]byte{a.pub, b.pub}
	l, err := check_keys(mint(&a, TERMS), keys)
	defer destroy(&l)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, l.licensee, "ada@example.com")
	l2, err2 := check_keys(mint(&b, TERMS), keys)
	defer destroy(&l2)
	testing.expect_value(t, err2, Error.None)
	_, err3 := check_keys(mint(&c, TERMS), keys)
	testing.expect_value(t, err3, Error.Signature)
	// The other order still accepts both.
	flipped := [][ed25519.PUBLIC_KEY_SIZE]byte{b.pub, a.pub}
	again, err4 := check_keys(mint(&a, TERMS), flipped)
	defer destroy(&again)
	testing.expect_value(t, err4, Error.None)

	bad := `{"v":1,"id":"ord_1","email":"not-an-email","scope":"professional","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`
	_, err5 := check_keys(mint(&a, bad), keys)
	testing.expect_value(t, err5, Error.Terms)
	_, none := check_keys(mint(&a, TERMS), nil)
	testing.expect_value(t, none, Error.No_Key)
}

// A comma-separated list is the set. A blank, a short token, or a character
// that is not hex refuses the whole list.
@(test)
a_key_set_is_comma_separated_hex :: proc(t: ^testing.T) {
	a, b := signer(), signer()
	ha := string(hex.encode(a.pub[:], context.temp_allocator))
	hb := string(hex.encode(b.pub[:], context.temp_allocator))
	upper := strings.to_upper(ha, context.temp_allocator)
	keys, ok := parse_key_set(fmt.tprintf("%s, %s", ha, hb))
	defer if ok {
		delete(keys)
	}
	testing.expect(t, ok && len(keys) == 2)
	testing.expect(t, keys[0] == a.pub && keys[1] == b.pub)
	held, err := check_keys(mint(&b, TERMS), keys[:])
	defer destroy(&held)
	testing.expect_value(t, err, Error.None)

	one, ook := parse_key_set(upper)
	defer if ook {
		delete(one)
	}
	testing.expect(t, ook && len(one) == 1 && one[0] == a.pub)

	bad := []string {
		"",
		"   ",
		",",
		fmt.tprintf("%s,", ha),
		fmt.tprintf(",%s", ha),
		fmt.tprintf("%s,,%s", ha, hb),
		ha[:len(ha) - 1],
		fmt.tprintf("%saa", ha),
		fmt.tprintf("%s,zzzz", ha),
		fmt.tprintf("%s %s", ha, hb),
	}
	for text in bad {
		_, parsed := parse_key_set(text)
		testing.expectf(t, !parsed, "%q parsed", text)
	}
}

// A replacement that cannot be staged leaves the previous line and receipt
// byte for byte. Once the blockage is gone, the new line replaces the old
// one, keeps its mode, and does not leave the staging file behind.
@(test)
a_failed_replacement_keeps_the_line_and_the_receipt :: proc(t: ^testing.T) {
	s := signer()
	dir, derr := os.make_directory_temp("", "leita-licence-replace-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "licence"}, context.temp_allocator)
	text := mint(&s, TERMS)
	testing.expect_value(t, save(path, text), Error.None)
	before, berr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, berr == nil)
	testing.expect_value(t, save_receipt(path, "LEITA-SOLD"), Error.None)
	receipt := receipt_path(path, context.temp_allocator)
	receipt_before, rerr := os.read_entire_file(receipt, context.temp_allocator)
	testing.expect(t, rerr == nil)

	// A directory where the staging file would be: the write cannot start.
	line_block := fmt.tprintf("%s.new", path)
	receipt_block := fmt.tprintf("%s.new", receipt)
	testing.expect(t, os.make_directory(line_block) == nil)
	testing.expect_value(t, save(path, mint(&s, other_terms(t))), Error.Unwritable)
	after, aerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, aerr == nil)
	testing.expect_value(t, string(after), string(before))
	testing.expect(t, os.is_dir(line_block), "the failed save does not remove the blockage")

	testing.expect(t, os.make_directory(receipt_block) == nil)
	testing.expect_value(t, save_receipt(path, "LEITA-OTHER"), Error.Unwritable)
	receipt_after, raerr := os.read_entire_file(receipt, context.temp_allocator)
	testing.expect(t, raerr == nil)
	testing.expect_value(t, string(receipt_after), string(receipt_before))
	still, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(still), string(before))

	testing.expect(t, os.remove_all(line_block) == nil)
	mode := os.Permissions{.Read_User, .Write_User}
	testing.expect(t, os.chmod(path, mode) == nil)
	next := mint(&s, other_terms(t))
	testing.expect_value(t, save(path, next), Error.None)
	got, gerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, gerr == nil)
	testing.expect_value(t, strings.trim_space(string(got)), next)
	testing.expect(t, !os.exists(line_block), "a published replacement leaves no staging file")
	when ODIN_OS != .Windows {
		info, serr := os.stat(path, context.temp_allocator)
		testing.expect(t, serr == nil)
		if serr == nil {
			defer os.file_info_delete(info, context.temp_allocator)
			testing.expect(t, info.mode == mode, "the replacement keeps the line's mode")
		}
	}

	testing.expect(t, os.remove_all(receipt_block) == nil)
	testing.expect_value(t, save_receipt(path, "LEITA-OTHER"), Error.None)
	key, ok := read_receipt(path)
	testing.expect(t, ok && key == "LEITA-OTHER")
	testing.expect(t, !os.exists(receipt_block))
}

// other_terms is TERMS with another order id, so a second save is a different line.
@(private)
other_terms :: proc(t: ^testing.T) -> string {
	next, _ := strings.replace_all(TERMS, `"id":"ord_1"`, `"id":"ord_2"`, context.temp_allocator)
	testing.expect(t, next != TERMS)
	return next
}

// The receipt key is kept beside the line and takes the line's permissions.
// Forgetting the line removes it. A line installed with keep was not fetched,
// so a receipt left beside an older line goes too.
@(test)
the_receipt_key_keeps_the_lines_permissions :: proc(t: ^testing.T) {
	s := signer()
	dir, derr := os.make_directory_temp("", "leita-licence-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	kept, _ := filepath.join({dir, "data", "history.db"}, context.temp_allocator)
	path := path_beside(kept, context.temp_allocator)
	text := mint(&s, TERMS)
	testing.expect_value(t, save(path, text), Error.None)
	mode := os.Permissions{.Read_User, .Write_User}
	testing.expect(t, os.chmod(path, mode) == nil)
	testing.expect_value(t, save_receipt(path, "LEITA-SOLD"), Error.None)
	got, ok := read_receipt(path)
	testing.expect(t, ok)
	testing.expect_value(t, got, "LEITA-SOLD")
	line, lerr := os.stat(path, context.temp_allocator)
	testing.expect(t, lerr == nil)
	defer os.file_info_delete(line, context.temp_allocator)
	receipt, rerr := os.stat(receipt_path(path, context.temp_allocator), context.temp_allocator)
	testing.expect(t, rerr == nil)
	defer os.file_info_delete(receipt, context.temp_allocator)
	// On Windows a writable file reports Permissions_Read_Write_All, not the
	// Unix bits chmod was given. The receipt must match the line either way.
	when ODIN_OS == .Windows {
		testing.expect(t, line.mode == os.Permissions_Read_Write_All, "the line stays writable")
	} else {
		testing.expect(t, line.mode == mode, "the line is owner read/write")
	}
	testing.expect(t, receipt.mode == line.mode, "the receipt takes the line's mode")

	elsewhere, _ := filepath.join({dir, "elsewhere.db"}, context.temp_allocator)
	_, missing := read_receipt(elsewhere)
	testing.expect(t, !missing, "another folder has no receipt")
	testing.expect_value(t, save_receipt(path, "not a key"), Error.Unwritable)
	testing.expect_value(t, save_receipt(path, ""), Error.Unwritable)

	_, kerr := keep(path, text, s.pub[:], context.temp_allocator)
	testing.expect_value(t, kerr, Error.None)
	_, still := read_receipt(path)
	testing.expect(t, !still, "keep drops a receipt the line was not fetched with")

	testing.expect_value(t, save_receipt(path, "LEITA-SOLD"), Error.None)
	was, ferr := forget(path)
	testing.expect(t, was && ferr == .None)
	testing.expect(t, !os.exists(path))
	_, gone := read_receipt(path)
	testing.expect(t, !gone)
}

// Memo is a ledger kept in memory, standing in for settings.db.
Memo :: struct {
	text:     string,
	found:    bool,
	readonly: bool,
}

memo_ledger :: proc(m: ^Memo) -> Ledger {
	return {user = m, get = proc(user: rawptr) -> (string, bool) {
			m := (^Memo)(user)
			return m.text, m.found
		}, set = proc(user: rawptr, text: string) -> bool {
			m := (^Memo)(user)
			if m.readonly {
				return false
			}
			m.text, m.found = strings.clone(text, context.temp_allocator), true
			return true
		}}
}

// trial_dir is a folder for one test's first-use file, and the file's path.
trial_dir :: proc(t: ^testing.T) -> (dir, path: string) {
	err: os.Error
	dir, err = os.make_directory_temp("", "leita-first-*", context.temp_allocator)
	testing.expect(t, err == nil)
	path, _ = filepath.join({dir, "data", FIRST_USE}, context.temp_allocator)
	return
}

unix :: proc(at: time.Time) -> i64 {
	return time.to_unix_seconds(at)
}

@(test)
first_use_is_remembered_from_the_first_time_it_is_asked :: proc(t: ^testing.T) {
	dir, path := trial_dir(t)
	defer os.remove_all(dir)
	memo: Memo
	now := time.unix(1_800_000_000, 0)

	first := first_use(path, memo_ledger(&memo), now)
	testing.expect_value(t, unix(first), unix(now))
	testing.expect(t, os.exists(path), "the file is written the first time")
	testing.expect_value(t, memo.text, "1800000000")
	later := time.time_add(now, 3 * DAY)
	testing.expect_value(t, unix(first_use(path, memo_ledger(&memo), later)), unix(now))
	testing.expect_value(t, days_left(first, later), TRIAL_DAYS - 3)
	testing.expect(t, unlocked(false, first, later))
	testing.expect(t, !unlocked(false, first, time.time_add(now, TRIAL_DAYS * DAY)))
	testing.expect(t, unlocked(true, first, time.time_add(now, TRIAL_DAYS * DAY)))
}

// Deleting either place does not start the trial again: the other gives it
// back, and the earlier of two starts is the one that counts.
@(test)
a_deleted_stamp_does_not_restart_the_trial :: proc(t: ^testing.T) {
	dir, path := trial_dir(t)
	defer os.remove_all(dir)
	memo: Memo
	now := time.unix(1_800_000_000, 0)
	first := first_use(path, memo_ledger(&memo), now)
	later := time.time_add(now, 40 * DAY)

	testing.expect(t, os.remove(path) == nil)
	testing.expect_value(t, unix(first_use(path, memo_ledger(&memo), later)), unix(first))
	testing.expect(t, !unlocked(false, first_use(path, memo_ledger(&memo), later), later))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(data)), "1800000000")

	memo = {}
	testing.expect_value(t, unix(first_use(path, memo_ledger(&memo), later)), unix(first))
	testing.expect_value(t, memo.text, "1800000000")

	// A later start in one place is put back to the earlier one.
	memo.text = "1900000000"
	testing.expect_value(t, unix(first_use(path, memo_ledger(&memo), later)), unix(first))
	testing.expect_value(t, memo.text, "1800000000")
}

// A stamp that is not a number, or a file that is there but cannot be read,
// ends the trial unless the other place holds a start; then it is mended.
@(test)
a_garbled_stamp_ends_the_trial :: proc(t: ^testing.T) {
	dir, path := trial_dir(t)
	defer os.remove_all(dir)
	now := time.unix(1_800_000_000, 0)
	testing.expect(t, os.make_directory_all(filepath.dir(path)) == nil)

	testing.expect(t, os.write_entire_file(path, "x\n") == nil)
	memo: Memo
	testing.expect_value(t, first_use(path, memo_ledger(&memo), now), TRIAL_OVER)
	testing.expect(t, !unlocked(false, first_use(path, memo_ledger(&memo), now), now))
	testing.expect(t, !memo.found, "nothing is written over it")

	memo = {
		text  = "x",
		found = true,
	}
	testing.expect_value(t, first_use("", memo_ledger(&memo), now), TRIAL_OVER)

	memo = {
		text  = "1799000000",
		found = true,
	}
	testing.expect_value(t, unix(first_use(path, memo_ledger(&memo), now)), 1_799_000_000)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(data)), "1799000000")
	// The mended stamp is inside the 30-day trial, so Pro is open. A stub that
	// always returns false fails here, beside the garbled stamp that locks it.
	testing.expect(t, unlocked(false, time.unix(1_799_000_000, 0), now))

	// A folder where the file should be: there, but not readable as one.
	testing.expect(t, os.remove(path) == nil)
	testing.expect(t, os.make_directory(path) == nil)
	testing.expect_value(t, first_use(path, {}, now), TRIAL_OVER)
}

// A start ahead of the clock, as when the stamp is set in the future or the
// clock is turned back past it, ends the trial; a little ahead, as a clock set
// by the network may be, is now.
@(test)
a_start_ahead_of_the_clock_ends_the_trial :: proc(t: ^testing.T) {
	dir, path := trial_dir(t)
	defer os.remove_all(dir)
	now := time.unix(1_800_000_000, 0)
	testing.expect(t, os.make_directory_all(filepath.dir(path)) == nil)

	ahead := unix(time.time_add(now, 365 * DAY))
	testing.expect(t, os.write_entire_file(path, fmt.tprintf("%d\n", ahead)) == nil)
	testing.expect_value(t, first_use(path, {}, now), TRIAL_OVER)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(data)), fmt.tprintf("%d", ahead))

	// The clock turned back: started at now, asked two days before it.
	testing.expect(t, os.remove(path) == nil)
	memo: Memo
	first := first_use(path, memo_ledger(&memo), now)
	back := time.time_add(now, -2 * DAY)
	testing.expect_value(t, first_use(path, memo_ledger(&memo), back), TRIAL_OVER)
	testing.expect(t, !unlocked(false, first, back), "a window already open locks too")
	testing.expect_value(t, days_left(first, back), 0)

	nudged := time.time_add(now, -time.Hour)
	testing.expect_value(t, unix(first_use(path, memo_ledger(&memo), nudged)), unix(now))
	testing.expect_value(t, days_left(first, nudged), TRIAL_DAYS)
}

// Where neither place can keep the start it would be now on every run, so the
// trial is over; one place that keeps it is enough.
@(test)
nowhere_to_keep_the_start_ends_the_trial :: proc(t: ^testing.T) {
	dir, _ := trial_dir(t)
	defer os.remove_all(dir)
	now := time.unix(1_800_000_000, 0)
	// A file where the data folder should be: nothing can be written under it.
	blocked, _ := filepath.join({dir, "blocked"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(blocked, "") == nil)
	path, _ := filepath.join({blocked, FIRST_USE}, context.temp_allocator)

	testing.expect_value(t, first_use("", {}, now), TRIAL_OVER)
	testing.expect_value(t, first_use(path, {}, now), TRIAL_OVER)
	memo := Memo {
		readonly = true,
	}
	testing.expect_value(t, first_use(path, memo_ledger(&memo), now), TRIAL_OVER)

	memo = {}
	testing.expect_value(t, unix(first_use(path, memo_ledger(&memo), now)), unix(now))
	testing.expect_value(t, memo.text, "1800000000")
	testing.expect_value(t, unix(first_use("", memo_ledger(&memo), now)), unix(now))
}

// A licence kept is the one in use, until what LEITA_LICENCE holds takes its
// place for a run; forgotten, there is none.
@(test)
the_licence_in_use_is_the_one_given_or_else_the_one_kept :: proc(t: ^testing.T) {
	s := signer()
	dir, derr := os.make_directory_temp("", "leita-licence-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	kept, _ := filepath.join({dir, "data", "history.db"}, context.temp_allocator)
	path := path_beside(kept, context.temp_allocator)

	_, from, err := in_use(path, "", s.pub[:])
	testing.expect_value(t, from, Source.None)
	testing.expect_value(t, err, Error.None)

	_, kerr := keep(path, "leita.e30=.AAAA", s.pub[:], context.temp_allocator)
	testing.expect_value(t, kerr, Error.Malformed)
	testing.expect(t, !os.exists(path), "what does not check is not kept")
	_, kerr = keep(path, mint(&s, TERMS), s.pub[:], context.temp_allocator)
	testing.expect_value(t, kerr, Error.None)

	l: Licence
	l, from, err = in_use(path, "", s.pub[:])
	testing.expect_value(t, from, Source.Kept)
	testing.expect_value(t, l.licensee, "ada@example.com")

	given := mint(
		&s,
		`{"v":1,"id":"ord_2","email":"ops@example.com","scope":"organisation","features":"pro","paidThrough":"2028-01-01T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`,
	)
	l, from, err = in_use(path, given, s.pub[:])
	testing.expect_value(t, from, Source.Env)
	testing.expect_value(t, l.licensee, "ops@example.com")
	_, from, err = in_use(path, "not a licence", s.pub[:])
	testing.expect_value(t, from, Source.Env)
	testing.expect_value(t, err, Error.Malformed)

	// A key of the wrong size is not a key, on a build that has one and one that
	// does not. nil would mean the keys this binary was built with.
	short := [3]byte{1, 2, 3}
	_, _, err = in_use(path, "", short[:])
	testing.expect_value(t, err, Error.No_Key)

	was, ferr := forget(path)
	testing.expect(t, was && ferr == .None)
	_, from, _ = in_use(path, "", s.pub[:])
	testing.expect_value(t, from, Source.None)
	was, _ = forget(path)
	testing.expect(t, !was, "nothing to forget")
}

THROW_PUB  :: #load("testdata/throwaway/ed25519.public.hex", string)
VECTOR_1   :: #load("testdata/throwaway/vector-1.line", string)
VECTOR_2   :: #load("testdata/throwaway/vector-2.line", string)
FORMAT_DOC :: #load("FORMAT.md", string)

throwaway_key :: proc(t: ^testing.T) -> [ed25519.PUBLIC_KEY_SIZE]byte {
	raw, ok := hex.decode(transmute([]byte)strings.trim_space(THROW_PUB), context.temp_allocator)
	testing.expect(t, ok && len(raw) == ed25519.PUBLIC_KEY_SIZE)
	key: [ed25519.PUBLIC_KEY_SIZE]byte
	copy(key[:], raw)
	return key
}

// The lines FORMAT.md publishes verify under the throwaway key, and the
// document carries the same bytes the files do.
@(test)
the_published_vectors_verify :: proc(t: ^testing.T) {
	key := throwaway_key(t)
	testing.expect(t, strings.contains(FORMAT_DOC, strings.trim_space(VECTOR_1)))
	testing.expect(t, strings.contains(FORMAT_DOC, strings.trim_space(VECTOR_2)))

	l, err := check("\n" + VECTOR_1, key[:])
	defer destroy(&l)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, l.format, Format.Annual)
	testing.expect_value(t, l.licensee, "ada@example.com")
	testing.expect_value(t, l.tier, Tier.Personal)
	testing.expect_value(t, l.order, "lic_7f3a9c2e1b")
	testing.expect_value(t, l.features, FEATURES_PRO)
	testing.expect_value(t, l.issued, "2026-10-19T12:00:00Z")
	testing.expect_value(t, l.paid_through, "2027-10-19T00:00:00Z")

	l2, err2 := check(VECTOR_2, key[:])
	defer destroy(&l2)
	testing.expect_value(t, err2, Error.None)
	testing.expect_value(t, l2.tier, Tier.Organisation)
	testing.expect_value(t, l2.licensee, "ops@northwind.example")
	testing.expect_value(t, l2.order, "lic_org_4401")
}

// A release at paidThrough is Pro; one second later is Free. No stamp is not Pro.
@(test)
pro_stops_at_the_paid_through_instant :: proc(t: ^testing.T) {
	key := throwaway_key(t)
	l, err := check(VECTOR_1, key[:])
	defer destroy(&l)
	testing.expect_value(t, err, Error.None)
	at := "2027-10-19T00:00:00Z"
	later := "2027-10-19T00:00:01Z"
	testing.expect(t, pro_entitled(l, at))
	testing.expect(t, !pro_entitled(l, later))
	testing.expect(t, !pro_entitled(l, ""))
	// This binary is a development build: no compiled stamp, so the line is not Pro.
	testing.expect(t, !pro_for_this_build(l))
	testing.expect(t, !pro_entitled({}, later))
}

@(test)
a_tampered_or_noncanonical_line_is_not_pro :: proc(t: ^testing.T) {
	key := throwaway_key(t)
	line := strings.trim_space(VECTOR_1)
	// Flip one character of the signature, clear of the padding.
	cut := strings.last_index_byte(line, '.')
	flipped := strings.concatenate({line[:cut + 1], "W", line[cut + 2:]}, context.temp_allocator)
	_, err := check(flipped, key[:])
	testing.expect_value(t, err, Error.Signature)

	s := signer()
	spaced := `{"v":1, "id":"lic_x","email":"ada@example.com","scope":"personal","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`
	_, err = check(mint(&s, spaced), s.pub[:])
	testing.expect_value(t, err, Error.Terms)

	bad_day := `{"v":1,"id":"lic_x","email":"ada@example.com","scope":"professional","features":"pro","paidThrough":"2027-02-29T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`
	_, err = check(mint(&s, bad_day), s.pub[:])
	testing.expect_value(t, err, Error.Terms)

	office := `{"v":1,"id":"lic_x","email":"ada@example.com","scope":"office","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`
	_, err = check(mint(&s, office), s.pub[:])
	testing.expect_value(t, err, Error.Terms)

	pro, perr := check(
		mint(
			&s,
			`{"v":1,"id":"lic_pro","email":"ada@example.com","scope":"professional","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`,
		),
		s.pub[:],
	)
	defer destroy(&pro)
	testing.expect_value(t, perr, Error.None)
	testing.expect_value(t, pro.tier, Tier.Professional)

	other := `{"v":1,"id":"lic_x","email":"ada@example.com","scope":"personal","features":"plus","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`
	_, err = check(mint(&s, other), s.pub[:])
	testing.expect_value(t, err, Error.Terms)

	// A payload whose version is not 1 is signed and still not terms.
	_, err = check(
		mint(
			&s,
			`{"v":2,"id":"lic_x","email":"ada@example.com","scope":"personal","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}`,
		),
		s.pub[:],
	)
	testing.expect_value(t, err, Error.Terms)
}

// A signed draft line, prefix leita1., is not this format and grants nothing.
@(test)
a_leita1_prefix_grants_nothing :: proc(t: ^testing.T) {
	s := signer()
	body := `{"licensee":"Ada","tier":"supporter","order":"ord_9","issued":"2026-10-11"}`
	signed := strings.concatenate(
		{"leita1.", base64.encode(transmute([]byte)body, allocator = context.temp_allocator)},
		context.temp_allocator,
	)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&s.priv, transmute([]byte)signed, sig[:])
	line := strings.concatenate(
		{signed, ".", base64.encode(sig[:], allocator = context.temp_allocator)},
		context.temp_allocator,
	)
	l, err := check(line, s.pub[:])
	testing.expect_value(t, err, Error.Version)
	testing.expect_value(t, l.format, Format.None)
	testing.expect(t, !pro_entitled(l, "2026-10-20T00:00:00Z"))
	testing.expect(t, !pro_for_this_build(l))
}

// The profile runs to year 9999, past the end of time.Time. A release this
// program can name is still at or before that cutoff.
@(test)
a_paid_through_past_2262_still_covers_an_earlier_release :: proc(t: ^testing.T) {
	s := signer()
	body := `{"v":1,"id":"lic_far","email":"ada@example.com","scope":"personal","features":"pro","paidThrough":"9999-12-31T23:59:59Z","issued":"2020-02-29T00:00:00Z"}`
	l, err := check(mint(&s, body), s.pub[:])
	defer destroy(&l)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, pro_entitled(l, "2262-04-11T23:47:16Z"))
	testing.expect(t, pro_entitled(l, "9999-12-31T23:59:59Z"))
	testing.expect(t, !pro_entitled(l, ""))
}

@(test)
the_instant_is_a_real_utc_day :: proc(t: ^testing.T) {
	testing.expect(t, instant_ok("2020-02-29T00:00:00Z"))
	testing.expect(t, instant_ok("9999-12-31T23:59:59Z"))
	testing.expect(t, !instant_ok("2019-01-01T00:00:00Z"))
	testing.expect(t, !instant_ok("2027-02-29T00:00:00Z"))
	testing.expect(t, !instant_ok("2100-02-29T00:00:00Z"))
	testing.expect(t, !instant_ok("2027-13-01T00:00:00Z"))
	testing.expect(t, !instant_ok("2027-10-19T24:00:00Z"))
	testing.expect(t, !instant_ok("2027-10-19T23:60:00Z"))
	testing.expect(t, !instant_ok("2027-10-19T23:59:60Z"))
	testing.expect(t, !instant_ok("2027-10-19t00:00:00Z"))
	testing.expect(t, !instant_ok("2027-10-19T00:00:00z"))
	testing.expect(t, !instant_ok("2027-10-19T00:00:00+00:00"))
}

// The mode a kept licence file has is the mode a replacement takes, and a name with
// no file says there is none: asked without statx, so on Linux 4.9 as on 7.x.
@(test)
a_kept_file_gives_its_mode_and_a_missing_one_gives_none :: proc(t: ^testing.T) {
	base, base_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, base_err == nil, "no temp directory")
	dir := fmt.tprintf("%s/leita_licence_mode_%d", base, os.get_pid())
	os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil, "could not make the directory")
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/licence", dir)
	testing.expect(t, os.write_entire_file(path, []byte{'x'}, {.Read_User, .Write_User}) == nil, "could not write")

	mode, found := prior_mode(path)
	testing.expect(t, found, "a kept file had no mode")
	// os.stat on Windows gives read and write to owner, group and other alike (it has no
	// POSIX modes), so there is no owner-only mode to compare.
	when ODIN_OS != .Windows {
		testing.expect_value(t, mode & os.Permissions_All, os.Permissions{.Read_User, .Write_User})
	} else {
		testing.expect(t, .Read_User in mode, "a kept file was not readable")
	}
	_, absent := prior_mode(fmt.tprintf("%s/absent", dir))
	testing.expect(t, !absent, "a missing file had a mode")
}

// Each way the disk can refuse a step of a save: the line kept before is what the
// file holds after, byte for byte, the save says it failed, and no staging file is
// left once the step after it could clean up.
@(test)
a_disk_fault_in_a_save_keeps_the_line_before :: proc(t: ^testing.T) {
	s := signer()
	dir, derr := os.make_directory_temp("", "leita-licence-faults-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	path, _ := filepath.join({dir, "licence"}, context.temp_allocator)
	stage := fmt.tprintf("%s.new", path)
	testing.expect_value(t, save(path, mint(&s, TERMS)), Error.None)
	before, _ := os.read_entire_file(path, context.temp_allocator)
	next := mint(&s, other_terms(t))
	defer faults.disarm()

	for op in ([]faults.Op{.Open, .Write, .Sync, .Rename}) {
		for fault in faults.Fault {
			if fault == .None || fault == .Kill || (fault == .Short && op != .Write) {
				continue
			}
			faults.arm({op = op, fault = fault, nth = 1})
			testing.expectf(
				t,
				save(path, next) == .Unwritable,
				"%v on %v: the save said it held",
				fault,
				op,
			)
			testing.expectf(t, faults.hits() == 1, "%v on %v was never met", fault, op)
			after, _ := os.read_entire_file(path, context.temp_allocator)
			testing.expectf(
				t,
				string(after) == string(before),
				"%v on %v changed the line kept",
				fault,
				op,
			)
			testing.expectf(t, !os.exists(stage), "%v on %v left %s", fault, op, stage)
		}
	}

	// The staging file cannot be removed after the rename failed: it is left, and
	// the next save writes over it rather than failing on it.
	faults.arm({op = .Rename, fault = .IO, nth = 1}, {op = .Remove, fault = .IO, nth = 1})
	testing.expect_value(t, save(path, next), Error.Unwritable)
	testing.expect(t, os.exists(stage), "the stage was removed")
	faults.disarm()
	testing.expect_value(t, save(path, next), Error.None)
	got, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(got)), next)
	testing.expect(t, !os.exists(stage), "the stage outlived a save that held")
}

// A licence that cannot be forgotten is still the one in use, and says so.
@(test)
a_disk_fault_in_forget_keeps_the_line :: proc(t: ^testing.T) {
	s := signer()
	dir, derr := os.make_directory_temp("", "leita-licence-faults-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	path, _ := filepath.join({dir, "licence"}, context.temp_allocator)
	text := mint(&s, TERMS)
	testing.expect_value(t, save(path, text), Error.None)
	defer faults.disarm()

	for fault in ([]faults.Fault{.No_Space, .IO, .Read_Only, .Denied}) {
		faults.arm({op = .Remove, fault = fault, nth = 1})
		was, err := forget(path)
		testing.expect(t, was)
		testing.expect_value(t, err, Error.Unwritable)
		l, from, lerr := in_use(path, "", s.pub[:])
		testing.expect_value(t, from, Source.Kept)
		testing.expect_value(t, lerr, Error.None)
		testing.expect(t, l.order != "", "the line kept no longer reads")
	}
}
