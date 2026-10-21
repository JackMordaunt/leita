/*
Package licence reads the Key the licence speaks of: a licence Librium signs
and the buyer pastes into leita, or opens as a file. leita checks it here,
offline, against the public key it was built with, and never asks anyone else:
nothing about the buyer or the machine leaves it.

A line is leita., the payload in standard base64, and the Ed25519 signature
of everything before the second dot, as licence/FORMAT.md in this directory
specifies. This package only checks lines. A build trusts one public key or
several, and a line holds when any of them verifies it. A line grants Pro on
a release whose authenticated instant is at or before paidThrough, and a
later release runs Free. A draft prefix, leita1. or leita2., is not a line
this build reads.

The one in use is kept as a file of its own in leita's data folder, beside
the history store.
*/
package leita_licence

import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import "../version"

// PREFIX begins a licence line. The dot is part of the prefix: the signed
// bytes start with it.
PREFIX :: "leita."

// FEATURES_PRO is the only feature set a line may name. Scope does not change it.
FEATURES_PRO :: "pro"

// KEY is the public keys licences are checked against, in hex, set with
// -define:LEITA_LICENCE_KEY=<hex>[,<hex>...]. Each key is 64 hex characters.
// Commas separate a set, and spaces around a comma are ignored. A build
// without a well-formed set takes no licence, so the justfile's release
// recipes refuse to build without one.
KEY :: #config(LEITA_LICENCE_KEY, "")

// RECEIPT is the file beside the licence line that holds the licence key from
// the receipt, so a line that no longer verifies can be exchanged once.
RECEIPT :: "licence-key"

// RECEIPT_MAX is the longest licence key the receipt file may hold. It is the
// same bound the activation request uses.
RECEIPT_MAX :: 128

// Tier is the permitted use a licence was bought for. All three grant the same
// Pro feature set.
Tier :: enum u8 {
	Personal, // one person, noncommercial use
	Professional, // one commercial operator
	Organisation, // one organisation, internal use
}

// Format is which line a checked licence came from. None is the zero value,
// and it entitles nothing. Annual is the one format: a paid-through cutoff.
Format :: enum u8 {
	None,
	Annual,
}

// Licence is a licence's terms, once its signature is checked. Its strings are
// owned; destroy frees them.
Licence :: struct {
	licensee:     string, // the licensee's email
	tier:         Tier,
	order:        string, // the licence id
	issued:       string, // the canonical instant the line was signed
	format:       Format,
	features:     string, // the feature set id; owned, always FEATURES_PRO when checked
	paid_through: string, // the canonical paid-through instant
}

Error :: enum u8 {
	None,
	No_Key, // this build was made without a key to check licences with
	Malformed, // not a licence: not three parts, or not base64
	Version, // a licence, but of a format this leita does not read
	Signature, // not signed by Librium, or changed since
	Terms, // signed, but its terms do not say what this leita needs
	Unreadable, // the file could not be read
	Unwritable, // the file could not be written
}

// parse_key_set reads text as comma-separated Ed25519 public keys, 64 hex
// characters each, either case. Spaces around a comma are ignored. Empty
// text, a blank entry, or a token that is not one key refuses the whole set,
// so a typo cannot drop a key and keep the rest. The result is in allocator.
@(private)
parse_key_set :: proc(
	text: string,
	allocator := context.temp_allocator,
) -> (
	keys: [dynamic][ed25519.PUBLIC_KEY_SIZE]byte,
	ok: bool,
) {
	trimmed := strings.trim_space(text)
	if trimmed == "" {
		return
	}
	keys = make([dynamic][ed25519.PUBLIC_KEY_SIZE]byte, allocator)
	rest := trimmed
	for {
		head, match, tail := strings.partition(rest, ",")
		token := strings.trim_space(head)
		if len(token) != ed25519.PUBLIC_KEY_SIZE * 2 || !hex_ok(token) {
			delete(keys)
			return {}, false
		}
		raw, decoded := hex.decode(transmute([]byte)token, allocator)
		if !decoded || len(raw) != ed25519.PUBLIC_KEY_SIZE {
			delete(keys)
			return {}, false
		}
		item: [ed25519.PUBLIC_KEY_SIZE]byte
		copy(item[:], raw)
		append(&keys, item)
		if match == "" {
			break
		}
		rest = tail
	}
	if len(keys) == 0 {
		delete(keys)
		return {}, false
	}
	return keys, true
}

// hex_ok reports whether s is only hex digits.
@(private)
hex_ok :: proc(s: string) -> bool {
	for c in s {
		switch c {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case:
			return false
		}
	}
	return true
}

// public_key is the one public key KEY names, when the build trusts exactly
// one. Several keys, or a missing or malformed set, is not one key.
public_key :: proc() -> (key: [ed25519.PUBLIC_KEY_SIZE]byte, ok: bool) {
	keys, parsed := parse_key_set(KEY)
	defer delete(keys)
	if !parsed || len(keys) != 1 {
		return
	}
	return keys[0], true
}

// check_built checks pasted against every public key the build trusts. An
// empty or malformed set is .No_Key, and the line is not read.
check_built :: proc(pasted: string, allocator := context.allocator) -> (Licence, Error) {
	keys, ok := parse_key_set(KEY)
	if !ok {
		return {}, .No_Key
	}
	defer delete(keys)
	return check_keys(pasted, keys[:], allocator)
}

/*
check reads pasted as a licence and checks it was signed with key, returning
its terms. pasted may carry whitespace around it, as a paste or a file does. Only a
licence whose signature holds is read past its prefix.
*/
check :: proc(
	pasted: string,
	key: []byte,
	allocator := context.allocator,
) -> (
	l: Licence,
	err: Error,
) {
	if len(key) != ed25519.PUBLIC_KEY_SIZE {
		return {}, .No_Key
	}
	one: [1][ed25519.PUBLIC_KEY_SIZE]byte
	copy(one[0][:], key)
	return check_keys(pasted, one[:], allocator)
}

/*
check_keys reads pasted as a licence and checks it against keys, in order.
The first signature that holds decides the terms; a later key is not tried
after that. No usable key is .No_Key. A signature none of them verifies is
.Signature, and the payload is not read.
*/
check_keys :: proc(
	pasted: string,
	keys: [][ed25519.PUBLIC_KEY_SIZE]byte,
	allocator := context.allocator,
) -> (
	l: Licence,
	err: Error,
) {
	if len(keys) == 0 {
		return {}, .No_Key
	}
	text := strings.trim_space(pasted)
	if strings.has_prefix(text, PREFIX) {
		return check_annual(text, keys, allocator)
	}
	// leita1., leita2., and a later leitaN. are formats this build does not read.
	if strings.has_prefix(text, "leita") && strings.index_byte(text, '.') > 0 {
		return {}, .Version
	}
	return {}, .Malformed
}

// check_annual reads a leita. line. The signature is checked before the
// payload is read, and the payload must be the canonical encoding
// licence/FORMAT.md's "Canonical payload" section names: a signature over any
// other bytes does not make them terms.
@(private)
check_annual :: proc(
	text: string,
	keys: [][ed25519.PUBLIC_KEY_SIZE]byte,
	allocator := context.allocator,
) -> (
	l: Licence,
	err: Error,
) {
	signed, payload_b64, sig_b64, split := signed_parts(text, PREFIX)
	if split != .None {
		return {}, split
	}
	if !b64_std_ok(payload_b64) || !b64_std_ok(sig_b64) {
		return {}, .Malformed
	}
	sig, serr := base64.decode(sig_b64, allocator = context.temp_allocator)
	if serr != nil || len(sig) != ed25519.SIGNATURE_SIZE {
		return {}, .Malformed
	}
	usable, held := false, false
	for &key in keys {
		pub: ed25519.Public_Key
		if !ed25519.public_key_set_bytes(&pub, key[:]) {
			continue
		}
		usable = true
		if ed25519.verify(&pub, transmute([]byte)signed, sig) {
			held = true
			break
		}
	}
	if !usable {
		return {}, .No_Key
	}
	if !held {
		return {}, .Signature
	}
	raw, terr := base64.decode(payload_b64, allocator = context.temp_allocator)
	if terr != nil || len(raw) == 0 {
		return {}, .Terms
	}
	id, email, scope, features, paid, issued, ok := annual_fields(string(raw))
	tier, known := scope_of(scope)
	if !ok ||
	   !known ||
	   features != FEATURES_PRO ||
	   !instant_ok(paid) ||
	   !instant_ok(issued) ||
	   !id_ok(id) ||
	   !email_ok(email) {
		return {}, .Terms
	}
	return {
			licensee = strings.clone(email, allocator),
			tier = tier,
			order = strings.clone(id, allocator),
			issued = strings.clone(issued, allocator),
			format = .Annual,
			features = strings.clone(FEATURES_PRO, allocator),
			paid_through = strings.clone(paid, allocator),
		},
		.None
}

// signed_parts splits text, which starts with prefix, into the signed message
// and the two base64 sections. The signed message is everything before the
// second dot.
@(private)
signed_parts :: proc(text, prefix: string) -> (signed, payload_b64, sig_b64: string, err: Error) {
	rest := text[len(prefix):]
	dot := strings.index_byte(rest, '.')
	if dot <= 0 || strings.index_byte(rest[dot + 1:], '.') >= 0 {
		return {}, {}, {}, .Malformed
	}
	return text[:len(prefix) + dot], rest[:dot], rest[dot + 1:], .None
}

// b64_std_ok reports whether s is standard base64 with padding, and no other alphabet.
@(private)
b64_std_ok :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) % 4 != 0 {
		return false
	}
	for c, i in s {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/':
		case '=':
			if i < len(s) - 2 {
				return false
			}
		case:
			return false
		}
	}
	return true
}

// annual_fields reads a canonical payload. ok is false unless every byte was
// the fixed skeleton with a string in each place.
@(private)
annual_fields :: proc(
	body: string,
) -> (
	id, email, scope, features, paid, issued: string,
	ok: bool,
) {
	i: int
	i, ok = take_literal(body, 0, `{"v":1,"id":`)
	if !ok {
		return
	}
	id, i, ok = take_token(body, i)
	if !ok {
		return
	}
	i, ok = take_literal(body, i, `,"email":`)
	if !ok {
		return
	}
	email, i, ok = take_token(body, i)
	if !ok {
		return
	}
	i, ok = take_literal(body, i, `,"scope":`)
	if !ok {
		return
	}
	scope, i, ok = take_token(body, i)
	if !ok {
		return
	}
	i, ok = take_literal(body, i, `,"features":`)
	if !ok {
		return
	}
	features, i, ok = take_token(body, i)
	if !ok {
		return
	}
	i, ok = take_literal(body, i, `,"paidThrough":`)
	if !ok {
		return
	}
	paid, i, ok = take_token(body, i)
	if !ok {
		return
	}
	i, ok = take_literal(body, i, `,"issued":`)
	if !ok {
		return
	}
	issued, i, ok = take_token(body, i)
	if !ok {
		return
	}
	i, ok = take_literal(body, i, `}`)
	if !ok || i != len(body) {
		ok = false
	}
	return
}

@(private)
take_literal :: proc(s: string, i: int, lit: string) -> (n: int, ok: bool) {
	end := i + len(lit)
	if end > len(s) || s[i:end] != lit {
		return i, false
	}
	return end, true
}

// take_token reads a JSON string that contains no escape. The canonical
// payload never needs one.
@(private)
take_token :: proc(s: string, i: int) -> (val: string, n: int, ok: bool) {
	if i >= len(s) || s[i] != '"' {
		return
	}
	j := i + 1
	for j < len(s) {
		c := s[j]
		if c == '\\' || c < 0x20 {
			return
		}
		if c == '"' {
			return s[i + 1:j], j + 1, true
		}
		j += 1
	}
	return
}

@(private)
id_ok :: proc(s: string) -> bool {
	if len(s) < 1 || len(s) > 64 {
		return false
	}
	for c in s {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_', '-':
		case:
			return false
		}
	}
	return true
}

@(private)
email_ok :: proc(s: string) -> bool {
	if len(s) < 3 || len(s) > 254 {
		return false
	}
	at := -1
	for ch, i in s {
		if ch < 0x21 || ch > 0x7E || ch == '"' || ch == '\\' {
			return false
		}
		if ch == '@' {
			if at >= 0 {
				return false
			}
			at = i
		}
	}
	return at > 0 && at < len(s) - 1
}

// scope_of is the permitted use a line names.
@(private)
scope_of :: proc(name: string) -> (Tier, bool) {
	switch name {
	case "personal":
		return .Personal, true
	case "professional":
		return .Professional, true
	case "organisation":
		return .Organisation, true
	}
	return {}, false
}

/*
instant_ok reports whether s is the canonical UTC instant, YYYY-MM-DDTHH:MM:SSZ.
No fraction, no offset, no leap second. Year is 2020 through 9999, and the
day has to be a real one, 29 February only in a leap year. The text is the
value. It is fixed width, so it sorts in time order, which a time.Time
cannot: core:time.Time is i64 nanoseconds from 1970, so it ends in 2262, and this profile runs to 9999.
*/
instant_ok :: proc(s: string) -> bool {
	if len(s) != 20 ||
	   s[4] != '-' ||
	   s[7] != '-' ||
	   s[10] != 'T' ||
	   s[13] != ':' ||
	   s[16] != ':' ||
	   s[19] != 'Z' {
		return false
	}
	for i in 0 ..< 20 {
		switch i {
		case 4, 7, 10, 13, 16, 19:
		case:
			if s[i] < '0' || s[i] > '9' {
				return false
			}
		}
	}
	year := instant_n(s, 0) * 100 + instant_n(s, 2)
	month := instant_n(s, 5)
	day := instant_n(s, 8)
	hour := instant_n(s, 11)
	minute := instant_n(s, 14)
	second := instant_n(s, 17)
	if year < 2020 || year > 9999 || hour > 23 || minute > 59 || second > 59 {
		return false
	}
	return day_ok(year, month, day)
}

@(private)
instant_n :: proc(s: string, i: int) -> int {
	return int(s[i] - '0') * 10 + int(s[i + 1] - '0')
}

@(private)
day_ok :: proc(year, month, day: int) -> bool {
	if month < 1 || month > 12 || day < 1 {
		return false
	}
	days := [12]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
		return day <= 29
	}
	return day <= days[month - 1]
}

// this_release is the authenticated instant compiled into this build, when
// version.RELEASED is the canonical form. A development build has none.
this_release :: proc() -> (at: string, ok: bool) {
	if !instant_ok(version.RELEASED) {
		return "", false
	}
	return version.RELEASED, true
}

/*
pro_entitled reports whether l gives Pro to the release stamped at release_at.
release_at is a canonical instant, or "" when the build has no authenticated
stamp. A line does when its feature set is pro and release_at is at or before
paid_through, including equal. A line does not entitle a build with no stamp.
*/
pro_entitled :: proc(l: Licence, release_at: string) -> bool {
	switch l.format {
	case .None:
		return false
	case .Annual:
		if l.features != FEATURES_PRO || !instant_ok(l.paid_through) || !instant_ok(release_at) {
			return false
		}
		return release_at <= l.paid_through
	}
	return false
}

/*
pro_for_this_build reports whether l gives Pro to the release compiled into
this binary. Feature gates ask this. unlocked, below, is the older question
and does not apply the cutoff.
*/
pro_for_this_build :: proc(l: Licence) -> bool {
	at, _ := this_release()
	return pro_entitled(l, at)
}

destroy :: proc(l: ^Licence, allocator := context.allocator) {
	delete(l.licensee, allocator)
	delete(l.order, allocator)
	delete(l.issued, allocator)
	delete(l.features, allocator)
	delete(l.paid_through, allocator)
	l^ = {}
}

// path_beside is where the licence in use is kept: a file named name in the
// folder that holds the history store at kept. "" when kept is.
path_beside :: proc(kept: string, allocator := context.allocator, name := "licence") -> string {
	if kept == "" {
		return ""
	}
	path, _ := filepath.join({filepath.dir(kept), name}, allocator)
	return path
}

// TRIAL_DAYS is how long the paid features, reports and change tracking, work
// without a licence from the day leita first ran. It matches the evaluation
// LICENSE.md §4 gives an organisation: to run the Software "for up to 30 days"
// before it must buy a Commercial Licence.
TRIAL_DAYS :: 30

// DAY is a day of the trial.
DAY :: 24 * time.Hour

/*
CLOCK_SLACK is how far ahead of the clock a trial's start may be and still
count as now, so that a clock corrected back by minutes or hours after the
first run does not end the trial. A start further ahead than this means the
clock was turned back past it, and the trial is over.
*/
CLOCK_SLACK :: DAY

// FIRST_USE is the file beside the history store that holds when the trial
// began (first_use).
FIRST_USE :: "first-use"

// TRIAL_OVER is the start first_use gives when it has no honest one: so long
// ago that the trial is over.
TRIAL_OVER :: time.Time{}

// unlocked is whether the paid features work at now under the rule the existing
// call sites ask: a line that verified, or the trial that began at first. It
// does not apply the paid-through cutoff; pro_for_this_build does.
unlocked :: proc(licensed: bool, first, now: time.Time) -> bool {
	return licensed || days_left(first, now) > 0
}

// days_left is how many days of the trial that began at first are left at now,
// counting the day under way; 0 once it is over, or when the clock was turned
// back past its start.
days_left :: proc(first, now: time.Time) -> int {
	gone := time.diff(first, now)
	if gone < -CLOCK_SLACK || gone >= TRIAL_DAYS * DAY {
		return 0
	}
	return TRIAL_DAYS - int(max(gone, 0) / DAY)
}

/*
Ledger is the second place the trial's start is kept, beside the first-use
file: settings.db, which the caller holds, since this package keeps to files of
its own (settings.trial_ledger). get is the text kept there and whether there is
any; set keeps text there and says whether it did. The zero Ledger keeps
nothing.
*/
Ledger :: struct {
	user: rawptr,
	get:  proc(user: rawptr) -> (text: string, found: bool),
	set:  proc(user: rawptr, text: string) -> bool,
}

// Holding is what one place holds of the trial's start.
@(private)
Holding :: enum u8 {
	Nothing, // no file, no setting: never written, or deleted
	Garbled, // there, but unreadable or not a number
	Stamp, // a start, in unix seconds
}

@(private)
Stamp :: struct {
	held: Holding,
	secs: i64,
}

/*
first_use is when the trial of the paid features began on this machine, as the
file at path and ledger remember it, at now. The first time it is asked it
writes now to both. Either may lose it, so the earlier of the two is the start,
and a place that lost it, or holds a later one, is given it again: deleting the
file, or settings.db, does not start the trial again while the other holds it.

Every other doubt ends the trial, and first_use returns TRIAL_OVER: a start that
is not a number, a file that is there but cannot be read, a start further ahead
of now than CLOCK_SLACK, and a machine where neither place can be written, which
would be told now again on every run. This fails closed on purpose. What it
guards is the paid features, reports and change tracking; scanning and Reclaim
never ask. Failing open would let a deleted file, a stamp set years ahead or a
read-only folder keep the trial for ever.
*/
first_use :: proc(path: string, ledger: Ledger, now: time.Time) -> time.Time {
	file, kept := stamp_of_file(path), stamp_of_ledger(ledger)
	secs, found := earliest(file, kept)
	if !found {
		if file.held == .Garbled || kept.held == .Garbled {
			return TRIAL_OVER
		}
		secs = time.to_unix_seconds(now)
	}
	start := time.unix(secs, 0)
	if time.diff(start, now) < -CLOCK_SLACK {
		return TRIAL_OVER
	}
	text := fmt.tprintf("%d\n", secs)
	wrote := false
	if file != (Stamp{.Stamp, secs}) {
		wrote = write_stamp(path, text) || wrote
	}
	if kept != (Stamp{.Stamp, secs}) && ledger.set != nil {
		wrote = ledger.set(ledger.user, strings.trim_space(text)) || wrote
	}
	if !found && !wrote {
		return TRIAL_OVER
	}
	return start
}

// earliest is the earlier start of a and b, and whether either holds one.
@(private)
earliest :: proc(a, b: Stamp) -> (secs: i64, found: bool) {
	for s in ([2]Stamp{a, b}) {
		if s.held == .Stamp && (!found || s.secs < secs) {
			secs, found = s.secs, true
		}
	}
	return
}

// stamp_of_file is what the file at path holds of the trial's start.
@(private)
stamp_of_file :: proc(path: string) -> Stamp {
	if path == "" || !os.exists(path) {
		return {}
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {held = .Garbled}
	}
	return stamp_of(string(data))
}

// stamp_of_ledger is what ledger holds of the trial's start.
@(private)
stamp_of_ledger :: proc(ledger: Ledger) -> Stamp {
	if ledger.get == nil {
		return {}
	}
	text, found := ledger.get(ledger.user)
	if !found {
		return {}
	}
	return stamp_of(text)
}

// stamp_of reads text as a start in unix seconds.
@(private)
stamp_of :: proc(text: string) -> Stamp {
	secs, ok := strconv.parse_i64(strings.trim_space(text))
	if !ok {
		return {held = .Garbled}
	}
	return {.Stamp, secs}
}

// write_stamp writes text to the file at path, making its folder if need be,
// and says whether it did.
@(private)
write_stamp :: proc(path, text: string) -> bool {
	if path == "" {
		return false
	}
	if dir := filepath.dir(path); !os.exists(dir) {
		os.make_directory_all(dir)
	}
	return os.write_entire_file(path, text) == nil
}

// read is the text of the file at path, in the temp allocator.
read :: proc(path: string) -> (string, Error) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "", .Unreadable
	}
	return string(data), .None
}

// save keeps text, a licence already checked, at path as the one in use,
// making its folder if need be, and replacing any licence kept before.
// The bytes already at path stay there when the replacement cannot be
// written or renamed into place: the destination is not truncated first.
save :: proc(path, text: string, allocator := context.temp_allocator) -> Error {
	if path == "" {
		return .Unwritable
	}
	if dir := filepath.dir(path); !os.exists(dir) {
		if os.make_directory_all(dir) != nil {
			return .Unwritable
		}
	}
	line := strings.concatenate({strings.trim_space(text), "\n"}, allocator)
	mode, use := prior_mode(path, allocator)
	if !replace_file(path, transmute([]byte)line, mode, use, allocator) {
		return .Unwritable
	}
	return .None
}

// prior_mode is the permission of the file at path, when there is one.
@(private)
prior_mode :: proc(
	path: string,
	allocator := context.temp_allocator,
) -> (
	mode: os.Permissions,
	ok: bool,
) {
	info, err := os.stat(path, allocator)
	if err != nil {
		return
	}
	defer os.file_info_delete(info, allocator)
	return info.mode, true
}

// replace_file publishes data as path by writing a sibling and renaming it
// over path. A failure, including a failure of that rename, leaves whatever
// path already held. The sibling is path with ".new" appended, and it is
// removed when the rename does not happen. mode, when ok, is applied to the
// sibling before the rename, so the published file has it and a failure of
// the chmod does not discard the previous file.
@(private)
replace_file :: proc(
	path: string,
	data: []byte,
	mode: os.Permissions,
	ok: bool,
	allocator := context.temp_allocator,
) -> bool {
	stage, serr := strings.concatenate({path, ".new"}, allocator)
	if serr != nil {
		return false
	}
	f, err := os.open(
		stage,
		os.O_WRONLY | os.O_CREATE | os.O_TRUNC,
		os.Permissions_Read_All + {.Write_User},
	)
	if err != nil {
		return false
	}
	wrote := 0
	for wrote < len(data) {
		n, werr := os.write(f, data[wrote:])
		if werr != nil || n < 1 {
			os.close(f)
			os.remove(stage)
			return false
		}
		wrote += n
	}
	if os.sync(f) != nil {
		os.close(f)
		os.remove(stage)
		return false
	}
	if os.close(f) != nil {
		os.remove(stage)
		return false
	}
	if ok && os.chmod(stage, mode) != nil {
		os.remove(stage)
		return false
	}
	if os.rename(stage, path) != nil {
		os.remove(stage)
		return false
	}
	return true
}

// keep checks text against key, nil for the keys leita was built with, and, if it
// holds, keeps it at path as the licence in use, as the window does, returning
// its terms in allocator. The receipt key is removed: this line was not fetched
// by exchanging one.
keep :: proc(
	path, text: string,
	key: []byte = nil,
	allocator := context.allocator,
) -> (
	Licence,
	Error,
) {
	l: Licence
	err: Error
	if key != nil {
		l, err = check(text, key, allocator)
	} else {
		l, err = check_built(text, allocator)
	}
	if err == .None {
		err = save(path, text)
	}
	// A line installed here was not fetched with a receipt key. A key left
	// beside an older line would exchange itself later and replace this one.
	if err == .None {
		err = forget_receipt(path)
	}
	if err != .None {
		destroy(&l, allocator)
		return {}, err
	}
	return l, .None
}

// forget removes the licence kept at path, saying whether there was one.
forget :: proc(path: string) -> (was: bool, err: Error) {
	if path == "" {
		return false, .None
	}
	was = os.exists(path)
	if was && os.remove(path) != nil {
		return true, .Unwritable
	}
	if forget_receipt(path) != .None {
		return was, .Unwritable
	}
	return was, .None
}

// ENV holds a licence for one run, in place of the one kept: for a server, a
// container or a CI job, where nothing is kept between runs.
ENV :: "LEITA_LICENCE"

// Source is where the licence in use came from.
Source :: enum u8 {
	None, // no licence is kept, and ENV holds none
	Env, // ENV, for this run
	Kept, // the file beside the history store
}

/*
in_use is the licence leita runs under: given, what ENV holds, for this run, or
else the one kept at path, checked against key, nil for the keys leita was built
with. err says why the one from names did not check; .None when it did, or when
there is none. In the temp allocator.
*/
in_use :: proc(path, given: string, key: []byte = nil) -> (l: Licence, from: Source, err: Error) {
	text := strings.trim_space(given)
	if text != "" {
		from = .Env
	} else if path != "" && os.exists(path) {
		from = .Kept
		text = read(path) or_return
	} else {
		return
	}
	if key != nil {
		l, err = check(text, key, context.temp_allocator)
	} else {
		l, err = check_built(text, context.temp_allocator)
	}
	return
}

// receipt_path is the licence key kept beside the line at licence_path.
receipt_path :: proc(licence_path: string, allocator := context.allocator) -> string {
	if licence_path == "" {
		return ""
	}
	path, _ := filepath.join({filepath.dir(licence_path), RECEIPT}, allocator)
	return path
}

// receipt_ok reports whether key can be sent as a licence key: 1 to
// RECEIPT_MAX bytes and no ASCII whitespace.
@(private)
receipt_ok :: proc(key: string) -> bool {
	if key == "" || len(key) > RECEIPT_MAX {
		return false
	}
	return strings.index_any(key, " \t\r\n") < 0
}

// read_receipt is the licence key kept beside the line at licence_path, in
// the temp allocator. ok is false when there is none or it is not a key.
read_receipt :: proc(licence_path: string) -> (key: string, ok: bool) {
	path := receipt_path(licence_path, context.temp_allocator)
	if path == "" || !os.exists(path) {
		return "", false
	}
	text, err := read(path)
	if err != .None {
		return "", false
	}
	key = strings.trim_space(text)
	if !receipt_ok(key) {
		return "", false
	}
	return key, true
}

// save_receipt keeps key beside the line at licence_path, with the mode
// os.stat reports for that line, not a fixed Unix mode. The line must already
// be there, so its mode is known.
save_receipt :: proc(licence_path, key: string, allocator := context.temp_allocator) -> Error {
	text := strings.trim_space(key)
	if licence_path == "" || !receipt_ok(text) || !os.exists(licence_path) {
		return .Unwritable
	}
	path := receipt_path(licence_path, allocator)
	if path == "" {
		return .Unwritable
	}
	if dir := filepath.dir(path); !os.exists(dir) {
		if os.make_directory_all(dir) != nil {
			return .Unwritable
		}
	}
	line := strings.concatenate({text, "\n"}, allocator)
	info, serr := os.stat(licence_path, allocator)
	if serr != nil {
		return .Unwritable
	}
	defer os.file_info_delete(info, allocator)
	// The receipt takes the line's mode. A failed write or rename leaves a
	// receipt already beside the line where it was.
	if !replace_file(path, transmute([]byte)line, info.mode, true, allocator) {
		return .Unwritable
	}
	return .None
}

// forget_receipt removes the licence key kept beside the line at licence_path.
forget_receipt :: proc(licence_path: string) -> Error {
	path := receipt_path(licence_path, context.temp_allocator)
	if path == "" || !os.exists(path) {
		return .None
	}
	if os.remove(path) != nil {
		return .Unwritable
	}
	return .None
}

// describe says why a licence was not taken, as the command line says it.
describe :: proc(err: Error) -> string {
	switch err {
	case .None:
		return "the licence holds"
	case .No_Key:
		return "this build of leita takes no licences"
	case .Malformed:
		return(
			"it is not a leita licence; give the whole line, from leita. to its end, or the file holding it" \
		)
	case .Version:
		return "it is a licence for a newer leita; update leita to use it"
	case .Signature:
		return "it is not a licence Librium signed, or it has been changed"
	case .Terms:
		return "it does not say who it is for or what it covers"
	case .Unreadable:
		return "the licence file could not be read"
	case .Unwritable:
		return "the licence could not be kept"
	}
	return ""
}
