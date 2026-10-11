package leita_app

import "core:strings"

import "../../licence"
import "../command"
import "../query"

/*
The licence, on the desk. The one in use is kept in a file beside the history
store and read once, at init; a licence the window offers is checked, and only
one that holds replaces it and is kept. Nothing here reaches past this machine:
licence.check needs only the public key leita was built with.

A licence kept that no longer checks, as after a build with another key, is
left on disk but not used, so a later build can still read it.
*/

// licence_open reads the licence kept at path, if there is one that checks
// against key; key nil means the one leita was built with.
licence_open :: proc(d: ^Desk, path: string, key: []byte) {
	d.licence_path = strings.clone(path)
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

licence_close :: proc(d: ^Desk) {
	licence.destroy(&d.licence)
	delete(d.licence_path)
	delete(d.licence_problem)
}

// add_licence checks the licence c offers, and uses and keeps it if it holds.
add_licence :: proc(d: ^Desk, c: ^command.Add_Licence) {
	d.licence_offered += 1
	delete(d.licence_problem)
	d.licence_problem = ""

	text := command.text_of(&c.text)
	if c.file {
		read, err := licence.read(text)
		if err != .None {
			d.licence_problem = strings.concatenate({"The licence ", licence.describe(err), "."})
			return
		}
		text = read
	}
	l, err := licence.check(text, d.licence_key)
	// Without a data folder to keep it in, it holds for this session only.
	if err == .None && d.licence_path != "" {
		err = licence.save(d.licence_path, text)
	}
	if err != .None {
		licence.destroy(&l)
		d.licence_problem = strings.concatenate({"The licence ", licence.describe(err), "."})
		return
	}
	licence.destroy(&d.licence)
	d.licence = l
	d.licensed = true
}

licence_answer :: proc(d: ^Desk) -> query.Licence_Result {
	r := query.Licence_Result {
		licensed = d.licensed,
		offered  = d.licence_offered,
		problem  = d.licence_problem,
	}
	if d.licensed {
		r.licensee = d.licence.licensee
		r.tier = licence.TIER_TITLES[d.licence.tier]
		r.order = d.licence.order
		r.issued = d.licence.issued
	}
	return r
}
