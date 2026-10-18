/*
Package search finds entries in a scan by a few typed characters, the way fzf
does: the term's characters must appear in order in an entry's path, not
necessarily together, and the matches are ranked by how well they line up. A
run of matched characters scores more than scattered ones, a match at the start
of a word or a path segment more than one inside it, and a match within the
entry's own name more than one spread along the directories above it.

The matching is modelled on fzf's (src/algo/algo.go in github.com/junegunn/fzf,
its v2 algorithm), not taken from it, and is tested on its own cases.

It works on whatever a scan has found so far (index.odin): each pass looks at
the entries found since the last, on as many threads as the caller gives it, and
a pass can be called off at any point. It knows nothing of the window.
*/
package search

import "core:unicode"
import "core:unicode/utf8"

// MAX_TERM is the most characters of a term matched; the rest are dropped.
MAX_TERM :: 64

// MAX_TEXT is the most characters of a text scored; a longer path is scored on
// its last MAX_TEXT, where its name is.
MAX_TEXT :: 512

/*
The scores, chosen after the values fzf's algo.go gives its path scheme
(github.com/junegunn/fzf, src/algo/algo.go, read 2026-10), not checked against
fzf's own output: a matched character is worth SCORE_MATCH, a gap costs GAP_START for its
first character and GAP_EXTENSION for each after, and a match where a word
starts earns a bonus, the most after a path separator, so a name or a folder
that starts with the term ranks first, then after a space or other punctuation; a lower-to-upper case change or a
digit after a non-digit earns BONUS_CAMEL. A run of matches keeps the bonus of
the character it started on, and the term's first character counts its bonus
twice.
*/
SCORE_MATCH              :: 16
GAP_START                :: -3
GAP_EXTENSION            :: -1
BONUS_BOUNDARY           :: SCORE_MATCH / 2
BONUS_NON_WORD           :: SCORE_MATCH / 2
BONUS_CAMEL              :: BONUS_BOUNDARY + GAP_EXTENSION
BONUS_CONSECUTIVE        :: -(GAP_START + GAP_EXTENSION)
BONUS_BOUNDARY_WHITE     :: BONUS_BOUNDARY
BONUS_BOUNDARY_DELIMITER :: BONUS_BOUNDARY + 1
BONUS_FIRST_MULTIPLIER   :: 2

// BONUS_MOST is the largest bonus a character can earn, as a run or alone.
BONUS_MOST :: max(
	BONUS_BOUNDARY,
	BONUS_NON_WORD,
	BONUS_CAMEL,
	BONUS_CONSECUTIVE,
	BONUS_BOUNDARY_WHITE,
	BONUS_BOUNDARY_DELIMITER,
)

// BONUS_NAME is what a match wholly inside an entry's own name earns over the
// same characters found along its path: worth more than any arrangement of
// bonuses, so a name that matches always ranks above a path that does.
BONUS_NAME :: SCORE_MATCH * 4

// Class is what a character is, for the bonus a match on it earns. A match on
// Delimiter or anything after it, part of a word, earns a word-start bonus.
Class :: enum u8 {
	Non_Word,
	White,
	Delimiter,
	Lower,
	Upper,
	Letter,
	Number,
}

// Pattern is a term made ready to match: its characters folded as the texts it
// is matched against will be. There is no literal mode, so accents always fold.
Pattern :: struct {
	runes: [MAX_TERM]rune,
	count: int,
	// Case matters only when the term has a capital in it, as fzf's smart case.
	exact: bool,
	// Every character is ASCII once folded, so a text can be matched a byte at a
	// time until it holds a character that is not.
	ascii: bool,
}

// pattern_make makes term ready to match. Spaces are dropped: a term is one run
// of characters, and a name with a space in it is found without typing it.
pattern_make :: proc(term: string) -> (p: Pattern) {
	p.ascii = true
	for r in term {
		if unicode.is_upper(r) {
			p.exact = true
		}
	}
	for r in term {
		if p.count == MAX_TERM {
			break
		}
		if r == ' ' || r == '\t' || r == utf8.RUNE_ERROR {
			continue
		}
		f := fold(r, p.exact)
		p.runes[p.count] = f
		p.count += 1
		if f >= utf8.RUNE_SELF {
			p.ascii = false
		}
	}
	return
}

/*
fold is r as matching compares it: lower case unless exact, either path
separator as a slash, so a term typed with / finds a Windows path, and a Latin
letter with a diacritic as its base letter (LATIN), as fzf folds it, so resume
finds Résumé.pdf and résumé finds Resume.pdf. Case is kept through the fold: É
is E, which exact tells from e.
*/
fold :: #force_inline proc(r: rune, exact: bool) -> rune {
	r := r
	if r >= utf8.RUNE_SELF {
		base := latin_base(r)
		if base == 0 {
			// Lowercase, then fold that letter, so a second fold does not
			// move again. Exact keeps the case of an ASCII base.
			lower := unicode.to_lower(r)
			base = latin_base(lower)
			if base == 0 {
				return r if exact else lower
			}
			if exact && base >= 'a' && base <= 'z' {
				base -= 'a' - 'A'
			}
		}
		r = rune(base)
	}
	if r == '\\' {
		return '/'
	}
	if !exact && r >= 'A' && r <= 'Z' {
		return r + ('a' - 'A')
	}
	return r
}

class_of :: proc(r: rune) -> Class {
	if r < utf8.RUNE_SELF {
		return ASCII_CLASS[r]
	}
	switch {
	case unicode.is_lower(r):
		return .Lower
	case unicode.is_upper(r):
		return .Upper
	case unicode.is_digit(r):
		return .Number
	case unicode.is_letter(r):
		return .Letter
	case unicode.is_space(r):
		return .White
	}
	return .Non_Word
}

// ASCII_CLASS is class_of for every ASCII character, as a table.
@(private, rodata)
ASCII_CLASS := #partial [utf8.RUNE_SELF]Class {
	' '  = .White,
	'\t' = .White,
	'\n' = .White,
	'\r' = .White,
	'/'  = .Delimiter,
	'\\' = .Delimiter,
	'0' ..= '9'     = .Number,
	'a' ..= 'z'     = .Lower,
	'A' ..= 'Z'     = .Upper,
}

// bonus_for is what a match on a character of class cur earns after one of
// class prev (fzf's bonusFor).
bonus_for :: proc(prev, cur: Class) -> i32 {
	if cur >= .Delimiter {
		#partial switch prev {
		case .White:
			return BONUS_BOUNDARY_WHITE
		case .Delimiter:
			return BONUS_BOUNDARY_DELIMITER
		case .Non_Word:
			return BONUS_BOUNDARY
		}
	}
	if prev == .Lower && cur == .Upper || prev != .Number && cur == .Number {
		return BONUS_CAMEL
	}
	#partial switch cur {
	case .Non_Word, .Delimiter:
		return BONUS_NON_WORD
	case .White:
		return BONUS_BOUNDARY_WHITE
	}
	return 0
}

/*
advance is how many of p's characters text takes, matching greedily from the
k-th: the first character of text that is p's k-th takes it, and so on. The
whole term is in text, in order, exactly when this reaches p.count, so it is
the cheap test every entry is put to before any is scored, and since it carries
on from k it can be run along a path a segment at a time.
*/
advance :: proc(p: ^Pattern, k: int, text: string) -> int {
	k := k
	if k >= p.count {
		return k
	}
	if p.ascii {
		// A byte at a time, each folded by a table, while the text is ASCII. A
		// byte past ASCII starts a character that is decoded and folded, since
		// a Latin letter with a diacritic may be one the term holds without it.
		fold_byte := &FOLD_BYTE[int(p.exact)]
		want := u8(p.runes[k])
		for i := 0; i < len(text); i += 1 {
			c := fold_byte[text[i]]
			if c == NOT_ASCII {
				r, size := utf8.decode_rune_in_string(text[i:])
				i += size - 1
				f := fold(r, p.exact)
				if f >= utf8.RUNE_SELF {
					continue
				}
				c = u8(f)
			}
			if c == want {
				k += 1
				if k == p.count {
					return k
				}
				want = u8(p.runes[k])
			}
		}
		return k
	}
	for r in text {
		if fold(r, p.exact) == p.runes[k] {
			k += 1
			if k == p.count {
				return k
			}
		}
	}
	return k
}

// NOT_ASCII is what FOLD_BYTE gives a byte that starts or continues a character
// past ASCII: no term's character, once folded to ASCII, is it.
@(private)
NOT_ASCII :: u8(utf8.RUNE_SELF)

// FOLD_BYTE is fold for every byte, as a table: the first as a term without a
// capital folds, the second as one with. A byte past ASCII is NOT_ASCII.
@(private)
FOLD_BYTE: [2][256]u8

@(private, init)
fold_byte_init :: proc "contextless" () {
	// As fold folds ASCII, which needs no context.
	for b in 0 ..< utf8.RUNE_SELF {
		c := u8(b)
		if c == '\\' {
			c = '/'
		}
		FOLD_BYTE[1][b] = c
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		FOLD_BYTE[0][b] = c
	}
	for b in utf8.RUNE_SELF ..< 256 {
		FOLD_BYTE[0][b], FOLD_BYTE[1][b] = NOT_ASCII, NOT_ASCII
	}
}

// matches is whether text holds the whole of p, in order.
matches :: proc(p: ^Pattern, text: string) -> bool {
	return advance(p, 0, text) == p.count
}

// Scratch is what scoring works in, kept by each thread that scores so a pass
// allocates nothing per entry. It is large, so it lives on the heap.
Scratch :: struct {
	text:   [MAX_TEXT]rune, // folded
	bonus:  [MAX_TEXT]i32,
	offset: [MAX_TEXT + 1]int, // byte offset of each character, and the end
	score:  [MAX_TERM][MAX_TEXT]i32,
	run:    [MAX_TERM][MAX_TEXT]u16, // matched characters in a row ending here
	from:   [MAX_TERM][MAX_TEXT]i16, // where the previous character matched
	at:     [MAX_TERM]int, // the positions matched, once traced back
	// A path being put together to be scored, a segment at a time.
	path:   [4096]u8,
	chain:  [64]u32,
}

// NONE is a score no match has.
@(private)
NONE :: min(i32) / 2

/*
score is how well text matches p, and where: the best-scoring placing of p's
characters in text, found as fzf's v2 algorithm finds it, by a Smith-Waterman
alignment with an affine gap, in O(len(p) * len(text)). ok is false when text does not
hold p. The positions are left in s.at as character indices, which s.offset
maps to bytes of text, for spans. A text longer than MAX_TEXT is scored on its
last MAX_TEXT characters.
*/
score :: proc(p: ^Pattern, text: string, s: ^Scratch) -> (total: i32, ok: bool) {
	m := p.count
	if m == 0 {
		return 0, true
	}
	n := load(s, text, p.exact)
	if n < m {
		return 0, false
	}
	for i in 0 ..< m {
		pc := p.runes[i]
		gapped, gapped_from := NONE, -1
		for j in 0 ..< n {
			// The best way to reach j with a gap before it: a match of the
			// previous character at j-2 or earlier, less the gap.
			if i > 0 && j >= 2 {
				if gapped != NONE {
					gapped += GAP_EXTENSION
				}
				if prev := s.score[i - 1][j - 2]; prev != NONE && prev + GAP_START >= gapped {
					gapped, gapped_from = prev + GAP_START, j - 2
				}
			}
			s.score[i][j], s.run[i][j], s.from[i][j] = NONE, 0, -1
			if s.text[j] != pc {
				continue
			}
			b := s.bonus[j]
			if i == 0 {
				s.score[0][j], s.run[0][j] = SCORE_MATCH + b * BONUS_FIRST_MULTIPLIER, 1
				continue
			}
			best, run, from := NONE, u16(0), -1
			if j >= 1 && s.score[i - 1][j - 1] != NONE {
				run = s.run[i - 1][j - 1] + 1
				// A run keeps the bonus of the character it started on, unless
				// this one starts a word worth more.
				first := s.bonus[j - int(run) + 1]
				if b >= BONUS_BOUNDARY && b > first {
					run = 1
				} else {
					b = max(b, BONUS_CONSECUTIVE, first)
				}
				best, from = s.score[i - 1][j - 1] + SCORE_MATCH + b, j - 1
			}
			if gapped != NONE {
				if g := gapped + SCORE_MATCH + s.bonus[j]; g > best {
					best, run, from = g, 1, gapped_from
				}
			}
			s.score[i][j], s.run[i][j], s.from[i][j] = best, run, i16(from)
		}
	}
	best, end := NONE, -1
	for j in 0 ..< n {
		// A tie goes to the later, nearer the name.
		if v := s.score[m - 1][j]; v >= best && v != NONE {
			best, end = v, j
		}
	}
	if end < 0 {
		return 0, false
	}
	j := end
	for i := m - 1; i >= 0; i -= 1 {
		s.at[i] = j
		j = int(s.from[i][j])
	}
	return best, true
}

// load puts text's last MAX_TEXT characters into s, folded, with each one's
// bonus and byte offset, and says how many there are.
@(private)
load :: proc(s: ^Scratch, text: string, exact: bool) -> int {
	start := 0
	if len(text) > MAX_TEXT {
		// Count back MAX_TEXT characters, so the name at the end is kept.
		count := 0
		start = len(text)
		for start > 0 && count < MAX_TEXT {
			start -= 1
			for start > 0 && text[start] & 0xC0 == 0x80 {
				start -= 1
			}
			count += 1
		}
	}
	n := 0
	prev := Class.Delimiter // the start of a text starts a segment
	for at := start; at < len(text) && n < MAX_TEXT; n += 1 {
		r := rune(text[at])
		size := 1
		c: Class
		if r < utf8.RUNE_SELF {
			// An ASCII character needs no decoding, and its class is a table's.
			c = ASCII_CLASS[r]
		} else {
			r, size = utf8.decode_rune_in_string(text[at:])
			c = class_of(r)
		}
		s.text[n] = fold(r, exact)
		s.bonus[n] = bonus_for(prev, c)
		s.offset[n] = at
		prev = c
		at += size
	}
	s.offset[n] = len(text)
	return n
}

// Span is a stretch of matched bytes, from up to but not including to.
Span :: struct {
	from, to: int,
}

/*
spans are the stretches of text the last score matched, each run of adjacent
characters one span, as byte offsets moved on by base. They go in allocator.
*/
spans :: proc(p: ^Pattern, s: ^Scratch, base: int, allocator := context.allocator) -> []Span {
	out := make([dynamic]Span, 0, p.count, allocator)
	for i in 0 ..< p.count {
		at := s.at[i]
		from, to := base + s.offset[at], base + s.offset[at + 1]
		if n := len(out); n > 0 && out[n - 1].to == from {
			out[n - 1].to = to
		} else {
			append(&out, Span{from, to})
		}
	}
	return out[:]
}
