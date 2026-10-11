/*
Package licence reads the Key the licence speaks of: a licence Librium signs
and the buyer pastes into leita, or opens as a file. leita checks it here,
offline, against the public key it was built with, and never asks anyone else:
nothing about the buyer or the machine leaves it.

A licence is one line of text:

	leita1.<payload>.<signature>

payload is the licence's terms as JSON in standard base64, and signature the
Ed25519 signature, in standard base64, of everything before the second dot. The
server that sells leita mints them; this package only checks them.

	{"licensee": "Acme Ltd", "tier": "office", "order": "…", "issued": "2026-10-11"}

A licence does not expire. The one in use is kept as a file of its own in
leita's data folder, beside the history store.
*/
package leita_licence

import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

// PREFIX begins every licence of this format, and names the format's version.
PREFIX :: "leita1."

// KEY is the public key licences are checked against, in hex, set with
// -define:LEITA_LICENCE_KEY=<hex>. A build without one takes no licence.
KEY :: #config(LEITA_LICENCE_KEY, "")

// Tier is what a licence was bought for, as the price list sells them.
Tier :: enum u8 {
	Supporter, // an individual's, for the paid features at home
	Office, // an organisation of up to 10 people, one site
	Team, // up to 50 people, one site
	Site, // anyone at one site
	Multi_Site, // anyone at any of its sites
}

// TIER_NAMES are the tiers as a licence's payload names them.
TIER_NAMES := [Tier]string {
	.Supporter  = "supporter",
	.Office     = "office",
	.Team       = "team",
	.Site       = "site",
	.Multi_Site = "multi_site",
}

// TIER_TITLES are the tiers as the window shows them.
TIER_TITLES := [Tier]string {
	.Supporter  = "Supporter",
	.Office     = "Office, up to 10 people",
	.Team       = "Team, up to 50 people",
	.Site       = "Site",
	.Multi_Site = "Multi-site",
}

// Licence is a licence's terms, once its signature is checked. Its strings are
// owned; destroy frees them.
Licence :: struct {
	licensee: string, // who it was sold to, person or organisation
	tier:     Tier,
	order:    string, // the order it was sold in, as the seller numbers them
	issued:   string, // the day it was signed, YYYY-MM-DD
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

// describe says what went wrong, for a sentence that begins "The licence …".
describe :: proc(err: Error) -> string {
	switch err {
	case .None:
		return "is valid"
	case .No_Key:
		return "cannot be checked: this build of leita takes no licences"
	case .Malformed:
		return "is not a leita licence; paste the whole line, from leita1. to its end"
	case .Version:
		return "is for a newer leita; update leita to use it"
	case .Signature:
		return "is not one Librium signed, or has been changed"
	case .Terms:
		return "does not say who it is for or what it covers"
	case .Unreadable:
		return "file could not be read"
	case .Unwritable:
		return "could not be saved"
	}
	return "is not valid"
}

// public_key is KEY, decoded; false when the build has none or it is not a key.
public_key :: proc() -> (key: [ed25519.PUBLIC_KEY_SIZE]byte, ok: bool) {
	b := hex.decode(transmute([]byte)string(KEY), context.temp_allocator) or_return
	if len(b) != len(key) {
		return
	}
	copy(key[:], b)
	return key, true
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
	pub: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pub, key) {
		return {}, .No_Key
	}
	text := strings.trim_space(pasted)
	if !strings.has_prefix(text, PREFIX) {
		// leita2. and on are a later format; anything else is not a licence.
		if strings.has_prefix(text, "leita") && strings.index_byte(text, '.') > 0 {
			return {}, .Version
		}
		return {}, .Malformed
	}
	cut := strings.last_index_byte(text, '.')
	if cut <= len(PREFIX) {
		return {}, .Malformed
	}
	signed, encoded_sig := text[:cut], text[cut + 1:]
	encoded_terms := signed[len(PREFIX):]
	if strings.index_byte(encoded_terms, '.') >= 0 {
		return {}, .Malformed
	}
	sig, serr := base64.decode(encoded_sig, allocator = context.temp_allocator)
	if serr != nil || len(sig) != ed25519.SIGNATURE_SIZE {
		return {}, .Malformed
	}
	if !ed25519.verify(&pub, transmute([]byte)signed, sig) {
		return {}, .Signature
	}
	raw, terr := base64.decode(encoded_terms, allocator = context.temp_allocator)
	if terr != nil {
		return {}, .Malformed
	}

	Terms :: struct {
		licensee, tier, order, issued: string,
	}
	terms: Terms
	if json.unmarshal(raw, &terms, allocator = context.temp_allocator) != nil {
		return {}, .Terms
	}
	tier, known := tier_of(terms.tier)
	if !known || strings.trim_space(terms.licensee) == "" || terms.order == "" {
		return {}, .Terms
	}
	return {
			licensee = strings.clone(strings.trim_space(terms.licensee), allocator),
			tier = tier,
			order = strings.clone(terms.order, allocator),
			issued = strings.clone(terms.issued, allocator),
		},
		.None
}

// tier_of is the tier name names, as a payload does.
tier_of :: proc(name: string) -> (Tier, bool) {
	for n, t in TIER_NAMES {
		if n == name {
			return t, true
		}
	}
	return {}, false
}

destroy :: proc(l: ^Licence, allocator := context.allocator) {
	delete(l.licensee, allocator)
	delete(l.order, allocator)
	delete(l.issued, allocator)
	l^ = {}
}

// path_beside is where the licence in use is kept: a file named licence in the
// folder that holds the history store at kept. "" when kept is.
path_beside :: proc(kept: string, allocator := context.allocator) -> string {
	if kept == "" {
		return ""
	}
	path, _ := filepath.join({filepath.dir(kept), "licence"}, allocator)
	return path
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
save :: proc(path, text: string) -> Error {
	if path == "" {
		return .Unwritable
	}
	if dir := filepath.dir(path); !os.exists(dir) {
		if os.make_directory_all(dir) != nil {
			return .Unwritable
		}
	}
	line := strings.concatenate({strings.trim_space(text), "\n"}, context.temp_allocator)
	if os.write_entire_file(path, transmute([]byte)line) != nil {
		return .Unwritable
	}
	return .None
}
