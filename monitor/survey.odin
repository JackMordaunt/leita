package leita_monitor

import "core:fmt"
import "core:strings"
import "core:time"

import "../history"
import "../ntfs"
import "../report"
import "../scan"
import "../survey"
import "../walk"

/*
How the monitor reads a watched place: the scan the command line runs, through
scan.resolve and survey.fill_run, at the gentle pace, folded once at the end,
but kept between runs as the place's baseline (history.baseline_path). Each run
after the first updates the last tree from what the system says changed since,
and reads the place whole only when that cannot be trusted, saying why
(survey/update.odin). The baseline is named for the place as scan.location
resolves it, as the command line and the window name theirs, so all three share
one tree of a place; it stays when the place is no longer watched, as long as
the history beside it. This is the one place the monitor learns what a place
holds: whatever reads it hands back a Place_Scan whose tree and rollup
history.keep takes.
*/

// Place_Scan is a watched place as one scan of it found it. It is heap allocated
// by survey_place, since the reader holds pointers into it.
Place_Scan :: struct {
	path:     string, // as given
	place:    string, // what history keeps it under (history.place_of)
	engine:   scan.Engine,
	started:  time.Time,
	duration: time.Duration,
	space:    Maybe(report.Space),
	tree:     scan.Tree,
	roll:     survey.Rollup,
	fill:     survey.Fill,
	top:      u32,
	updated:  bool, // updated from the baseline rather than read whole
	why:      string, // why it was read whole, a constant from survey, "" for no reason given
	resolved: bool, // fill.target holds a target to destroy
	grown:    bool, // tree was initialised
}

/*
survey_place scans path to the end at the gentle pace, from its baseline beside
the history store at kept when it has one, keeping the result there, and returns
what it found, or nil and why not, in the temp allocator. The caller frees what it
found with place_scan_destroy. made_up is the day of a made-up disk to scan in
place of path, nil to scan path itself.
*/
//review:ignore odin-allocator-parameter a place's scan lives on the context allocator as before, freed by place_scan_destroy; only made_up is new
survey_place :: proc(
	path, kept: string,
	made_up: Maybe(int) = nil,
) -> (
	s: ^Place_Scan,
	problem: string,
) {
	s = new(Place_Scan)
	s.path = strings.clone(path)
	s.started = time.now()
	start := time.tick_now()

	target, choice, err := scan.resolve(path, made_up = made_up)
	if err != nil {
		place_scan_destroy(s)
		return nil, fmt.tprintf("cannot scan %s: %v", path, err)
	}
	s.resolved = true
	s.fill.target = target
	s.engine = choice.engine
	if choice.engine == .None {
		place_scan_destroy(s)
		return nil, "nothing here can be scanned"
	}
	s.fill.wcfg = walk.Config {
		media = target.media,
		pace  = .Gentle,
	}
	if tree_err := scan.tree_init(&s.tree, walk.width(s.fill.wcfg)); tree_err != nil {
		place_scan_destroy(s)
		return nil, "cannot make room for the scan"
	}
	s.grown = true
	s.roll.linked = true
	s.fill.engine = choice.engine
	s.fill.probe = choice.probe
	s.fill.opts = ntfs.Read_Options{}
	s.fill.tree = &s.tree
	s.fill.baseline = history.baseline_path(
		kept,
		scan.location(target, context.temp_allocator),
		context.temp_allocator,
	)
	survey.fill_run(&s.fill)
	s.engine = s.fill.engine
	s.updated = s.fill.how == .Updated
	s.why = s.fill.why
	s.duration = time.tick_since(start)
	if why := survey.problem(&s.fill); why != "" {
		place_scan_destroy(s)
		return nil, why
	}
	survey.rollup_advance(&s.roll, &s.tree)
	s.top = s.tree.root
	if s.top >= s.roll.seen || .Used not_in scan.node_flags(scan.node(&s.tree, s.top)) {
		place_scan_destroy(s)
		return nil, "the scan found nothing"
	}
	s.place = strings.clone(history.place_of(&s.tree, s.top, s.engine))
	s.space = report.space_of(&s.fill)
	return s, ""
}

// place_scan_destroy frees what survey_place made.
place_scan_destroy :: proc(s: ^Place_Scan) {
	if s == nil {
		return
	}
	survey.rollup_destroy(&s.roll)
	survey.fill_destroy(&s.fill)
	if s.grown {
		scan.tree_destroy(&s.tree)
	}
	if s.resolved {
		scan.target_destroy(&s.fill.target)
	}
	delete(s.path)
	delete(s.place)
	free(s)
}

// bytes is what the place held.
bytes :: proc(s: ^Place_Scan) -> u64 {
	return survey.total(&s.roll, s.top)
}
