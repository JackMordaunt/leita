/*
Package fuzz checks search.fold and the ASCII advance path against bytes that
are not all valid UTF-8.

	fold   fold(fold(r)) == fold(r), including RUNE_ERROR
	ascii  an ASCII pattern's byte path agrees with the rune path

A case draws a short string from a fixed corpus, then breaks it. Nothing here
reads the disk or a package global: FOLD_BYTE stays as the package built it.
*/
package search_fuzz

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import harness "jm:fuzz"

import search ".."

// Case is the harness subject. This suite keeps no state: each promise is a
// pure function of the bytes it draws.
Case :: struct {}

// properties outlives suite: a Suite holds the slice, it does not copy it.
properties := []harness.Property(Case){{"fold", check_fold}, {"ascii", check_ascii}}

// CORPUS is this suite's regressions, relative to the repository root.
CORPUS :: "search/fuzz/corpus"

// INPUT_CAP is as long a text as a case may hand the folder. Past this the
// case is a generator bug, not a search bug.
INPUT_CAP :: 2048

suite :: proc() -> harness.Suite(Case) {
	return {name = "search", setup = setup, teardown = teardown, properties = properties}
}

run :: proc(opts := harness.Opts{}, allocator := context.allocator) -> harness.Report {
	return harness.run(suite(), opts, allocator)
}

setup :: proc() -> (Case, bool) {
	return {}, true
}

teardown :: proc(_: ^Case) {}

// seeds are the strings damage starts from. The fifth one is not UTF-8.
seeds := []string {
	"Resume",
	"Résumé",
	"src/Main.go",
	"ABC/def",
	"\xff\xfe",
	// Names from search_test.odin: the cases its folds and bracket matches
	// are written against, each a fold that is not a plain ASCII lower-casing.
	"Straße",
	"CV/RÉSUMÉ",
	"Núñez/Ñoño.txt",
	"Øresund",
	"Фотографии",
	"写真フォルダ/写真.jpg",
}

// check_fold: folding a rune twice is the same as folding it once, and the
// same for every rune of the drawn string.
check_fold :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	text, _ := harness.damage_text(src, seeds)
	if len(text) > INPUT_CAP {
		return fmt.tprintf("drew %d bytes, cap is %d", len(text), INPUT_CAP), false
	}
	exact := harness.boolean(src)
	if why, held := check_rune_fold(utf8.RUNE_ERROR, exact); !held {
		return why, false
	}
	for r in text {
		if why, held := check_rune_fold(r, exact); !held {
			return why, false
		}
	}
	once := fold_all(text, exact)
	twice := fold_all(once, exact)
	if once != twice {
		return fmt.tprintf("fold(fold(%q)) is %q", text, twice), false
	}
	return "", true
}

// check_ascii compares the two advance paths. The pattern stays ASCII, so the
// fast path is the one that runs; the slow path is the same pattern with that
// flag cleared. They must consume the same prefix of a text that may not be
// ASCII at all.
check_ascii :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	text, _ := harness.damage_text(src, seeds)
	if len(text) > INPUT_CAP {
		return fmt.tprintf("drew %d bytes, cap is %d", len(text), INPUT_CAP), false
	}
	term := "Resume" if harness.boolean(src) else "resume"
	fast := search.pattern_make(term)
	if !fast.ascii {
		return fmt.tprintf("pattern %q was not ASCII", term), false
	}
	slow := fast
	slow.ascii = false
	got := search.advance(&fast, 0, text)
	want := search.advance(&slow, 0, text)
	if got != want {
		return fmt.tprintf(
				"advance(%q, %q) is %d on the fast path and %d on the slow path",
				term,
				text,
				got,
				want,
			),
			false
	}
	return "", true
}

@(private)
check_rune_fold :: proc(r: rune, exact: bool) -> (detail: string, ok: bool) {
	once := search.fold(r, exact)
	twice := search.fold(once, exact)
	if once != twice {
		return fmt.tprintf("fold(fold(%U)) is %U, fold is %U", r, twice, once), false
	}
	return "", true
}

@(private)
fold_all :: proc(s: string, exact: bool) -> string {
	b := strings.builder_make()
	for r in s {
		buf, n := utf8.encode_rune(search.fold(r, exact))
		strings.write_bytes(&b, buf[:n])
	}
	return strings.to_string(b)
}
