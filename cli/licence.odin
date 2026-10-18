package leita_cli

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

import "../history"
import "../human"
import "../licence"
import "../settings"
import "../term"

/*
leita licence: the licence leita runs under, from the command line, for a
machine with no window, a server above all. A licence is kept where the window
keeps its own, beside the history store, so each sees what the other added.
LEITA_LICENCE holds one for a single run instead, as in a container, where
nothing is kept between runs.

A licence is the line beginning leita1., or the file from the receipt that
holds it. A licence key from the receipt is exchanged for its licence by the
window alone: the command line sends nothing anywhere.
*/

LICENCE_USAGE :: `leita licence — the licence leita runs under.

  leita licence             whose licence leita runs under, its tier, and that it does
                            not expire; without one, how long the trial has left
  leita licence add LICENCE check a licence and keep it beside leita's data, where
                            the window finds it too: the line beginning leita1., or
                            the file from your receipt that holds it
  leita licence remove      forget the licence kept here
  LEITA_LICENCE=LICENCE     run under LICENCE, the line, for one run in place of the
                            one kept: for a server or a container that keeps nothing

Reports, change tracking and scheduled scans need a licence once the 30-day trial
has ended; scanning never does. A licence does not expire.
`

// TIER_TITLES are the tiers as the command line names them, as the window does.
@(rodata)
TIER_TITLES := [licence.Tier]string {
	.Supporter  = "Supporter",
	.Office     = "Office, up to 10 people",
	.Team       = "Team, up to 50 people",
	.Site       = "Site",
	.Multi_Site = "Multi-site",
}

/*
Licence_Context is what leita licence works with: the history store the licence
is kept beside, what LEITA_LICENCE holds, the key licences are checked against,
nil for the one leita was built with, and the clock the trial is read by.
*/
Licence_Context :: struct {
	kept:  string,
	given: string,
	key:   []byte,
	now:   time.Time,
}

// licence_command_line runs leita licence on this machine, saying how it went
// on standard output, and returns the exit code.
licence_command_line :: proc(args: []string) -> int {
	mode, _ := term.parse_mode(os.get_env("LEITA_COLOR", context.temp_allocator))
	set_style(mode)
	c := Licence_Context {
		kept  = history.default_path(context.temp_allocator),
		given = os.get_env(licence.ENV, context.temp_allocator),
		now   = time.now(),
	}
	return licence_dispatch(c, args, os.to_writer(os.stdout))
}

// licence_dispatch carries out the leita licence command args names, saying how
// it went on w and what went wrong on standard error.
licence_dispatch :: proc(c: Licence_Context, args: []string, w: io.Writer) -> int {
	verb := args[0] if len(args) > 0 else ""
	switch {
	case verb == "-h" || verb == "--help":
		b := strings.builder_make(context.temp_allocator)
		term.write_usage(&b, style, "leita licence", LICENCE_USAGE)
		fmt.wprint(w, strings.to_string(b))
		return EXIT_OK
	case verb == "" && len(args) <= 1:
		return show_licence(c, w)
	case verb == "add" && len(args) == 2:
		return add_licence(c, args[1], w)
	case verb == "remove" && len(args) == 1:
		return remove_licence(c, w)
	}
	say_error("leita licence takes add LICENCE, remove, or nothing, not %q", strings.join(args, " ", context.temp_allocator))
	fmt.eprintln("leita licence -h lists what it takes")
	return EXIT_ERROR
}

// show_licence says whose licence leita runs under, or how long the trial has
// left without one. A licence there that does not check is an error.
@(private = "file")
show_licence :: proc(c: Licence_Context, w: io.Writer) -> int {
	l, from, err := licence.in_use(licence.path_beside(c.kept, context.temp_allocator), c.given, c.key)
	if err == .None && from != .None {
		licence_label(w, "licensed", "to %s", l.licensee)
		licence_label(w, "tier", "%s", TIER_TITLES[l.tier])
		licence_label(w, "order", "%s, issued %s", l.order, l.issued)
		licence_label(w, "expires", "never")
		if from == .Env {
			licence_label(w, "from", "%s, for this run", licence.ENV)
		}
		return EXIT_OK
	}
	if err != .None {
		if from == .Env {
			say_error("%s holds no licence this leita takes: %s", licence.ENV, licence.describe(err))
		} else {
			say_error("the licence kept here does not hold: %s", licence.describe(err))
		}
	}
	left := licence.days_left(settings.trial_began(c.kept, c.now), c.now)
	if left > 0 {
		fmt.wprintfln(
			w,
			"no licence; the trial of reports, change tracking and scheduled scans has %d %s left",
			left,
			"day" if left == 1 else "days",
		)
	} else {
		fmt.wprintln(
			w,
			"no licence, and the 30-day trial of reports, change tracking and scheduled scans has ended; leita licence add LICENCE adds one",
		)
	}
	return EXIT_ERROR if err != .None else EXIT_OK
}

// add_licence checks offered, a licence or the file holding one, and keeps it
// beside the history store for every run after.
@(private = "file")
add_licence :: proc(c: Licence_Context, offered: string, w: io.Writer) -> int {
	text := offered
	if os.is_file(offered) {
		read, err := licence.read(offered)
		if err != .None {
			say_error("%s", licence.describe(err))
			return EXIT_ERROR
		}
		text = read
	}
	text = strings.trim_space(text)
	if !strings.has_prefix(text, "leita") || !strings.contains_rune(text, '.') {
		say_error(
			"that is not a licence: give the line beginning leita1., or the file from your receipt that holds it; a licence key is exchanged for its licence in Leita, the window",
		)
		return EXIT_ERROR
	}
	path := licence.path_beside(c.kept, context.temp_allocator)
	if path == "" {
		say_error("no folder to keep leita's data in")
		return EXIT_ERROR
	}
	l, err := licence.keep(path, text, c.key, context.temp_allocator)
	if err != .None {
		say_error("%s", licence.describe(err))
		return EXIT_ERROR
	}
	fmt.wprintfln(w, "added the licence: licensed to %s, %s; it does not expire", human.shown(l.licensee), TIER_TITLES[l.tier])
	return EXIT_OK
}

// remove_licence forgets the licence kept beside the history store.
@(private = "file")
remove_licence :: proc(c: Licence_Context, w: io.Writer) -> int {
	was, err := licence.forget(licence.path_beside(c.kept, context.temp_allocator))
	switch {
	case err != .None:
		say_error("the licence kept here could not be removed")
		return EXIT_ERROR
	case !was:
		fmt.wprintln(w, "no licence is kept here")
	case:
		fmt.wprintln(w, "removed the licence kept here")
	}
	return EXIT_OK
}

// licence_label writes one line of what leita licence shows, as label does.
@(private = "file")
licence_label :: proc(w: io.Writer, name: string, format: string, args: ..any) {
	pad := strings.repeat(" ", max(LABEL - len(name), 0) + 1, context.temp_allocator)
	fmt.wprintfln(w, "%s%s%s", bold(name), pad, human.shown(fmt.tprintf(format, ..args)))
}
